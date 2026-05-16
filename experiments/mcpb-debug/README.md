# mcpb-debug: Cowork Live Artifact 400 isolation

Series of minimal `.mcpb` Desktop Extensions used to diagnose why
`mcp__Notion_Extension_for_Waggle__notion-query` returns HTTP 400 when called
from a Cowork **Live Artifact** (via `window.cowork.callMcpTool`), while:

- the same call from Cowork **chat** succeeds
- a different Desktop Extension (`sh-mcp-auth-gateway`) called from a Live Artifact succeeds
- Notion's **Hosted MCP** called from a Live Artifact succeeds

The extension's stdio server in `providers/notion/extension/server/index.js` has no
custom request validation or auth — so the 400 is produced upstream (Cowork runtime /
mcpb bridge) and is triggered by something specific to `Notion_Extension_for_Waggle`'s
**declarative shape** (manifest, schemas, tool names, `user_config`, dependencies, startup)
or its **Notion API behavior** (response size, latency, shape).

These extensions bisect that space.

## Bisection strategy

| Phase | Extension | Question it answers |
|---|---|---|
| 1 | `01-echo-baseline/` | Can a minimal mcpb extension be called from a Live Artifact at all? (Should be **yes** — `sh-mcp-auth-gateway` already proves so.) |
| 1 | `02-notion-clone-mock/` | Is the cause in the declarative shape of `notion-extension`, or in its real Notion API calls? Same manifest + schemas + startup as the real extension, but handlers return fixed mock JSON. |
| 2a *(if needed)* | `03-…`, `04-…`, ... | Conditional on Phase 1 outcome — see decision table below. |

### Phase 1 result (2026-05-16)

Both `01-echo-baseline` and `02-notion-clone-mock` returned **400** from a Cowork Live Artifact — same as the real `Notion_Extension_for_Waggle`. Phase 1's decision table collapsed to the "All custom Node-based mcpb extensions fail" row: the cause is **NOT** Notion-specific manifest/schema, NOT the Notion API call, NOT `user_config`, NOT multi-tool registration, NOT kebab-case tool names.

The only confirmed-working custom extension is `sh-mcp-auth-gateway`. Inspecting its `.mcpb` reveals these differences vs ours:

| Aspect | sh-mcp-auth-gateway (✅) | Our extensions (❌) |
|---|---|---|
| `manifest_version` | `"0.2"` | `"0.3"` |
| `server.type` | `"binary"` (compiled Mach-O) | `"node"` |
| Tool declaration | `"tools_generated": true` (no `tools` array) | explicit `"tools"` array |
| `mcp_config.command` | absolute path to binary | bare `"node"` |
| `compatibility.platforms` / `keywords` | absent | present |

### Phase 2: which of these flips the result?

Bisect by minimal diff against `01-echo-baseline`. Each variant changes **only one** field:

- `03-echo-manifest-v02` — only `manifest_version` switched to `"0.2"`
- `04-echo-tools-generated` — only `tools_generated: true` (and removed explicit `tools` array)
- `05-echo-lowercase-name` — only `display_name` removed and `name` is all-lowercase hyphenated. Hypothesis: working tool prefixes are all lowercase (`sh-mcp-auth-gateway`, hex Hosted-MCP ID), failing ones (`MCPB_Debug_Echo_Baseline`, `Notion_Clone_Mock`, `Notion_Extension_for_Waggle`) all contain uppercase letters/underscores generated from `display_name`. Expected tool prefix here: `mcpb-debug-echo-lowercase`.
- *(deferred)* `06-echo-binary` — only `server.type: "binary"`. Requires compiling Node code to a single executable (e.g., `node --experimental-sea-config` or `pkg`). Skip unless 03/04/05 all still 400.

## Per-extension procedure

For every extension `NN-name/`:

```bash
cd experiments/mcpb-debug/<NN-name>
npm install
npx @anthropic-ai/mcpb pack .
```

Then in Cowork:

1. Open the produced `.mcpb` → install. If the extension declares `user_config`, enter any non-empty dummy string (no real API call is made by mock extensions).
2. **Chat smoke test**: call the extension's tool from Cowork chat once. Should succeed — confirms the extension is healthy.
3. **Live Artifact test**: register a tiny artifact that calls `window.cowork.callMcpTool('mcp__<display_name_with_underscores>__<tool_name>', args)` and prints the result.
4. Record success / 400 in the table below.

## Result log

| Extension | Chat smoke | Live Artifact | Notes |
|---|---|---|---|
| `01-echo-baseline` | ✅ | ❌ 400 | tool: `mcp__MCPB_Debug_Echo_Baseline__echo_test` |
| `02-notion-clone-mock` v0.0.1 | ✅ | ❌ 400 | tool: `mcp__Notion_Clone_Mock__notion-query` (with `display_name`) |
| `02-notion-clone-mock` v0.0.2 | ⬜ | ⬜ | tool: `mcp__mcpb-debug-notion-clone-mock__notion-query` (`display_name` removed — confirms fix works on complex multi-tool/user_config setup) |
| `03-echo-manifest-v02` | ⬜ | ⬜ | tool: `mcp__MCPB_Debug_Echo_Manifest_V02__echo_test` |
| `04-echo-tools-generated` | ⬜ | ⬜ | tool: `mcp__MCPB_Debug_Echo_Tools_Generated__echo_test` |
| `05-echo-lowercase-name` | ⬜ | ⬜ | tool: `mcp__mcpb-debug-echo-lowercase__echo_test` |
| `06-notion-extension-clone` | ⬜ | ⬜ | exact functional clone of real `notion-extension` (real Notion API), no `display_name`. tool: `mcp__mcpb-debug-notion-extension-clone__notion-query` |

Reference (working baseline, not built here):
- `sh-mcp-auth-gateway` — Cowork Live Artifact: ✅
- `mcp__daf76358-…` (Notion Hosted MCP) — Cowork Live Artifact: ✅

## Out of scope

- HTML artifacts to drive the Live Artifact tests live on the Cowork side and are not committed here.
- These extensions are throwaways. Delete the directories once the root cause is identified.
