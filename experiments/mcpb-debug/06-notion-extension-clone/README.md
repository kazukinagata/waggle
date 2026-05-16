# 06-notion-extension-clone

Exact functional clone of `providers/notion/extension/` — **real Notion API calls**, identical server logic, identical schemas. The only changes are:

1. `manifest.json` `name` changed to `mcpb-debug-notion-extension-clone` (so it can coexist with the real extension)
2. `manifest.json` `display_name` removed → Cowork tool prefix becomes `mcp__mcpb-debug-notion-extension-clone__...` (all lowercase, hyphenated)
3. `server/index.js`'s `new Server({ name, version })` updated to match

`server/index.js` is byte-for-byte identical to `providers/notion/extension/server/index.js` apart from the server-name line.

## Purpose

After `02-notion-clone-mock` v0.0.2 confirmed the prefix-casing fix works against mock handlers, this extension confirms the same fix works against **real Notion** end-to-end — before committing to the breaking change in the production extension.

## Build

```bash
cd experiments/mcpb-debug/06-notion-extension-clone
npm install
npx @anthropic-ai/mcpb pack .
```

## Install and test

1. Install in Cowork → enter a **real** Notion integration token (your `ntn_...`)
2. Chat smoke: `mcp__mcpb-debug-notion-extension-clone__notion-query` against any real DB ID
3. Live Artifact: `window.cowork.callMcpTool('mcp__mcpb-debug-notion-extension-clone__notion-query', { database_id: '<real-db>', page_size: 1 })`

Expected: ✅ same result as chat (real Notion data returned). If so, removing `display_name` from the real extension will fix the production issue.
