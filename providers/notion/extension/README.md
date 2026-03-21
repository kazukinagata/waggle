# notion-query Desktop Extension

MCP server that queries Notion databases with server-side filtering. Supports people property filters (Assignees) that the Notion hosted MCP cannot handle.

## Build

```bash
cd skills/providers/notion/extension
npm install
npx @anthropic-ai/mcpb pack .
```

This produces `notion-query.mcpb`.

## Install

Open the `.mcpb` file in Claude Desktop or Cowork. You will be prompted to enter your Notion internal integration token.

### Creating the token

1. Go to https://www.notion.so/profile/integrations
2. Click **New integration**
3. Capabilities: **Read content** only
4. Copy the token (`ntn_...`)
5. In Notion, open your **Agentic Tasks** page → **⋯** → **Connections** → connect the integration

## Tool: notion-query

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `database_id` | string | yes | Notion database UUID |
| `filter` | object | no | Notion filter object |
| `sorts` | array | no | Notion sorts array |

Returns `{"results": [...]}` with full page objects across all pages (pagination handled automatically).

### Filter examples

```json
// Tasks assigned to a user
{"property":"Assignees","people":{"contains":"<user_id>"}}

// Ready tasks by assignee
{"and":[{"property":"Status","select":{"equals":"Ready"}},{"property":"Assignees","people":{"contains":"<user_id>"}}]}
```
