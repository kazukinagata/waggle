---
name: query-prefers-uncapped
description: With both an uncapped notion-query tool (a remote connector whose server name is an opaque UUID) and the official connector's notion-query-data-sources available, the notion-provider query flow uses the uncapped tool, passes page_size, and never calls the official data-source query or notion-search (GROW-9457)
tags: [query, tool-selection, grow-9457]
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
