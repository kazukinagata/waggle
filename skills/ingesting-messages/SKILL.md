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
3. Load `processed_message_ids`: query `intakeLogDatabaseId` using the provider's "Querying Any Notion Database" flow and collect all existing Message ID values.
4. **FIFO cleanup**: If the Intake Log has more than 1000 entries, delete the oldest records (by Processed At) until the count is at or below 1000.

### Active Threads Preparation

Active Threads enables continuous monitoring of threads the user has participated in, even after the original messages fall outside the lookback period.

1. Read the config page and check for `activeThreadsDatabaseId`.
2. If `activeThreadsDatabaseId` is missing or the database does not exist:
   - Create a new database named "Active Threads" under the Waggle parent page using `notion-create-database`.
   - Schema:
     | Property | Notion Type | Description |
     |---|---|---|
     | Thread ID | title | `channel_id:thread_ts` |
     | Channel ID | rich_text | Slack channel ID |
     | Thread TS | rich_text | thread_ts value |
     | Last Checked | date | Timestamp of last check for new replies |
     | Status | select | `active` / `closed` |
   - Write the new database ID back to the config page as `activeThreadsDatabaseId`.
3. Load `active_threads`: query `activeThreadsDatabaseId` with filter `Status = active` and collect all records.

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

### 1b-2. Active Threads Check

For each thread in `active_threads`, check for new replies that the lookback-period queries may have missed:

1. Call `slack_read_thread` with `channel_id` and `message_ts` set to the thread's Thread TS value. Set `oldest` to the thread's `Last Checked` timestamp to retrieve only new replies since the last check.
2. From the response, exclude:
   - Messages sent by `current_user` (own messages)
   - Messages whose unique ID (`channel_id:ts`) is already in `processed_message_ids`
3. Add any remaining unprocessed messages to the message pool for classification.
4. Update the thread's `Last Checked` to the current timestamp (even if no new messages were found).

This ensures threads discovered in previous ingesting runs continue to be monitored regardless of the lookback period. Without this step, threads whose original messages and user replies have both fallen outside the lookback window would become invisible to Query 3.

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

## Step 1.6: Thread Context Enrichment

For each message in the deduplicated pool that originated from a thread (i.e., has a `thread_ts` or equivalent thread identifier), fetch the full thread to provide conversational context for classification and task creation.

### Slack

For each unique `thread_ts` among the fetched messages:
1. Call `slack_read_thread` with `channel_id` and `message_ts` set to the `thread_ts` value.
2. From the response, extract:
   - **Parent message**: The thread's root message (first message in the thread).
   - **Preceding replies**: All replies that came *before* the triggering message, in chronological order.
3. Construct `thread_context` for the message:
   ```
   [Thread Context — {N} messages in #{channel_name}]
   @{parent_author} (thread start): {parent_message_text}
   @{reply_1_author}: {reply_1_text}
   ...
   @{reply_N_author}: {reply_N_text}
   ---
   [This message]
   @{sender}: {message_text}
   ```
4. **Truncation**: If the assembled thread context exceeds 2000 characters, keep the parent message in full and truncate the middle replies, preserving the 3 most recent replies before the triggering message. Insert `... ({K} earlier replies omitted)` where truncation occurs.
5. Attach `thread_context` to the message object for use in Steps 2 and 3.

### Teams / Discord

Apply the same pattern using equivalent thread/reply-fetching APIs if available. If the platform's MCP does not support thread fetching, set `thread_context = null` and note: `(thread context: unavailable — platform MCP does not support thread reads)`.

### Non-Thread Messages

Messages that are not part of a thread: set `thread_context = null`. No additional API calls.

---

## Step 1.7: Attachment Processing

For each message in the deduplicated pool, detect and attempt to read image attachments.

### Detection

Check each message for a `files` array (Slack) or equivalent attachment field (Teams/Discord). Filter for image file types only:
- **Slack**: entries where `mimetype` starts with `image/` (e.g., `image/png`, `image/jpeg`, `image/gif`)
- **Teams / Discord**: equivalent image attachment fields

If a message has no image attachments, set `attachment_info = null` and move on.

### Image Reading (best-effort)

For each image attachment detected:

1. Extract the image's `permalink` from the file object.
2. Attempt to read the image using `WebFetch` with the `permalink` URL.
3. If `WebFetch` succeeds and returns image content: describe the image in detail, focusing on text content, UI elements, error messages, diagrams, or any actionable information visible. Store the description. Set `read_status = "success"`.
4. If `WebFetch` fails (auth error, timeout, or empty result): set `read_status = "failed"` and `description = null`.

### Message Permalink

For each message that has at least one image with `read_status = "failed"`, construct (or extract from the API response) the message permalink so it can be shown to the user:
- **Slack**: If the message payload includes a `permalink` field, use it directly. Otherwise construct: `https://{workspace}.slack.com/archives/{channel_id}/p{ts_without_dot}` where `ts_without_dot` is the message `ts` with the dot removed.
- **Teams / Discord**: Use the message URL/link from the API response if available.

### Output

Attach `attachment_info` to each message object:

```
attachment_info:
  has_images: true
  images:
    - filename: "{name}"
      mimetype: "{mimetype}"
      permalink: "{file_permalink}"
      description: "{AI description}" or null
      read_status: "success" or "failed"
  message_permalink: "{constructed_or_extracted_permalink}" or null
```

- `message_permalink`: Only set when at least one image has `read_status = "failed"`. Set to `null` if all images were read successfully.
- Messages with no image attachments: `attachment_info = null`.

### Limits

- Process a maximum of **3 images per message**. If a message has more than 3 images, process the first 3 and note: `"({N - 3} additional images not processed)"`.
- If the total number of images across all messages exceeds **10**, process only the first 10 (in message order) and log: `"Image processing capped at 10. {remaining} images skipped."`

### Teams / Discord

Apply the same detection and reading pattern using equivalent attachment/file APIs. If the platform's MCP does not support file metadata, set `attachment_info = null` and note: `(attachment processing: unavailable — platform MCP does not support file metadata)`.

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

Classify each message into A (Hearing Needed), B (Self-Action), or C (Delegate). When `thread_context` is available, use it alongside the message text to improve classification accuracy. When `attachment_info` is available and contains successfully read image descriptions, treat those descriptions as part of the message content for classification purposes. For example, a message saying "fix this" with an attached screenshot of a bug (successfully described) should be classified as Category B if the description provides enough context to act on. For the full classification heuristics, examples, and confirmation flow, follow `references/classification-guide.md` in this directory.

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

| # | Category | Sender | Summary | Status | Executor | Attachments |
|---|----------|--------|---------|--------|----------|-------------|
| 1 | B: Self | @alice | Update README with new endpoints | Ready | claude-desktop | |
| 2 | A: Hearing | @bob | Fix this layout issue | Blocked | human | 1 img (read) |
| 3 | B: Self | @charlie | Bug in checkout flow | Ready | cli | 1 img (unread) |
| 4 | C: Delegate | @alice | @charlie deployment script | Backlog | human | |

The Attachments column shows: blank if no images, `{N} img (read)` if all images were read successfully, `{N} img (unread)` if any image failed to read, `{N} img ({S} read, {F} unread)` for mixed results.

**Unread image attachments**: If any messages have images with `read_status = "failed"`, display them below the table:

> The following messages have image attachments that could not be read automatically. Please review them before confirming task creation:
> - **#3** (@charlie): [View message in Slack]({message_permalink})

The user can then open the links, review the images, and optionally update the task summary or category before confirming.

Use `AskUserQuestion`: "Create these N tasks? (Please review unread image links above first)"
- **"Create all"** — proceed to Step 3
- **"Select individually"** — for each task, ask create / skip
- **"Cancel"** — abort task creation, output summary of what would have been created

If no messages have unread images, use the standard prompt: "Create these N tasks?"

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

### Active Threads Update

1. For each processed message that was part of a thread (has a `thread_ts` value):
   - Construct `thread_id` = `{channel_id}:{thread_ts}`
   - If `thread_id` is not already in `active_threads`: create a new record in Active Threads DB via `notion-create-pages` with Status=`active` and Last Checked=current timestamp.
2. **Auto-close stale threads**: For each Active Thread where `Last Checked` is more than 7 days ago AND no new messages were found in this run: update Status to `closed`.
3. **FIFO cleanup**: If the number of Active Threads with Status=`active` exceeds 200, close the oldest threads (by Last Checked) until the count is at or below 200.

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
Thread context: {T} messages enriched with thread history
Attachments: {I} images detected, {S} read successfully, {F} unreadable
```

---
