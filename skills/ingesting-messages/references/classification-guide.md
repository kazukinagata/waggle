# Message Classification Guide

## 3 Categories

| Category | Criteria | Action |
|---|---|---|
| **A: Hearing Needed** | Insufficient info, question format, ambiguous request, seeking approval | Main task (Status=Blocked) + Blocker task (Status=Ready, executor=human, Assignee=requester) |
| **B: Self-Action** | AI-processable implementation, research, documentation, clear work request | Task (Status=Ready, executor=claude-desktop or cli, Assignee=self) |
| **C: Delegate** | Clearly intended for another team member (name explicitly mentioned, etc.) | Task (Status=Backlog, executor=human, Assignee=assignee) |

**When classification is unclear**: Treat as Category A (safe default).

## Classification Heuristics and Examples

**Category A (Hearing Needed)** — default when uncertain:
- Question format: "Can you ...?", "What's the status of ...?"
- Approval requests: "Review and approve this"
- References context the AI does not have: "about that thing we discussed yesterday"
- Example: `"Hey, can you look at the design doc and let me know if the approach works?"` → A (which document? what feedback criteria?)

**Category B (Self-Action)** — clear and actionable:
- Specific work request: "Write unit tests for the auth module"
- Research / summary: "Compile the Q3 metrics report"
- Implementation request with sufficient context to start
- Example: `"Please update the README to include the new API endpoints"` → B

**Category C (Delegate)** — explicitly addressed to another member:
- Names another member: "Ask @alice to ..."
- Current user is CC; the action owner is someone else
- Example: `"@you FYI — @bob needs to update his deployment script"` → C (action owner is Bob)

**Decision rule**: If torn between B and A → choose A. If torn between C and A → choose A. A is always the safe default.

## Using Thread Context for Classification

When `thread_context` is available for a message, use the full thread conversation — not just the individual reply — to determine the correct category:

1. **Read the parent message first**: The parent often establishes the topic and intent. A reply that says "sure, go ahead" is ambiguous alone but clear when the parent says "Can I refactor the auth module?"
2. **Track action ownership across the thread**: If earlier messages establish that a specific person is responsible, a follow-up reply may be a status update (Category A) rather than a new work request (Category B).
3. **Resolve ambiguous references**: Thread replies frequently use pronouns ("it", "that", "this") or short phrases. The parent message and preceding replies resolve these references.

### Thread-Aware Examples

| Message alone | Without context | With thread context | Correct classification |
|---|---|---|---|
| "Sure, I'll handle it" | A (unclear what "it" is) | Parent: "@you Can you write the migration script for the users table?" | B (Self-Action — clear task) |
| "Done" | A (what is done?) | Parent: "@you Please review PR #42" → earlier reply: "Looking at it now" | A (Hearing — need to confirm what action, if any, remains) |
| "Can you take a look?" | A (ambiguous) | Parent: "@alice Deploy fix for #123" → "@you Can you take a look?" | B (Self-Action — code review request with clear PR reference) |

## Using Attachment Info for Classification

When `attachment_info` is available for a message and images were successfully read (`read_status = "success"`), incorporate the image descriptions into classification:

1. **Image descriptions expand message context**: A terse message like "fix this" paired with a successfully-read screenshot description of "a 500 error on the login page with stack trace showing NullPointerException in AuthService.java line 42" transforms an ambiguous message into a clear, actionable request (Category B).
2. **Unread images increase ambiguity**: If a message has image attachments that could NOT be read, treat the message as having incomplete context. This makes Category A (Hearing Needed) more likely, since the image might contain critical information for understanding the request.
3. **Multiple images**: When a message has several images, consider all successfully-read descriptions together to understand the full picture.

### Attachment-Aware Examples

| Message text | Image status | Without image | With image context | Classification |
|---|---|---|---|---|
| "fix this" | read: "500 error on /login with stack trace" | A (unclear what "this" is) | B (clear bug with location) | B |
| "fix this" | unread | A (unclear) | A (still unclear, image might clarify) | A |
| "thoughts?" | read: "architecture diagram showing microservice layout" | A (no context) | A (diagram helps, but still a question needing human judgment) | A |
| "deploy this to prod" | read: "screenshot of a config.yaml file" | B (clear action) | B (action is clear, config visible) | B |

## Classification Confirmation

After classifying all messages, display the results and ask the user to confirm:

| # | Category | Sender | Summary | Thread | Attachments |
|---|----------|--------|---------|--------|-------------|
| 1 | B: Self-Action | @alice | Update README with new endpoints | | |
| 2 | A: Hearing Needed | @bob | Design doc review request | yes | |
| 3 | B: Self-Action | @charlie | Fix checkout bug | | 1 image (read) |
| 4 | A: Hearing Needed | @dave | Fix this | | 1 image (unread) |
| 5 | C: Delegate | @alice → @charlie | Deployment script update | | |

The Thread column shows "yes" if thread context was used for classification, blank otherwise. The Attachments column shows: blank if no images, `{N} image (read)` if all images were read successfully, `{N} image (unread)` if any image could not be read, `{N} image ({S} read, {F} unread)` for mixed results.

Use `AskUserQuestion`: "Review the classification. Change any categories?"
- **"Looks good"** — proceed to Step 2.5 with current categories
- **"Change categories"** — for each message, ask which category (A / B / C) to assign. Update the classification before proceeding.
