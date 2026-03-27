---
name: ingesting-messages
description: >
  Reads incoming messages (Slack, Teams, Discord) and custom intake sources
  addressed to the current user and auto-converts them into categorized tasks
  (hearing-needed, self-action, or delegate). Supports per-user custom source
  configuration via ~/.waggle/intake-prompt.md or Global Instructions.
  Use this skill whenever the user wants to process incoming messages, check
  their inbox, or convert messages into tasks — even if they don't say "intake".
  Triggers on: "message intake", "intake", "process messages",
  "convert messages to tasks", "check slack", "check teams", "inbox processing".
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

### Session Bootstrap

Load `${CLAUDE_PLUGIN_ROOT}/skills/bootstrap-session/SKILL.md` and follow its instructions.
Skip if `active_provider` and `current_user` are already set in this conversation.

### Lookback Period

Determine how far back to fetch messages:

- If the user specified a lookback period (e.g., "past 3 days", "48 hours", "since Monday"), set `lookback_period` to that value.
- Default: `lookback_period = "24 hours"`

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

### Custom Intake Source Loading

Load custom intake instructions if configured:

1. **CLI / Claude Desktop**: Read `~/.waggle/intake-prompt.md` if it exists. Store contents as `custom_intake_instructions`. If the file does not exist, set `custom_intake_instructions = null`.
2. **Cowork**: Check the system prompt context for content between `<waggle-custom-intake>` and `</waggle-custom-intake>` tags. If found, store that content as `custom_intake_instructions`. If not found, set `custom_intake_instructions = null`.

---

## Step 1: Fetch Unprocessed Messages

Use the detected Messaging MCP to retrieve all messages from the past `{lookback_period}` addressed to `current_user` via a multi-query strategy:

### 1a. Search Intent (platform-agnostic)

Retrieve every message from the past `{lookback_period}` that is directed at or contextually relevant to `current_user`:
1. **DMs**: Direct messages sent to self
2. **Channel mentions**: Messages in channels/groups that @-mention `current_user`
3. **Thread participant replies**: New replies in threads where `current_user` has participated (started or replied), even if no @-mention is present

### 1b. Slack Query Example

- **Query 1 (DMs)**: Search with `to:me`
- **Query 2 (Channel mentions)**: Search for messages containing `<@USER_ID>` (the `current_user`'s Slack user ID). Exclude own messages. Search scope must include both public and private channels the user is a member of. If the MCP tool has a channel-type filter, ensure `private` / `mpim` / `im` types are included alongside `public_channel`.
- **Query 3 (Thread participant replies)**:
  1. From Query 1, Query 2, and a `from:me` search (past `{lookback_period}`), collect all `thread_ts` values of threads `current_user` participates in
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

## Step 1.5: Custom Source Intake

If `custom_intake_instructions` is null, skip this step.

Follow the instructions in `custom_intake_instructions` to fetch items from each configured custom source:

1. Access each source using available MCP tools or APIs as described in the instructions.
2. If the required tools are not available for a source, log a warning and skip it:
   > "Custom source '{source_name}' skipped — required tools not available."
3. For non-messaging sources (spreadsheets, task systems), use `{source_name}:{unique_id}` as the message unique ID for dedup against the Intake Log.
4. Add retrieved items to the message pool for classification in Step 2.
5. Apply the same dedup rules (Step 1d) and filters (Step 1c) where applicable.

---

## Step 2: Classify Messages (3 Categories)

Classify each message into A (Hearing Needed), B (Self-Action), or C (Delegate). For the full classification heuristics, examples, and confirmation flow, follow `references/classification-guide.md` in this directory.

When classification is unclear, treat as Category A (safe default).

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

## Step 2.7: Creation Confirmation

Display the final task list to be created:

| # | Category | Sender | Summary | Status | Executor |
|---|----------|--------|---------|--------|----------|
| 1 | B: Self | @alice | Update README with new endpoints | Ready | claude-desktop |
| 2 | A: Hearing | @bob | Design doc review request | Blocked | human |
| 3 | C: Delegate | @alice | @charlie deployment script | Backlog | human |

Use `AskUserQuestion`: "Create these N tasks?"
- **"Create all"** — proceed to Step 3
- **"Select individually"** — for each task, ask create / skip
- **"Cancel"** — abort task creation, output summary of what would have been created

---

## Step 3: Bulk Task Creation

Create tasks directly via `notion-create-pages` for each message (do not go through the managing-tasks skill). For the dedup check, common fields, and category-specific field templates, follow `references/task-creation-templates.md` in this directory.

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
Custom sources: {list of sources processed, or "none configured"}
```

---
