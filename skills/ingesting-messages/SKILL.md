---
name: ingesting-messages
description: >
  Reads incoming messages (Slack, Teams, Discord) addressed to the current user
  and auto-converts them into categorized Notion tasks (hearing-needed, self-action,
  or delegate). Designed for daily scheduled execution.
  Triggers on: "message intake", "intake", "process messages",
  "メッセージ取り込み", "メッセージ処理"
user-invocable: true
---

# Waggle — Message Intake

Reads incoming messages from messaging tools addressed to the current user and auto-converts them into Notion tasks.
**read-only**: Does not send any messages. Only creates tasks.

## Scheduled Task Setup (Claude Desktop)

To run automatically every morning via Claude Desktop:
1. Claude Desktop → Scheduled Tasks → New
2. Trigger: Daily / 09:00 (user's timezone)
3. Prompt: `Run the ingesting-messages skill`

---

## Step 0: Preparation

### Provider Detection + Identity Resolve

1. Load `${CLAUDE_PLUGIN_ROOT}/skills/detecting-provider/SKILL.md` → `active_provider`. Skip if set.
2. Load `${CLAUDE_PLUGIN_ROOT}/skills/resolving-identity/SKILL.md`:
   - Obtain `current_user` (for message filtering).
   - Obtain `org_members` (for Category C: identifying assignees).

### Messaging MCP Auto-Detection

Inspect available MCP tools and determine which messaging tool to use:

| Tool group | Service |
|---|---|
| `slack-*` tools exist | Slack |
| `teams-*` or `ms-teams-*` tools exist | Microsoft Teams |
| `discord-*` tools exist | Discord |

- Multiple detected: Use AskUserQuestion to ask "Which messaging service would you like to use?"
- None detected: Stop and inform "No messaging MCP is configured. Please set up a Slack/Teams/Discord MCP."

### Message Intake Log Preparation

The Intake Log is a Notion database (`Intake Log`) that tracks which messages have already been processed.

1. Read the config page and check for `intakeLogDatabaseId`.
2. If `intakeLogDatabaseId` is missing or the database does not exist:
   - Create a new database named "Intake Log" under the Waggle parent page using `notion-create-database`.
   - Schema:
     | Property | Notion Type | Description |
     |---|---|---|
     | Message ID | title | Message unique ID (e.g. Slack: `channel_id:ts`) |
     | Tool Name | select | `slack` / `teams` / `discord` |
     | Processed At | date | Processing timestamp |
   - Write the new database ID back to the config page as `intakeLogDatabaseId`.
3. Load `processed_message_ids`: query `intakeLogDatabaseId` via `notion-search` and collect all existing Message ID values.
4. **FIFO cleanup**: If the Intake Log has more than 1000 entries, delete the oldest records (by Processed At) until the count is at or below 1000.

---

## Step 1: Fetch Unprocessed Messages

Use the detected Messaging MCP to retrieve all messages from the past 24 hours addressed to `current_user` via a multi-query strategy:

### 1a. Search Intent (platform-agnostic)

Retrieve every message from the past 24 hours that is directed at or contextually relevant to `current_user`:
1. **DMs**: Direct messages sent to self
2. **Channel mentions**: Messages in channels/groups that @-mention `current_user`
3. **Thread participant replies**: New replies in threads where `current_user` has participated (started or replied), even if no @-mention is present

### 1b. Slack Query Example

- **Query 1 (DMs)**: Search with `to:me`
- **Query 2 (Channel mentions)**: Search for messages containing `<@USER_ID>` (the `current_user`'s Slack user ID). Exclude own messages. Search scope must include both public and private channels the user is a member of. If the MCP tool has a channel-type filter, ensure `private` / `mpim` / `im` types are included alongside `public_channel`.
- **Query 3 (Thread participant replies)**:
  1. From Query 1, Query 2, and a `from:me` search (past 24h), collect all `thread_ts` values of threads `current_user` participates in
  2. Fetch replies for each thread
  3. Exclude own messages and already-processed messages
  4. If the MCP does not support thread-level queries, skip Query 3 and note it in the summary

### 1c. Common Filters (applied after merge)

- `id ∉ processed_message_ids`
- If bot message (has `bot_id` or bot-related `subtype`): keep only if it @-mentions `current_user`; discard otherwise
- Not sent by self

### 1d. Deduplication

Merge all query results and deduplicate by message unique ID (Slack: `channel_id:ts`).

### 1e. Platform Notes

- **Teams / Discord**: Translate to equivalent APIs. The intent (DMs + mentions + thread participant replies) is the same.
- **Thread queries unsupported**: Skip Query 3 and add `(thread check: skipped — MCP does not support thread queries)` to the summary.

---

## Step 2: Classify Messages (3 Categories)

Classify each message into one of 3 categories:

| Category | Criteria | Action |
|---|---|---|
| **A: Hearing Needed** | Insufficient info, question format, ambiguous request, seeking approval | Main task (Status=Blocked) + Blocker task (Status=Ready, executor=human, Assignees=requester) |
| **B: Self-Action** | AI-processable implementation, research, documentation, clear work request | Task (Status=Ready, executor=claude-desktop or cli, Assignees=self) |
| **C: Delegate** | Clearly intended for another team member (name explicitly mentioned, etc.) | Task (Status=Backlog, executor=human, Assignees=assignee) |

**When classification is unclear**: Treat as Category A (safe default).

### Classification Heuristics and Examples

**Category A (Hearing Needed)** — default when uncertain:
- Question format: "Can you …?", "What's the status of …?"
- Approval requests: "Review and approve this"
- References context the AI does not have: "about that thing we discussed yesterday"
- Example: `"Hey, can you look at the design doc and let me know if the approach works?"` → A (which document? what feedback criteria?)

**Category B (Self-Action)** — clear and actionable:
- Specific work request: "Write unit tests for the auth module"
- Research / summary: "Compile the Q3 metrics report"
- Implementation request with sufficient context to start
- Example: `"Please update the README to include the new API endpoints"` → B

**Category C (Delegate)** — explicitly addressed to another member:
- Names another member: "Ask @alice to …"
- Current user is CC; the action owner is someone else
- Example: `"@you FYI — @bob needs to update his deployment script"` → C (action owner is Bob)

**Decision rule**: If torn between B and A → choose A. If torn between C and A → choose A. A is always the safe default.

---

## Step 2.5: Enrich Task Details (Category B/C)

Before creating tasks, enrich Category B and C messages with additional details via `AskUserQuestion`.

**Category B (Self-Action) — ask:**
- Acceptance Criteria: What are the completion conditions?
- Working Directory: Which repository / directory to work in?
- Execution Plan: Any specific approach or constraints?
- Context: Additional background information?

**Category C (Delegate) — ask:**
- Acceptance Criteria: What is the expected deliverable?
- Context: Background info for the assignee (or their agent)
- Due Date: Any deadline?

**How to ask:**
- If there are multiple B/C messages, batch them into a single `AskUserQuestion` call (do not ask per-message)
- If the user replies "as-is" or equivalent, proceed with only the information from the original message
- Incorporate answers into the task fields when creating tasks in Step 3

---

## Step 3: Bulk Task Creation

Create tasks directly via `notion-create-pages` for each message (do not go through the managing-tasks skill).

### Pre-Creation Dedup Check

Before creating each task:
1. Generate `source_message_id` from the message unique ID (Slack: `channel_id:ts`)
2. Query the Tasks DB via `notion-search` for existing tasks with the same `Source Message ID`
3. If a matching task exists: skip the message and count it as `Skipped (already exists as task)`
4. If no match: include `Source Message ID` in the created task's fields

### Common Fields

| Field | Value |
|---|---|
| Title | `From @{sender}: {message summary (50 chars max)}` |
| Description | Full original message + append `Source: {tool_name} DM from @{sender} at {datetime}` |
| Tags | `["ingesting-messages"]` |
| Context | `Received via {tool_name} on {date}` |

### Category-Specific Fields

**Category A (Hearing Needed):**
1. Create the blocker task first:
   - Title: `[Hearing] Confirm with {requester_name}: {question summary}`
   - Status: `Ready`
   - Executor: `human`
   - Assignees: `[requester]` (Load `${CLAUDE_PLUGIN_ROOT}/skills/looking-up-members/SKILL.md` to resolve)
   - If requester cannot be identified: Assignees empty, record "Sender: {sender}" in Context
2. Create the main task:
   - Status: `Blocked`
   - Blocked By: `[blocker_task_id]`
   - Executor: `human` (undetermined)
   - Assignees: `[current_user]`

**Category B (Self-Action):**
- Status: `Ready`
- Executor: Determine from environment and context:
  - `execution_environment = "cowork"`: Default for AI-executed tasks is `cowork`
  - `execution_environment = "claude-desktop"`: Default for AI-executed tasks is `claude-desktop`
  - `execution_environment = "cli"`: Code work → `cli`, external integrations → `claude-desktop`
- Assignees: `[current_user]`
- Working Directory: Empty (user sets later)

**Category C (Delegate):**
- Status: `Backlog`
- Executor: `human` (always fixed to human when assigned to others)
- Assignees: Load `${CLAUDE_PLUGIN_ROOT}/skills/looking-up-members/SKILL.md` to resolve assignee
  - If assignee cannot be identified: Assignees empty, record "Expected assignee: {name or hint}" in Context
- Working Directory: Empty (other person's filesystem unknown)
- Branch: Empty (other person's git environment unknown)

---

## Step 4: Log Update + View Server Push

1. For each processed message, create a record in the Intake Log DB via `notion-create-pages`:
   - Message ID: the message unique ID (e.g. `channel_id:ts`)
   - Tool Name: the messaging tool name (e.g. `slack`)
   - Processed At: current timestamp
2. If the Intake Log DB exceeds 1000 entries, delete the oldest records (by Processed At) to bring it back to 1000.
3. Push data to view server:
```bash
# Silently skip if server is not running
curl -s http://localhost:3456/api/health -o /dev/null 2>/dev/null && \
  curl -s -X POST http://localhost:3456/api/data \
    -H "Content-Type: application/json" -d '<tasks_json>' -o /dev/null 2>/dev/null || true
```

---

## Step 5: Summary Output

```
[Message Intake Complete] via {tool_name}
Processed: N / Skipped (already processed): K / Skipped (already exists as task): J
  A (Hearing Needed): X → Blocked tasks + Blocker tasks created
  B (Self-Action):    Y → Ready tasks created
  C (Delegate):       Z → Backlog tasks created
```

---

## Language

Always respond in the user's language.
