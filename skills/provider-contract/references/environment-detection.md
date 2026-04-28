# Environment Detection

Waggle runs in three runtime environments. Provider plugins MAY need to adjust behavior based on the active environment.

## Environments

### Cowork

- **Detection** (any one signal positive → Cowork; see "Detection Logic" below):
  1. The active system prompt includes an `<application_details>` block (or
     equivalent) that mentions "Cowork" — e.g. "Claude is powering Cowork
     mode, a feature of the Claude desktop app"
  2. Cowork-specific MCP tools are available: `mcp__cowork__*` (e.g.
     `mcp__cowork__create_artifact`,
     `mcp__cowork__request_cowork_directory`) or
     `mcp__cowork-onboarding__*`
  3. Legacy: `CLAUDE_CODE_IS_COWORK=1` is set on the host. **Note:** Bash
     subshells in Cowork run in an isolated sandbox that does not inherit
     host env vars, so `echo "$CLAUDE_CODE_IS_COWORK"` typically returns
     empty even on Cowork. This signal is a **positive hint when present**,
     never a negative result when absent.
- **Skill discovery**: Provider skills appear in the `<available_skills>` system prompt block with `<name>`, `<description>`, and `<location>` tags
- **Parallel execution**: Scheduled Tasks
- **Characteristics**: Cloud-hosted agent environment. No local filesystem persistence between sessions. MCP tools are available.

### Claude Desktop

- **Detection**: `CLAUDE_CODE_ENTRYPOINT=claude-desktop`
- **Skill discovery**: Provider plugins registered in `installed_plugins.json`
- **Parallel execution**: Scheduled Tasks
- **Characteristics**: Desktop application environment. Local filesystem access. MCP tools are available.

### CLI (Terminal)

- **Detection**: `CLAUDE_CODE_ENTRYPOINT=cli` (or environment variable is unset)
- **Skill discovery**: Provider plugins registered in `installed_plugins.json`
- **Parallel execution**: tmux panes
- **Characteristics**: Terminal environment. Full local filesystem access. MCP tools are available.

## Detection Logic

Waggle core's `detecting-provider` skill determines the environment using a
multi-signal Cowork check. Any one positive Cowork signal classifies the
session as Cowork; only after all three are negative does the agent fall
through to the env-var-based Claude Desktop / CLI distinction.

```
is_cowork =
       system_prompt_mentions_cowork
    OR any_mcp__cowork__*_or_mcp__cowork-onboarding__*_tool_available
    OR  ( bash: CLAUDE_CODE_IS_COWORK == "1" )    # legacy hint, may false-negative

if is_cowork:
    execution_environment = "cowork"
elif (bash) CLAUDE_CODE_ENTRYPOINT == "claude-desktop":
    execution_environment = "claude-desktop"
else:
    execution_environment = "cli"
```

Cowork is checked first (highest priority) because `CLAUDE_CODE_ENTRYPOINT`
may also be set on Cowork.

### Why three signals

The legacy `CLAUDE_CODE_IS_COWORK=1` heuristic alone is not reliable. Bash
subshells in Cowork run in an isolated sandbox that does not inherit host
environment variables, so `echo "$CLAUDE_CODE_IS_COWORK"` returns empty even
when the host process is in Cowork mode. Falling through to CLI would
silently break: provider discovery would look for the wrong files, the
default executor recommendation would be wrong, and parallel execution
would suggest tmux (which is not available on Cowork).

Signals 1 and 2 are LLM-introspection — the agent inspects its own system
prompt and available-tools list, which are not affected by the Bash sandbox.
Keeping the env-var as a third signal preserves backward compatibility:
when it does fire, it confirms Cowork; when it doesn't, the other two
signals already cover the case. Do **not** simplify this back to a single
env-var check.

## Provider Compatibility

| Provider | CLI | Claude Desktop | Cowork | Constraint |
|---|---|---|---|---|
| Notion | Yes | Yes | Yes | Requires Notion MCP tools in all environments |
| Turso | Yes | Yes | Yes | Requires `TURSO_URL` and `TURSO_AUTH_TOKEN` env vars |
| SQLite | Yes | Yes | No | Local file not accessible from Cowork |

## Provider Considerations by Environment

### MCP Tool Availability

MCP tools (e.g., `notion-update-page`) are available in all three environments. Providers that rely solely on MCP tools for data access work everywhere without environment-specific branching.

### Script Execution

Bash scripts can run in CLI and Claude Desktop. In Cowork, script execution depends on the agent's sandbox capabilities. Providers SHOULD prefer MCP tools over scripts when possible for maximum compatibility.

### File System Access

- **CLI / Claude Desktop**: Full local filesystem access. SQLite databases, local config files, and script execution all work.
- **Cowork**: Limited filesystem. Local-only providers (SQLite) are not supported. Cloud-backed providers (Notion, Turso) work via API/MCP tools.

### Environment Variables

Environment variables (`TURSO_URL`, `NOTION_TOKEN`, etc.) are available in all environments but must be configured differently:
- **CLI**: Shell profile (`.bashrc`, `.zshrc`) or `.env` files
- **Claude Desktop**: Application settings or system environment
- **Cowork**: Project or organization environment configuration
