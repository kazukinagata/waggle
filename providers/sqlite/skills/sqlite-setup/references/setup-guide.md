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

## Step 2: Initialize Database

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/sqlite-provider/scripts/init-db.sh
```

This creates `~/.waggle/tasks.db` with all required tables.

## Step 3: Create Config

Write `~/.waggle/config.json`:

```json
{
  "provider": "sqlite",
  "dbPath": "~/.waggle/tasks.db"
}
```

Use Bash to create:
```bash
mkdir -p ~/.waggle
cat > ~/.waggle/config.json << 'EOF'
{
  "provider": "sqlite",
  "dbPath": "~/.waggle/tasks.db"
}
EOF
```

## Step 4: Verify

Insert and query a test task:

```bash
DB_PATH="$HOME/.waggle/tasks.db"
sqlite3 "$DB_PATH" "INSERT INTO tasks (title, status, priority) VALUES ('Setup test', 'Backlog', 'Low') RETURNING id, title, status;"
```

If the insert succeeds, report:
> "SQLite provider is set up. Database at `~/.waggle/tasks.db`. Ready to use."

Then delete the test task:
```bash
sqlite3 "$DB_PATH" "DELETE FROM tasks WHERE title = 'Setup test';"
```
