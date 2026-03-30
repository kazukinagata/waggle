# Waggle Notion Provider

Notion-specific provider plugin for waggle.

## Caveats

- Relations must be added ONE AT A TIME via `notion-update-data-source`. Batching multiple `ADD COLUMN RELATION` statements in a single call causes a 500 error.
- `notion-update-page` cannot set relation property values (Blocked By, Parent Task) because its `properties` parameter only accepts `string | number | null`. Use `update-relations.sh` (requires `NOTION_TOKEN`) instead. See notion-provider SKILL.md "Updating Relation Fields" section.
- Notion does not support hard delete via the API. Use `notion-update-page` with `archived=true` to soft-delete.
- Rate limits (HTTP 429) are retryable — wait for `Retry-After` header seconds, then retry.
