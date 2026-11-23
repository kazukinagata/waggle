---
name: query-permission-falls-back-to-official
description: When the only uncapped notion-query tool returns a permission error, the query flow falls back to the official connector's notion-query-data-sources and tells the user the error text verbatim (GROW-9455 comment, GROW-9457)
tags: [query, permission-error, grow-9457]
runs: 1
plugins: ["../.."]
max_turns: 30
timeout_seconds: 600
allowed_tools: [Read, Glob, Grep, Skill, TodoWrite]
---

This is a Cowork session (`execution_environment = "cowork"`, `active_provider = "notion"`). Detection is already done — do not run `detecting-provider` or `resolving-identity`; use these values:

- `tasksDatabaseId`: `11111111-2222-4333-8444-555555555555`
- current user (Notion user ID): `99999999-aaaa-4bbb-8ccc-dddddddddddd`

Follow the waggle-notion `notion-provider` skill's "Querying Tasks" flow and list my Ready tasks (title and priority). This is read-only: do not create or update any page.
