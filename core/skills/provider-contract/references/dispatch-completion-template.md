# Dispatch Completion Template

The "On Completion Template" section in a provider SKILL.md defines the instructions that waggle core injects into dispatch prompts. These instructions tell dispatched agents how to report results back to the data source after task execution.

## How It Works

1. Waggle core's `executing-tasks` skill builds a dispatch prompt for each task.
2. The dispatch prompt includes an "On Completion" section.
3. The content of this section comes from the active provider's SKILL.md — specifically the "On Completion Template" or "Task Record Reference" section.
4. The dispatched agent reads these instructions and uses them to write results.

## Requirements

The On Completion section MUST include:

1. **Task ID placeholder** — how the dispatched agent identifies which task to update.
2. **Agent Output instructions** — how to write execution results.
3. **Status update logic** — transition to "In Review" if Requires Review is on, otherwise "Done".
4. **Error handling** — how to write error details to Error Message and set Status to "Blocked".
5. **Absolute paths** — any script paths MUST be absolute. MUST NOT use `${CLAUDE_PLUGIN_ROOT}`.
6. **Graceful failure** — if the provider update fails, the agent should complete execution anyway.

## Notion Provider Example

```markdown
## On Completion
Notion page ID for this task: `<page-id>`

On completion, perform the following:
1. Use `notion-update-page` to write execution results to the "Agent Output" field
2. Update Status:
   - If Requires Review = ON: "In Review"
   - If Requires Review = OFF: "Done"
3. On error: write error details to "Error Message" and update Status to "Blocked"
4. If the Notion update fails, ignore the error and complete execution
```

This example works because `notion-update-page` is an MCP tool available in all environments (CLI, Desktop, Cowork). No script paths are needed.

## SQL-Based Provider Example (Turso / SQLite)

```markdown
## On Completion
Task ID for this task: `<task-id>`

On completion, perform the following:
1. Run the update script to write execution results:
   ```bash
   bash /home/user/.claude/plugins/waggle-turso/skills/turso-provider/scripts/update-task.sh \
     "<task-id>" \
     --agent-output "<result summary>" \
     --status "<In Review|Done>"
   ```
   - If Requires Review = ON: use status "In Review"
   - If Requires Review = OFF: use status "Done"
2. On error, record it:
   ```bash
   bash /home/user/.claude/plugins/waggle-turso/skills/turso-provider/scripts/update-task.sh \
     "<task-id>" \
     --error-message "<error details>" \
     --status "Blocked"
   ```
3. If the update script fails, ignore the error and complete execution
```

Note: The script paths above are absolute paths resolved at dispatch time. The SKILL.md uses `${CLAUDE_PLUGIN_ROOT}` which is automatically resolved to absolute paths when the provider SKILL.md is loaded via the Skill tool.

## Writing Your On Completion Template

In your provider SKILL.md, write the template with `<page-id>` or `<task-id>` as the placeholder. Waggle core replaces this placeholder with the actual task identifier at dispatch time.

If your provider uses MCP tools (like Notion), reference the tool name directly — MCP tools are available to dispatched agents.

If your provider uses scripts, reference them with `${CLAUDE_PLUGIN_ROOT}` in the SKILL.md. The Skill tool automatically resolves this to the absolute path when the SKILL.md is loaded. The scripts themselves MUST use the `SCRIPT_DIR` pattern internally, not `${CLAUDE_PLUGIN_ROOT}`.
