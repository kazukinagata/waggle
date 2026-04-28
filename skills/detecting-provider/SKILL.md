---
name: detecting-provider
description: Detects the active data source provider and retrieves configuration (database IDs, constants). Internal shared skill — not for direct user invocation.
user-invocable: false
---

# Waggle — Provider Detection

Determine the execution environment, the active provider, and load its SKILL.md.
**Skip if already determined in this conversation.**

## Step 1: Environment Detection

Determine `execution_environment` ∈ {`cowork`, `claude-desktop`, `cli`}.
**Skip if already set in this conversation.**

Cowork is checked first because the Cowork host may also expose
`CLAUDE_CODE_ENTRYPOINT`. Detect Cowork via the **OR** of three signals — any
single positive answer means Cowork. The env-var signal is a legacy hint:
its **absence is not evidence against Cowork**, because Bash subshells in
Cowork run in an isolated sandbox that does not inherit host env vars.

Signals to check, in order:

1. **System prompt self-identification.** Inspect the active system prompt
   for an `<application_details>` block (or equivalent) that mentions
   "Cowork" — e.g. "Claude is powering Cowork mode, a feature of the Claude
   desktop app". This is the most authoritative signal.
2. **Cowork-specific MCP tools.** Check whether any tool whose name matches
   `mcp__cowork__*` or `mcp__cowork-onboarding__*` is available — either as
   a regular tool or as a deferred tool surfaced via system reminders /
   ToolSearch (e.g. `ToolSearch` with query `+cowork`).
3. **Legacy env var (best-effort).** Run `echo "$CLAUDE_CODE_IS_COWORK"` via
   Bash. A value of `"1"` is a positive hint. An empty result is **not**
   negative evidence — Cowork's sandboxed Bash typically returns empty even
   on Cowork.

Decision:

```
if any(signal_1, signal_2, signal_3):
    execution_environment = "cowork"
elif (bash) CLAUDE_CODE_ENTRYPOINT == "claude-desktop":
    execution_environment = "claude-desktop"
else:
    execution_environment = "cli"
```

When Cowork is detected, briefly note which signal fired (e.g. "Cowork
detected via system prompt" / "via mcp__cowork__* tools" / "via env var")
so misdetections can be diagnosed later.

| Environment | Parallel Execution | Session Type |
|---|---|---|
| `cowork` | Cowork agents | Cowork |
| `claude-desktop` | Scheduled Tasks | Claude Desktop |
| `cli` | tmux panes | Terminal CLI |

## Step 2: Determine Provider Discovery Method

Branch on the `execution_environment` set in Step 1:
- If `execution_environment == "cowork"` → Step 3A (Cowork skill discovery)
- Otherwise → Step 3B (CLI/Desktop plugin discovery)

## Step 3A: Skill Discovery — Cowork

Check `<available_skills>` in the system prompt for skill names matching:
- `notion-provider` → `active_provider = "notion"`
- `sqlite-provider` → `active_provider = "sqlite"`
- `turso-provider` → `active_provider = "turso"`

If 0 matches → Step 4 (no provider).
If 2+ matches → Step 5 (conflict resolution).
Otherwise → skip to Step 6.

## Step 3B: Plugin Discovery — CLI / Desktop

Read `~/.claude/plugins/installed_plugins.json` (via Bash: `cat ~/.claude/plugins/installed_plugins.json 2>/dev/null`) and find keys matching `waggle-notion@*`, `waggle-sqlite@*`, or `waggle-turso@*`:
- `waggle-notion` → `active_provider = "notion"`
- `waggle-sqlite` → `active_provider = "sqlite"`
- `waggle-turso` → `active_provider = "turso"`

Do NOT extract `installPath` or derive path variables — path resolution is handled by the Skill tool in Step 7.

If the file does not exist or no matches found → Step 4 (no provider).
If 2+ matches → Step 5 (conflict resolution).
Otherwise → skip to Step 6.

## Step 4: No Provider Found

Error — inform the user:
> "No waggle provider plugin found. Install one: waggle-notion, waggle-sqlite, or waggle-turso."

Then stop.

## Step 5: Conflict Resolution

If multiple provider plugins are detected:
1. Check `WAGGLE_PROVIDER` environment variable → use it if set
2. Otherwise, AskUserQuestion: "Multiple waggle providers detected: [list]. Which one should I use?"

## Step 6: Validate MCP Availability

Before loading the provider:
- **Notion**: verify `notion-*` MCP tools are available. If not → "waggle-notion is installed but Notion MCP server is not configured. Run 'setup notion' to configure."
- **Turso**: verify `TURSO_URL` and `TURSO_AUTH_TOKEN` env vars are set. If not → "TURSO_URL and TURSO_AUTH_TOKEN must be set. Run 'setup turso' to configure."
- **SQLite**: if `execution_environment == "cowork"` → "SQLite provider is not supported on Cowork (ephemeral environment). Use waggle-notion or waggle-turso instead."

## Step 7: Load Provider SKILL.md

Load the provider skill using the Skill tool:
- Notion: `waggle-notion:notion-provider`
- SQLite: `waggle-sqlite:sqlite-provider`
- Turso: `waggle-turso:turso-provider`

**REQUIRED — Load this skill now via the Skill tool.**

**Version skew detection:** After loading, if the provider SKILL.md content contains `PROVIDER_PLUGIN_ROOT`, warn the user:
> "Your provider plugin uses the deprecated PROVIDER_PLUGIN_ROOT variable. Please update to the latest version."

## Step 8: Config Retrieval

Retrieve database IDs and constants. **Skip if `headless_config` is already set in this conversation.**

Follow the active provider SKILL.md's Config Retrieval section to populate `headless_config`.
