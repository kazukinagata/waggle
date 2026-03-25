# Message Classification Guide

## 3 Categories

| Category | Criteria | Action |
|---|---|---|
| **A: Hearing Needed** | Insufficient info, question format, ambiguous request, seeking approval | Main task (Status=Blocked) + Blocker task (Status=Ready, executor=human, Assignees=requester) |
| **B: Self-Action** | AI-processable implementation, research, documentation, clear work request | Task (Status=Ready, executor=claude-desktop or cli, Assignees=self) |
| **C: Delegate** | Clearly intended for another team member (name explicitly mentioned, etc.) | Task (Status=Backlog, executor=human, Assignees=assignee) |

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

## Classification Confirmation

After classifying all messages, display the results and ask the user to confirm:

| # | Category | Sender | Summary |
|---|----------|--------|---------|
| 1 | B: Self-Action | @alice | Update README with new endpoints |
| 2 | A: Hearing Needed | @bob | Design doc review request |
| 3 | C: Delegate | @alice → @charlie | Deployment script update |

Use `AskUserQuestion`: "Review the classification. Change any categories?"
- **"Looks good"** — proceed to Step 2.5 with current categories
- **"Change categories"** — for each message, ask which category (A / B / C) to assign. Update the classification before proceeding.
