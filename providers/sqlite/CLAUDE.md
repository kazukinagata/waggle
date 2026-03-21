# Waggle SQLite Provider

SQLite-specific provider plugin for waggle. Local zero-config task management.

## Caveats

- Escape single quotes in SQL values by doubling them: `'` -> `''`.
- `SQLITE_BUSY` errors are retryable — wait 1-2 seconds and retry, max 3 attempts.
- If the database file is missing, run `init-db.sh` to create it with the full schema.
