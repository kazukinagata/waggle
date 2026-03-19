---
name: setting-up-tasks
description: >
  Guides initial setup of the Agentic Tasks plugin — detects or configures
  MCP connections and runs provider-specific database initialization.
  Triggers on: "setup agentic tasks", "initialize task management",
  "configure notion tasks", "configure data source",
  "タスク管理セットアップ", "タスク管理初期化".
---

# Agentic Tasks — Setup Guide

You are guiding the user through the initial setup of the Agentic Tasks plugin.

## Step 1: Check for Existing MCP Configuration

Inspect available MCP tools to detect any already-configured providers:
- `notion-*` tools present → Notion MCP is already configured
- `mcp__airtable__*` tools present → Airtable MCP is already configured
- SQLite/database tools present → SQLite is already configured

### If a single provider MCP is already present
Use AskUserQuestion to confirm:
> "I detected an existing [provider] MCP connection. Would you like to set up Agentic Tasks using [provider]?"

If yes, skip to Step 3 with that provider.

### If multiple provider MCPs are present
Use AskUserQuestion to ask which one to use:
> "I detected multiple data source MCPs: [list providers]. Which one should I set up Agentic Tasks for?"

Then skip to Step 3 with the selected provider.

### If `~/.waggle/config.json` exists with a `"provider"` field
The provider is already configured. Skip to Step 3 with that provider as the active provider.

### If no provider MCP is present
Continue to Step 2 to guide the user through MCP setup.

## Step 2: Choose a Data Source and Configure MCP

Use AskUserQuestion to ask which data source the user wants to use:
> "Which data source would you like to use for waggle?
> - **SQLite** — instant local setup, zero external dependencies
> - **Notion** — team collaboration via Notion workspace
> - **Turso** — remote SQLite for multi-agent sync (requires Turso account)"

Then guide MCP setup based on the environment:

### Determining the Environment

- **Terminal CLI**: `~/.claude/settings.json` exists or `CLAUDE_PLUGIN_ROOT` is set
- **Claude Desktop**: Global Instructions / CLAUDE.md is accessible from the current context

### Claude Code — MCP Setup Instructions

Add the following to `~/.claude/settings.json` under `"mcpServers"`:

**Notion:**
```json
"notion": {
  "type": "http",
  "url": "https://mcp.notion.com/mcp"
}
```

After adding, authenticate by visiting `https://mcp.notion.com/mcp` in a browser and following the OAuth flow. Then restart Claude Code and run the setup skill again.

### Claude Desktop — MCP Setup Instructions

**Notion:**
Open Claude Desktop settings → MCP Servers → Add Server → Enter `https://mcp.notion.com/mcp`.
Authenticate with your Notion account when prompted. Then run the setup skill again.

### SQLite — No MCP Required

SQLite requires no external MCP server. Proceed directly to Step 3.

## Step 3: Run Provider-Specific Setup

Once the active provider is confirmed, load and follow:

```
${CLAUDE_PLUGIN_ROOT}/skills/providers/{active_provider}/setup.md
```

This file contains all provider-specific database creation, schema initialization, and verification steps.

## Step 4: Daily Routine Scheduled Task Registration (Claude Desktop only)

After provider-specific setup completes, check the execution environment.

### Environment Check

Determine the environment:
1. If environment variable `CLAUDE_CODE_ENTRYPOINT` is `claude-desktop` → Claude Desktop
2. Otherwise → Terminal CLI (skip this step entirely)

### Prompt User

Use AskUserQuestion:
> "Would you like to register a daily routine that ingests messages into tasks and guides you through task refinement and execution every morning?"

If the user declines, skip this step.

### Ask Preferred Time

If yes, use AskUserQuestion:
> "What time should the daily routine run? (default: 09:00)"

Accept the user's answer or default to 09:00.

### Create Scheduled Task

Call `mcp__scheduled-tasks__create_scheduled_task`:
- `taskId`: `daily-tasks-<current_user_name_slug>` (see Slug Generation Rules below)
- `prompt`: `Run the running-daily-tasks skill`
- `description`: `Agentic Tasks: Daily routine for <user_name>`
- `cronExpression`: `0 <HH> * * *` (based on user's chosen time, e.g. `0 9 * * *` for 09:00)

### Slug Generation Rules

To generate `<current_user_name_slug>` from the user's display name:

1. Lowercase the text
2. Replace non-alphanumeric characters with hyphens
3. Collapse consecutive hyphens
4. Trim leading/trailing hyphens
5. Truncate to 30 characters (break at hyphen boundary if possible)

Example: "Taro Yamada" → `taro-yamada`

### Report

```
Daily routine registered: runs every day at <HH:MM>.
Scheduled Task ID: daily-tasks-<user_name_slug>
To modify: Claude Desktop → Scheduled Tasks
```

## Language

Always communicate with the user in the language they are using.
