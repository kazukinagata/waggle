# 01-echo-baseline

Minimal MCP Desktop Extension. Establishes the "should work" baseline for diagnosing why `Notion_Extension_for_Waggle` returns 400 from Cowork Live Artifact while `sh-mcp-auth-gateway` succeeds.

## What this extension tests

- 1 tool (`echo_test`), `snake_case` name
- Simple `inputSchema` (`input: string`)
- No `user_config`
- No third-party dependencies beyond `@modelcontextprotocol/sdk`
- stdio transport (same as `notion-extension`)
- `manifest_version: 0.3` (same as `notion-extension`)

## Expected result

Success when called from a Cowork Live Artifact (`window.cowork.callMcpTool('mcp__MCPB_Debug_Echo_Baseline__echo_test', { input: 'hello' })`). This mirrors `sh-mcp-auth-gateway`'s behavior.

If this fails, custom mcpb extensions in general cannot be called from Live Artifact — investigate the Cowork runtime / mcpb pack pipeline instead of `notion-extension` internals.

## Build

```bash
cd experiments/mcpb-debug/01-echo-baseline
npm install
npx @anthropic-ai/mcpb pack .
```

Produces `mcpb-debug-echo-baseline.mcpb`.

## Install and test in Cowork

1. Open the `.mcpb` in Cowork → install (no token needed)
2. Chat smoke test: ask Claude to call `mcp__MCPB_Debug_Echo_Baseline__echo_test` with `{ input: "hi" }` → should return `"hi"`
3. Live Artifact test: register a one-button artifact that calls `window.cowork.callMcpTool('mcp__MCPB_Debug_Echo_Baseline__echo_test', { input: 'hi' })` and prints the result
4. Record: 200 success or 400 error → see `experiments/mcpb-debug/README.md` decision table
