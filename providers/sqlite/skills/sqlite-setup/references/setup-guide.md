# Waggle — SQLite Provider Setup

## Step 1: Prerequisites

Verify sqlite3 and jq are available:

```bash
command -v sqlite3 && echo "sqlite3: OK" || echo "sqlite3: NOT FOUND"
command -v jq && echo "jq: OK" || echo "jq: NOT FOUND"
```

If either is missing, guide the user:
- **sqlite3**: `sudo apt install sqlite3` (Linux) / `brew install sqlite` (macOS)
- **jq**: `sudo apt install jq` (Linux) / `brew install jq` (macOS)

## Step 2: Configure Database Path (optional)

The default database path is `~/.waggle/tasks.db`. If the user wants a custom path, set the `WAGGLE_SQLITE_DB_PATH` environment variable in `~/.claude/settings.json`:

```json
{
  "env": {
    "WAGGLE_SQLITE_DB_PATH": "/custom/path/to/tasks.db"
  }
}
```

If using the default path, this step can be skipped.

## Step 3: Initialize Database

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/sqlite-provider/scripts/init-db.sh "${WAGGLE_SQLITE_DB_PATH:-$HOME/.waggle/tasks.db}"
```

This creates the database with all required tables at the configured path (or the default `~/.waggle/tasks.db`).

## Step 4: Verify

Insert and query a test task:

```bash
DB_PATH="${WAGGLE_SQLITE_DB_PATH:-$HOME/.waggle/tasks.db}"
sqlite3 "$DB_PATH" "INSERT INTO tasks (title, status, priority) VALUES ('Setup test', 'Backlog', 'Low') RETURNING id, title, status;"
```

If the insert succeeds, report:
> "SQLite provider is set up. Database at `<DB_PATH>`. Ready to use."

Then delete the test task:
```bash
sqlite3 "$DB_PATH" "DELETE FROM tasks WHERE title = 'Setup test';"
```
