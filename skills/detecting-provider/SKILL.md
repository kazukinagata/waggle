---
name: detecting-provider
description: Detects the active data source provider and retrieves configuration (database IDs, constants). Internal shared skill — not for direct user invocation.
user-invocable: false
---

# Waggle — Provider Detection

Determine the active provider using the following layered check.
**Skip if already determined in this conversation.**

## Layer 1: Config File Detection

Check for `~/.waggle/config.json` (via Bash: `cat ~/.waggle/config.json 2>/dev/null`):

1. If the file exists and contains `"provider"`:
   - `"provider": "notion"` → `active_provider = "notion"`
   - `"provider": "sqlite"` → `active_provider = "sqlite"`
   - `"provider": "turso"` → `active_provider = "turso"`
   - **REQUIRED — Read `${CLAUDE_PLUGIN_ROOT}/skills/providers/{active_provider}/SKILL.md` now.**

2. Alternatively, if `TURSO_URL` environment variable is set:
   - `active_provider = "turso"`
   - **REQUIRED — Read the corresponding provider SKILL.md.**

## Layer 2: MCP Tool Auto-Detection (fallback)

If no config file was found, inspect available MCP tools:
- `notion-*` tools present → `active_provider = "notion"`

If detected, **REQUIRED — Read the corresponding provider SKILL.md.**
This file contains query method selection logic and data operation procedures.

## Layer 3: Conflict Resolution
If multiple provider MCPs are detected, determine the environment:
- Check `env.WAGGLE_PROVIDER` in `~/.claude/settings.json`

If a value is found, use it as active_provider. **REQUIRED — Read the corresponding provider SKILL.md** (same instruction as Layer 2).

## Layer 4: Ask User
If provider is still undetermined, use AskUserQuestion:
> "Multiple data source MCPs are available. Which provider should I use for waggle? Available: [list detected providers]"

## No Provider Detected
If no provider is found via MCP tools or config file, inform the user they need to run the **setting-up-tasks** skill first to configure a data source, then stop.

## Environment Detection

After detecting the provider, also determine the execution environment and set `execution_environment` as a conversation context variable.
**Skip if already set in this conversation.**

Detection logic:
1. If environment variable `CLAUDE_CODE_ENTRYPOINT` is `claude-desktop` → `execution_environment = "claude-desktop"`
2. Otherwise → `execution_environment = "cli"`

This value is used by downstream skills (executing-tasks, managing-tasks, etc.) for execution flow branching.

| Environment | Parallel Execution | Session Type |
|---|---|---|
| `claude-desktop` | Scheduled Tasks | Claude Desktop |
| `cli` | tmux panes | Terminal CLI |

## Config Retrieval

After detecting the provider, retrieve database IDs and constants from the Config page.
**Skip if `headless_config` is already set in this conversation.**

Follow the active provider SKILL.md's Config Retrieval section to populate `headless_config`.

For all providers, config can be read from `~/.waggle/config.json` and stored in `headless_config`. The provider SKILL.md Config Retrieval section has the details.

## Constants

Constants shared across skills. All skills that go through detecting-provider reference these values.

| Constant | Value | Purpose |
|--------|-----|------|
| `stallThresholdMultiplier` | 4 | Stall detection: elapsed hours > Complexity Score × this value |
| `stallDefaultHours` | 24 | Default stall threshold (hours) when Complexity Score is not set |
