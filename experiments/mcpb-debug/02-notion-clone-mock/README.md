# 02-notion-clone-mock

Mirror of `providers/notion/extension/` (manifest + schemas + startup) but with mock handlers. **Never calls the Notion API.**

> **v0.0.2 (2026-05-16)**: `display_name` removed to test the prefix-casing hypothesis confirmed in `05-echo-lowercase-name`. Tool prefix is now `mcpb-debug-notion-clone-mock` (all lowercase, hyphenated) instead of `Notion_Clone_Mock`.

## What this extension tests

Compared to `01-echo-baseline`, this extension reproduces every declarative aspect of `notion-extension`:

- 2 tools, `kebab-case` names (`notion-query`, `notion-update-relation`)
- Identical `inputSchema` to the real extension, including `filter: { type: "object" }` with no `properties` field
- `user_config.notion_token` (sensitive, required)
- `import { Client } from "@notionhq/client"` (loaded at startup, used to instantiate the client; never called)
- `display_name` removed (v0.0.2), so the Cowork tool prefix is `mcp__mcpb-debug-notion-clone-mock__...` (all lowercase, hyphenated)

Only the handlers differ: they return fixed JSON instead of calling Notion.

## Bisection logic

| 01-echo | 02-clone-mock | Conclusion | Next step |
|---|---|---|---|
| OK | **400** | Static side (manifest/schema/registration) is the cause | Build `03-…` adding the suspected manifest factor to `01` |
| OK | OK | Notion API call / response is the cause (size / shape / latency) | Build `03-notion-live-call/` that issues exactly one real `databases.query` |
| 400 | 400 | All custom mcpb extensions fail from Live Artifact | Stop bisecting; check Cowork runtime / mcpb pack pipeline |
| 400 | OK | (unlikely) | Investigate individually |

## Build

```bash
cd experiments/mcpb-debug/02-notion-clone-mock
npm install
npx @anthropic-ai/mcpb pack .
```

Produces `mcpb-debug-notion-clone-mock.mcpb`.

## Install and test in Cowork

1. Open the `.mcpb` in Cowork → install. When prompted for `Notion Internal Integration Token`, enter any non-empty dummy string (e.g., `mock`). No real API call is made.
2. Chat smoke test: ask Claude to call `mcp__mcpb-debug-notion-clone-mock__notion-query` with `{ database_id: "00000000-0000-0000-0000-000000000000" }`. Should return `{"results":[], "has_more":false, "next_cursor":null, "_mock":true}`.
3. Live Artifact test: register a one-button artifact that calls `window.cowork.callMcpTool('mcp__mcpb-debug-notion-clone-mock__notion-query', { database_id: 'x' })` and prints the result.
4. Record: 200 success or 400 error → consult the bisection table above.
