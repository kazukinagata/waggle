# Changelog

All notable changes to the Waggle project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/).

## [2.4.0] - 2026-04-13

This release is a comprehensive task quality improvement pass based on an analysis of ~60 tasks in a real Notion Tasks DB. The analysis found systemic issues: ~50% of tasks had empty Acceptance Criteria, ~73% had no Execution Plan, ~80% of Done AI tasks had no Agent Output, ~35% had no Priority, GOps imports often produced stubs, `[DRAFT — update after hearing]` placeholders were never refined, and test tasks lingered indefinitely. This release addresses each of those issues through a combination of validation gates (for new tasks), monitoring visibility (for existing debt), and ingest-time auto-generation (for incoming messages).

### Added

#### Validation gates (applied to new task transitions)
- **Agent Output required on Done** (`validating-fields`): AI executor tasks (cli / claude-code / claude-desktop / cowork) transitioning to Done now fail validation if Agent Output is empty. Legacy tasks created before the 2026-04-14 enforcement cutoff remain a warning only, so historical Done tasks are not retroactively invalidated. The canonical input format gains `createdAt` (used for the legacy cutoff) and `repository` fields.
- **Code task Working Directory / Repository warnings** (`validating-fields`): AI-executor tasks at Ready transition emit recommended warnings when their description / AC / plan contains code-related keywords but Working Directory or Repository is unset. The keyword list lives in the new `skills/validating-fields/config/code-task-keywords.txt` and is tunable without touching the jq pipeline. Working Directory still becomes a hard error at In Progress transition — this is the earlier signal.

#### Monitoring (visibility for existing quality debt)
- **Quality Debt tracking** (`monitoring-tasks`): Task health reports gain a new Dimension 6 with three sub-dimensions. DRAFT AC (tasks whose AC still contains `[DRAFT` and are no longer Blocked), Priority missing (non-Done / non-Cancelled tasks without Priority), and Test tasks (placeholder titles matching an anchored pattern that deliberately does not match legitimate titles like "Unit test task for DELETE endpoint"). The report section suggests a copy-paste-ready `planning-tasks` batch invocation so users can refine debt without figuring out the invocation syntax.

#### Ingestion improvements (better new-task quality at source)
- **GOps stub enrichment** (`ingesting-messages`, P2): Adds `scripts/detect-stub-import.sh` for deterministic stub detection (short description + task-ID marker like "タスクID:" / "task ID:" / "issue #" / "ticket #") and extends Step 1.5 so that when an item is detected as a stub, the orchestrating LLM fetches the source page body via `notion-fetch` and discussion comments via `notion-get-comments`, then semantically maps them to waggle Description / Acceptance Criteria / Context / Assignee / Priority. Falls back gracefully to the stub with a `stub-import` tag if the enrichment fetch fails.
- **Auto-generated AC/EP at ingest for Category B** (`ingesting-messages`, P1): Step 2.5 is restructured into three phases. Phase A auto-generates 2-5 verifiable Acceptance Criteria, a 3-7 step Execution Plan, a Working Directory guess, and a negation-aware Priority inference ("this is not urgent" correctly does not match Urgent) directly from the message, thread context, and attachment descriptions. Criteria that cannot be grounded in the source text are prefixed `[INFERRED]` in the AC itself — the prefix persists in Notion as an audit trail. Phase A.5 invokes `validating-fields` for a semantic gate (no auto-retry; failed drafts are marked `[LOW CONFIDENCE]` and surfaced first). Phase B paginates Category B messages into 5-per-batch `AskUserQuestion` calls with ranking (LOW CONFIDENCE → INFERRED → complexity → priority) and quick actions (Accept all high-confidence / Review individually / Skip batch).
- **Slack clarification replies for Category A** (`ingesting-messages`, P0): The biggest behavioral change in this release. Ambiguous Category A messages can be resolved by sending a short user-approved clarification reply in the same Slack thread instead of creating a `[Hearing]` task pair. Gated by six safety prerequisites: Slack MCP available, message is repliable, `WAGGLE_EXECUTION_MODE=interactive` environment variable (unset = "scheduled" safe default — Claude Desktop Scheduled Tasks and cron jobs never send messages), sender is not a bot, no clarification sent in the last 24 hours (`Active Threads.Clarification Sent At` idempotency), and a `~/.waggle/locks/clarification-*.lock` concurrency lock with 60-second TTL. Missing-information detection is LLM-driven via the new `references/clarification-heuristics.md` reference (three dimensions: Action / Target / Completion condition). Language detection for the reply is also LLM-driven — regex and char-class ratios were rejected because they mishandle negation and mixed-language messages. Full two-level fallback chain: Slack send fail → `[Hearing]` task → `[Hearing]` fail → intake-failed log + retry next run. Active Threads schema auto-repair adds the `Clarification Sent At` field on existing databases. The `ingesting-messages` frontmatter now documents the opt-in Slack send capability and adds "clarify slack message" as a trigger phrase.

### Changed

#### Architecture
- **Cross-skill interaction rules** (`CLAUDE.md`): Clarified that cross-skill interaction is natural-language-only. Skills may now say "invoke the X skill" without hardcoding paths to other skills' scripts or SKILL.md files. References to another skill's internal structure (line numbers, function names, reference files, step IDs) are explicitly forbidden. For self-references within a skill, use the official Claude Code runtime variable `${CLAUDE_SKILL_DIR}` instead of `${CLAUDE_PLUGIN_ROOT}/skills/<self>/...` paths, which silently break on rename.
- **Cross-skill refactor** (P-2): Swept the entire `skills/` tree and converted every existing `Load ${CLAUDE_PLUGIN_ROOT}/skills/<other>/SKILL.md` and `bash ${CLAUDE_PLUGIN_ROOT}/skills/<other>/scripts/...` pattern to natural language invocation ("Invoke the `<other>` skill to ..."). `validating-fields` gains a "How to Invoke This Skill" section so callers know how to pass input and interpret output. Self-references migrate to `${CLAUDE_SKILL_DIR}`. Affected skills: bootstrap-session, executing-tasks (+ tmux-parallel.md), planning-tasks, managing-tasks (+ references), running-daily-tasks, delegating-tasks, health-checking, monitoring-tasks, viewing-tasks, managing-views, ingesting-messages (+ references), troubleshooting (refactored in a dedicated final commit because it is the user's emergency exit), and provider-contract (documents the new convention).

## [2.3.0] - 2026-04-10

### Added
- **Image attachment handling** in `ingesting-messages`: Detects image attachments in messages, attempts best-effort reading via `permalink_public` + `WebFetch`, and surfaces unreadable images with message permalinks for manual review before task creation.
- Attachment-aware classification heuristics in `classification-guide.md`: Successfully-read image descriptions expand message context for classification; unread images bias toward Category A (Hearing Needed).
- `[Attachments]` section in task descriptions (`task-creation-templates.md`) with per-image read status and AI-generated descriptions.
- Attachments column in Step 2.7 creation confirmation and classification confirmation tables.
- Per-message (3) and global (10) image processing caps with `read_status = "skipped"` for cap-exceeded images.

## [2.2.0] - 2026-04-09

### Changed
- Bumped waggle to 2.2.0 and waggle-server to 0.5.0 for the next release cycle (no functional changes beyond version bump).

## [2.1.0] - 2026-04-09

### Added
- **Task detail panel** (all views): Linear-style slide-out panel showing all task fields — status, priority, executor, assignees, due date, tags, project, team, blocked-by links, parent/subtask navigation, description, acceptance criteria, execution plan, agent output, error message, artifacts, and metadata. Includes "Open in source" link.
- **Advanced multi-field filtering** (all views): 7 filter types (Status, Priority, Executor, Assignee, Tags, Due Date presets) with multi-select dropdown checkboxes, active filter pills, dynamic option population, and "Clear all" support.
- **URL state persistence**: Filter and sort state serialized to URL hash — bookmarkable and shareable.
- **Column sorting** (List view): Click column headers to sort by title, status, priority, executor, assignees, or due date.
- **Blocked column** (Kanban view): 6th column for Blocked tasks with error message preview.
- **Blocked status styling** (Gantt view): Red-tinted bars for Blocked tasks.
- **Keyboard navigation** (all views): J/K to move between tasks, Enter to open detail panel, Escape to close, `/` to focus search, C to copy task ID.
- **Executor column** (List view): New column showing task executor type.
- **Shared module architecture**: Extracted duplicated CSS/JS into `shared.css`, `shared.js`, `detail-panel.css/js`, `filter-bar.css/js` — reducing per-view file size by ~60%.

### Changed
- View server static HTML export (`generate-static-html.sh`) now supports calendar and gantt views and inlines shared resources for standalone output.
- Task click behavior changed from copy-ID-only to opening the detail panel (ID is still copied automatically).

## [2.0.0] - 2026-04-09

### Breaking Changes
- **Rename `Assignees` → `Assignee`** across all providers and skills. Notion DB column must be renamed via migration script after upgrade.
- Canonical JSON key changed from `assignees` to `assignee`.

### Added
- **Active Threads tracking** in `ingesting-messages`: Threads the user has participated in are now persisted in an Active Threads DB, so new replies are detected even after the original messages fall outside the lookback period.
- **Team name detection** in `looking-up-members`: Queries matching a team name now return a `teamMatch` result instead of expanding to all team members.
- **Single-assignee validation warning** in `validate-task-fields.sh`: Warns when `assigneeCount > 1`.
- `Created At` (created_time) field added to task schema.
- `Acknowledged At` (date) column added to Notion migration (existing schema field, previously missing from some databases).
- `Cancelled` status option added to Status enum.
- `CHANGELOG.md` for tracking release history.
- `troubleshooting` skill for diagnosing common issues.

### Changed
- Strengthened single-assignee rule in `assigning-to-others`, `delegating-tasks`, and `task-creation-flow` to explicitly reject team/group assignments.
- Team name guard added to `delegating-tasks` Step 3.

