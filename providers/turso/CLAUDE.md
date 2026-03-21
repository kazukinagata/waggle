# Waggle Turso Provider

Turso-specific provider plugin for waggle.

## Caveats

- Requires `TURSO_URL` and `TURSO_AUTH_TOKEN` environment variables to be set.
- Uses the Turso HTTP pipeline API (`/v2/pipeline`) for all SQL operations.
- Rate limits and connection timeouts are retryable (max 3 attempts with 2-second wait).
- Auth failures (401) are terminal — user must check their auth token.
