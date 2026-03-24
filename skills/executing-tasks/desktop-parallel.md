# Scheduled Task Parallel Flow (Claude Desktop / Cowork)

Loaded when the user chooses "Scheduled Task parallel creation" in executing-tasks. Used by both Claude Desktop and Cowork environments.

## Step 1: Dispatch Prompt Generation

For each task, use the Dispatch Prompt Template (see `dispatch-prompt.md` in this directory) to build the prompt text.

## Step 2: Claim Task

For each task:
- Status → "In Progress"
- Dispatched At → current time in ISO 8601

## Step 3: Scheduled Task Creation

For each task, call `mcp__scheduled-tasks__create_scheduled_task`:
- `taskId`: `<task-title-slug>-<page-id-4char>` (see Slug Generation Rules below)
- `prompt`: the constructed dispatch prompt
- `description`: `Waggle: <task-title>`
- `cronExpression`: omit (manual / ad-hoc execution)

### Slug Generation Rules

To generate `<task-title-slug>` from the task title:

1. Lowercase the text
2. Replace non-alphanumeric characters with hyphens
3. Collapse consecutive hyphens
4. Trim leading/trailing hyphens
5. Truncate to 30 characters (break at hyphen boundary if possible)

`<page-id-4char>` is the first 4 characters of the task ID (for uniqueness).

Example: "Implement Login API" with ID `b2dc0275...` → `implement-login-api-b2dc`

## Step 4: Session Reference

Write `scheduled:<taskId>` to the task's Session Reference field.

## Step 5: Report

Report the created Scheduled Tasks and their working directories.
