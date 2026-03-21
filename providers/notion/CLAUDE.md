# Waggle Notion Provider

Notion-specific provider plugin for waggle.

## Caveats

- Relations must be added ONE AT A TIME via `notion-update-data-source`. Batching multiple `ADD COLUMN RELATION` statements in a single call causes a 500 error.
- Notion does not support hard delete via the API. Use `notion-update-page` with `archived=true` to soft-delete.
- Rate limits (HTTP 429) are retryable — wait for `Retry-After` header seconds, then retry.
