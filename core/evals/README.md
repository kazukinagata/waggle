# waggle core evals

`claude plugin eval` cases for core skills. Not run in CI (each case is a full Claude run on your own
credential).

| Case | Tools in the session | Expected |
|---|---|---|
| `health-remote-connector-only` | uncapped `notion-query` on a remote connector whose server name is a UUID, plus the official connector | `health-checking`'s Notion query tool check probes it with `page_size`, passes, and names it |
| `health-extension-only` | the Desktop Extension's `notion-query`, plus the official connector | the check passes |
| `health-no-uncapped-tool` | only the official connector | the check warns, points to the Desktop Extension or a remote query connector, and does not probe `notion-query-data-sources` |

The cases load the `waggle-notion` provider as well, so run them from the repository root (a case may only
load plugins under the directory the eval is run against). On Linux / WSL, point `TMPDIR` outside `/tmp`:

```bash
mkdir -p "$HOME/.cache/claude-evaltmp"
TMPDIR="$HOME/.cache/claude-evaltmp" claude plugin eval . --eval-dir core/evals \
  --trust-plugin --runs 1 --ablation none --no-publish [--case <name>] --json <result>.json
```

Results are written under `core/evals/results/` (git-ignored).
