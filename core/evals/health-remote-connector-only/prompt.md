---
name: health-remote-connector-only
description: With only a remote query connector (server name is an opaque UUID) providing the uncapped notion-query, plus the official connector, health-checking's Notion query tool check passes and names that connector (GROW-9458)
tags: [health-checking, grow-9458]
runs: 1
plugins: ["../..", "../../../providers/notion"]
max_turns: 30
timeout_seconds: 600
allowed_tools: [Read, Glob, Grep, Skill, TodoWrite]
---

This is a Cowork session (`execution_environment = "cowork"`, `active_provider = "notion"`). Detection is already done — do not run `detecting-provider`; the Waggle Config page has `intakeLogDatabaseId: 33333333-4444-4555-8666-777777777777`.

Run the waggle `health-checking` skill, but only its Notion query tool check (treat the other checks as skipped), and give me the report.
