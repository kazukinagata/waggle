# Dispatch Prompt Template

Content of `$SDIR/task-{i}.md`. Replace `<On Completion>` with the provider-specific update instruction from the active provider's SKILL.md (Task Record Reference section).

The template below uses placeholders in angle brackets. Omit sections whose source field is empty.

````markdown
# <Title>

You are an AI agent executing a development task delegated by the Waggle Orchestrator.
Complete the task autonomously.

## Description
<Description>

## Acceptance Criteria
<Acceptance Criteria>

## Context
<Context> (omit if empty)

## Execution Plan
<Execution Plan> (omit if empty)

## Environment
- Repository: <Repository> (omit if empty)
- Working Directory: <Working Directory>
- Git Branch: <Branch> (only if set)

## On Completion
Notion page ID for this task: `<page-id>`

On completion, perform the following:
1. Use `notion-update-page` to write execution results to the "Agent Output" field (available in both environments)
2. Update Status:
   - If Requires Review = ON: "In Review"
   - If Requires Review = OFF: "Done"
3. On error: write error details to "Error Message" and update Status to "Blocked"
4. If the Notion update fails, ignore the error and complete execution

Note: Working Directory is an absolute path.

## Rules
- Follow existing code patterns and conventions
- Write tests for new features
- Do not modify files outside the task's scope
- If blocked, do not guess — record the issue in Error Message
````
