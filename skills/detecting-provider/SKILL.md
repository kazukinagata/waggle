---
name: detecting-provider
description: Detects the active data source provider and retrieves configuration (database IDs, constants). Internal shared skill — not for direct user invocation.
user-invocable: false
---

# Waggle — Provider Detection

Determine the active provider and load its SKILL.md.
**Skip if already determined in this conversation.**

## Step 1: Determine Discovery Method

Check `CLAUDE_CODE_IS_COWORK` environment variable (via Bash: `echo "$CLAUDE_CODE_IS_COWORK"`):
- If `"1"` → use Step 2A (Cowork skill discovery)
- Otherwise → use Step 2B (CLI/Desktop plugin discovery)

## Step 2A: Skill Discovery — Cowork

Check `<available_skills>` in the system prompt for skill names matching:
- `notion-provider` → `active_provider = "notion"`
- `sqlite-provider` → `active_provider = "sqlite"`
- `turso-provider` → `active_provider = "turso"`

If 0 matches → Step 3 (no provider).
If 2+ matches → Step 4 (conflict resolution).
Otherwise → skip to Step 5.

## Step 2B: Plugin Discovery — CLI / Desktop

Read `~/.claude/plugins/installed_plugins.json` (via Bash: `cat ~/.claude/plugins/installed_plugins.json 2>/dev/null`) and find keys matching `waggle-notion@*`, `waggle-sqlite@*`, or `waggle-turso@*`:
- `waggle-notion` → `active_provider = "notion"`
- `waggle-sqlite` → `active_provider = "sqlite"`
- `waggle-turso` → `active_provider = "turso"`

Do NOT extract `installPath` or derive path variables — path resolution is handled by the Skill tool in Step 6.

If the file does not exist or no matches found → Step 3 (no provider).
If 2+ matches → Step 4 (conflict resolution).
Otherwise → skip to Step 5.

## Step 3: No Provider Found

Error — inform the user:
> "No waggle provider plugin found. Install one: waggle-notion, waggle-sqlite, or waggle-turso."

Then stop.

## Step 4: Conflict Resolution

If multiple provider plugins are detected:
1. Check `WAGGLE_PROVIDER` environment variable → use it if set
2. Otherwise, AskUserQuestion: "Multiple waggle providers detected: [list]. Which one should I use?"

## Step 5: Validate MCP Availability

Before loading the provider:
- **Notion**: verify `notion-*` MCP tools are available. If not → "waggle-notion is installed but Notion MCP server is not configured. Run 'setup notion' to configure."
- **Turso**: verify `TURSO_URL` and `TURSO_AUTH_TOKEN` env vars are set. If not → "TURSO_URL and TURSO_AUTH_TOKEN must be set. Run 'setup turso' to configure."
- **SQLite**: if `CLAUDE_CODE_IS_COWORK` = `"1"` → "SQLite provider is not supported on Cowork (ephemeral environment). Use waggle-notion or waggle-turso instead."

## Step 6: Load Provider SKILL.md

Load the provider skill using the Skill tool:
- Notion: `waggle-notion:notion-provider`
- SQLite: `waggle-sqlite:sqlite-provider`
- Turso: `waggle-turso:turso-provider`

**REQUIRED — Load this skill now via the Skill tool.**

**Version skew detection:** After loading, if the provider SKILL.md content contains `PROVIDER_PLUGIN_ROOT`, warn the user:
> "Your provider plugin uses the deprecated PROVIDER_PLUGIN_ROOT variable. Please update to the latest version."

## Step 7: Environment Detection

Determine the execution environment. **Skip if already set in this conversation.**

Detection logic:
1. If environment variable `CLAUDE_CODE_IS_COWORK` is `"1"` (and `CLAUDE_CODE_ENTRYPOINT` is `local-agent`) → `execution_environment = "cowork"`
2. If environment variable `CLAUDE_CODE_ENTRYPOINT` is `claude-desktop` → `execution_environment = "claude-desktop"`
3. Otherwise → `execution_environment = "cli"`

| Environment | Parallel Execution | Session Type |
|---|---|---|
| `cowork` | Cowork agents | Cowork |
| `claude-desktop` | Scheduled Tasks | Claude Desktop |
| `cli` | tmux panes | Terminal CLI |

## Step 8: Config Retrieval

Retrieve database IDs and constants. **Skip if `headless_config` is already set in this conversation.**

Follow the active provider SKILL.md's Config Retrieval section to populate `headless_config`.

