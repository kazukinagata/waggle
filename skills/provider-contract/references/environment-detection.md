# Environment Detection

Waggle runs in three runtime environments. Provider plugins MAY need to adjust behavior based on the active environment.

## Environments

### Cowork

- **Detection**: `CLAUDE_CODE_IS_COWORK=1` environment variable is set, `CLAUDE_CODE_ENTRYPOINT=local-agent`
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

Waggle core's `detecting-provider` skill determines the environment:

```
if CLAUDE_CODE_IS_COWORK == "1":
    execution_environment = "cowork"
elif CLAUDE_CODE_ENTRYPOINT == "claude-desktop":
    execution_environment = "claude-desktop"
else:
    execution_environment = "cli"
```

Cowork is checked first (highest priority) because `CLAUDE_CODE_ENTRYPOINT` may also be set on Cowork.

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
