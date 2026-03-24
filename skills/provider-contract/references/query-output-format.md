# Query Output Format

All provider query operations MUST return results in this standard format.

## Format

```json
{
  "results": [
    { /* Task object */ },
    { /* Task object */ },
    ...
  ]
}
```

Each Task object in the `results` array contains:
- `id` — the provider-specific unique identifier for the task
- All Core field values (using canonical JSON keys from `task-schema.md`)
- Any Extended field values that are populated (omit or set to `null` if absent)

## Example Response

```json
{
  "results": [
    {
      "id": "abc-123-def",
      "title": "Implement user authentication",
      "description": "Build JWT-based authentication with refresh tokens...",
      "acceptanceCriteria": "1. Login endpoint returns JWT\n2. Refresh token rotation works",
      "status": "Ready",
      "priority": "High",
      "executor": "cli",
      "blockedBy": [],
      "requiresReview": true,
      "executionPlan": "1. Set up JWT middleware\n2. Create login endpoint\n3. Add refresh logic",
      "workingDirectory": "/home/user/api-server",
      "sessionReference": "",
      "dispatchedAt": null,
      "agentOutput": "",
      "errorMessage": "",
      "dueDate": "2026-03-28",
      "assignees": [{ "id": "user-456", "name": "Bob" }],
      "tags": ["auth", "backend"]
    },
    {
      "id": "ghi-789-jkl",
      "title": "Write API documentation",
      "description": "Document all REST endpoints using OpenAPI 3.0...",
      "acceptanceCriteria": "1. All endpoints documented\n2. Examples included",
      "status": "Ready",
      "priority": "Medium",
      "executor": "cli",
      "blockedBy": ["abc-123-def"],
      "requiresReview": false,
      "executionPlan": "1. Generate OpenAPI skeleton\n2. Add endpoint details\n3. Add examples",
      "workingDirectory": "/home/user/api-server",
      "sessionReference": "",
      "dispatchedAt": null,
      "agentOutput": "",
      "errorMessage": "",
      "assignees": [{ "id": "user-456", "name": "Bob" }],
      "tags": ["docs"]
    }
  ]
}
```

## Notes

- The `results` array MAY be empty if no tasks match the filter.
- Extended fields that have no value SHOULD be omitted or set to `null`.
- The `blockedBy` array contains task IDs (strings), not full task objects.
- Provider-specific metadata (e.g., Notion page URLs, database-specific IDs) MAY be included as additional fields but MUST NOT conflict with canonical field names.
- Query-only fields (`branch`, `sourceMessageId`) MAY appear in query results but are excluded from view server data push.
