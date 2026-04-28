---
name: setting-up-tasks
description: >
  Guides initial setup of the waggle plugin — detects or configures
  MCP connections and runs provider-specific database initialization.
  Use this skill whenever the user wants to set up, initialize, or configure
  waggle for the first time, or connect a new data source provider.
  Triggers on: "setup waggle", "initialize task management",
  "configure notion tasks", "configure data source", "get started with waggle",
  "first-time setup", "connect provider".
user-invocable: true
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

If yes, check if the corresponding provider plugin is installed. This skill cannot delegate to `detecting-provider` because it runs *before* a provider exists (detecting-provider would error with "No waggle provider plugin found" and stop the setup flow).

First, decide which discovery source to inspect by detecting Cowork via the same multi-signal OR used by `detecting-provider` — Cowork iff **any** of:
1. The active system prompt mentions "Cowork" (e.g. an `<application_details>` block stating "Claude is powering Cowork mode")
2. A tool whose name matches `mcp__cowork__*` or `mcp__cowork-onboarding__*` is available
3. `echo "$CLAUDE_CODE_IS_COWORK"` returns `"1"` (legacy hint; absence is not evidence against Cowork because Bash subshells in Cowork are sandboxed)

Then branch:
- If Cowork → look in `<available_skills>` for `{provider}-provider`
- Otherwise → read `~/.claude/plugins/installed_plugins.json` for `waggle-{provider}@*`

If not installed → error:
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

## Step 3.5: Custom Intake Source Configuration

Configure additional sources for the message intake skill. This step runs for all environments.

### Prompt User

Use AskUserQuestion (multiSelect) to ask:
> "The message intake skill reads from Slack/Teams/Discord by default. Would you like to also ingest from additional sources?"
> - "Additional messaging tools (e.g., Google Chat, Discord)"
> - "Spreadsheet to scan for new tasks"
> - "Other task management system (e.g., Jira, Linear)"
> - "Custom processing step (free-text)"

If the user selects none or says "skip", proceed to Step 4.

### Collect Details

For each selected option, ask follow-up questions using AskUserQuestion:

- **Messaging tools** → "Which tool? How should it be accessed (MCP tool name, API, etc.)?"
- **Spreadsheet** → "Which spreadsheet? (name or URL) Which columns/rows indicate new tasks?"
- **Task system** → "Which system? What filter criteria? How to access (MCP tools, API)?"
- **Custom step** → "Describe what should happen and when (before/after standard intake):"

Compose the answers into natural language instructions that the `ingesting-messages` skill will follow at runtime.

Example:
```
# Custom Intake Sources

## Google Chat
After standard messaging intake, check Google Chat DMs for the past 24 hours using google-chat MCP tools.
Create tasks from actionable messages using the same classification rules.

## Sprint Tracker Spreadsheet
Scan the "Sprint Tracker" Google Sheet (https://docs.google.com/...) for rows added in the past 24 hours.
Create each new row as a Backlog task with the row contents as the description.
```

### Save Instructions

Determine the environment (reuse `execution_environment` from detecting-provider):

#### CLI / Claude Desktop

Write the instructions to `~/.waggle/intake-prompt.md`:

Confirm to user:
> "Custom intake sources saved to `~/.waggle/intake-prompt.md`. The ingesting-messages skill will read this file each time it runs. You can edit the file directly to update your configuration."

#### Cowork

Since Cowork has an ephemeral filesystem, output the instructions as a block the user must paste into their Global Instructions:

> "Cowork does not have a persistent filesystem. Please add the following to your Global Instructions so it's available in every session:"
>
> ```
> <waggle-custom-intake>
> {composed instructions}
> </waggle-custom-intake>
> ```

## Step 3.6: Custom Task-Creation Rules

Collect business-logic rules for how new tasks should be created — for example, tag naming conventions, tag assignment per category, default priority rules, or how Acceptance Criteria should be phrased. These rules are applied by `managing-tasks`, `ingesting-messages`, and `planning-tasks` whenever they create or plan a task.

This is independent of Step 3.5 (custom intake sources). A user may configure one, both, or neither.

### Prompt User

Use AskUserQuestion:
> "Do you want to define project-specific rules for how waggle creates tasks? Examples: required tags, tag operation rules, default priorities, AC phrasing style. You can skip this and configure it later by editing `~/.waggle/task-creation-prompt.md`."

If the user skips, proceed to Step 4.

### Collect Rules

Ask follow-up questions via AskUserQuestion to capture:
- **Tag rules**: required tags, naming conventions, category → tag mapping
- **Priority rules**: when to default to Urgent / High / Medium / Low
- **Assignee defaults**: any rules for routing tasks to specific members
- **AC / Execution Plan style**: e.g. "AC must use Given/When/Then"

Compose the answers into natural language instructions.

Example:
```
# Custom Task-Creation Rules

## Tags
- All tasks in the `frontend/` directory must include the `frontend` tag.
- Security-related tasks (mentioning CVE, vulnerability, auth bypass) must include `security`.

## Priority
- Tasks mentioning production incidents or customer escalations default to Urgent.
- Tasks blocked on external vendors default to Low.

## Acceptance Criteria style
- Use Given/When/Then format for all user-facing feature tasks.
- Always include at least one testable criterion with a command or metric.
```

### Save Rules

Determine the environment (reuse `execution_environment` from detecting-provider):

#### CLI / Claude Desktop

Write the rules to `~/.waggle/task-creation-prompt.md`. Keep the file under **10 KB** — the loader rejects anything larger. Do not paste text from untrusted sources into this file; it is concatenated into agent prompts and carries prompt-injection risk.

Confirm to user:
> "Custom task-creation rules saved to `~/.waggle/task-creation-prompt.md`. The managing-tasks, ingesting-messages, and planning-tasks skills will read this file each time they run. You can edit the file directly to update your rules. **Security note**: this file is trusted input — only put rules you authored yourself, and keep the file under 10 KB."

#### Cowork

Since Cowork has an ephemeral filesystem, output the rules as a block the user must paste into their Global Instructions:

> "Cowork does not have a persistent filesystem. Please add the following to your Global Instructions so it's available in every session. Only paste rules you authored yourself — this text is concatenated directly into agent prompts."
>
> ```
> <waggle-custom-task-creation>
> {composed rules}
> </waggle-custom-task-creation>
> ```

