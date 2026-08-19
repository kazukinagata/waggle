# Waggle Notion Provider

Notion-specific provider plugin for waggle.

## Caveats

- Relations must be added ONE AT A TIME via `notion-update-data-source`. Batching multiple `ADD COLUMN RELATION` statements in a single call causes a 500 error.
- `notion-update-page` cannot set relation property values (Blocked By, Parent Task) because its `properties` parameter only accepts `string | number | null`. Use the `mcp__notion-extension__notion-update-relation` MCP tool instead; `update-relations.sh` (requires `NOTION_TOKEN` in shell env) is an advanced manual fallback. See notion-provider SKILL.md "Updating Relation Fields" section.
- `notion-update-page` likewise cannot set `files` property values (e.g. Attachments). Use `attach-file.sh` (CLI, `NOTION_TOKEN`) or the `mcp__notion-extension__notion-set-files-property` MCP tool (Desktop/Cowork). Local-file uploads need the integration's "Insert content" capability. Files read back from a Notion-hosted upload carry a signed URL that expires after ~1 hour — re-fetch the page for a fresh URL. See notion-provider SKILL.md "Setting the Attachments Property" section.
- Reading a `files` property's **contents** needs `notion-read-files-property` (extension v1.3.0+); no hosted tool and no CLI script can do it. That signed URL is a bearer credential, so the tool never returns it and neither should anything else — a hosted entry comes back with `url: null` by design. `type:"external"` entries are not fetched by the tool at all: Notion holds only the URL, so it is returned for a general-purpose fetcher to use. See notion-provider SKILL.md "Reading the Attachments Property".
- Notion does not support hard delete via the API. Use `notion-update-page` with `archived=true` to soft-delete.
- Rate limits (HTTP 429) are retryable — wait for `Retry-After` header seconds, then retry.
