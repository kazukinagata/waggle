# Waggle — Notion Provider Setup

This file contains Notion-specific setup steps. It is called by the setting-up-tasks skill
after the active provider has been confirmed as **notion**.

## Step 1: Verify Notion MCP Connection

Call `notion-search` with query "test" to confirm the Notion MCP connection is working.

If it fails, guide the user to set up the Notion MCP in their environment:

**Claude Code:**
Add the following to `~/.claude/settings.json` under `"mcpServers"`:
```json
"notion": {
  "type": "http",
  "url": "https://mcp.notion.com/mcp"
}
```
Then restart Claude Code and run the setup skill again.

**Claude Desktop:**
Open Claude Desktop settings -> MCP Servers -> Add Server -> Enter `https://mcp.notion.com/mcp`.
Authenticate with your Notion account when prompted.

## Step 1b: Detect Existing Setup

1. Call `notion-search` with query "Waggle Config" to check for an existing configuration.
2. If no "Waggle Config" page is found, call `notion-search` with query "Agentic Tasks Config" (legacy fallback). If found, use it as the Config page (do not rename it).
3. If a Config page is found (from either search) -> enter **Migration Mode**:

### Migration Mode

a. Fetch the Config page body via `notion-fetch` and parse the JSON code block. Display the current configuration to the user.

b. **Check Teams DB entries**:
   - Fetch teams from `teamsDatabaseId`. Count entries.
   - 0 entries -> Guide the user to Step 4c (Register Initial Teams) of the normal setup flow.
   - 1+ entries -> Display team list and ask if any updates are needed.

c. **Check Sprints DB Team relation**: If `sprintsDatabaseId` exists in config:
   - Fetch the Sprints DB schema via `notion-fetch`.
   - If no `Team` field exists -> add it: `ADD COLUMN "Team" RELATION('<TEAMS_DS_ID>')`

d. **Tasks DB Team relation**: If a `Team` relation field exists on the Tasks DB:
   - Inform: "The Team field on Tasks is no longer used by the plugin. It will remain in Notion but the plugin will not read or write it."

e. Report: "Migration complete. Your setup has been updated to the latest plugin version."

4. If no Config page is found -> proceed with normal new setup flow below.

## Step 2: Choose Parent Page Location

### 2a: List available teamspaces

Call `notion-get-teams` to retrieve available teamspaces and display them to the user.

### 2b: Ask the user for a shared parent page

Use `AskUserQuestion` to ask:
> "Where should I create the Waggle workspace? To ensure all team members can discover the configuration, please specify an existing **page** inside a shared teamspace (e.g. a page name or URL).
>
> **Note:** Please choose a normal page, not a database. If you want it directly under a teamspace root, first create a new empty page there in the Notion UI, then tell me its name."

Show the teamspaces retrieved in 2a as reference.

**Edge case — no teamspaces found (solo user):**
If `notion-get-teams` returns no results, the workspace likely has a single user. In this case, inform the user that creating at the workspace root will make the page private and only visible to them, then allow root creation:
> "No shared teamspaces were found. Creating at the workspace root will make the page private (only visible to you). Is that OK?"

### 2c: Resolve and validate the specified page

1. Use `notion-search` to find the page the user specified.
2. **Reject databases:** If the search result's type is `database`, do NOT use it. Inform the user that databases cannot be used as a parent and ask them to choose a normal page instead.
3. If the search returns multiple matches, ask the user to disambiguate.
4. **Verify with `notion-fetch`:** Call `notion-fetch` on the selected page ID to confirm it is a page and to retrieve its ancestor path.
5. **Show the actual hierarchy:** Display the ancestor path (e.g. "Teamspace > Company Home > Office Manual > **Selected Page**") to the user and ask them to confirm this is the correct location. This is important because `notion-search` results do not show the full hierarchy, which can be misleading.

Once confirmed, note the page ID as `TARGET_PARENT_PAGE_ID`.

## Step 3: Create Parent Page

Create a parent page using `notion-create-pages`:
- Title: "Waggle" (or as specified by user)
- Parent: `{ "page_id": "<TARGET_PARENT_PAGE_ID>" }` (always use the resolved page ID from Step 2c; only omit for solo users who accepted the private-root fallback)

Note the returned page ID as `PARENT_PAGE_ID`.

## Step 4: Create Databases

Create each database using `notion-create-database` with `PARENT_PAGE_ID` as the parent.

**IMPORTANT: Relations must be added AFTER creating the database, one at a time via `notion-update-data-source`.** Do NOT include relations in the initial `notion-create-database` call — add them separately in Step 4b. Adding multiple relations in a single `notion-update-data-source` call causes an internal server error; each relation must be its own call.

### Step 4a: Create databases (no relations yet)

#### Tasks Database

Create with all non-relation fields:

| Property | Type | Config |
|---|---|---|
| Title | title | — |
| Description | rich_text | — |
| Acceptance Criteria | rich_text | — |
| Status | select | Options: Backlog, Ready, In Progress, In Review, Done, Blocked |
| Priority | select | Options: Urgent, High, Medium, Low |
| Executor | select | Options: cli, claude-desktop, cowork, human |
| Requires Review | checkbox | — |
| Execution Plan | rich_text | — |
| Working Directory | rich_text | — |
| Session Reference | rich_text | — |
| Dispatched At | date | — |
| Agent Output | rich_text | — |
| Error Message | rich_text | — |
| Context | rich_text | — |
| Artifacts | rich_text | — |
| Repository | url | — |
| Due Date | date | — |
| Tags | multi_select | — |
| Assignees | people | — |
| Issuer | people | Who created/initiated this task |
| Branch | rich_text | Git branch name. Set when using git worktree with Executor=cli |

Note the returned data source ID as `TASKS_DS_ID`.

#### Teams Database

Create with: Name (title), Members (people)

Note the returned data source ID as `TEAMS_DS_ID`.

#### Intake Log Database

Create with:

| Property | Type | Config |
|---|---|---|
| Message ID | title | — |
| Tool Name | select | Options: slack, teams, discord |
| Processed At | date | — |

Note the returned data source ID as `INTAKE_LOG_DS_ID`.

### Step 4b: Add relations one at a time

**Each `notion-update-data-source` call must contain exactly ONE `ADD COLUMN` statement.** Multiple statements in one call will fail with a 500 error.

Add the following relations in separate calls:

1. Tasks <- `Blocked By` -> Tasks (self): `ADD COLUMN "Blocked By" RELATION('<TASKS_DS_ID>')`
2. Tasks <- `Parent Task` -> Tasks (self): `ADD COLUMN "Parent Task" RELATION('<TASKS_DS_ID>')`

### Step 4c: Register Initial Team(s)

1. Use AskUserQuestion: "Would you like to register your team? Enter a team name and its members (e.g. 'Backend Team: Alice, Bob'). You can add multiple teams. Type 'skip' to skip this step."
2. If the user provides team info:
   a. Call `notion-get-users` (no arguments) to list all workspace members.
   b. For each member name provided, match against the workspace members list (case-insensitive partial match).
   c. If a name is ambiguous (multiple matches), use AskUserQuestion to confirm which member.
   d. Create the team page in Teams DB via `notion-create-pages`: Name = team name, Members = resolved user IDs.
   e. Ask: "Would you like to add another team?" and repeat if yes.
3. Recommend at least 1 team. If 0 teams are registered, warn: "No teams registered. Team-scoped features (sprint planning, standup, etc.) will not filter by team."

## Step 5: Create Config Page

Create a page using `notion-create-pages` under `PARENT_PAGE_ID`:
- Title: "Waggle Config"
- Body: a code block (language: `json`) containing:

```json
{
  "tasksDatabaseId": "<TASKS_DB_ID>",
  "teamsDatabaseId": "<TEAMS_DB_ID>",
  "intakeLogDatabaseId": "<INTAKE_LOG_DB_ID>"
}
```

Replace the placeholders with the actual IDs from Step 4.

After the JSON block, append the following as plain text:

```
**WARNING: Do not rename this page.** The plugin discovers configuration by searching for a page titled "Waggle Config". Renaming it will break auto-discovery for all team members.

## Schema Contract
- Core fields: Do not rename or delete (skills depend on them)
- Extended fields: May be renamed or deleted (some features will stop working)
- User-defined fields: Fully customizable (add Sprint, Epic, Story Points, etc. as needed)
```

## Step 5b: Configure Notion API Token (Recommended for Claude Code)

For faster task queries with server-side filtering (by assignee, status, etc.), set up a Notion internal integration:

1. Go to https://www.notion.so/profile/integrations
2. Click **New integration**
3. Name: `Waggle CLI`
4. Select the workspace that contains your Waggle databases
5. Capabilities: **Read content** (minimum required)
6. Click **Submit** and copy the **Internal Integration Secret** (`ntn_...`)

Then connect the integration to your databases:

1. Open the **Waggle** parent page in Notion
2. Click **...** menu -> **Connections** -> **Connect to** -> select **Waggle CLI**

Finally, set the token as an environment variable:

**Claude Code** — add to `~/.claude/settings.json`:
```json
{
  "env": {
    "NOTION_TOKEN": "ntn_xxxxxxxxxxxxx"
  }
}
```

**Shell profile** — add to `~/.bashrc` or `~/.zshrc`:
```bash
export NOTION_TOKEN="ntn_xxxxxxxxxxxxx"
```

This step is optional — the plugin works without it using MCP-only queries, but server-side filtering is significantly faster for large task databases.

## Step 5c: Write ~/.waggle/config.json

After the Config page is created, write a local config file so waggle can detect the Notion provider without relying solely on MCP tool auto-detection:

```bash
mkdir -p ~/.waggle
cat > ~/.waggle/config.json << EOF
{
  "provider": "notion",
  "tasksDatabaseId": "<TASKS_DB_ID from Step 4>",
  "teamsDatabaseId": "<TEAMS_DB_ID from Step 4>"
}
EOF
```

Replace the placeholders with the actual IDs from Step 4.

## Step 6: Verify

Use `AskUserQuestion` to confirm:
> "Setup complete! I've created the Waggle workspace in Notion with Tasks, Teams, and Intake Log databases, and a Config page storing the database IDs. Would you like me to create a test task to verify everything is working?"

If yes, create a test task using `notion-create-pages` with the Tasks database as parent:
- Title: "Test task — delete me"
- properties: `{"Status": "Ready", "Priority": "Medium"}`

Tell the user setup is complete and they can start using:
- Natural language task management (`managing-tasks` skill)
- Visual views (`viewing-tasks` skill)
