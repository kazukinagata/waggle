---
name: setting-up-tasks
description: >
  Guides initial setup of the waggle plugin — detects or configures
  MCP connections and runs provider-specific database initialization.
  Triggers on: "setup waggle", "initialize task management",
  "configure notion tasks", "configure data source",
  "タスク管理セットアップ", "タスク管理初期化".
---

# Waggle — Setup Guide

You are guiding the user through the initial setup of the waggle plugin.

## Step 1: Check for Existing MCP Configuration

Inspect available MCP tools to detect any already-configured providers:
- `notion-*` tools present → Notion MCP is already configured
- SQLite/database tools present → SQLite is already configured

### If a single provider MCP is already present
Use AskUserQuestion to confirm:
> "I detected an existing [provider] MCP connection. Would you like to set up waggle using [provider]?"

If yes, check if the corresponding provider plugin is installed (use the same discovery method as detecting-provider: check `~/.claude/plugins/installed_plugins.json` for `waggle-{provider}@*` keys, or `<available_skills>` for `{provider}-provider` in Cowork). If not installed → error:
> "The waggle-{provider} provider plugin is not installed. Install it first, then run setup again."

If installed, skip to Step 3 with that provider.

### If multiple provider MCPs are present
Use AskUserQuestion to ask which one to use:
> "I detected multiple data source MCPs: [list providers]. Which one should I set up waggle for?"

Then check if the corresponding provider plugin is installed (same discovery method as above). If not installed → error with install instructions. If installed, skip to Step 3 with the selected provider.

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

The provider plugin's setup skill handles all database creation and configuration.

If the provider plugin is installed, instruct the user:
> "Run 'setup {provider}' to initialize the {provider} provider."

The provider plugin's `{provider}-setup` skill is user-invocable and handles everything:
- Database/schema creation
- Config page creation (Notion) or config file generation
- Validation and testing

## Step 4: Daily Routine Scheduled Task Registration (Claude Desktop / Cowork)

After provider-specific setup completes, check the execution environment.

### Environment Check

Determine the environment:
1. If environment variable `CLAUDE_CODE_IS_COWORK` is `"1"` → Cowork (proceed)
2. If environment variable `CLAUDE_CODE_ENTRYPOINT` is `claude-desktop` → Claude Desktop (proceed)
3. Otherwise → Terminal CLI (skip this step entirely)

### Prompt User

Use AskUserQuestion:
> "Would you like to register a daily routine that ingests messages into tasks and guides you through task refinement and execution every morning?"

If the user declines, skip this step.

### Ask Preferred Time

If yes, use AskUserQuestion:
> "What time should the daily routine run? (default: 09:00)"

Accept the user's answer or default to 09:00.

### Ask Custom Routine Options

Use AskUserQuestion (multiSelect) to ask:
> "Would you like to add any of the following to your daily routine?"
> - "Ingest from additional messaging tools (e.g., Google Chat, Discord)"
> - "Check a spreadsheet for new tasks"
> - "Run a custom step before/after message intake"

#### If the user selects nothing

Use the default prompt: `Run the running-daily-tasks skill`

#### If the user selects one or more options

Ask follow-up questions for each selected option using AskUserQuestion:

- **Additional messaging tools** → "Which messaging tools should be checked? (e.g., Google Chat, Discord)"
- **Spreadsheet** → "Which spreadsheet should be scanned? (provide a name or URL)"
- **Custom step** → "Describe the custom step you'd like to add (free-text):"

Then build the prompt by appending additional instructions to the base prompt:

```
Run the running-daily-tasks skill.

Additional instructions for this daily routine:
- <instruction derived from each selected option>
```

Example with two options selected:
```
Run the running-daily-tasks skill.

Additional instructions for this daily routine:
- After message intake, also check Google Chat DMs for the past 24 hours and create tasks from actionable messages.
- Before task refinement, scan the "Sprint Tracker" spreadsheet for new rows and create corresponding Backlog tasks.
```

### Create Scheduled Task

Call `mcp__scheduled-tasks__create_scheduled_task`:
- `taskId`: `daily-tasks-<current_user_name_slug>` (see Slug Generation Rules below)
- `prompt`: The constructed prompt string from the previous step
- `description`: `waggle: Daily routine for <user_name>`
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
