# waggle-notion evals

`claude plugin eval` cases for the `notion-provider` skill's tool selection. They are not run in CI (each
case is a full Claude run on your own credential); run them when you change how the provider chooses a
Notion tool.

## What they check

| Case | Tools in the session | Expected |
|---|---|---|
| `query-prefers-uncapped` | uncapped `notion-query` on a remote connector whose server name is a UUID, plus the official connector | the uncapped tool is used with `page_size`; the official `notion-query-data-sources` and `notion-search` are never called |
| `query-permission-falls-back-to-official` | the same, but the uncapped tool returns a permission error (HTTP 403, in Japanese — the wording a real remote connector uses) | the official data-source query is used, and the error text is relayed to the user |
| `query-auth-error-falls-back-to-official` | the same, but the uncapped tool returns an authentication error (HTTP 401, asking to reconnect; no word for permission) | treated as an access error: the official data-source query is used, and the error text is relayed |
| `query-permission-prefers-extension` | the remote connector returns a permission error, the Desktop Extension's `notion-query` works, plus the official connector | the Desktop Extension is used; the official data-source query is never called |

`mocks/` holds the suite-wide stand-ins (the remote connector and the official connector); a case overrides a
file by placing one with the same path under `<case>/mocks/`.

## Running

On Linux / WSL, point `TMPDIR` outside `/tmp` (the child Claude's sandbox denies writes under `/tmp`):

```bash
mkdir -p "$HOME/.cache/claude-evaltmp"
TMPDIR="$HOME/.cache/claude-evaltmp" claude plugin eval providers/notion \
  --trust-plugin --runs 1 --ablation none --no-publish [--case <name>] --json <result>.json
```

Results are written under `providers/notion/evals/results/` (git-ignored).
