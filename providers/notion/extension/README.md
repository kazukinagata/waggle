# notion-extension Desktop Extension

MCP server for Notion database operations that the hosted Notion MCP cannot handle:
- **Query** with people property filters (e.g., Assignee)
- **Update relation properties** (e.g., Blocked By, Parent Task) with replace/append modes
- **Upload images** into a page body (local file via the Notion File Upload API, or external URL)
- **Read images** from a page body as inline image content the model can see

## Build

```bash
cd providers/notion/extension
npm install
npx @anthropic-ai/mcpb pack .
```

This produces `extension.mcpb` (named after the directory).

## Install

Open the `.mcpb` file in Claude Desktop or Cowork. You will be prompted to enter your Notion internal integration token.

### Creating the token

1. Go to https://www.notion.so/profile/integrations
2. Click **New integration**
3. Capabilities: **Read content**, **Update content**, and **Insert content**
   (Insert content is required for `notion-upload-image` — without it Notion
   returns `403 restricted_resource` when appending blocks)
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
{"property":"Assignee","people":{"contains":"<user_id>"}}

// Ready tasks by assignee
{"and":[{"property":"Status","select":{"equals":"Ready"}},{"property":"Assignee","people":{"contains":"<user_id>"}}]}
```

## Tool: notion-update-relation

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `page_id` | string | yes | Notion page UUID to update |
| `property_name` | string | yes | Relation property name (e.g., "Blocked By") |
| `mode` | string | yes | `"replace"` or `"append"` |
| `relation_ids` | string[] | no | Page IDs for the relation (default: `[]`) |

- **replace**: Sets the relation to exactly the provided IDs. Empty array clears the relation.
- **append**: Merges with existing relation values and deduplicates. Empty array is a no-op (returns the existing relation IDs without writing). To clear the relation use `mode: "replace"` with `relation_ids: []`.

Returns a minimal confirmation echo:

```json
{
  "ok": true,
  "page_id": "<uuid>",
  "property_name": "Blocked By",
  "mode": "append",
  "relation_ids": ["<id1>", "<id2>", "<id3>"]
}
```

`relation_ids` is the **post-update final state** of the relation (for `append`, this is the merged + deduplicated list). If callers need other page fields (properties, `last_edited_time`, `archived`), fetch the page separately via `notion-fetch` or `notion-query`. This shape was chosen over returning the full Page object to keep MCP tool output small — relation updates are frequent in Waggle workflows.

### Examples

```json
// Set Blocked By to multiple tasks
{"page_id":"<page_id>","property_name":"Blocked By","mode":"replace","relation_ids":["<id1>","<id2>"]}

// Append a blocker
{"page_id":"<page_id>","property_name":"Blocked By","mode":"append","relation_ids":["<new_id>"]}

// Clear a relation
{"page_id":"<page_id>","property_name":"Blocked By","mode":"replace","relation_ids":[]}
```

## Tool: notion-upload-image

Appends an image block to a page body. Requires the integration's **Insert content** capability.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `page_id` | string | yes | Notion page (or block) UUID to append the image to |
| `file_path` | string | one of | Absolute path to a local image file. Uploaded via the Notion File Upload API (single-part, max 20MB; free workspaces are capped lower by Notion). Mutually exclusive with `external_url`. |
| `external_url` | string | one of | Publicly reachable image URL, embedded as an external image block (no upload). Mutually exclusive with `file_path`. |
| `caption` | string | no | Caption text for the image block |

Supported file extensions: png, jpg, jpeg, gif, webp, svg, bmp, tif, tiff, heic, ico.

Returns a minimal confirmation echo:

```json
{"ok": true, "page_id": "<uuid>", "block_id": "<uuid>", "image_type": "file_upload", "filename": "screenshot.png"}
```

`image_type` is `"file_upload"` for local files and `"external"` for URLs.

### Examples

```json
// Paste a local screenshot
{"page_id":"<page_id>","file_path":"/tmp/screenshot.png","caption":"build failure"}

// Embed an external image
{"page_id":"<page_id>","external_url":"https://example.com/mockup.png"}
```

## Tool: notion-read-images

Reads images from a page body and returns them as **inline image content** the model can see directly — no URL handling needed (Notion's `file`-type URLs are signed and expire after ~1 hour; this tool downloads them immediately).

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `page_id` | string | yes | Notion page (or block) UUID to read images from |
| `max_images` | integer | no | Max images returned inline (default 10, max 20). Overflow is listed in `skipped`. |
| `block_ids` | string[] | no | Only return images whose block ID is in this list (with or without dashes) |
| `include_nested` | boolean | no | Recurse into container blocks (toggles, columns, callouts), depth capped at 3. Default `true`. Child pages/databases are never descended into. |

The response is a mixed content array: first a text part with a JSON summary, then the image parts in the same order as the summary's `images` array:

```json
{
  "count": 2,
  "total_found": 3,
  "images": [
    {"index": 0, "block_id": "<uuid>", "mime_type": "image/png", "size_bytes": 48211, "caption": "mockup", "source_type": "file"}
  ],
  "skipped": [
    {"block_id": "<uuid>", "mime_type": "image/svg+xml", "url": "https://...", "reason": "not a raster type the model can view inline (png/jpeg/gif/webp)"}
  ]
}
```

Images over 5MB and non-raster types (svg, tiff, heic) are listed in `skipped` instead of returned inline.
