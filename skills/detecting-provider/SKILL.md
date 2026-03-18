---
name: detecting-provider
description: Detects the active data source provider and retrieves configuration (database IDs, constants). Internal shared skill — not for direct user invocation.
user-invocable: false
---

# Agentic Tasks — Provider Detection

Determine the active provider using the following layered check.
**Skip if already determined in this conversation.**

## Layer 1: MCP Tool Auto-Detection
Inspect which MCP tools are available:
- `notion-*` tools present → active_provider = **notion**
- `mcp__airtable__*` tools present → active_provider = **airtable**
- SQLite/database tools present → active_provider = **sqlite**

If exactly one provider MCP is detected, use it.

**REQUIRED — Read `${CLAUDE_PLUGIN_ROOT}/skills/providers/{active_provider}/SKILL.md` now.**
This file contains query method selection logic (Query Path Detection) and data operation procedures.
Skipping this step causes incorrect query paths and suboptimal performance.
Do NOT use MCP search/fetch tools for task queries until you have read the provider SKILL.md.

## Layer 2: Conflict Resolution (multiple provider MCPs detected)
If multiple provider MCPs are detected, determine the environment:
- Check `env.AGENTIC_TASKS_PROVIDER` in `~/.claude/settings.json`

If a value is found, use it as active_provider. **REQUIRED — Read the corresponding provider SKILL.md** (same instruction as Layer 1).

## Layer 3: Ask User
If provider is still undetermined, use AskUserQuestion:
> "Multiple data source MCPs are available. Which provider should I use for agentic-tasks? Available: [list detected providers]"

## No MCP Detected
If no provider MCP is found at all, inform the user they need to run the **setting-up-tasks** skill first to configure a data source, then stop.

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

## Constants

Constants shared across skills. All skills that go through detecting-provider reference these values.

| Constant | Value | Purpose |
|--------|-----|------|
| `stallThresholdMultiplier` | 4 | Stall detection: elapsed hours > Complexity Score × this value |
| `stallDefaultHours` | 24 | Default stall threshold (hours) when Complexity Score is not set |
