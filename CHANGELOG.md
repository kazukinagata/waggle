# Changelog

All notable changes to the Waggle project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/).

## [2.7.0] - 2026-05-14

### Added

- **Cowork Live Artifact mode for the Tasks Dashboard** (`skills/viewing-tasks`): In Cowork `/viewing-tasks` no longer attempts to boot a localhost view server (Cowork browsers cannot reach `localhost:3456`). Instead it registers a single self-contained Live Artifact via `mcp__cowork__create_artifact({ id: "waggle-tasks", ... })` that bundles all four view renderers (Kanban / List / Calendar / Gantt) with a tab strip at the top, persists the active tab in `localStorage` (`waggle-tasks-active-tab-v1`), and fetches Notion data via `window.cowork.callMcpTool("mcp__Notion_Extension_for_Waggle__notion-query", ...)` directly. Subsequent `/viewing-tasks` invocations check `mcp__cowork__list_artifacts()` and instruct the user to open the existing panel rather than re-registering. The user-visible interface (4 views in one dashboard) is identical to the localhost selector flow — only the transport differs.
- **Cowork Live Artifact mode for custom views** (`skills/managing-views`): `/managing-views` Create / List / Regenerate operations now branch on `execution_environment`. In Cowork each custom view becomes its own artifact (`id = "waggle-view-<slug>"`) registered via `mcp__cowork__create_artifact`. List operations filter `mcp__cowork__list_artifacts()` results by `id == "waggle-tasks" || id.startsWith("waggle-view-")` because Cowork's `list_artifacts` does not return the `description` or `mcp_tools` fields passed on create — all retrievable metadata must be encoded in the `id`. The local file at `~/.waggle/views/<slug>.html` remains the canonical source of truth in every environment.
- **Cowork Reference Template marker** (`skills/managing-views/SKILL.md`): the reference custom-view template gains a `<!-- COWORK_BOOT -->` HTML comment marker inside `<head>`. The Cowork generator (`scripts/generate-cowork-custom-artifact.sh`) replaces it with `window.__COWORK_QUERY_CONFIG__` + `window.__coworkFetch` adapter at registration time. In cli / claude-desktop the marker is a harmless comment, so the same source file works in both modes.
- **`scripts/generate-cowork-artifact.sh`** (`skills/viewing-tasks/scripts/`): bundler that fuses kanban / list / calendar / gantt HTMLs into a single Cowork-ready artifact. Wraps each view's inline `<script>` in an IIFE with a defensive preamble (`var W = window.Waggle = window.Waggle || {}; W._renderers = W._renderers || [];`) to prevent the four views' top-level `function render()` declarations from colliding in shared global scope (HTML `<script>` tags share one scope; this was a critical correctness issue confirmed in pre-flight review with the Cowork team). Rewrites each `W.onDataUpdate = render` into a multiplex push, strips per-view `W.initData()` calls, and triggers `initData()` once at the bundle tail. Includes strict self-tests: ≥4 IIFE openings, ≥4 defensive preambles, exactly 4 `function render(` declarations, ≥4 multiplex pushes, no leftover `W.onDataUpdate = render`, plus DOCTYPE + charset assertions on every input.
- **`scripts/generate-cowork-custom-artifact.sh`** (`skills/managing-views/scripts/`): single-view variant of the bundler for custom views. Validates DOCTYPE / charset / marker presence then injects the live-fetch adapter via the `<!-- COWORK_BOOT -->` marker substitution.

### Changed

- **`shared.js` data layer hooks** (`skills/viewing-tasks/server/static/shared.js`): `updateData()` now also fans out to a `W._renderers` array (after the existing single-callback `W.onDataUpdate`) so the bundled Cowork artifact can subscribe four renderers to one data update. `initData()` short-circuits to `window.__coworkFetch()` when present, otherwise runs the existing `fetchTasks() + connectSSE()` pair. `refreshTasks()` similarly delegates to `__coworkFetch` when present. All three hooks are no-ops in cli / claude-desktop where neither `W._renderers` nor `__coworkFetch` is defined.
- **`viewing-tasks/SKILL.md` structure**: top-level branch on `execution_environment` (Mode Selection) replaces the prior single-mode flow. The existing localhost flow is renamed under "Localhost Server Mode" with no behavioral change; the new "Cowork Live Artifact Mode" section sits alongside it. Frontmatter description rewritten to match both transports.
- **`managing-views/SKILL.md` operations**: each of Create / List / Delete / Regenerate now has parallel cli/desktop and cowork branches. The Reference Template's data plumbing (formerly checking `window.__STATIC_DATA__`) is rewritten to check `window.__coworkFetch` first, falling back to `fetch('/api/tasks') + SSE` for localhost. Adds a unified `setStatus()` helper and a Loading / Empty / Error state triad so custom views render consistently across modes.

### Removed

- **Static HTML Export branch** (`skills/viewing-tasks/SKILL.md`, `skills/viewing-tasks/scripts/generate-static-html.sh`, `skills/viewing-tasks/server/static/shared.js`): the `CLOUD_SHELL`-gated standalone-HTML branch and its supporting script are removed. Static export was a stopgap for remote/sandboxed environments where localhost was unreachable; the new Cowork Live Artifact mode supersedes it for the only documented use case (Cowork). The `window.__STATIC_DATA__` branch in `shared.js initData()` is also dropped — it was dead code once the generator script went. Non-Cowork remote sandboxes (raw Google Cloud Shell, GitPod, etc.) lose visualization as a consequence; can be restored as a separate fallback if a user reports the gap.

### Notes

- **Cowork artifact `id` naming scheme**: `waggle-tasks` is the primary dashboard (singleton); `waggle-view-<slug>` is a user-defined custom view. The `id` is the only stable retrievable metadata Cowork exposes via `list_artifacts`, and is immutable across `update_artifact` calls.
- **Deletion semantics in Cowork**: Cowork provides no `delete_artifact` API. `/managing-views delete <slug>` degrades to (1) removing the local source file under `~/.waggle/views/` and (2) calling `update_artifact` with a stub HTML body and `update_summary: "[DELETED] <slug>"`. The artifact panel persists in the Cowork sidebar until the user dismisses it manually. Documented as a known limitation; can be revisited if Cowork adds delete.
- **Windows cold-start (GitHub Issue #55788)**: the artifact's first `callMcpTool` invocation may fail with HTTP 400 on Windows in a cold-start state. The adapter polls `window.cowork?.callMcpTool` for up to 3 seconds and surfaces a friendly "Cowork runtime unavailable" banner on timeout. Documented workaround: have the user invoke any Notion MCP tool from the Cowork chat once before opening the artifact. Mac is unaffected.
- **Cowork adapter duplication**: `generate-cowork-artifact.sh` and `generate-cowork-custom-artifact.sh` each carry their own copy of the `extractJson` / `parseNotionPageToTask` / `paginatedQuery` / `coworkFetch` adapter. Per the project's skill-independence rule, scripts owned by one skill cannot source files from another skill's directory. The duplication is documented at the top of both scripts so future changes are applied in both places.

## [2.6.1] - 2026-05-11

### Fixed

- **Slack `after:` date filter off-by-one wiped boundary-day messages** (`skills/ingesting-messages`): the skill translated `lookback_period` (e.g., "24 hours") into `after:YYYY-MM-DD` without compensating for Slack's exclusive-date semantics. A 24-hour lookback from 2026-05-08 14:25 JST computed `after:2026-05-07`, which Slack interprets as "5/8 onwards" — silently dropping the entire 5/7 from all three intake queries. The skill now documents the exclusive behavior and instructs either using the MCP tool's Unix-timestamp `after` argument (inclusive) or subtracting an additional day from the query-string `after:` filter when only the string form is available. `before:YYYY-MM-DD` is documented as symmetrically exclusive. Empirical verification against the affected user's workspace confirmed `from:<@USER> after:2026-05-06` returns 5/7 messages while `after:2026-05-07` does not.
- **Bot-posted messages dropped by `slack_search_*` default** (`skills/ingesting-messages`): the MCP default `include_bots: false` filtered out messages from automation bots (meeting-notifier bots, action-item posters, intake bots) at the search layer, before Step 1c-1's Block Kit body refetch could trigger. Combined with the date-filter off-by-one above, the 2026-05-08 user run silently missed all three MTG Pipeline Bot action-item posts from `#gp-mtg-actions-test` on 5/7, each of which @-mentioned the user via Block Kit. The Slack Query Example now mandates `include_bots: true` (or the MCP's equivalent parameter) on all three queries.
- **`slack_read_thread(oldest=...)` exclusive bound dropped boundary-ts replies** (`skills/ingesting-messages` Step 1b-2 Active Threads Check): passing `oldest = Last Checked` skipped a reply posted at exactly that timestamp. Step 1b-2 now subtracts 1 microsecond from `Last Checked` before passing it as `oldest` so replies at the boundary are included.

## [2.6.0] - 2026-05-08

### Added

- **Cowork DB ID caching via `<waggle-config>` Global Instructions XML tag** (`providers/notion/skills/notion-provider`, `providers/notion/skills/notion-setup`): Cowork sessions can now persist resolved Notion DB IDs across sessions by pasting a `<waggle-config>{json}</waggle-config>` block into Global Instructions, mirroring the existing `<waggle-custom-intake>` / `<waggle-custom-task-creation>` pattern. `notion-provider` Config Retrieval Step 1 (cache fast path) now reads this tag on Cowork as the equivalent of the env-var fast path on CLI / Claude Desktop. After a successful search-based resolve, Step 3 (Cache Populate) prompts the Cowork user once per session with a paste-ready block; the user can dismiss with "Later" to defer until the next session. Previously Cowork users had no cache mechanism — `setup-guide.md` Step 5c explicitly skipped env-var writes on Cowork — so every session re-ran `notion-search` and was vulnerable to the partial-match bug fixed below.
- **Full-set DB ID caching** (`providers/notion/skills/notion-provider`, `providers/notion/skills/notion-setup`, `skills/provider-contract`, `skills/health-checking`): the env-var cache and the Cowork `<waggle-config>` JSON now cover all five resolved IDs (`tasksDatabaseId`, `teamsDatabaseId`, `intakeLogDatabaseId`, `sprintsDatabaseId`, `activeThreadsDatabaseId`), not just tasks/teams. Adds env vars `WAGGLE_NOTION_INTAKE_LOG_DB_ID`, `WAGGLE_NOTION_SPRINTS_DB_ID`, `WAGGLE_NOTION_ACTIVE_THREADS_DB_ID`. Previously the fast path populated `headless_config` with only `tasksDatabaseId` / `teamsDatabaseId`, leaving downstream skills (e.g. `ingesting-messages` needing `intakeLogDatabaseId`) to silently re-fetch the Config page each session — Step 3's new auto-write would have made this gap more common after upgrade. The `~/.waggle/config.json` migration flow in `health-checking` is updated to migrate all five keys.
- **Auto-cache on resolve for CLI / Claude Desktop** (`providers/notion/skills/notion-provider` Config Retrieval Step 3): when bootstrap resolves the Config page via search (cache miss), it now silently writes/merges every resolved ID into `~/.claude/settings.json` so subsequent sessions hit the env-var fast path. Previously only the initial `notion-setup` flow wrote these vars — users who completed setup before env-var caching existed (or under a different mechanism) re-ran search every session forever.
- **Stale-cache recovery with explicit precedence** (`providers/notion/skills/notion-provider` Config Retrieval, Error Handling): if a cached `tasksDatabaseId` fails Schema Validation with a "database not found" error, the cache is discarded, search is re-run, and Step 3 re-populates the cache. The recovery path includes an explicit precedence note over the `Database access denied → Terminal` row in the Error Handling table, plus a corresponding exception in that table, so the two directives no longer conflict for cached-value origins. If Schema Validation fails a second time with the freshly-resolved ID (i.e., the Config page itself is stale), that second failure is terminal — the user is instructed to update the Config page or re-run `setting-up-tasks`.

### Fixed

- **Notion config discovery picked member-specific databases as the Config page** (`providers/notion/skills/notion-provider`, `providers/notion/skills/notion-setup/references/setup-guide.md`): `notion-search "Waggle Config"` returns partial-match / semantic results, so member-scoped databases like `Waggle:Hori`, `Waggle:Funase`, and parent pages like `メンバー別：Waggle` ranked alongside the actual Config page. The previous logic relied on a parent-relationship tiebreaker that mis-fired in practice — on 2026-05-08 a Cowork session resolved the wrong page and adopted a per-member data-source ID as `tasksDatabaseId`, breaking every downstream `notion-query` with "Could not find database with ID" errors. The Config Retrieval flow and the `notion-setup` Step 1b detection both now require a CLIENT-SIDE filter of `title == "Waggle Config"` (exact, case-sensitive) AND `type == "page"` AND not trashed/archived. Anything else is discarded before disambiguation.

### Removed

- **Legacy "Agentic Tasks Config" page-name fallback** (`providers/notion/skills/notion-provider`, `providers/notion/skills/notion-setup/references/setup-guide.md`): the page has been renamed workspace-wide to "Waggle Config" since 2.4.x. The legacy-name fallback added a second `notion-search` round-trip and complicated the discovery flow without a remaining audience. Workspaces that have not yet migrated will now receive a clear error pointing them to `setting-up-tasks` (or to manually rename the page) instead of silently using the legacy name.

## [2.5.6] - 2026-05-08

### Changed

- **Removed `notion-search` fallback for filtered task queries** (`providers/notion/skills/notion-provider`): Path 3 (`notion-search` + `notion-fetch` with client-side filtering) was added in 2.5.3 as a graceful degradation when `notion-query` (Desktop Extension MCP) or the `NOTION_TOKEN` bash script was unavailable. In practice the degraded path silently surfaced tasks owned by other assignees — Notion's `notion-search` cannot filter by `people` properties server-side and the skills did not enforce a client-side Assignee check. It also masked the underlying setup error (e.g. a Notion integration missing share access on the Tasks DB / Intake Log / Active Threads DB), making triage harder. The Querying Tasks and "Querying Any Notion Database" flows now halt the current step when the structured query path is unavailable or returns a database-access error, surfacing the Notion API error message verbatim along with an actionable hint (share the database with the named integration, or install the Desktop Extension). Non-filtered uses of `notion-search` (e.g. finding the Waggle Config page during `bootstrap-session`) are unchanged. Cascading effect: `running-daily-tasks` Steps 2 / 2.5 / 3 / 3.5 and `ingesting-messages` Intake Log / Active Threads reads now stop with a clear error instead of producing unreliable results. The halt is step-scoped — when one step halts, the user is prompted whether to continue to the next step or end.

## [2.5.5] - 2026-04-28

### Fixed

- **Cowork environment was misclassified as CLI when host env vars were not visible to Bash** (`detecting-provider`, `provider-contract/references/environment-detection.md`, `waggle-protocol`, `setting-up-tasks`): `detecting-provider` decided `execution_environment` solely from `CLAUDE_CODE_IS_COWORK` / `CLAUDE_CODE_ENTRYPOINT` read via Bash. Cowork's Bash subshell runs in an isolated sandbox that does not inherit host env vars, so `echo "$CLAUDE_CODE_IS_COWORK"` returns empty even on Cowork — silently falling through to the CLI branch. Downstream effects: provider discovery looked for `~/.claude/plugins/installed_plugins.json` (absent on Cowork), `managing-tasks` recommended `cli` instead of `cowork` as the default executor, `executing-tasks` offered tmux parallel (impossible on Cowork), and `loading-custom-instructions` tried to read `~/.waggle/*.md` instead of system-prompt XML tags. Detection is now multi-signal: Cowork is identified via **any** of (1) the active system prompt mentioning Cowork (e.g. "Claude is powering Cowork mode"), (2) availability of `mcp__cowork__*` or `mcp__cowork-onboarding__*` tools, or (3) the legacy `CLAUDE_CODE_IS_COWORK=1` env var. The legacy signal remains a positive hint but is no longer required — its absence is not evidence against Cowork. `setting-up-tasks` line 28 (the standalone "is the provider plugin installed?" check that runs before any provider exists, so cannot delegate to `detecting-provider`) inlines the same multi-signal Cowork test. Claude Desktop and CLI detection are unchanged. `detecting-provider/SKILL.md` was restructured so environment detection now happens once at Step 1, with provider discovery (Step 2 → 3A/3B) and the SQLite-on-Cowork guard (Step 6) both reading the precomputed `execution_environment` instead of re-checking the env var.

## [2.5.4] - 2026-04-24

### Fixed

- **Block Kit bot messages were silently dropped during Slack intake** (`ingesting-messages`): `slack_search_*` returns an empty `text` field for bot messages whose content lives entirely in `blocks` (e.g. MTG Pipeline Bot meeting-task notifiers, Colla-style quiz bots). Slack's search index still resolves `<@current_user>` mentions inside the blocks and matches the query, but without a visible body the 2.5.1 KEEP-on-@-mention rule in Step 1c could not fire and the message was omitted from the unprocessed-messages pool. Added Step 1c-1: any bot message arriving with an empty/whitespace-only `text` is refetched via `slack_read_channel` with pinpoint `oldest`/`latest` on the message `ts` (which expands `blocks` into plain text) before the KEEP/DISCARD decision. The full rendered body — including the `<@current_user>` mention and actionable content — now flows into classification and task creation.

## [2.5.3] - 2026-04-24

### Fixed

- **Notion query / relation-update path detection broke CLI users after 2.5.2** (`providers/notion/skills/notion-provider`): 2.5.2 collapsed per-`execution_environment` branching into a single `mcp__notion-extension__notion-query`-availability check, on the (wrong) assumption that the Desktop Extension MCP is reachable everywhere. The extension is a **Claude Desktop** extension — it is not loaded in CLI. As a result, CLI users with a perfectly valid `NOTION_TOKEN` in `~/.claude/settings.json` always fell to Path 2 (`notion-search` + `notion-fetch`), losing server-side Assignee filtering and getting the degraded warning. Restore per-environment branching: CLI uses the bundled bash script driven by shell-env `NOTION_TOKEN`; Claude Desktop / Cowork use the Desktop Extension MCP tool (`NOTION_TOKEN` is not exposed to the shell in those environments, so the bash script is not usable there). The MCP fallback (`notion-search` + `notion-fetch`) remains the last-resort Path 3 with an environment-specific warning telling the user what to fix. Same fix applied to Relation Update Path Detection and to "Querying Any Notion Database".

## [2.5.2] - 2026-04-24

### Fixed

- **Notion query path auto-detection ignored the Desktop Extension MCP** (`providers/notion/skills/notion-provider`): `Query Path Detection` and `Relation Update Path Detection` keyed off `[ -n "$NOTION_TOKEN" ]` in the shell, but Claude Code no longer exports `NOTION_TOKEN` to the shell — the token is injected directly into MCP tool invocations. As a result, "my tasks" and other Assignee-filtered queries misrouted to Path 2 (`notion-search` + `notion-fetch`), triggering the `NOTION_TOKEN is not set` warning and dropping Assignee filtering, even though `mcp__notion-extension__notion-query` was available and would have served the request correctly. Detection is now MCP-tool-availability-based: Path 1 is taken whenever `mcp__notion-extension__notion-query` (or `mcp__notion-extension__notion-update-relation` for relation updates) is present, regardless of `execution_environment`. The bash scripts remain in `scripts/` as an advanced manual option under `### Manual ... (requires NOTION_TOKEN in shell env)` headings, outside the auto-detection flow. Path 2's warning text is reworded to reflect the new trigger ("MCP tool not available" rather than "NOTION_TOKEN not set") and calls out that Assignee (people property) filtering is what's actually lost on this path.

## [2.5.1] - 2026-04-17

### Fixed

- **Slack bot @-mentions were silently dropped during intake** (`ingesting-messages`): Step 1c's single-line "If bot message: keep only if it @-mentions `current_user`; discard otherwise" was interpreted too aggressively by the orchestrating LLM, causing bot-origin messages that DID mention the user (CI bots, deploy bots, monitoring alerts, etc.) to be filtered out before classification. Split the rule into explicit KEEP/DISCARD bullets with the keep condition stated first, and inlined a note that Step 2.3 Prerequisite #4's bot-sender check only gates Slack clarification replies — it never excludes bot messages from intake. Bot-origin Category A messages now correctly fall through to `[Hearing]` task creation.

## [2.5.0] - 2026-04-13

### Added

- **Custom task-creation instructions** — users can now define business-logic rules (tag naming, priority defaults, Assignee routing, AC/Execution Plan style) that are honored whenever waggle creates or plans a task. On CLI / Claude Desktop the rules live in `~/.waggle/task-creation-prompt.md`; on Cowork they live in a `<waggle-custom-task-creation>...</waggle-custom-task-creation>` block inside Global Instructions. Applied by `managing-tasks`, `ingesting-messages`, and `planning-tasks` during field resolution. Never overrides `validating-fields` hard gates or drives status transitions / destructive operations.
- **New shared skill `loading-custom-instructions`** — centralizes environment-aware loading of user-authored instructions by key. `managing-tasks`, `ingesting-messages`, and `planning-tasks` invoke it at startup with keys `task-creation` (new) and `intake` (existing). The skill ships a deterministic bash loader (`scripts/load.sh`) that reads the file once into memory (TOCTOU-reduced), enforces a 10 KiB size cap, validates keys with strict kebab-case (rejecting trailing / consecutive hyphens as well as path traversal), and rejects files containing prompt-boundary control markers on the CLI/Desktop path — both ChatML-family tokens (`<|endofprompt|>`, `<|im_start|>`, `<|im_end|>`) and Claude's legacy text-completion boundaries (`\n\nHuman:`, `\n\nAssistant:`). Covered by 16 unit tests in `scripts/test-load.sh`. The output variable name normalizes hyphens to underscores so `custom_task_creation_instructions` is a valid identifier even though the key is `task-creation`. Cowork loading (XML tag extraction from the system prompt) is handled by the SKILL.md directly since bash cannot read the agent's own context.
- **`setting-up-tasks` Step 3.6** — parallel setup flow for custom task-creation rules alongside the existing Step 3.5 (custom intake sources). Prompts the user for tag / priority / AC rules, composes them into natural language, writes them to `~/.waggle/task-creation-prompt.md` on CLI/Desktop or outputs a Global Instructions block on Cowork. Includes security guidance: keep the file under 10 KB, never paste untrusted text.

### Changed

- **`ingesting-messages` custom instruction loading** — the inline `~/.waggle/intake-prompt.md` loader is refactored to invoke the new `loading-custom-instructions` shared skill with key `intake`. Existing behavior (silent null fallback, Cowork XML tag parsing) is preserved. The skill now additionally loads `custom_task_creation_instructions` via the same shared loader and applies it in `task-creation-templates.md` — the hardcoded `["ingesting-messages"]` Tags default becomes a fallback that user rules can extend or replace.

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

