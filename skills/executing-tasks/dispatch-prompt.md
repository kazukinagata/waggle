# Dispatch Prompt Template

Content of `$SDIR/task-{i}.md`. The `<ON_COMPLETION_BLOCK>` placeholder is replaced at generation time by the active provider's On Completion Template (rendered with actual task IDs, database paths, and absolute script paths).

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
<ON_COMPLETION_BLOCK>

Note: Working Directory is an absolute path.

## Rules
- Follow existing code patterns and conventions
- Write tests for new features
- Do not modify files outside the task's scope
- If blocked, do not guess — record the issue in Error Message
````
