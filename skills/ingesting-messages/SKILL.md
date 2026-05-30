---
name: ingesting-messages
description: >
  Reads incoming messages (Slack, Teams, Discord) and custom intake sources
  addressed to the current user and auto-converts them into categorized tasks
  (hearing-needed, self-action, or delegate). For ambiguous Slack messages
  in an explicitly interactive session, can optionally send a user-approved
  clarification reply in-thread instead of creating a hearing-task pair.
  Supports per-user custom source configuration via ~/.waggle/intake-prompt.md
  or Global Instructions, and per-user task-creation rules (tag naming,
  priority defaults, etc.) via ~/.waggle/task-creation-prompt.md or Global
  Instructions.
  Use this skill whenever the user wants to process incoming messages, check
  their inbox, or convert messages into tasks — even if they don't say "intake".
  Triggers on: "message intake", "intake", "process messages",
  "convert messages to tasks", "check slack", "check teams", "inbox processing",
  "clarify slack message", "find my tasks in slack", "check slack for my tasks",
  "my mentions in slack", "pull tasks from slack".
user-invocable: true
---

# Waggle — Message Intake

Reads incoming messages from messaging tools addressed to the current user and auto-converts them into Notion tasks.

**Primary mode**: creates tasks from messages.
**Opt-in mode**: can send Slack thread replies to ask for clarification on ambiguous messages. This mode is strictly user-approved and is disabled by default in any non-interactive run (see `WAGGLE_EXECUTION_MODE` in Step 2.3).

## Scheduled Task Setup (Claude Desktop)

To run automatically every morning via Claude Desktop:
1. Claude Desktop → Scheduled Tasks → New
2. Trigger: Daily / 09:00 (user's timezone)
3. Prompt: `Run the ingesting-messages skill`

---

## Step 0: Preparation

### Session Bootstrap

Invoke the `bootstrap-session` skill to establish the active provider and current user.
Skip if `active_provider` and `current_user` are already set in this conversation.

### Lookback Period

Determine how far back to fetch messages:

- If the user specified a lookback period (e.g., "past 3 days", "48 hours", "since Monday"), set `lookback_period` to that value.
- Default: `lookback_period = "24 hours"`

#### Translating `lookback_period` to Slack date filters

Slack's `after:YYYY-MM-DD` and `before:YYYY-MM-DD` query-string filters are **exclusive** of the named date — `after:2026-05-07` returns messages from 2026-05-08 onwards, NOT 5/7. Compute the cutoff carefully:

- **Preferred path — Unix-timestamp argument**: if the MCP tool exposes an `after` (or `oldest`) argument that accepts a Unix timestamp, use that. The Unix-timestamp form is inclusive: `after = int(unix_timestamp(now() - lookback_period))` returns messages at or after that instant.
- **Fallback — query-string filter with date adjustment**: if the MCP tool only supports the query-string `after:` filter, compute `cutoff_date = (now() - lookback_period).date()` and emit `after:{cutoff_date - 1 day}` to compensate for Slack's exclusivity. Example: a 24-hour lookback at 2026-05-08 14:25 JST has `cutoff_date = 2026-05-07`; emit **`after:2026-05-06`** (NOT `after:2026-05-07`, which would exclude 5/7 entirely).

`before:YYYY-MM-DD` is symmetrically exclusive — use `before:{end_date + 1 day}` if the end date itself should be included. The query-string filters `on:YYYY-MM-DD` and `during:YYYY-MM-DD` are inclusive but only cover a single day, so they are not useful for arbitrary lookback ranges.

**Sanity check (advisory)**: after running the query, if you happen to have prior expectation that the boundary day contained Slack activity for `current_user`, confirm at least one returned result is on that boundary day. If results all skip the boundary day **and** the user is normally active there, the off-by-one may have come back — re-check the filter. Skip this check when the boundary day is plausibly empty (user offline, weekend, no relevant traffic); an empty boundary day is not by itself evidence of a bug.

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
3. Load `processed_message_ids` (date-windowed, paginated).
   - Derive `intake_log_retention_days` from the current `lookback_period` so the dedup window always covers what the messaging MCP can re-surface in this run: `intake_log_retention_days = max(30, ceil(lookback_period_in_days) + 7)`. The `+ 7` buffer absorbs Step 4's exclusive `before:` cutoff, off-by-one day adjustments in the Slack date filter (see Step 0's "Translating `lookback_period` to Slack date filters"), and timing skew between Step 0 and Step 4 within a single run.
   - Compute `retention_cutoff = (now - intake_log_retention_days).date()` in ISO `YYYY-MM-DD` form.
   - Query the Intake Log with the provider's "Querying Any Notion Database" flow using:
     - `filter`: `{"property":"Processed At","date":{"on_or_after":"<retention_cutoff>"}}`
     - `page_size`: 50 (keeps each MCP response under typical host token caps with the full Notion page payload)
     - `start_cursor`: from the previous response's `next_cursor` on subsequent calls
   - Iterate while the response's `has_more` is `true`, collecting each record's `Message ID` title value into `processed_message_ids`. Stop when `has_more` is `false`.
   - **Cross-run edge case**: if the current `lookback_period` is materially longer than the lookback used by recent prior runs, Step 4 of those prior runs may already have archived Intake Log records whose `Processed At` is older than the prior run's (shorter) `intake_log_retention_days`. Such already-processed messages will be missing from `processed_message_ids` and re-classified as new, producing duplicate task candidates in Step 2.7's confirmation table. This is a known trade-off — the dedup window only stretches forward from the run that asked for the longer lookback. The user can mitigate at the Step 2.7 confirmation by switching to "Select individually" and skipping rows they recognise as duplicates of existing tasks.
   - This load path replaces the older "fetch the whole database in one call" pattern, which silently overflowed the MCP token cap once the log exceeded ~200 records (~250KB of full-page JSON) and stalled the run for many minutes while it tried to recover from the host-side spill file.
   - **Extension version requirement**: this paginated path requires `notion-extension` v0.4.0 or later. If the response does not contain a `has_more` field even when `page_size` was set, the installed extension is v0.3.x and is silently ignoring `page_size` (the server returns the aggregated full result set instead). Treat this as a halt condition for the current run: surface "Notion Desktop Extension is older than v0.4.0. Install the latest version to use paginated intake. Step halted." rather than continuing with a possibly-truncated aggregate that may exceed the host token cap. The `health-checking` skill probes for this and is the right place for users to verify their installed version.
4. FIFO/count-based cleanup is intentionally **not** performed here. The Intake Log is bounded by Step 4's time-based TTL cleanup instead (see below), so Step 0 does not need to know or shrink the total record count.

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
     | Clarification Sent At | date | When a Slack clarification reply was last sent to this thread (optional, used by Step 2.3 idempotency) |
   - Write the new database ID back to the config page as `activeThreadsDatabaseId`.
3. **Schema auto-repair** (for databases created before the `Clarification Sent At` field was introduced):
   - Fetch the database schema via `notion-fetch`
   - If the `Clarification Sent At` property is missing, add it via `notion-update-data-source` with `ADD COLUMN "Clarification Sent At" DATE`
   - Existing records will have `null` for this field; no data migration is needed
4. Load `active_threads`: query `activeThreadsDatabaseId` with filter `Status = active` and collect all records.

### Custom Instruction Loading

Load both custom intake instructions and custom task-creation instructions via the shared loader:

1. Invoke the `loading-custom-instructions` skill with key `intake` to populate `custom_intake_instructions`. If no custom intake source is configured, the variable is `null`. This governs which additional sources are scanned in Step 1.5.
2. Invoke the `loading-custom-instructions` skill with key `task-creation` to populate `custom_task_creation_instructions`. If no custom task-creation rules are configured, the variable is `null`. This is applied in Step 3 when building per-category task fields (see `task-creation-templates.md`).

Both files (`~/.waggle/intake-prompt.md` and `~/.waggle/task-creation-prompt.md`) may exist independently; they serve different purposes. On Cowork, both are loaded from their respective `<waggle-custom-intake>` / `<waggle-custom-task-creation>` XML tags in Global Instructions.

---

## Step 1: Fetch Unprocessed Messages

Use the detected Messaging MCP to retrieve all messages from the past `{lookback_period}` addressed to `current_user` via a multi-query strategy:

### 1a. Search Intent (platform-agnostic)

Retrieve every message from the past `{lookback_period}` that is directed at or contextually relevant to `current_user`:
1. **DMs**: Direct messages sent to self
2. **Channel mentions**: Messages in channels/groups that @-mention `current_user`
3. **Thread participant replies**: New replies in threads where `current_user` has participated (started or replied), even if no @-mention is present

### 1b. Slack Query Example

**All three queries below MUST pass `include_bots: true`** (or the equivalent MCP parameter — `with_bots`, `bots: true`, etc.; consult the MCP tool's schema for the exact name). The MCP default is to exclude bots, which silently drops messages from automation bots — meeting summary bots, action-item posters, intake bots — even when those bots @-mention the user via Block Kit. Without this flag set, Step 1c-1 (Block Kit body refetch) never fires because the bot messages are absent from the search result entirely.

**For the date filter on each search, follow "Translating `lookback_period` to Slack date filters" in Step 0.** Prefer the MCP tool's Unix-timestamp `after` argument over the query-string `after:` filter when both are supported. If using the query-string filter, remember to subtract 1 day from the cutoff date to compensate for Slack's exclusive-date semantics.

- **Query 1 (DMs)**: Search with `to:me`, `include_bots: true`, and the lookback filter from Step 0.
- **Query 2 (Channel mentions)**: Search for messages containing `<@USER_ID>` (the `current_user`'s Slack user ID), with `include_bots: true` and the lookback filter. Exclude own messages. `include_bots: true` is especially important here — channels dedicated to bot-posted action items (e.g., a meeting-notifier bot posting to `gp-mtg-actions-test`) are exactly the case where the default `false` silently wipes the entire intake source. Search scope must include both public and private channels the user is a member of. If the MCP tool has a channel-type filter, ensure `private` / `mpim` / `im` types are included alongside `public_channel`.
- **Query 3 (Thread participant replies)**:
  1. From Query 1, Query 2, and a `from:me` search (past `{lookback_period}`, also with `include_bots: true`), collect all `thread_ts` values of threads `current_user` participates in
  2. Fetch replies for each thread
  3. Exclude own messages and already-processed messages
  4. If the MCP does not support thread-level queries, skip Query 3 and note it in the summary

### 1b-2. Active Threads Check

For each thread in `active_threads`, check for new replies that the lookback-period queries may have missed:

1. Call `slack_read_thread` with `channel_id` and `message_ts` set to the thread's Thread TS value. Set `oldest` to **`str(unix_timestamp(Last Checked) - 0.000001)`** — convert the Notion `date` field to a Unix timestamp float (e.g., `datetime.fromisoformat(Last_Checked).timestamp()`), subtract one microsecond, then pass as a string (same pattern as Step 1c-1's `oldest` / `latest` window). The MCP's `oldest` parameter is exclusive of the named ts; passing the literal `Last Checked` (after correct Unix conversion) would still skip a reply posted at exactly that timestamp, so the ±1 μs subtraction is required. Passing the raw Notion ISO-8601 date string directly will either error or silently return wrong results.
2. From the response, exclude:
   - Messages sent by `current_user` (own messages)
   - Messages whose unique ID (`channel_id:ts`) is already in `processed_message_ids`
3. Add any remaining unprocessed messages to the message pool for classification.
4. Update the thread's `Last Checked` to the current timestamp (even if no new messages were found).

This ensures threads discovered in previous ingesting runs continue to be monitored regardless of the lookback period. Without this step, threads whose original messages and user replies have both fallen outside the lookback window would become invisible to Query 3.

### 1c. Common Filters (applied after merge)

- `id ∉ processed_message_ids`
- Not sent by self
- Bot messages (has `bot_id` or bot-related `subtype` such as `bot_message`):
  - **If `text` is empty / whitespace-only / only newlines, apply Step 1c-1 first** (Block Kit body refetch) before the KEEP/DISCARD bullets below. The KEEP check needs a real body to scan for `<@current_user>`; skipping 1c-1 would let the message silently fall through to DISCARD.
  - **KEEP** if the (possibly refetched) body @-mentions `current_user` — from this point on, treat it identically to a human message. It flows through classification (Step 2), enrichment (Step 2.5), and task creation (Step 3) with no further bot-specific filtering. The bot-sender check in Step 2.3 Prerequisite #4 only gates sending Slack **clarification replies** (because bots do not read replies); it does NOT exclude the message from intake — bot-origin Category A messages still produce a `[Hearing]` task via the fall-through path.
  - **DISCARD** otherwise (bot noise that does not concern the user).

### 1c-1. Slack Block Kit Body Refetch (bot messages)

Slack's `slack_search_*` MCP does not render `blocks` to plain text. Bot messages whose content lives entirely in Block Kit (meeting notifiers like MTG Pipeline Bot, quiz bots like Colla, etc.) therefore come back with an empty or whitespace-only `text` field, even though Slack's search index resolved an `<@current_user>` mention inside the blocks and matched the query. Left untreated, Step 1c's KEEP-on-@-mention rule cannot fire (no body to scan) and the message is silently dropped.

Procedure:

1. **Trigger**: the bot message's `text` is empty / whitespace-only / only newlines. (Bot messages with non-empty plain text — e.g. attendance confirmers, system-notice bots — skip 1c-1 entirely and go straight to Step 1c's KEEP/DISCARD.)
2. **Refetch**: call `slack_read_channel` with:
   - `channel_id` = the message's channel
   - `oldest` = `str(float(ts) - 0.000001)` (one microsecond before the target)
   - `latest` = `str(float(ts) + 0.000001)` (one microsecond after)
   - `limit` = 1

   Both `oldest` and `latest` are **exclusive** bounds in this MCP, so setting either equal to `ts` returns zero messages. The ± 1 μs window is the tightest pinpoint that still includes the target and nothing else. The response expands `blocks` into a plain-text representation. Replace the message's `text` with that rendered body.
3. **Fallback on empty / error**: if the response contains no messages, or the call errors (API failure, rate limit, DM permission issue, message deleted since the search, etc.), record `Block Kit refetch failed for {channel_id}:{ts}` under Step 5's `⚠️ Fallback events:` section and **DISCARD** the message. Never KEEP on an unverified mention — the match in Slack's search index alone is not sufficient evidence that the current body still @-mentions the user.
4. **Apply 1c**: with the refetched body in hand, return to Step 1c's KEEP/DISCARD bullets and run the `<@current_user>` scan normally.

Non-bot messages are unaffected — skip this step for them.

Teams / Discord: if the equivalent search MCP exhibits similar Block Kit–style truncation, apply the same pattern with the platform's channel-read API. Otherwise skip.

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

## Step 1.5: Custom Source Intake

If `custom_intake_instructions` is null, skip this step.

Follow the instructions in `custom_intake_instructions` to fetch items from each configured custom source:

1. Access each source using available MCP tools or APIs as described in the instructions.
2. If the required tools are not available for a source, log a warning and skip it:
   > "Custom source '{source_name}' skipped — required tools not available."
3. For non-messaging sources (spreadsheets, task systems), use `{source_name}:{unique_id}` as the message unique ID for dedup against the Intake Log.
4. Add retrieved items to the message pool for classification in Step 2.
5. Apply the same dedup rules (Step 1d) and filters (Step 1c) where applicable.

### Stub Detection and Enrichment

Many custom sources (notably GOps imports) produce items whose description is effectively a stub — e.g. "GOpsタスク (タスクID: 4548). 見積前". Stub items create low-quality waggle tasks because the orchestrating LLM cannot build a meaningful Acceptance Criteria or Execution Plan from 20 characters of text.

For each item retrieved from a custom source, first detect whether it is a stub using the deterministic detector:

```bash
echo '<item_json>' > /tmp/item.json
bash "${CLAUDE_SKILL_DIR}/scripts/detect-stub-import.sh" /tmp/item.json
```

The output JSON has this shape:

```json
{
  "is_stub": true,
  "stub_reason": "Short description with task ID reference and only status keyword",
  "source_id": "4548",
  "description_length": 26
}
```

If `is_stub` is `false`, proceed with the item as-is. If `is_stub` is `true`, attempt enrichment:

1. **Fetch the source page body**. For Notion-based sources (like GOps), call `notion-fetch` with the source page ID or URL. For other sources, follow the fetch instructions in `custom_intake_instructions`.

2. **Fetch discussion comments**. For Notion, call `notion-get-comments` on the same page ID. The comments often contain the real requirements — the specification discussion, approval decisions, and follow-up context that did not make it into the page body.

3. **Transfer fields semantically (LLM judgment)**. The LLM reads the fetched content and maps it to the waggle task fields:
   - Source body → waggle `Description` (preserve useful headings, strip navigation)
   - Source requirements / checklist → waggle `Acceptance Criteria` if they are verifiable; otherwise treat as context
   - Most recent 5 comments (by date) → appended to waggle `Context` with a `[From {source_name} discussion]` header so the executor knows their origin
   - Source assignee (if present) → resolved via the `looking-up-members` skill and set as waggle `Assignee`
   - Source priority / severity → mapped to waggle `Priority` when the source uses a comparable scale; otherwise leave unset

4. **Fallback on fetch failure**. If the fetch fails (page deleted, permission denied, rate-limited), do not block the ingest. Proceed with the stub item, but:
   - Add `stub-import` to the waggle task's `Tags`
   - Append to `Context`: "Imported as stub from {source_name}. Enrichment fetch failed — the source page may need manual review before this task can be executed."

This enrichment step is LLM-driven by design. The deterministic detector only decides whether enrichment is worth attempting; the actual Description / AC / Context construction is a semantic task that the orchestrating LLM performs directly. No separate agent is spawned.

---

## Step 1.8: Attachment Processing

For each message in the deduplicated pool, detect and attempt to read image attachments.

### Detection

Check each message for a `files` array (Slack) or equivalent attachment field (Teams/Discord). Filter for image file types only:
- **Slack**: entries where `mimetype` starts with `image/` (e.g., `image/png`, `image/jpeg`, `image/gif`)
- **Teams / Discord**: equivalent image attachment fields

If a message has no image attachments, set `attachment_info = null` and move on.

### Image Reading (best-effort)

For each image attachment detected:

1. Check the file object for a `permalink_public` field.
2. If `permalink_public` exists and is non-null: attempt to read the image using `WebFetch` with the `permalink_public` URL.
   - If `WebFetch` succeeds and returns image content: describe the image in detail, focusing on text content, UI elements, error messages, diagrams, or any actionable information visible. Store the description. Set `read_status = "success"`.
   - If `WebFetch` fails (timeout, empty result, or HTML returned): set `read_status = "unread"` and `description = null`.
3. If `permalink_public` is not available (file not publicly shared): set `read_status = "unread"` and `description = null`. Do not attempt `WebFetch` with `permalink` or `url_private` as these require authentication that `WebFetch` cannot provide.

> **Limitation**: Most Slack files are not publicly shared, so `permalink_public` will often be absent. In practice, the majority of images will follow the "unread" path. This is by design — the user is prompted to review unread images via message permalinks in Step 2.7.

### Message Permalink

For each message that has at least one image with `read_status = "unread"` or `"skipped"`, construct (or extract from the API response) the message permalink so it can be shown to the user:
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
      read_status: "success" or "unread" or "skipped"
  message_permalink: "{constructed_or_extracted_permalink}" or null
```

- `message_permalink`: Only set when at least one image has `read_status = "unread"` or `"skipped"`. Set to `null` if all images were read successfully.
- Messages with no image attachments: `attachment_info = null`.

### Limits

- Process a maximum of **3 images per message**. If a message has more than 3 images, process the first 3. Calculate `remaining_count = total_images - 3` and note: `"({remaining_count} additional images not processed)"`.
- If the total number of images across all messages exceeds **10**, process only the first 10 (in message order) and log: `"Image processing capped at 10. {remaining} images skipped."` When the cap is reached mid-message, include all remaining images from that message in `attachment_info.images` with `read_status = "skipped"` and `description = "(global cap reached)"`. For subsequent messages that have not been processed at all, set `attachment_info = null`.

### Teams / Discord

Apply the same detection and reading pattern using equivalent attachment/file APIs. If the platform's MCP does not support file metadata, set `attachment_info = null` and note: `(attachment processing: unavailable — platform MCP does not support file metadata)`.

---

## Step 2: Classify Messages (Category × Worthiness)

Classify each message along **two dimensions** in a single LLM call (v2.8.0+):

1. **Category**: A (Hearing Needed) | B (Self-Action) | C (Delegate)
2. **Worthiness** (Layer 0): `task` | `calendar-like` | `info-only`

When `thread_context` is available, use it alongside the message text. When `attachment_info` is available and contains successfully read image descriptions, treat those descriptions as part of the message content. For example, a message saying "fix this" with an attached screenshot of a bug (successfully described) should be classified as Category B / worthiness=task if the description provides enough context to act on.

For the full classification heuristics, worthiness rules, examples, and confirmation flow, follow `references/classification-guide.md` in this directory.

When classification is unclear, treat as Category A (safe default). When worthiness is unclear, treat as `task` (never silently downgrade a message to non-task).

---

## Step 2.3: Slack Clarification for Category A Messages (opt-in)

For each Category A message, before falling through to the `[Hearing]` task creation in Step 3, evaluate whether the ambiguity can be resolved with a short Slack reply to the sender. A well-placed clarification reply often unblocks a message faster than creating a separate hearing task, and it keeps the conversation in the natural Slack thread where the sender is already engaged.

This entire step is **opt-in and gated**. If any of the prerequisites below fail, fall through to the existing Category A flow in Step 3 — the clarification logic never runs silently.

### Prerequisites (all must pass, else fall through to [Hearing] task)

1. **`slack_send_message` MCP tool is available** (auto-detect). Teams / Discord clarification is not implemented yet.

2. **The message has a `thread_ts` or is repliable** (has both `channel_id` and `ts`). If the message is a DM without a thread, use `ts` as the thread root for the reply.

3. **The current run is explicitly interactive** — gated by the `WAGGLE_EXECUTION_MODE` environment variable:
   - `WAGGLE_EXECUTION_MODE=interactive` → clarification is allowed (still subject to user approval in Step 2.3d)
   - `WAGGLE_EXECUTION_MODE=scheduled` or `unattended` → **never send Slack messages**, always fall through to `[Hearing]` task creation
   - **Unset → treat as scheduled** (safe default). Users running ingest interactively must explicitly set `WAGGLE_EXECUTION_MODE=interactive` in their shell profile. Claude Desktop Scheduled Tasks and cron jobs must NOT set it. The `setting-up-tasks` skill documents this during initial setup.

   Why this is a hard gate: inference-based detection ("are we inside a Claude Desktop Scheduled Task?") is unreliable because a user can SSH into the same machine and manually run ingest. An explicit env var avoids that class of bypass entirely.

4. **The sender is not a bot or system account**. Skip clarification if the message has `bot_id`, `subtype: bot_message`, or if the sender's display name contains obvious bot indicators (`bot`, `-bot`, `app`, `notification`). Bots do not read Slack replies — sending them a clarification is spam. Fall through to a `[Hearing]` task instead.

5. **No clarification has been sent to this thread in the last 24 hours**. This is the idempotency check: query the Active Threads record for the matching `{channel_id}:{thread_root_ts}` and check its `Clarification Sent At` field. If the timestamp is within the past 24 hours, skip this message (do not re-send, do not create a duplicate hearing task — the user is already waiting on the previous clarification).

6. **Concurrency lock**. Before composing the reply, create a lock file at `~/.waggle/locks/clarification-{channel_id}-{thread_root_ts}.lock` with the current timestamp. If the lock file already exists and its mtime is within the last 60 seconds, another ingest run is racing on the same thread — skip this message and let the other run finish. Stale locks (mtime > 60 seconds) are treated as abandoned and overwritten. The lock is released after Step 2.3e completes (success or fallback). On Cowork, the filesystem is ephemeral and runs are single-tenant, so the lock is effectively a no-op there; it remains useful for CLI and Claude Desktop runs that may race.

If **all six prerequisites pass**, proceed to Step 2.3a. Otherwise fall through to Step 3 Category A flow.

### Step 2.3a: Reason about missing information (LLM-driven)

Load `${CLAUDE_SKILL_DIR}/references/clarification-heuristics.md` as reference context. For each eligible Category A message, reason through the three dimensions defined there (Action / Target / Completion condition) using semantic understanding, not regex. Produce a structured verdict per message:

```
{
  "missing": ["action", "target", "completion"],  // subset, may be empty
  "can_clarify": bool,
  "questions": [
    { "dimension": "action", "text": "<question in sender's language>" },
    ...
  ]
}
```

Apply the decision rule from the heuristics file:
- 0 missing → reclassify as Category B (skip Step 2.3 entirely for this message)
- 1-2 missing → `can_clarify = true`, prepare that many questions
- 3 missing → present user choice in Step 2.3d (clarification OR hearing task)

### Step 2.3b: Compose the reply (LLM-driven language detection)

For each message where `can_clarify = true`, compose the full reply in the sender's language. Determine the language from the message prose using the LLM's native multilingual understanding. Do not use char-class ratios; the LLM can reliably distinguish "Japanese prose with English file paths" from "English prose with a Japanese proper noun". If the prose is truly ambiguous (e.g. the message is only a code block), fall back to the `defaultLanguage` field on the Waggle Config page, or English if that field is unset.

Follow the question templates in `clarification-heuristics.md` and wrap them in a short friendly framing — the goal is a reply that feels natural in the thread, not a robotic checklist.

### Step 2.3c: Preview to the user

Present all eligible Category A messages in a single `AskUserQuestion` call, paginated 5 per batch. For each message, show:

- The original message preview (from, first line)
- The ambiguous dimensions detected
- The composed reply text (so the user sees exactly what will go out)
- Per-message action: `[Send reply]` / `[Create hearing task instead]` / `[Skip]`

Batch-level actions:
- `[Send all drafted replies]` — fast path if the user trusts the drafts
- `[Review individually]` — per-message decision
- `[Create hearing tasks for all]` — fall through to Step 3 for every eligible message

### Step 2.3d: Execute the chosen action

For each message, based on the user's choice:

**Send reply**:
1. Re-check the idempotency prerequisites (Active Threads `Clarification Sent At` within 24h, lock file) because the user may have spent time on the preview screen.
2. Call `slack_send_message` with `channel_id`, `thread_ts = thread_ts || ts`, and the composed reply text.
3. On success:
   - Create an Intake Log entry with `Tool Name = "slack (clarification-sent)"` so the original message is marked processed and does not re-surface on the next run.
   - Create or update the Active Threads record for `{channel_id}:{thread_root_ts}`, setting `Status = active`, `Last Checked = now`, and `Clarification Sent At = now`. This registers the thread for continuous monitoring so the sender's follow-up reply is picked up in the next ingest run.
   - Release the concurrency lock.
4. On failure (network, rate limit, permission): proceed to the fallback chain in Step 2.3e.

**Create hearing task instead**: Fall through to the existing Step 3 Category A flow. The `[Hearing]` task template is defined in `task-creation-templates.md`.

**Skip**: Do NOT create an Intake Log entry. The message will re-surface in the next ingest run so the user can reconsider.

### Step 2.3e: Fallback chain on failure

Clarification must never dead-end on the user. The fallback chain is:

```
Primary: Slack clarification reply
  │
  ├─ slack_send_message fails (network, rate limit, permission denied)
  │    └─> Fallback 1: Create a [Hearing] task via the Step 3 Category A flow
  │          ├─ [Hearing] task creation fails (Notion API error, assignee
  │          │   resolution fails, schema error)
  │          │    └─> Fallback 2: Log to Intake Log with
  │          │         Tool Name = "slack (intake-failed)",
  │          │         do NOT mark the message as processed, do NOT create
  │          │         a partial task. Surface the failure in the Step 5
  │          │         summary so the user can investigate. The message
  │          │         will re-surface on the next ingest run.
  │          └─ [Hearing] task creation succeeds
  │               └─> Proceed, but note the downgrade in the summary
  └─ Success → Update Active Threads + Intake Log as in Step 2.3d
```

No auto-retry at any level. Retries are the next ingest run's job, mediated by the Intake Log dedup check.

### Active Threads registration for sent clarifications

After a successful clarification send, the Active Threads DB is the only place waggle remembers that it asked a question. The record `clarification_sent_at` timestamp is the 24h idempotency key. The existing Active Threads auto-close logic (7-day staleness → `Status = closed`) applies unchanged — if the sender never answers, the thread closes on its own and the user can decide whether to follow up manually.

---

## Step 2.5: Enrich Task Details (Category B/C)

Category B messages go through a three-phase enrichment: auto-generation, validation, and user confirmation. Category C messages use the manual-ask path because the delegating user — not the LLM — should be the one defining expectations for the recipient.

### Phase A: Auto-Generation (Category B only)

For each Category B message, the orchestrating LLM generates a draft task inline using the message content, `thread_context`, and any successfully-read `attachment_info` image descriptions as input. No separate agent is spawned; the generation happens in the orchestration context directly.

Generate the following draft fields:

1. **Acceptance Criteria** — 2 to 5 verifiable criteria. Each criterion must include at least one of: a specific command (e.g. `npm test`, `curl ...`), a file path, a numeric threshold with unit (`<2s`, `200 OK`), or an observable state verb (returns, displays, creates, passes, fails, contains, ...). The list of valid state verbs matches the semantic check that `validating-fields` applies in Phase A.5 below — produce AC that will pass that check.

2. **Hallucination guard (grounding)**: Every criterion must reference a specific keyword, entity, file path, URL, or metric that appears in the original message text or thread context. If the LLM is inclined to add a criterion that is not grounded in the source text, it must prefix that criterion with `[INFERRED] ` in the AC text. This prefix is persisted in the Notion task (not stripped before save) so that:
   - The user sees it during the Phase B review and can confirm or remove it.
   - If the user accepts as-is without removing the prefix, the `[INFERRED]` tag remains visible in the Notion page as an audit trail — whoever executes or reviews the task later knows that particular criterion was inferred, not explicitly stated.
   - If the user edits the line and removes the prefix, that manual edit is treated as confirmation that the criterion is now grounded.

3. **Execution Plan** — 3 to 7 numbered steps. Each step is an action verb + target + expected outcome. Same grounding rule: steps should reference entities present in the message.

4. **Working Directory inference** — if the message (or attachments) mentions a repository name, project name, or file path, suggest the matching absolute working directory. If no repo signal is present, leave empty — the user will decide in Phase B.

5. **Priority inference** — determine priority from the message context using natural language understanding, paying attention to negation:
   - Positive urgency signals ("urgent", "asap", "急いで", "至急", "immediately", "ブロッカー") → Urgent
   - Deadline signals ("by tomorrow", "明日まで", "today", "今日中", "this week", "今週中") → High
   - Gentle requests with no time signal → Medium
   - Explicit low urgency ("whenever", "no rush", "余裕があるとき", "low priority") → Low
   - **Negation-aware**: "this is **not** urgent", "**not** a blocker", "急ぎではない", "I **don't** think this is urgent" must NOT match Urgent. The LLM must read the surrounding 1-2 clauses before classifying, not pattern-match on the keyword in isolation.
   - If no clear signal in either direction → leave Priority unset; the Ready validator will warn but not block.

### Phase A.5: Validate Generated Fields (deterministic gate + Reviewer)

Before showing the auto-generated draft to the user:

1. **Skip-path check** — if the message was classified `worthiness=calendar-like` or `worthiness=info-only`, skip this entire phase. The Phase B confirmation table will default the row to `[Skip]` and the user decides whether to `[Create as task]`, `[Convert to note]`, or `[Discard]` (see "Phase B" below). No Reviewer cost is incurred for non-task items.

2. **Rubric (Layer 1)** — invoke the `validating-fields` skill with the generated task data and target status `"Ready"`. It returns `{valid, errors, warnings}`.

3. **Reviewer (Layer 2, v2.8.0+)** — if Rubric passes, invoke the `reviewing-quality` skill in `live` mode. **Important**: at this stage the task does not exist yet (Step 3 creates it). Pass the generated draft fields directly to `reviewing-quality`; receive the verdict **in memory** for use in Phase B's display, and persist the verdict to the new task's `Quality Verdict` field **as part of Step 3's task creation** (one `create_task` call carrying Title / Description / AC / EP / Status / Quality Verdict in a single payload), not as a separate write.

   Branch on the verdict:
   - `PASS` → display the draft normally in Phase B.
   - `NEEDS_REFINEMENT` or `REJECT` → mark the draft `[NEEDS-REFINE]` in the Phase B display, surface the Reviewer's specific gaps and suggested fixes inline, and let the user decide what to do in Phase B.

If Rubric fails (`valid: false`), do NOT spawn the Reviewer — the draft is marked `[NEEDS-REFINE]` and the Rubric errors are surfaced. (Rubric is the cheap pre-filter; the protocol forbids spending Reviewer dollars on tasks that already fail the deterministic check.)

If the user edits the draft in Phase B, the in-memory verdict is invalidated — it no longer matches the actual content. A Category B task is created at `Status: Ready`, which requires a valid verdict in the same create payload (see the Ready+ rule in `references/task-creation-templates.md`), so an edited draft cannot be created at Ready with an empty verdict. Resolve it one of two ways at task-creation time in Step 3:
- **Re-review** — invoke `reviewing-quality` in `live` mode on the edited content, and persist the returned `verdict_string` as `Quality Verdict` in the Ready create payload; or
- **Defer** — create the task at `Status: Backlog` instead (verdict omitted); the next Ready transition (via `planning-tasks`, `managing-tasks`, or `running-daily-tasks` Step 2.6) computes a fresh verdict on the actual content before promotion.

Only AC/EP accepted unchanged keep the in-memory verdict and are created at Ready directly.

No auto-retry. Auto-retry with a "stricter prompt" is intentionally avoided because it introduces non-determinism, cost inflation, and potential infinite loops when the underlying message genuinely lacks enough information. It is cheaper and more honest to show the low-confidence draft to the user and let them correct it.

### Phase B: User Confirmation (paginated batch)

Present Category B messages in pages of up to **5 messages per `AskUserQuestion` call**. If more than 5 messages exist, split into multiple pages.

Within each page, **rank messages** so the ones most likely to need the user's attention appear first:
1. Drafts marked `worthiness:calendar-like` / `worthiness:info-only` (Layer 0 flagged)
2. Drafts marked `[NEEDS-REFINE]` (Phase A.5 Rubric or Reviewer flagged)
3. Drafts whose AC contains any `[INFERRED]` prefixes
4. Longer / more complex messages (more entities referenced)
5. Higher inferred priority (Urgent → High → Medium → Low → unset)

For each page, present the following top-level options:

- **[Accept all clean]** — auto-accept every message in the page that has no worthiness flag, no `[NEEDS-REFINE]` mark, and no `[INFERRED]` criteria. Single click, whole batch moves.
- **[Review individually]** — walk through each message with per-message options.
- **[Skip batch]** — create every message in the page with the original message text only, no auto-generated AC/EP/Priority.

When the user chooses "Review individually", **worthiness-flagged** messages (`calendar-like` / `info-only`) get this 3-way prompt (default = Skip):

- **[Skip]** (default) — do not create a task. Mark the source message as processed so it does not re-surface next run.
- **[Create as task]** — create the task anyway. Add the `worthiness:calendar-like` (or `info-only`) tag and the classifier's reason to `Context`. This task will skip Layer 1/2 evaluation for the rest of its lifecycle, but per the protocol can still be delegated or executed normally.
- **[Convert to note]** — file as a Notion note (sub-page) instead of a task. (Out of scope for v2.8.0 — falls back to Skip if no note destination is configured. Logged in Step 5's `⚠️ Fallback events:` section.)

For normal (worthiness=task) messages, each gets these per-message options:

- **[Accept]** — use the auto-generated draft exactly as shown. `[INFERRED]` prefixes remain in the saved AC as an audit trail.
- **[Edit]** — user rewrites the AC/EP/Priority inline. The edited result is treated as authoritative (user-edits are NOT re-run through Reviewer — only the Rubric check applies on the next Ready transition).
- **[Manual]** — discard the auto-generated draft and capture manual AC/EP/Priority from scratch via `AskUserQuestion` sub-prompts.
- **[Skip]** — create with message content only (no AC/EP/Priority). Useful when the task is genuinely trivial or the user wants to plan it later via `planning-tasks`.

**Placeholder rule for empty AC/EP after Phase B (v2.8.0+)**: at task-creation time in Step 3, never write a literally empty `Acceptance Criteria` or `Execution Plan`. If after Phase B the resolved field is empty (e.g., the user picked `[Skip]` for a worthiness-flagged item, picked `[Create as task]` for a `calendar-like` / `info-only` row, picked `[Manual]` without filling fields, or otherwise short-circuited the draft), insert the appropriate placeholder:

- AC empty → `[DRAFT-AC] Original message: "{message_text_snippet}"`
- EP empty → `[DRAFT-EP] 1. Refine this plan with /planning-tasks 2. ...`

These placeholders ensure the task appears in `monitoring-tasks`'s `DRAFT placeholders` debt list and in `running-daily-tasks` Step 2 refinement, so worthiness-tagged tasks that exempt from the `SHALLOW_AC` / `EMPTY_AC_READY_PLUS` monitoring categories are still visible to at least one safety net. Worthiness-tagged tasks remain exempt from the Rubric R-AC1..R-AC3 / R-EP1..R-EP3 checks at Ready transitions, but R-AC4 + R-EP5 (no `[DRAFT-*]` placeholder remaining) still applies, so the user MUST remove the placeholder before promoting the task — they cannot accidentally promote an empty worthiness-tagged task to Ready.

### Phase C: Category C — Manual Ask Only

Category C tasks are delegations. The delegating user knows what they want from the recipient; the LLM should not guess. Use the existing manual-ask flow via `AskUserQuestion`:

- **Acceptance Criteria**: What is the expected deliverable?
- **Context**: Background info for the assignee (or their agent)
- **Due Date**: Any deadline?

If there are multiple Category C messages, batch them into a single `AskUserQuestion` call. If the user replies "as-is" or equivalent, proceed with only the information from the original message. Incorporate answers into the task fields when creating tasks in Step 3.

**v2.8.0+**: If after the manual ask the AC or EP is still empty, fill it with the `[DRAFT-AC]` / `[DRAFT-EP]` placeholder (per the protocol). The task remains in Backlog and shows up in the `running-daily-tasks` Step 2 refinement queue. Do not invoke Reviewer for Category C at intake — the recipient (when they accept the task) will decide whether to refine it.

---

## Step 2.7: Creation Confirmation

Display the final task list to be created (messages handled via Step 2.3 clarification replies are NOT listed here — they were processed in Step 2.3 and do not produce tasks on this run):

| # | Category | Sender | Summary | Disposition | Status | Executor | Attachments |
|---|----------|--------|---------|-------------|--------|----------|-------------|
| 1 | B: Self | @alice | Update README with new endpoints | Creating Ready task | Ready | claude-desktop | |
| 2 | A: Hearing | @bob | Fix this layout issue | [Hearing] task (user declined clarification) | Blocked | human | 1 image (read) |
| 3 | B: Self | @charlie | Bug in checkout flow | Creating Ready task | Ready | cli | 1 image (unread) |
| 4 | C: Delegate | @alice | @charlie deployment script | Delegating to @charlie | Backlog | human | |

The Disposition column is a transient display field (computed per run) that tells the user why each message is being handled this way. For Category A messages it records whether a clarification was sent, a hearing task was created, or the message was skipped. For Category B/C it shows the standard disposition.

The Attachments column shows: blank if no images, `{N} image (read)` if all images were read successfully, `{N} image (unread)` if any image could not be read, `{N} image ({S} read, {F} unread)` for mixed results. Images with `read_status = "skipped"` (global cap) are counted as unread for display purposes.

**Unread image attachments**: If any messages have images with `read_status = "unread"` or `"skipped"`, display them below the table:

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
2. **TTL cleanup** (time-based, replaces the old count-based FIFO): archive Intake Log records whose `Processed At` is older than the **same** `intake_log_retention_days` value derived in Step 0 (`max(30, ceil(lookback_period_in_days) + 7)`). Reusing the same value guarantees the in-memory dedup set built in Step 0 and the on-disk retention window in the database stay aligned within this run.
   - Compute `retention_cutoff = (now - intake_log_retention_days).date()`.
   - Query the Intake Log with `filter: {"property":"Processed At","date":{"before":"<retention_cutoff>"}}`, `page_size: 50`. Iterate `start_cursor` / `has_more` as in Step 0.
   - For each returned record, soft-delete via `notion-update-page` with `archived: true`. (Notion has no hard delete via API.)
   - **Per-run cap**: stop after archiving 200 records in total, even if more pages remain. The next run will continue from the same `before` cutoff. This bounds cleanup wall-clock time on the first run after upgrading from the old count-based FIFO, when a user may have thousands of records older than `retention_cutoff` accumulated under the prior 1000-entry cap. Without this cap, the cleanup itself could re-introduce a multi-minute hang and undo the benefit of this skill change.
   - Tolerate rate limits: on HTTP 429, honor the `Retry-After` header. Do not block the rest of the run on cleanup failure — log the error and continue. The next run will retry.
   - Skipping the cleanup is safe (the next run will catch up); skipping the load in Step 0 is not, so cleanup runs last.

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
  A (Hearing Needed): X total
    → Clarification replies sent in-thread:  X1
    → [Hearing] task pairs created:          X2
    → Skipped (user chose to defer):         X3
  B (Self-Action):    Y → Ready tasks created (auto-generated AC/EP for {y_gen} of them)
  C (Delegate):       Z → Backlog tasks created
Custom sources: {list of sources processed, or "none configured"}
  → {stub_count} stub items detected, {stub_enriched} enriched successfully
Thread context: {T} messages enriched with thread history
Attachments: {I} images detected, {S} read successfully, {F} unread or skipped
Execution mode: {"interactive" | "scheduled"} (from WAGGLE_EXECUTION_MODE)
```

If any Step 2.3 fallbacks fired (Slack send failed, hearing-task creation failed), list them below the summary so the user can investigate:

```
⚠️ Fallback events:
  - Clarification to #channel thread {ts} failed (rate limit) → fell back to [Hearing] task
  - Hearing task creation for message {id} failed (Notion schema error) → marked intake-failed, will retry next run
```

---
