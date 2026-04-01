# notion-extension Desktop Extension

MCP server for Notion database operations that the hosted Notion MCP cannot handle:
- **Query** with people property filters (e.g., Assignees)
- **Update relation properties** (e.g., Blocked By, Parent Task) with replace/append modes

## Build

```bash
cd providers/notion/extension
npm install
npx @anthropic-ai/mcpb pack .
```

This produces `notion-extension.mcpb`.

## Install

Open the `.mcpb` file in Claude Desktop or Cowork. You will be prompted to enter your Notion internal integration token.

### Creating the token

1. Go to https://www.notion.so/profile/integrations
2. Click **New integration**
3. Capabilities: **Read content** and **Update content**
4. Copy the token (`ntn_...`)
5. In Notion, open your **Waggle** page → **⋯** → **Connections** → connect the integration

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

## Tool: notion-update-relation

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `page_id` | string | yes | Notion page UUID to update |
| `property_name` | string | yes | Relation property name (e.g., "Blocked By") |
| `mode` | string | yes | `"replace"` or `"append"` |
| `relation_ids` | string[] | no | Page IDs for the relation (default: `[]`) |

- **replace**: Sets the relation to exactly the provided IDs. Empty array clears the relation.
- **append**: Merges with existing relation values and deduplicates.

Returns the updated Notion page object.

### Examples

```json
// Set Blocked By to multiple tasks
{"page_id":"<page_id>","property_name":"Blocked By","mode":"replace","relation_ids":["<id1>","<id2>"]}

// Append a blocker
{"page_id":"<page_id>","property_name":"Blocked By","mode":"append","relation_ids":["<new_id>"]}

// Clear a relation
{"page_id":"<page_id>","property_name":"Blocked By","mode":"replace","relation_ids":[]}
```
