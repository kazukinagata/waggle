# Changelog

All notable changes to the Waggle project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/).

## [2.0.0] - 2026-04-09

### Breaking Changes
- **Rename `Assignees` → `Assignee`** across all providers and skills. Notion DB column must be renamed via migration script after upgrade.
- Canonical JSON key changed from `assignees` to `assignee`.

### Added
- **Active Threads tracking** in `ingesting-messages`: Threads the user has participated in are now persisted in an Active Threads DB, so new replies are detected even after the original messages fall outside the lookback period.
- **Team name detection** in `looking-up-members`: Queries matching a team name now return a `teamMatch` result instead of expanding to all team members.
- **Single-assignee validation warning** in `validate-task-fields.sh`: Warns when `assigneeCount > 1`.
- `Created At` (created_time) field added to task schema.
- `Acknowledged At` (date) field added to task schema.
- `Cancelled` status option added to Status enum.
- `CHANGELOG.md` for tracking release history.
- `troubleshooting` skill for diagnosing common issues.

### Changed
- Strengthened single-assignee rule in `assigning-to-others`, `delegating-tasks`, and `task-creation-flow` to explicitly reject team/group assignments.
- Team name guard added to `delegating-tasks` Step 3.

### Migration
After merging, run the migration script:
```bash
NOTION_TOKEN=xxx bash /tmp/migrate-assignee.sh <database_id>
```
This will:
1. Rename `Assignees` → `Assignee`
2. Add `Created At` (created_time) column
3. Add `Acknowledged At` (date) column
