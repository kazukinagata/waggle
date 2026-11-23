---
name: health-no-uncapped-tool
description: With only the official connector, the check warns that no uncapped query tool is available and points to the Desktop Extension or a remote query connector; it does not count notion-query-data-sources as one (GROW-9458)
tags: [health-checking, grow-9458]
runs: 1
plugins: ["../..", "../../../providers/notion"]
max_turns: 30
timeout_seconds: 600
allowed_tools: [Read, Glob, Grep, Skill, TodoWrite]
---

This is a Cowork session (`execution_environment = "cowork"`, `active_provider = "notion"`). Detection is already done — do not run `detecting-provider`; the Waggle Config page has `intakeLogDatabaseId: 33333333-4444-4555-8666-777777777777`.

Run the waggle `health-checking` skill, but only its Notion query tool check (treat the other checks as skipped), and give me the report.
