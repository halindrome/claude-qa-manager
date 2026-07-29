#!/usr/bin/env bash
# do-reviewer.sh — thin shim over gemma-reviewer.sh that runs the same
# second-opinion MR QA review against DigitalOcean's serverless inference
# (https://inference.do-ai.run/v1/), which exposes an OpenAI-compatible
# chat-completions endpoint and a multi-vendor model catalog
# (Anthropic, OpenAI, DeepSeek, Kimi, Llama, Qwen, etc.).
#
# Default model: deepseek-v4-pro
#   1M context, distinct training lineage from Claude, code-strong,
#   ~$0.12 per typical MR review round at DO list pricing.
#
# Why a shim instead of a separate implementation:
# gemma-reviewer.sh already supports --model + --endpoint override and now
# accepts a bearer token via $LLM_API_KEY, so swapping endpoint+model+auth
# is sufficient. Post-processing rewrites "[gemma]" tags to "[do]" so the
# SKILL.md tag-merger stays unambiguous about which reviewer produced which
# finding. See gemma-reviewer.sh for the underlying chat-completions logic.

set -euo pipefail

# -------- defaults --------
DO_INFERENCE_URL="${DO_INFERENCE_URL:-https://inference.do-ai.run/v1/chat/completions}"
DO_MODEL="${DO_MODEL:-deepseek-v4-pro}"

# Hosted reasoning/MoE models behave like Qwen3 locally: large prompts plus
# reasoning tokens can exhaust an 8192 ceiling. DeepSeek V4 Pro advertises
# 1M context. Give the delegated call generous output room; the actual
# response will be far smaller.
DO_MAX_TOKENS="${DO_MAX_TOKENS:-24000}"

# Hosted inference can be slow under load. Match the qwen-reviewer timeout.
DO_TIMEOUT="${DO_TIMEOUT:-1200}"

# -------- arg parsing --------
MR=""
TARGET=""
ROUND=""
CONTRACT_FILE=""
SKIP_CONTRACT_FLAG=""
OUTPUT=""
ENDPOINT_OVERRIDE=""
MODEL_OVERRIDE=""

usage() {
  cat >&2 <<'USAGE'
Usage: do-reviewer.sh --mr <N> --target <name> --round <N> \
           --contract-file <path> [--skip-contract] --output <path> \
           [--endpoint URL] [--model NAME]

Thin shim over gemma-reviewer.sh. Defaults --model to $DO_MODEL
(default: deepseek-v4-pro) and --endpoint to $DO_INFERENCE_URL
(default: https://inference.do-ai.run/v1/chat/completions).
Output tags are rewritten [gemma] -> [do].

Required env:
  DO_LLM_API_KEY  DigitalOcean inference bearer token

Optional env:
  DO_INFERENCE_URL  Chat-completions endpoint
  DO_MODEL          Model id from DO's serverless catalog
                    (e.g. deepseek-v4-pro, openai-gpt-5.3-codex,
                     anthropic-claude-4.6-sonnet, llama-4-maverick)
  DO_MAX_TOKENS     Output token ceiling (default: 24000)
  DO_TIMEOUT        curl --max-time seconds (default: 1200)

Exit codes: same as gemma-reviewer.sh (0 ok, 1 net, 2 empty, 3 endpoint err, 64 bad args).
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mr) MR="$2"; shift 2 ;;
    --target) TARGET="$2"; shift 2 ;;
    --round) ROUND="$2"; shift 2 ;;
    --contract-file) CONTRACT_FILE="$2"; shift 2 ;;
    --skip-contract) SKIP_CONTRACT_FLAG="--skip-contract"; shift 1 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --endpoint) ENDPOINT_OVERRIDE="$2"; shift 2 ;;
    --model) MODEL_OVERRIDE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 64 ;;
  esac
done

declare -A FLAG_NAME=(
  [MR]=--mr
  [TARGET]=--target
  [ROUND]=--round
  [CONTRACT_FILE]=--contract-file
  [OUTPUT]=--output
)
for v in MR TARGET ROUND CONTRACT_FILE OUTPUT; do
  if [[ -z "${!v:-}" ]]; then
    echo "Missing required arg: ${FLAG_NAME[$v]}" >&2
    usage; exit 64
  fi
done

if [[ -z "${DO_LLM_API_KEY:-}" ]]; then
  echo "[do] ERROR: DO_LLM_API_KEY env var is not set. Export the DigitalOcean serverless inference token before invoking this shim." >&2
  exit 64
fi

# Resolve effective model + endpoint
EFFECTIVE_MODEL="${MODEL_OVERRIDE:-$DO_MODEL}"
EFFECTIVE_ENDPOINT="${ENDPOINT_OVERRIDE:-$DO_INFERENCE_URL}"

# -------- canary --------
echo "[do] start ts=$(date -u +%Y-%m-%dT%H:%M:%SZ) mr=${MR} target=${TARGET} round=${ROUND} model=${EFFECTIVE_MODEL} endpoint=${EFFECTIVE_ENDPOINT}" >&2

TMP_OUT="$(mktemp)"
_do_cleanup() {
  local rc=$?
  rm -f "$TMP_OUT"
  echo "[do] end ts=$(date -u +%Y-%m-%dT%H:%M:%SZ) exit=${rc}" >&2
  return $rc
}
trap '_do_cleanup' EXIT

# Locate sibling gemma-reviewer.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEMMA="${SCRIPT_DIR}/gemma-reviewer.sh"
if [[ ! -x "$GEMMA" ]]; then
  echo "[do] ERROR: gemma-reviewer.sh not found or not executable at ${GEMMA}" >&2
  exit 1
fi

# Invoke gemma-reviewer.sh with our model + endpoint + bearer token,
# capturing its output to a temp file. Stderr (including gemma's canary)
# passes through.
set +e
LLM_API_KEY="$DO_LLM_API_KEY" \
MAX_TOKENS="$DO_MAX_TOKENS" \
LM_STUDIO_TIMEOUT="$DO_TIMEOUT" \
  "$GEMMA" \
    --mr "$MR" \
    --target "$TARGET" \
    --round "$ROUND" \
    --contract-file "$CONTRACT_FILE" \
    ${SKIP_CONTRACT_FLAG:+$SKIP_CONTRACT_FLAG} \
    --output "$TMP_OUT" \
    --endpoint "$EFFECTIVE_ENDPOINT" \
    --model "$EFFECTIVE_MODEL"
INNER_RC=$?
set -e

# Post-process: rewrite literal [gemma] -> [do:<model>] in the findings file
# so triple-review mode can distinguish between two DO-hosted reviewers
# (e.g. [do:deepseek-v4-pro] vs [do:openai-gpt-5.3-codex]) in the merged
# report. Then move to the caller-requested output path.
DO_TAG="[do:${EFFECTIVE_MODEL}]"
if [[ -s "$TMP_OUT" ]]; then
  sed "s/\[gemma\]/${DO_TAG}/g" "$TMP_OUT" > "${OUTPUT}" || {
    echo "[do] ERROR: failed to rewrite gemma->${DO_TAG} tags into ${OUTPUT}" >&2
    exit 1
  }
else
  # Inner wrapper produced an empty/missing file; mirror that to OUTPUT so
  # the caller sees the same emptiness the inner wrapper produced.
  : > "${OUTPUT}"
fi

exit "$INNER_RC"
