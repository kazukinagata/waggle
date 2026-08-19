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
     runs in a separate environment on Cowork and does not inherit the host's
     `CLAUDE_*` variables, so `echo "$CLAUDE_CODE_IS_COWORK"` returns
     empty even on Cowork — confirmed for every `CLAUDE_*` variable. This
     signal is a **positive hint when present**, never a negative result
     when absent. The rule is not absolute for *all* variables: temp-directory
     variables such as `TMPDIR` are present, so absence of a variable is not by
     itself proof of the environment.
- **Skill discovery**: Provider skills appear in the `<available_skills>` system prompt block with `<name>`, `<description>`, and `<location>` tags
- **Parallel execution**: Scheduled Tasks
- **Characteristics**: the agent loop runs natively on the host; code execution
  happens in an isolated Linux VM. Persistence is two-layered — the session home is
  per-session and unreachable from other sessions, while a connected folder is
  host-backed and does survive across sessions. MCP tools are available.

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
runs in a separate environment on Cowork that does not inherit the host's
`CLAUDE_*` variables, so `echo "$CLAUDE_CODE_IS_COWORK"` returns empty even
when the host process is in Cowork mode. Falling through to CLI would
silently break: provider discovery would look for the wrong files, the
default executor recommendation would be wrong, and parallel execution
would suggest tmux parallelism, which Waggle does not offer on Cowork.

**On tmux specifically:** `tmux` *is* installed in Cowork's execution VM — the
long-standing claim that it is unavailable was wrong. Waggle still does not offer tmux
parallelism there, for a different reason: whether a pane created inside the VM is
visible to the user is unverified, and a parallel mode whose panes nobody can see is
worse than no parallel mode. Do not enable it on the strength of tmux merely existing.

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
| Turso | Yes | Yes | No | Requires `TURSO_URL` and `TURSO_AUTH_TOKEN` env vars; see the note below |
| SQLite | Yes | Yes | No | `sqlite3` is absent from Cowork's execution VM, and a local DB file on the host is not reachable from it |

**Turso on Cowork.** The blocker is credential delivery, not connectivity. The provider
reaches the database over HTTPS, which the execution VM permits, but it needs
`TURSO_URL` and `TURSO_AUTH_TOKEN` in the shell's environment. Cowork's execution VM does not inherit the host's environment, and
the injection mechanisms that do reach it require the values to sit in plaintext, which
is not an acceptable place for a database credential. Delivering a secret safely needs a
Desktop Extension, which is not available yet. This is a deliberate refusal, not a
missing feature: do not restore Cowork support on the grounds that an injection
mechanism exists.

## Provider Considerations by Environment

### MCP Tool Availability

MCP tools (e.g., `notion-update-page`) are available in all three environments. Providers that rely solely on MCP tools for data access work everywhere without environment-specific branching.

### Script Execution

Bash scripts run in all three environments, but not always in the same filesystem as
the agent loop.

- **CLI / Claude Desktop**: the agent loop and Bash share one filesystem. A path the
  agent has is a path the shell can open.
- **Cowork**: two privileged environments. The agent loop runs natively on the host
  (Read, Grep, Glob, Skill, MCP); code execution happens in an isolated Linux VM
  (Bash). The same plugin therefore exists at unrelated paths in each, and only the
  `plugin_<id>/skills/<name>` tail is common to them. Scripts themselves are present
  and executable in the VM — mounted read-only under
  `/sessions/<session>/mnt/.remote-plugins/`, byte-identical to the host copy — so the
  constraint is addressing, not availability.

Consequently a skill MUST resolve `${CLAUDE_SKILL_DIR}` in the shell before invoking a
bundled script, in the same shell invocation, and MUST fail closed if resolution does
not land on the expected file. See the `provider-contract` skill,
§ Resolving the Skill Directory, for the canonical resolver.

Tool availability in the Cowork VM, as measured: `tmux` and `jq` are present;
`sqlite3` is not.

Providers MAY still prefer MCP tools over scripts, since an MCP tool needs no path
resolution at all.

### File System Access

- **CLI / Claude Desktop**: Full local filesystem access. SQLite databases, local config files, and script execution all work.
- **Cowork**: two layers, with different persistence.
  - The **session home** is created fresh per session, and another session's home is
    permission-denied. Nothing written there survives or is shared.
  - A **connected folder** is host-backed and mounted into the VM, so writes there do
    survive across sessions. Concurrent access to one connected folder from two
    sessions is untested — do not rely on it for locking.

  Local-only providers (SQLite) are not supported regardless: `sqlite3` is not
  installed in the VM. Cloud-backed providers (Notion, Turso) work via API/MCP tools.

### Environment Variables

Environment variables (`TURSO_URL`, `NOTION_TOKEN`, etc.) are available in all environments but must be configured differently:
- **CLI**: Shell profile (`.bashrc`, `.zshrc`) or `.env` files
- **Claude Desktop**: Application settings or system environment
- **Cowork**: Project or organization environment configuration
