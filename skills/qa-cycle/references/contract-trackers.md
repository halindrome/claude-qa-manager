# Contract trackers

SKILL.md Step 0.5 resolves the contract from a ticket when one can be found. Which
tracker holds the ticket, what a reference to it looks like, and who fetches it are
decided by preflight and reported under `contract` in `preflight.json`.

## Choosing the tracker

`contract.tracker` in config, default `auto`:

| value | ticket references | fetched by |
|---|---|---|
| `jira` | ids matching `contract.ticket_pattern` (default `[A-Z]+-[0-9]+`) in the MR title and description, minus key-shaped non-tickets (`HTTP-400`, `SHA-256`, `CVE-2024`, …) | the orchestrator, `mcp__jira__jira_get` |
| `forge` | `#N` and `…/issues/N` in the MR title and description | preflight, through `forge_view_issue` (GitHub or GitLab issues, using the forge CLI already authenticated) |
| `none` | not looked for | nobody — the contract is always synthesized from the MR |
| `auto` | — | resolves to `jira` when an MCP server or plugin named `jira` is registered, otherwise `forge` |

`preflight.json` reports the resolved value in `contract.tracker` and how it was
chosen in `contract.tracker_source` (`auto` | `config`). A Jira MCP registered under
another name is not detected by `auto`: set `contract.tracker` to `jira`.

An unrecognised `contract.tracker` raises `unknown_contract_tracker` and runs with no
lookup; a `ticket_pattern` that is not a valid extended regex raises
`invalid_ticket_pattern` and the default pattern is used. Neither degrades silently.

## Forge references

- `#N` counts when not preceded by a word character, `/`, `&` or `!`, so
  cross-project references (`group/project#12`), HTML entities (`&#123;`) and GitLab
  merge-request references (`!12`) are not taken for this project's issues.
- At most five references are fetched, title references first.
- Fetched issues are written to `contract.tickets_path` as an array of
  `{number, title, state, description, url}`. Acceptance criteria live in the issue
  description; extract them as you would from a ticket's description field.
- On GitHub `#N` may be a pull request; `gh issue view` refuses one, so it lands in
  `contract.unfetched`. That is expected when an MR description links other PRs.
- When references exist and NONE could be fetched, preflight warns
  `contract_tickets_unfetched`, and Step 0.5 records `contract_source=ticket-unfetched`.

## Contract source values

| `contract_source` | meaning |
|---|---|
| `jira:<ID>` / `forge:#<N>` | the ticket the user confirmed |
| `<tracker>:<ID> (auto: sole candidate)` | the only candidate that resolved, used without asking |
| `ticket-unfetched:<IDs>` | references existed but none could be fetched; the contract was synthesized and the round note says so |
| `synthesized` | no ticket referenced (or the user declined every candidate) |
