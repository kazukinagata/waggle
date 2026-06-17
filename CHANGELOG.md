# Changelog

All notable changes to the Waggle project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/).

## Quality Verdict integrity check at Ready / In Progress — 2026-06-17

Telemetry surfaced a quality-gate bypass where a batch flow (a manually-invoked
`running-daily-tasks` run) promoted tasks to `Ready` by writing a self-authored
`PASS` Quality Verdict instead of running `reviewing-quality` — the "hash" was a
human-readable mnemonic (e.g. `line0612a`) rather than a real `sha256("Title|Description|AC|EP")`
prefix, and the timestamp was a placeholder. Because the Ready gate was advisory
(SessionStart guidance, no verification), a fabricated verdict satisfied it.

- **`waggle` 2.14.0 → 2.15.0** (MINOR — new validation; no schema change):
  - `validating-fields` now accepts an optional `qualityVerdict` canonical field and, on
    `Ready` / `In Progress` transitions, **deterministically rejects a malformed verdict**
    (a string whose `hash` is not a real `[0-9a-f]{8}`, e.g. a mnemonic) and a **non-PASS**
    verdict. A fabricated, hand-authored verdict can no longer pass the field validator.
  - An absent verdict stays a warning (not a hard error): it may be written in a separate
    update, and the content-hash match (`hash == sha256("Title|Description|AC|EP")[:8]`) is
    verified by the org-layer hook, out of scope for this provider-agnostic check.
  - `validating-fields/SKILL.md` documents the new `qualityVerdict` field, its construction
    from Notion (`Quality Verdict` rich_text) and SQLite/Turso (`quality_verdict`), and the
    Ready/In Progress requirement. New `skills/validating-fields/tests/run.sh` covers the cases.
  - Known limitation: a mnemonic hash that is coincidentally all-hex (e.g. `fac0618a`) passes
    the format check; catching it requires the content-hash recompute, deferred to the
    org-layer hook (which can fetch the task content).
  - Providers unchanged.

## Start Date extended field — 2026-06-17

A new optional `Start Date` extended field complements the existing `Due Date`, letting a task
express a planned work window (start → due). Previously the schedule views had to *guess* when work
began — the Gantt chart derived a bar's start from `dispatchedAt` (falling back to `dueDate`), which
is a heuristic rather than a plan. `Start Date` is a standard `date` field (ISO 8601), optional with
graceful degradation exactly like `Due Date`: no validation, no status-transition gating.

- **`waggle` 2.13.0 → 2.14.0** (MINOR — new extended field + view-server data model):
  - `waggle-protocol` Extended Fields and `provider-contract` task-schema gain `Start Date | date | `startDate``; the canonical JSON shape and query-output example carry `startDate`.
  - View server `Task` type carries `startDate`, pushed through by every provider. **Full view integration**: detail panel shows it; List view adds a sortable `Start Date` column; the filter bar gains a `Start Date` has/none filter (persisted as `?start=`); the Calendar plots a task on its start day (marked `▶`) in addition to its due day; the Gantt now uses `startDate` for the bar start when present, falling back to the prior `dispatchedAt → dueDate` behavior.
- **`waggle-notion` 3.6.0 → 3.7.0** (MINOR — new optional property):
  - `Start Date` maps to a Notion `date` property (`task_start_date`). It is a plain date, settable via `notion-update-page` — **no extension repack required**. Auto-repair DDL `ADD COLUMN "Start Date" DATE`; the setup guide creates it on fresh boards.
- **`waggle-sqlite` 2.3.0 → 2.4.0** and **`waggle-turso` 2.3.0 → 2.4.0** (MINOR — new column):
  - `start_date TEXT` column. `init-db.sh` also migrates existing DBs via the same idempotent `pragma_table_info`-guarded `ALTER TABLE ... ADD COLUMN` pattern used for `attachments` (Turso does it as query-then-ALTER over the HTTP API).

## Attachments extended field (`file[]`) — 2026-06-08

A new optional `Attachments` extended field lets tasks carry files **as task data** (a property), portable across providers. This closes the gap where `rich_text` fields (Description / Acceptance Criteria) cannot hold images and PR #69 only covered page-**body** images. The abstract type is `file[]` — an array of file descriptors `{url, name, mime_type?, size?}` that **reference** hosted bytes rather than holding them, because file hosting is a per-provider capability (`supportsFileHosting`), not just a column type.

- **`waggle` 2.12.0 → 2.13.0** (MINOR — new extended field + view-server data model):
  - `waggle-protocol` Extended Fields gains `Attachments | file[]`; `provider-contract` task-schema documents the `file[]` descriptor shape, the canonical JSON, and a `supportsFileHosting` Provider Mapping table (Notion=true, SQLite/Turso=false). Waggle has no runtime capability negotiation — `supportsFileHosting` is guidance for skills: against a non-hosting provider, require an externally-hosted URL and never upload a local file.
  - View server `Task` type carries `attachments`; providers push it through. No UI rendering yet — Notion `file`-type URLs are signed and expire ~1h, so rendering a pushed URL in a long-lived view would break; deferred to a follow-up.
- **`waggle-notion` 3.5.0 → 3.6.0** + **`notion-extension` 1.1.0 → 1.2.0** (MINOR — new write surface):
  - `Attachments` maps to a Notion `files` property. New `attach-file.sh` (CLI/`NOTION_TOKEN`) and `notion-set-files-property` MCP tool (Desktop/Cowork) set/append files — `notion-update-page` cannot. Local files upload via the File Upload API (reusing the body-image flow); external URLs store as-is; append is read-modify-write. Auto-repair DDL `ADD COLUMN "Attachments" FILES` (live-confirmed), best-effort with graceful manual fallback.
  - Extension repack required (`npx @anthropic-ai/mcpb pack .`); reinstall for Desktop/Cowork. New helper unit tests (`mimeForAttachment`, `validateSetFilesInput`, `toWritableFiles`).
- **`waggle-sqlite` 2.2.0 → 2.3.0** and **`waggle-turso` 2.2.0 → 2.3.0** (MINOR — new column, no hosting):
  - `attachments TEXT DEFAULT '[]'` JSON-array column (same convention as `tags`/`assignee`). `init-db.sh` now also migrates existing DBs via an idempotent `pragma_table_info`-guarded `ALTER TABLE ... ADD COLUMN` (Turso does it as query-then-ALTER over the HTTP API). `supportsFileHosting=false` — values must be externally-hosted, caller-supplied URLs.

## Findings block carried into ingesting-messages deferred creates — 2026-06-06

Follow-up to v2.11.0 (its explicitly deferred item). `ingesting-messages` Phase A.5 runs the quality review before the task exists, so `reviewing-quality` returns the verdict and findings block to the caller instead of writing them (deferred-write contract). v2.11.0 updated the contract but not `ingesting-messages` itself — the returned findings block was ignored, so DM-sourced tasks accepted with a `NEEDS_REFINEMENT` / `REJECT` verdict carried only the one-line verdict: a later `/planning-tasks` run or Ready-transition gate fell back to verdict-only display with no record of *what* to fix.

- **`waggle` 2.11.0 → 2.12.0** (MINOR — behavior change in `ingesting-messages`; no schema change):
  - Phase A.5 holds the returned findings block in memory alongside the verdict; on non-PASS creates (any status) Step 3 appends it to the task's `Context` in the same create payload, mirroring what `reviewing-quality` writes itself for existing tasks.
  - `task-creation-templates.md` Common Fields and the Ready+ rule document the carry: never attach a block whose hash does not match the `verdict_string` being written.
  - Phase B edit invalidation now covers the block: editing a draft discards verdict + block together; Re-review carries the freshly returned block, Defer omits both.
  - `reviewing-quality` drops the "ingesting-messages currently ignores the returned findings block" interim note — the contract now holds for all creation-time callers.

## Creation-time quality gate + findings persistence — 2026-06-06

In a planning-assisted `managing-tasks` creation (user asks the planning agent to draft AC/EP), a `NEEDS_REFINEMENT` Reviewer verdict led to the task being silently created at Backlog — no user choice — and the Reviewer's gaps and suggested fixes survived only in chat (only the one-line `Quality Verdict` string was persisted). Two root causes: the task-creation flow had no instruction for branching on a creation-time verdict (the equivalent gate already existed in `planning-tasks` Step 5 and `ingesting-messages` Phase B), and no skill persisted the findings anywhere — which also made `schema-and-transitions.md`'s "present the cached gaps + suggested fixes" instruction unfulfillable on the cache-only pre-Ready path. A further mismatch: the Reviewer's gaps are usually requester-side information (who approves, what the brief is), so the existing "re-spawn the planning agent with the fixes attached" refinement could never resolve them without asking the user.

- **`waggle` 2.10.0 → 2.11.0** (MINOR — behavior change + new protocol convention; no schema change):
  - `managing-tasks` task-creation-flow gains "Planning-Assisted Creation & Creation-Time Quality Gate": agent-drafted AC/EP gets a live `reviewing-quality` review before the task is created; on non-PASS the user explicitly chooses `[Refine now] [Create at Backlog as-is]` — never a silent Backlog create. The refine loop asks the user one concrete question per requester-side gap, re-plans with the answers, and re-reviews — repeating until PASS, until the user parks the task, or until the existing suppression guard (2 consecutive same-axis failures → 7-day freeze) ends it. Status Auto-Determination now requires verdict PASS (in addition to the Rubric) when a creation-time verdict exists.
  - `reviewing-quality` persists non-PASS gaps/fixes as a **Quality Review Findings block** on the task's `Context` field in the same step as the verdict cache write: at most one block per task, hash-tied to the verdict line for staleness detection, replaced on re-review, removed on PASS, stripped from `Context` before the spec reaches the Reviewer agent. Cache hits on non-PASS verdicts now return `gaps`/`fixes` read from the block, making them presentable on cache-only hot paths. A "Deferred-write contract" section covers creation-time callers (block returned in-memory and carried in the create payload; the in-memory previous verdict feeds the suppression check).
  - `planning-tasks` Step 5 `NEEDS_REFINEMENT` adopts the same user-driven loop (`[Refine now] [Save anyway]`, questions before re-plan, until PASS / save / suppression), replacing the at-most-once re-plan that skipped the user. REJECT and batch-mode notes point at the persisted findings.
  - `managing-tasks` pre-Ready quality gate documents where the cached gaps/fixes actually come from (the persisted block) and the fallback when they are absent or stale.
  - `waggle-protocol` Quality Spec gains a "Findings Persistence" section; the `Context` extended-field description notes the managed block; `managing-tasks` planning-assisted creation joins the allowed live-Reviewer call sites.
- Providers unchanged — the block lives inside the existing `Context` column.
- `CLAUDE.md` documents that plugin-level subagents under `agents/` are a stable public interface (not skill internals) — multiple skills already spawn them by name; renaming one is a breaking interface change.
- Out of scope (follow-up): carrying the findings block into `ingesting-messages` deferred create payloads (`reviewing-quality` documents that the returned block is currently ignored there).

## Output discipline — suppress step-by-step narration — 2026-06-06

Skill flows narrated every internal step to the user ("Now I'll detect the provider…", "Config resolved. Now validating the schema.", verdict hashes, view-server push results). A single `managing-tasks` task creation produced ~20 such one-liners around its tool calls — protocol internals relayed as chat, burying the messages that matter (prompts, gate verdicts, the final summary). Root cause: no skill carried any output-style directive, so the agent fell back to its default narrate-every-transition behavior, amplified by the fine-grained step structure and the 6+ SKILL.md loads per flow.

- **`waggle` 2.9.0 → 2.10.0** (MINOR — behavior change across all workflow skills):
  - Every user-invocable workflow skill (12 core) gains an `## Output Discipline` section: no step-transition narration, no protocol internals; user-facing text is limited to (a) prompts needing input, (b) errors/warnings, (c) intermediate results that change the outcome — e.g. a non-PASS quality verdict and its gaps, which explain why a task lands at Backlog instead of Ready (PASS verdicts fold silently into the final summary), and (d) the final result summary.
  - Every shared skill (8 core) gains a `**Silent operation:**` line: return results to the invoking flow; the caller owns all user communication; only errors, warnings, and prompts required to proceed surface directly.
  - `provider-contract` adds the silent-operation rule as a contract requirement for provider skills, so a waggle flow's user-visible output is identical regardless of backing provider.
  - `waggle-protocol` and `provider-contract` themselves carry no Output Discipline block — they are specification documents, not pipelines.
  - `CLAUDE.md` Key Conventions documents the pattern so new skills include the matching block.
  - Wording follows skill-creator guidance: explain the why instead of bare MUSTs, keep the block lean, generalize rather than enumerate specific offenders.
- **`waggle-notion` 3.4.0 → 3.5.0, `waggle-sqlite` 2.1.0 → 2.2.0, `waggle-turso` 2.1.0 → 2.2.0** (MINOR each):
  - `{provider}-provider` skills gain the `**Silent operation:**` line; `{provider}-setup` skills gain the `## Output Discipline` section.

## Give planning and reviewer agents the Skill tool — 2026-06-05

The planning agents drafted AC / Execution Plans from generic knowledge only. Org-distributed knowledge and operational skills (installed plugins) were invisible to them: a restricted `tools:` list excludes the `Skill` tool, and excluding the `Skill` tool also removes the available-skills listing from the agent's system prompt (verified empirically — an agent with `tools: Read, Bash, Grep, Glob` reports no Skill tool and no skills list, while an all-tools agent sees both). Adding `Skill` gives the agents the catalog *and* the ability to load a skill properly, so AC/EP can be grounded in domain procedures instead of re-derived from scratch.

- **`waggle` 2.9.0** (MINOR — agent capability extension; no skill or provider changes):
  - `agents/code-planning-agent.md`, `agents/knowledge-planning-agent.md`, `agents/task-quality-reviewer-agent.md`: `tools` now include `Skill`.
  - Planning agents gain one design-step instruction: if the available skills list contains domain-knowledge or operational skills relevant to the task, invoke them via the Skill tool before drafting, and ground AC/EP in what they prescribe.
  - Reviewer gains a bounded allowance: may invoke at most one read-only knowledge skill to ground its judgment (`maxTurns: 4` is unchanged and remains the hard cap).
  - **Generic by design.** Waggle names no specific skills or plugins; which skills exist is an installation concern. Org-specific nudging (e.g. "use these plugins for this domain") belongs in org extension plugins — e.g. a `SubagentStart` hook that injects `additionalContext` for these agent types.

## Page-body image upload & read support (Notion provider) — 2026-06-05

The Notion provider previously handled only database properties — there was no way to paste an image into a task page body, or to make images pasted there (mockups, screenshots a human added as context) visible to the agent. Both directions now exist on both access paths (Desktop Extension MCP tools and CLI bash scripts).

- **`notion-extension` 1.0.0 → 1.1.0** (MINOR — two new tools; `providers/notion/extension`).
  - **`notion-upload-image`**: appends an image block to a page body from exactly one of `file_path` (local file, sent through the Notion File Upload API: `POST /v1/file_uploads` → multipart send → attach; single-part cap 20MB) or `external_url` (embedded as an external image block, no upload). Optional `caption`. Returns a minimal echo `{ok, page_id, block_id, image_type, filename?}`. The File Upload endpoints are called via the Node 18+ built-in `fetch` because the pinned `@notionhq/client` 2.3.0 predates that API — the SDK is intentionally **not** bumped (newer majors move `databases.query` to the dataSources API and would destabilize the existing tools); a startup guard exits with a clear error if `fetch` is unavailable. All raw fetches (REST calls and image downloads) carry a 30s `AbortSignal` timeout so a hung connection cannot block the MCP server.
  - **`notion-read-images`**: walks the page's block tree (`blocks.children.list`, paginated; recurses into toggles/columns/callouts to depth 3, never into `child_page`/`child_database`), downloads each image block, and returns the images as **inline MCP image content** the model sees directly — preceded by a text part with a JSON summary (`{count, total_found, images:[{index, block_id, mime_type, size_bytes, caption, source_type}], skipped}`) whose `images` order matches the image parts. Notion's `file`-type URLs are signed and expire after ~1 hour, so the tool downloads immediately and callers never touch URLs. Optional `max_images` (default 10), `block_ids` filter (dash-insensitive), `include_nested`. Images over 5MB, non-raster types (svg/tiff/heic — Claude vision cannot view them), and requested `block_ids` matching no image are reported in `skipped` with a reason instead of returned.
  - Image-handling logic that needs no network (MIME map, upload-input validation, image-block collection/recursion classification) lives in a new `server/helpers.js`, unit-tested in `providers/notion/tests/extension/` (`run.sh`, 33 cases). The network handlers are verified manually against a real workspace.
- **`waggle-notion` 3.3.1 → 3.4.0** (MINOR — new feature surface).
  - **CLI parity scripts** (`providers/notion/skills/notion-provider/scripts/`): `upload-image.sh <page_id> <file_path|--url <url>> [caption]` and `download-images.sh <page_id> [output_dir]`, following the existing `update-relations.sh` conventions (NOTION_TOKEN + jq preflight, `Notion-Version: 2022-06-28`, 429 `retry_after` / 500 exponential-backoff retry). The download script saves to `<output_dir>/<block_id>.<ext>` and prints a JSON manifest, skipping images over 5MB (curl `--max-filesize` + post-download size check — mirrors the extension's inline limit); on CLI the agent then views the files with the Read tool (the MCP inline-image return only exists on the extension path).
  - **`notion-provider` SKILL.md** gains a "Page Body Images" section with the same per-environment path detection as relation updates (CLI → bash scripts via shell `NOTION_TOKEN`; Claude Desktop / Cowork → extension MCP tools, v1.1.0+ detected by tool availability) and the caveats (capability, size caps, URL expiry).
  - **"Insert content" capability is required for uploads** — verified live: a token with only Read/Update content passes `POST /v1/file_uploads` and the multipart send, then fails at the block-append step with `403 restricted_resource`. Both the extension server and the bash script append a remediation hint (enable Insert content at notion.so/profile/integrations) to that error. The extension README, manifest `user_config` description, and `notion-setup` setup-guide previously instructed Read (+Update) content only and now name all three capabilities.
  - File Upload API confirmed working against `Notion-Version: 2022-06-28` (the version used everywhere in the provider) — no version-header change needed.

## Strengthen SessionStart guidance with reviewing-quality bypass note — 2026-06-01

Follow-up to the SessionStart soft-guidance change (below). That change removed the hard Ready+ Quality-Verdict gate (#66); the intent to prevent **bypassing the `reviewing-quality` review** before a Ready+ promotion was left only implicitly covered by "route through the skills." A payload-based hard re-enforcement was considered and rejected: the only Waggle-distinctive signal in an `update-page` payload is the `Quality Verdict` property name, and in an OSS context that name could collide with an unrelated database's column — so any deny keyed on it risks a false positive. Enforcement on this path is therefore left advisory; the guidance is made explicit instead.

- **`waggle-notion` 3.3.0 → 3.3.1** (PATCH — guidance text only; no logic, interface, or behavior change). `providers/notion/hooks/session-guidance.sh` now states: before moving a task into a Ready+ status (`Ready` / `In Progress` / `In Review` / `Done`), a live `reviewing-quality` run must produce a fresh `Quality Verdict` written in the same update as the Status change, and a task must never be promoted to Ready+ with a bare Status-only write. The stale "the Quality-Verdict gate" phrasing (which implied an enforced gate that no longer exists) was reworded to "the quality review (AC/EP rubric + reproducibility check)."
  - This remains **advisory, not enforced** — nothing blocks a direct write. It is the strongest available nudge against the one bypass path that cannot be detected without false positives (a bare `Status=Ready+` write carrying no Waggle-distinctive property).
  - Test: `providers/notion/tests/hook/run.sh` adds an assertion that the injected guidance contains the `reviewing-quality` + `Ready+` clause (now 12 cases).

## Replace the PreToolUse hard-deny guard with SessionStart soft guidance — 2026-06-01

The PreToolUse guard (PRs #65 / #66, below) hard-denied direct Notion MCP writes that *looked like* a Waggle Task page. The "looks like a Task page" decision was a pure property-name fingerprint with no way to scope the write to the configured Tasks data source: `update-page` / `update-relation` payloads carry only a `page_id` (no parent data source), a fetch is infeasible in a synchronous 5s hook, and on Cowork the Tasks-DB id is not even available to the hook. As a result the guard **false-positive-denied unrelated Notion databases** — e.g. any create touching `Title`+`Description` (two "common" fields), or any write setting `Status` to a common value like `Done`. No smarter fingerprint can fix this on the unscopable path. We chose to stop enforcing at the tool boundary and instead **guide** the model.

- **`waggle-notion` 3.2.0 → 3.3.0** (MINOR — enforcement mechanism replaced). Removes the PreToolUse hard-deny guard and replaces it with a non-blocking **SessionStart** guidance hook.
  - **Removed.** `providers/notion/hooks/check-task-write.sh` and its test suite (`providers/notion/tests/hook/` — `run.sh`, `driver.sh`, 30 fixtures + transcripts). The off-switches `WAGGLE_TASK_WRITE_GUARD` and `WAGGLE_QUALITY_GATE` no longer exist (there is nothing to switch off — guidance never blocks). The Ready+ Quality-Verdict *gate* (#66) is likewise no longer enforced at the hook boundary; the `reviewing-quality` pipeline and the advisory cache checks in `managing-tasks` / `executing-tasks` are unchanged.
  - **Added.** `providers/notion/hooks/session-guidance.sh`, a SessionStart hook (matcher `startup|compact|resume`) that injects standing `additionalContext`: Task pages live in the Waggle Tasks database; do not write them directly via `notion-create-pages` / `notion-update-page` / `notion-update-relation`; route every task operation through the Waggle skills; direct writes bypass the AC/EP rubric, executor invariants, Acknowledged At auto-set, subtask cascading, and the Quality-Verdict gate; reads are fine. The Tasks data-source id is embedded only when `WAGGLE_NOTION_TASKS_DB_ID` is set. The `compact` source re-injects the guidance after context compaction so it is not lost.
  - **Same fail-open wrapper** as the old guard: `P="${CLAUDE_PLUGIN_ROOT:-}/hooks/session-guidance.sh"; [ -f "$P" ] && exec bash "$P"; echo '{}'`. On Cowork-Windows (`${CLAUDE_PLUGIN_ROOT}` empty) the script is unreachable and the wrapper emits a clean no-op.
  - **`skills/managing-tasks/SKILL.md`** description no longer claims direct writes are "blocked by a PreToolUse hook"; it states they skip quality gates and that a SessionStart reminder reinforces routing through the skill.
  - **Trade-off (intentional).** Zero false positives — no Notion write is ever blocked. Bypass suppression is now **advisory, not enforced**: a determined or forgetful agent can still write a Task page directly. Hook availability on Mac Cowork is unverified and is to be confirmed on-device (does SessionStart fire, and does the guidance survive compaction).
  - **Tests.** `providers/notion/tests/hook/run.sh` now exercises the guidance script (well-formed SessionStart JSON; id embedded only with the env var; fail-open on bad stdin), the wrapper (unresolved vs. resolved `CLAUDE_PLUGIN_ROOT`), and the SessionStart matcher (`startup`/`compact`/`resume` match, `clear` does not).

## PreToolUse Ready+ verdict gate — unreviewed tasks cannot enter Ready+ — 2026-05-29

Builds on the PreToolUse guard (same date, below). A live-log audit (`waggle_live_review_report.html`, 2026-05-28) found that **97% (29/30) of sessions with a live trigger never invoked `reviewing-quality`** and the `task-quality-reviewer-agent` subagent ran **zero** times. The cause is structural: every entry skill's `reviewing-quality` invocation was natural-language prose with no hard mechanism, and the real gates (`managing-tasks` Backlog→Ready, `executing-tasks` dispatch) only *read* the `Quality Verdict` cache advisorily. With the live reviewers rarely running, the cache stayed empty/`UNREVIEWED`, so the advisory gates passed everything. This entry adds a hard, payload-deterministic gate so the invariant no longer depends on the model remembering to run a prose step.

- **`waggle-notion` 3.1.0 → 3.2.0** (MINOR — gate extension). Adds a **Ready+ verdict gate** to `providers/notion/hooks/check-task-write.sh`: a create/update that promotes a Task to a Ready+ status (`Ready` / `In Progress` / `In Review` / `Done`) is **denied** unless the same payload carries a valid `Quality Verdict`.
  - **Invariant.** A write that sets Status to a Ready+ value must include a `Quality Verdict` matching `^(PASS|NEEDS_REFINEMENT|REJECT) hash=[0-9a-f]{8} @<iso> v1` (non-`UNREVIEWED`). `NEEDS_REFINEMENT` / `REJECT` are accepted — a user can still "Save anyway" with a real verdict; only **promoting an unreviewed task** is blocked. `Backlog` / `Blocked` / `Cancelled` writes are below the gate and unaffected.
  - **Payload-first (Cowork-robust).** The decision reads the verdict from the tool payload, not the transcript — it survives auto-compaction and works where `transcript_path` is unreadable (Cowork VM split). A `reviewing-quality` / `task-quality-reviewer-agent` trace in a readable transcript is accepted as a supplementary allow signal, but is never required.
  - **Anti-fabrication (bar-raising, not crypto).** The gate enforces verdict *format* only. Cryptographic hash re-verification is intentionally **non-blocking**: `reviewing-quality` computes its hash in prose (no deterministic serializer exists yet), so a payload-side `sha256` re-check would false-deny legitimate fresh verdicts. Hardening the hash into a blocking check is deferred to a follow-up once the serialization is pinned.
  - **Off-switch.** `WAGGLE_QUALITY_GATE=off` disables the verdict gate independently while leaving the writer guard active; `WAGGLE_TASK_WRITE_GUARD=off` still disables everything. Both fail open on internal error.
  - **Gate interaction (intentional).** For a Ready+ write, a valid-format verdict (or a `reviewing-quality` transcript trace) **allows the call and exits before #65's skill-auth check** — so for Ready+ promotions the quality gate *supersedes* the skill-auth gate rather than stacking with it. This is deliberate: only `reviewing-quality` (always invoked under an authorized writer skill) produces a verdict, so a valid verdict is itself evidence of an authorized path, and the payload-first decision is what makes the gate work on Cowork where the transcript is unreadable. The trade-off is that a hand-fabricated verdict string clears both gates for a Ready+ write — see the format-only anti-fabrication note above; hardening is deferred to the hash follow-up. The #65 skill-auth gate continues to apply unchanged to all non-Ready+ Task writes (Backlog/Blocked/Cancelled creates, relation updates, field edits).
  - New fixtures `18`–`29` in `providers/notion/tests/hook/` cover Ready+ deny/allow, carry-forward, supplementary trace, both off-switches, and multi-page batch creates with mixed statuses (`28`/`29`). (Fixture `13` updated: delegation resets Status to `Backlog`, never promotes to Ready, so it no longer collides with the gate.)

- **`waggle` 2.8.4 → 2.8.5** (PATCH — skills emit the verdict the gate requires). The hook requires the verdict in the *same* payload as the Status change; these skills now produce that atomic write instead of writing the verdict separately (or not at all):
  - `reviewing-quality`: its return contract adds `verdict_string` — the canonical cache string callers echo into a Ready+ promotion payload (avoids each caller re-implementing the cache format).
  - `planning-tasks`: PASS→Ready now persists the live verdict **in the Status=Ready write** (previously PASS computed a verdict but never wrote it to the page). Single and batch flows.
  - `managing-tasks`: Backlog→Ready and all Ready+ transitions (incl. "mark done" and auto-cascade) carry the verdict in the Status payload; the `UNREVIEWED` "Save anyway with no verdict" path is removed — a cache miss runs a live review first.
  - `executing-tasks`: Ready→In Progress dispatch carries the existing verdict forward in the In Progress write.
  - `ingesting-messages`: the Category A hearing-blocker (created at `Ready`) now obtains a verdict via `reviewing-quality` and includes it in the atomic create; edited Category B drafts are created at `Backlog` (verdict deferred) rather than at `Ready` with an empty verdict.
  - **Limits.** Notion-UI direct edits bypass MCP and remain uncatchable by the hook (catch-net: `running-daily-tasks` Step 2.6 / `monitoring-tasks --deep`). Format validation raises the bar but is not cryptographic proof of a real review.

## PreToolUse guard against direct Notion writes on Tasks — 2026-05-29

The architectural enforcement promised by the 2026-05-24 entry ("the PreToolUse hook itself, shipping in v2.9.0") now ships — in the **`waggle-notion` provider plugin**, **not** in waggle core. This supersedes the abandoned core-hook approach (PR #64).

- **`waggle-notion` 3.0.1 → 3.1.0** (MINOR — new hook). Adds `providers/notion/hooks/hooks.json` + `providers/notion/hooks/check-task-write.sh`, a `PreToolUse` hook that hard-denies (`permissionDecision: "deny"`) direct Notion MCP writes to Waggle Task pages unless an authorized Waggle writer skill is active in the recent transcript.
  - **Why a provider hook in an external script.** The matched tools are Notion-specific, so the hook lives in the Notion provider, keeping core clean. The guard logic (schema fingerprint + transcript authorization) is an external script `check-task-write.sh`, invoked from `hooks.json` via a thin shell-form wrapper: `P="${CLAUDE_PLUGIN_ROOT:-}/hooks/check-task-write.sh"; [ -f "$P" ] && exec bash "$P"; echo '{}'`. The plugin's target audience is **macOS**, where plugin hooks run on the native shell and `${CLAUDE_PLUGIN_ROOT}` resolves to a real path, so an external script is clean and maintainable (vs. a ~50-line inline `bash -c` blob). On **Cowork-Windows**, `${CLAUDE_PLUGIN_ROOT}` is empty in *every* hook form (exec-form pre-substitution and env export both dead — verified on-device 2026-05-30), so the script is unreachable and in-script platform detection can never run; the wrapper instead detects the unresolved-root *symptom* and **fails open cleanly** (`echo '{}'` → allow, exit 0) rather than crashing with a noisy `exit 127`. The earlier prototype (PR #64) used `bash "${CLAUDE_PLUGIN_ROOT}/..."` directly and broke silently there; the wrapper makes that fail-open explicit while keeping the macOS/Linux/WSL path fully functional. Shell form requires the placeholder to be double-quoted yourself (here it sits inside the quoted `P="…"` assignment).
  - **What it matches.** `mcp__…__notion-create-pages`, `…__notion-update-page`, and `…__notion-update-relation` (prefix-agnostic, so both the hosted Notion MCP and the `notion-extension` server are covered). `notion-query` and other reads are not matched.
  - **How it decides.** For create/update it fingerprints the property-name set: any one *distinctive* Waggle field (`Executor`, `Acknowledged At`, `Quality Verdict`, `Execution Plan`, `Acceptance Criteria`, `Blocked By`), or two *common* fields (`Status`, `Priority`, `Assignee`, `Due Date`, `Tags`, `Title`, `Description`), or a `Status` set to a Waggle status value, marks the call as a Tasks write. Expanded property keys are normalized first — `date:` / `place:` prefixes and the `userDefined:` prefix that Notion uses for url/id properties (e.g. `date:Due Date:start` → `Due Date`, `userDefined:URL` → `URL`). `update-page` is only inspected for `command: "update_properties"`. Any `notion-update-relation` (which only exists on the waggle-exclusive `notion-extension` server) is treated as a Tasks write unconditionally.
  - **Authorization.** The call passes if the recent transcript shows an active Waggle *writer* skill: `managing-tasks`, `ingesting-messages`, `delegating-tasks`, `executing-tasks`, `planning-tasks`, `running-daily-tasks`. Read-only `viewing-tasks` / `monitoring-tasks` are intentionally **not** authorizers (the shared `assigning-to-others` skill is omitted too — it is always invoked under one of the writer skills above, so it never needs its own entry).
  - **Fail-open & opt-out.** Any internal error returns allow (`{}`) so hook bugs never brick a session. Set `WAGGLE_TASK_WRITE_GUARD=off` to disable entirely.
  - **Migration note (BREAKING-LITE).** Workflows that previously wrote directly to the Tasks DB outside an entry skill now receive a deny with a redirect to `/waggle:managing-tasks`. This is the intended behavior; opt out via the env var if needed.
  - Unit tests: `providers/notion/tests/hook/` (`run.sh` runs all fixtures through `driver.sh`, which invokes `check-task-write.sh` directly, plus the matcher regex and two wrapper assertions — unresolved-root clean allow, and resolved-root reaches-the-script).

- **`waggle` 2.8.3 → 2.8.4** (PATCH — description triggers). Sharpens skill-discovery coverage for prompts that were observed bypassing entry skills:
  - `managing-tasks`: adds dependency/relation triggers (block, unblock, blocked by, parent task, subtask, link tasks, relation, …) and scoped-query phrasing ("tasks for <store/project>").
  - `ingesting-messages`: adds Slack-scoped lookup triggers ("find my tasks in slack", "check slack for my tasks", "my mentions in slack", "pull tasks from slack").
  - `executing-tasks`: notes that explicit "execute the X task" / "run task ID …" requests enter through this skill so the Ready-state transition runs the quality gate.
  - `viewing-tasks`: clarifies it is read-only and that writes/mutation-leading scoped filters route through `managing-tasks`.

## `managing-tasks` description hardened against MCP-direct bypass — 2026-05-24

The `managing-tasks` skill's description had a soft anti-shortcut signal ("If the user mentions tasks in any way, use this skill") that didn't name the specific bypass path Claude was tempted to take — direct `notion-create-pages` / `notion-update-page` / `notion-update-relation` calls on the Tasks DB. The description now explicitly names these tools as forbidden and announces the upcoming PreToolUse hook (shipping in v2.9.0) that will enforce this.

- **`waggle` 2.8.2 → 2.8.3** (PATCH — description tweak). Two changes to `skills/managing-tasks/SKILL.md` frontmatter:
  1. Added an anti-shortcut directive that names the three Notion MCP tools that bypass quality gates (AC/EP rubric, executor invariants, `Acknowledged At` auto-set, subtask cascading) and previews the upcoming hook.
  2. Disambiguated "assign" from `delegating-tasks`. `managing-tasks` now triggers on "assign to self" only; "assign to another person / hand off" stays exclusive to `delegating-tasks`.
- Body and reference files unchanged. Skill behavior is unchanged at runtime — only the description language is sharpened.
- This is the first of two planned changes. The follow-up (v2.9.0) will add the PreToolUse hook itself, providing language-agnostic architectural enforcement on top of this soft signal.

## notion-extension `notion-update-relation` response slimmed — 2026-05-22

- **`notion-extension` 0.5.0 → 1.0.0** (MAJOR — output contract change). The `notion-update-relation` MCP tool previously returned the full Notion Page object from `notion.pages.update()` (typically 3–10 KB per call: 15 Core + 9 Extended properties with their full rich_text / relation arrays). It now returns a minimal confirmation echo:

  ```json
  { "ok": true, "page_id": "<uuid>", "property_name": "Blocked By", "mode": "append", "relation_ids": ["<id1>", "<id2>"] }
  ```

  `relation_ids` reports the post-update final state — for `append` mode this is the merged + deduplicated list (the value `handleUpdateRelation` already computes internally as `finalIds`). A repo-wide search confirmed no skill, script, or test reads any field of the previously returned Page object, so the cut is non-breaking in practice. The motivation is per-call token consumption: `notion-update-relation` is invoked on every Blocked By / Parent Task update across `managing-tasks` / `delegating-tasks` / `ingesting-messages` flows, so the ~95% payload reduction adds up quickly over a session. Callers that need other page fields after the update should re-fetch via `notion-fetch` or `notion-query`.

- **`waggle-notion` 3.0.0 → 3.0.1** (PATCH — companion bump). The bundled extension's output shape narrows, but the provider plugin's external skill behavior is unchanged — no consumer in `skills/` depends on the dropped Page-object fields. `providers/notion/extension/README.md` and `providers/notion/skills/notion-provider/SKILL.md` ("Path 2: Desktop Extension") are updated to document the new shape.

- **Bug fix (alongside the response cut)**: `mode: "append"` with `relation_ids: []` previously cleared the existing relation as a side effect of the merge being skipped (`finalIds` defaulted to the empty input). Treating "append nothing" as a destructive write was surprising — the prior shape hid this because the full Page object was returned regardless. The 1.0.0 release adds a guard that short-circuits this case as a no-op and returns the existing relation IDs. To clear a relation, callers must use `mode: "replace"` with `relation_ids: []`.

- **Bug fix**: the MCP `Server()` constructor in `server/index.js` had its `version` field still hardcoded to `"0.5.0"`; bumped to `"1.0.0"` to match `manifest.json` / `package.json` (otherwise MCP capability negotiation would surface a version mismatch).

- **Migration**: any external automation that reads `properties.*`, `last_edited_time`, `archived`, etc. off the response must switch to `notion-fetch` / `notion-query` to retrieve those fields. None of the internal Waggle skills are affected. The CLI shell-script path (`update-relations.sh`) is untouched.

## Provider plugin version catch-up — 2026-05-19

The `waggle` plugin (root) was bumped through 2.8.0 → 2.8.1 → 2.8.2, but the three provider plugins in `providers/*/.claude-plugin/plugin.json` were not bumped alongside, even though their content changed materially:

- **`waggle-notion` 2.1.0 → 3.0.0** (MAJOR). v2.8.0 added the `Quality Verdict` core field to auto-repair. v2.8.1 changed the `Issuer` column type from `PERSON` to `CREATED_BY`, which is a breaking change for existing databases — `docs/quality-calibration.md` and the Migration Guide in `providers/notion/skills/notion-provider/SKILL.md` describe the manual migration. The major bump records this break.
- **`waggle-sqlite` 2.0.0 → 2.1.0** (MINOR). v2.8.1 added an `Issuer` column substitution to the Create Task INSERT template and a precondition halt when `current_user.id` resolves to a fallback sentinel. The underlying schema is unchanged, so existing databases need no migration; the bump reflects the behavioral addition.
- **`waggle-turso` 2.0.0 → 2.1.0** (MINOR). Same set of changes as `waggle-sqlite`.

This is a bookkeeping entry — no source-code change beyond the three manifest files. The underlying behavior was already shipped in waggle 2.8.0 / 2.8.1; this catch-up just realigns the provider version numbers to match the changes they actually carry.

## [2.8.2] - 2026-05-19

### Changed

- **`agents/task-quality-reviewer-agent.md`** tuned based on v2.8.0 calibration findings. The v2.8.0 calibration over 30 tasks yielded 92.9% agreement (rated), but the two disagreements pointed at distinct failure modes, and qualitative memos consistently flagged a third pattern (executor-homework overreach). v2.8.2 directly addresses two of three:

  - **Mandatory Step 3 "Goal clarity definition test"** (replaces the prose criterion): the Reviewer now must enumerate every proper noun / brand / store / project name / internal jargon term in the goal sentence and explicitly answer "What is &lt;term&gt;?" from the spec alone for each. If any term fails the test, Goal clarity is ✗ — no rationalizing from context. There is no △ on this axis; the test is binary. Examples show the difference between "Sticky Bones LP" (✓ if a product link is inline) and "republish the topics with Wkit" (✗ — `topics`, `Wkit` undefined).
  - **New Step 4 "Request-time vs execute-time boundary"** (applied before the axis evaluation in Step 5) explicitly partitions responsibilities. Information the executor can resolve themselves (branch names, file paths via grep, equivalent tool choices) is execute-time and MUST NOT down-score Verifiability or Reproducibility. Information the executor cannot resolve without the requester (goal, deliverable definition, links to undocumented decisions) is request-time and is the only valid target for gaps and fixes.
  - **Rules** section gains "Don't ask the requester for the executor's homework" and "Undefined domain nouns are Goal-clarity failures, not Hidden-context warnings."
  - **Output format**: every gap and every fix MUST be a request-time item. Execute-time details (branch names, exact code edits) are no longer permitted in gaps or fixes. The Goal-clarity entry in the per-axis findings template is now `◯/✗` (binary) instead of `◯/△/✗`.

- **Sanity-check rerun on the two v2.8.0 disagreement cases**:
  - Case A (undefined domain nouns: a task containing terms like `Wkit`, `ネオンコレクション`, `topics` without definitions). Previously `NEEDS_REFINEMENT`; now `REJECT` ✓ — Goal-clarity definition test correctly flags every undefined noun.
  - Case B (AC mixes Pre-requirements with completion criteria; implementation and design conflated in a single task). Previously `NEEDS_REFINEMENT`; still `NEEDS_REFINEMENT`. This is a task-granularity / AC-composition failure that the v2.8.2 axes do not target directly — see `docs/calibration-results.md` for the analysis and the v2.8.3 follow-up plan.

  Net: 1 of 2 known disagreements resolved with no regressions on the v2.8.0 PASS / NEEDS_REFINEMENT distribution.

- **`docs/calibration-results.md`** appended with a v2.8.2 prompt-tuning section recording the two sanity-check verdicts, the resolution status, and the v2.8.3 follow-up (task-granularity axis).

### Follow-ups (v2.8.3+)

1. Introduce a "task-granularity" axis (or strengthen Boundary clarity) so that ACs which conflate Pre-requirements, design outputs, and implementation completion criteria are flagged as boundary failures. This is the remaining v2.8.0 disagreement pattern.
2. Full re-run of the 30-task calibration against the v2.8.3 Reviewer prompt to confirm both disagreements are resolved without regressions.

## [2.8.1] - 2026-05-19

### Changed (breaking)

- **`Issuer` is now provider-auto-populated.** The core field switches from a skill-set `person[]` to a provider-managed value populated automatically at task-creation time. Skills MUST NOT include `Issuer` in their create payloads. Motivation: telemetry on a 100-task sample showed ~27% of tasks ended up with empty `Issuer` because the old design required every skill / intake / automation path to remember to set it explicitly, and several paths reliably forgot (scheduled tasks where `current_user` failed to resolve, third-party automations writing directly to the data store, intake-template payload omissions, manual Notion-UI creates). Centralizing the responsibility at the provider boundary eliminates every one of those paths in one move. See `skills/waggle-protocol/SKILL.md` § Issuer Auto-Populate Contract.
- **Notion provider: `Issuer` column type `PERSON` → `CREATED_BY`.** `notion-provider/SKILL.md` auto-repair DDL now creates a `CREATED_BY`-typed Issuer on fresh databases. Existing v2.7.x databases keep their old `PERSON` column; auto-repair will NOT replace it because the change is destructive. Operators upgrading must run the migration manually — see `providers/notion/skills/notion-provider/SKILL.md` § Migration Guide: v2.7.x → v2.8.1. The migration's trade-offs are explicit in that guide: existing Issuer values are lost (Notion back-fills the new column from each page's `created_by` metadata, surfacing the actual creator rather than any deliberate "issuer override"); the people-array shape becomes single-user; the proxy / "on behalf of" workflow no longer survives. The recommended replacement for that workflow is setting `Assignee` (rather than overloading `Issuer`).
- **SQLite/Turso providers: `Issuer` populated by the Create Task INSERT template.** The `issuer TEXT DEFAULT ''` column in `init-db.sh` is unchanged, but the provider SKILL.md Create Task examples now substitute `${current_user.id}` into the INSERT directly. Callers do not pass Issuer. A precondition check halts the INSERT if `current_user.id` resolves to a fallback sentinel (`"local"` or `"unknown"`) — this enforces the "no anonymous tasks" rule and prevents the empty/sentinel-valued Issuer failure mode at the source. SQLite/Turso filter recipes for "owned by user via Issuer fallback" now use `t.issuer = '<user_id>'` exact match instead of array-contains, since the column is now a single-value TEXT.
- **Filter syntax for Notion Issuer queries**: shifts from `"Issuer","people":{...}` to `"Issuer","created_by":{...}` to match the new column type. Operator names (`contains`, `is_empty`) are unchanged. `running-daily-tasks` does not embed this syntax — it asks the active provider for the filter — so the change is confined to the Notion provider SKILL.md filter recipes.

### Changed (non-breaking)

- `skills/managing-tasks/references/task-creation-flow.md` — the "Issuer (auto-populated, write-once)" guidance is rewritten to instruct skills to NOT set Issuer in create payloads.
- `skills/ingesting-messages/references/task-creation-templates.md` — the Common Fields table loses its `| Issuer | [current_user] |` row, replaced by a note explaining that the provider auto-populates.
- `skills/assigning-to-others/SKILL.md` + `skills/delegating-tasks/SKILL.md` — the "Issuer is preserved" rule is now reframed: enforcement moves from the skill to the provider boundary (Notion's `created_by` is read-only; SQLite/Turso Update Task templates do not include `issuer`). Skill-side behavior is now simply "don't pass Issuer in update payloads," which falls out naturally from following the provider templates.
- `skills/validating-fields/SKILL.md` Construction Guide — Notion read path changes from `.properties.Issuer.people | length > 0` to `(.properties.Issuer.created_by.id // null) != null`. SQLite/Turso read path tightened from a length-based check to an explicit null/empty check. Canonical JSON contract is unchanged (`issuer` is still a boolean).
- `skills/monitoring-tasks/scripts/analyze-tasks.sh` — `has_issuer` and `issuer_ids` extractions updated to the new Notion shape. Downstream set-difference logic for "assigned by someone else" detection is unchanged because it works regardless of whether `issuer_ids` has 0 or 1 element.

### Migration

Operators with an existing v2.7.x Notion database MUST run the manual migration in `providers/notion/skills/notion-provider/SKILL.md` § Migration Guide before upgrading skills. Fresh databases get the correct column type automatically via auto-repair. SQLite/Turso databases do not need migration — the schema is unchanged, only the INSERT template guidance changed.

## [2.8.0] - 2026-05-19

### Added

- **3-layer Task Quality Gate system** (Layer 0 worthiness advisory, Layer 1 deterministic Rubric, Layer 2 LLM Intent Reproducibility Check). The protocol spec (`skills/waggle-protocol/SKILL.md`) gains a Quality Spec section documenting all three layers, the 2 reserved placeholder prefixes (`[DRAFT-AC]` / `[DRAFT-EP]` and `[NEEDS-REFINE]`), and the `Quality Verdict` cache format v1. Goal: ensure every task that reaches Ready is reproducible by a stranger handed only the spec — i.e., agent-autonomous quality.
- **`agents/task-quality-reviewer-agent.md`** (new). Independent reviewer subagent that scores a task spec along 5 axes (Goal clarity, Boundary clarity, Verifiability, Reproducibility, Hidden context) from a new-colleague perspective. Returns PASS / NEEDS_REFINEMENT / REJECT plus per-axis findings and concrete suggested fixes. Pinned to `claude-sonnet-4-6` for cost predictability; `maxTurns: 4` with a 3-file / 10K-token read budget.
- **`skills/reviewing-quality/`** (new, `user-invocable: false`). Single integration point for the Quality Verdict pipeline. Owns: Reviewer agent spawn, content-hash verdict cache (sha256 of Title|Description|AC|EP), 7-day same-axis-failure suppression, batch fan-out, Rubric pre-filter, worthiness-tag skip. Modes: `live`, `cache-only`, `live cache-aware`.
- **`Quality Verdict` core field** (16th Core field) auto-repaired into the Notion DB on the first session after upgrade. Stores `<verdict> hash=<8hex> @<iso8601> v1 [suppressed-until=<iso8601>]`.
- **Layer 0 worthiness classifier** in `skills/ingesting-messages/` Phase A. Extends the existing Category A/B/C classifier output schema to also emit `worthiness ∈ {task, calendar-like, info-only}` in a single LLM call (no new pass). Worthiness ≠ task items skip Phase A.5 Reviewer entirely (cost saved) and surface in Phase B's confirmation table with a `[Skip] / [Create as task] / [Convert to note] / [Discard]` user prompt — never silently discarded.
- **`running-daily-tasks` Step 2.6 — Ready Quality Health Check**. Inserted between Blocked Task Review and Dispatch. Catches tasks that reached Ready or beyond without going through the v2.8.0 gates (typically Notion UI direct edits, legacy tasks). Batch-invokes `reviewing-quality` in live cache-aware mode; most tasks return from cache.
- **`monitoring-tasks --deep`** flag (opt-in, default OFF). Adds Reviewer-based debt analysis on top of the default Rubric-only debt categories.
- **8 new Quality Debt categories** in `monitoring-tasks`: `EMPTY_AC_READY_PLUS`, `EMPTY_EP_READY_PLUS`, `SHALLOW_AC`, `SHALLOW_EP_STEPS`, `MISSING_CONCRETE_ARTIFACT_EP`, `STUB_INGEST_AGED`, `LIKELY_NON_TASK` (calendar-like leakage detection via title regex), and a top-level `Ready Health Score` percentage.
- **`docs/quality-calibration.md`** documenting the ship-blocker calibration procedure (30 hand-labeled tasks, ≥80% agreement required, with fallback configurations if the gate fails).
- **`docs/quality-gates.html`** visualizing the 3-layer gate system across all task creation paths (gate-by-path table, typical-flow SVG, layered skills/agents dependency graph).
- **Self-reflection 1-line note** added to `agents/code-planning-agent.md` and `agents/knowledge-planning-agent.md` before Round 1 of the brainstorming protocol. Catches obvious gaps before the user sees them.

### Changed

- **`agents/code-planning-agent.md` / `agents/knowledge-planning-agent.md`** now use `[NEEDS-REFINE]` instead of the legacy `[LOW CONFIDENCE]` prefix when the user disengages mid-brainstorm. Aligns with the protocol's 2 reserved prefixes.
- **`skills/planning-tasks/`** Quality Gate (Step 5 / Phase 5) now invokes `reviewing-quality` after the user accepts the AC/EP. Branches on `PASS` (proceed) / `NEEDS_REFINEMENT` (apply suggested fixes or save anyway) / `REJECT` (save with `[NEEDS-REFINE]` and keep Backlog).
- **`skills/managing-tasks/`** task creation flow gains a "defer" shortcut: empty AC/EP fields are filled with `[DRAFT-AC]` / `[DRAFT-EP]` placeholders instead of being saved empty. Subtask decomposition no longer inherits parent AC/EP (which historically created misleading copy-paste specs); children are initialized with placeholders. Pre-Ready transitions invoke `reviewing-quality` in cache-only mode (hot path).
- **`skills/ingesting-messages/`** Phase A.5 now also invokes `reviewing-quality` (live) after the Rubric pass, for `worthiness=task` Category B messages. User edits in Phase B remain authoritative — they are NOT re-run through the Reviewer; only the Rubric applies on the next Ready transition.
- **`skills/executing-tasks/`** Dispatch Readiness gains a Quality Verdict cache-only check after the existing Rubric gate. Per the protocol, live Reviewer invocation is forbidden at dispatch (hot path); cache miss surfaces `[Refine via /planning-tasks] [Dispatch anyway]` to the user.
- **`skills/delegating-tasks/`** + **`skills/assigning-to-others/`** invoke `reviewing-quality` in live cache-aware mode (default-on). Delegation is the bypass-catch chokepoint where a 10–20s live Reviewer wait is the right trade-off because delegation is rare and high-impact.
- **`skills/validating-fields/`** documents the canonical Rubric (4 AC rules + 4 EP rules) in `references/quality-rubric.md`. The skill remains LLM-free; Rubric evaluation is regex/length heuristics only. Adds a `find_quality_debt` shared API contract consumed by `monitoring-tasks` and `running-daily-tasks`.
- **`providers/notion/skills/notion-provider/SKILL.md`** schema validation list bumped to 16 Core fields (adds `Quality Verdict`). Auto-repair runs once at session bootstrap; per-call repair is not introduced.

### Telemetry

- Waggle does not implement its own telemetry. Cost and latency observation for the new Reviewer invocations rely on the platform's (Claude Code / Cowork) OpenTelemetry integration. No plugin-side log files, span emission, or metric counters were added.

## [2.7.3] - 2026-05-16

### Fixed

- **Cowork Live Artifact dashboard is now visible again** (`skills/viewing-tasks/server/static/shared.js`, `skills/viewing-tasks/scripts/generate-cowork-artifact.sh`). Two viewing-tasks bugs were silently breaking the bundled Live Artifact, both masked by the larger 400 error (see Changed below). First, the Cowork fetch adapter calls `window.Waggle.updateData({ tasks, updatedAt, currentTeam })` after every successful Notion query, but `updateData` was defined locally inside `shared.js`'s IIFE and never exported on the `window.Waggle` surface — so the guard `typeof window.Waggle.updateData === 'function'` was always false and data silently never reached the renderers. Added `updateData: updateData` to the export object. Second, `generate-cowork-artifact.sh`'s `strip_init_keyboard` awk function terminated on the first `})` + `;` line it saw, but that pattern also occurs inside nested function expressions (`getTaskElement: function (taskId) { ... }`), so the stripper cut mid-block in every per-view template (`kanban.html` / `list.html` / `calendar.html` / `gantt.html`). The bundle ended up with orphaned `getTaskElement: function (...)` property fragments that raised SyntaxError, killing each view's IIFE before its `render` could register on `W._renderers` — leaving the dashboard with zero renderers attached even when data did arrive. `strip_init_keyboard` is now a brace-depth tracker that ends stripping only when depth returns to 0 on a line containing the closing `);`. Added a self-test that fails the build if any `^[[:space:]]+getTaskElement:[[:space:]]+function` line survives in the bundled output.

### Changed

- **`Notion Extension for Waggle` v0.4.0 → v0.5.0** (`providers/notion/extension`). Removed the `display_name` field from `manifest.json`. The MCP tool prefix is generated from `display_name` when present and falls back to `name` otherwise — under v0.4.x the prefix was `mcp__Notion_Extension_for_Waggle__...`, which Cowork's Live Artifact bridge rejected with HTTP 400. Follow-up isolation testing pinned the trigger to **underscores in the prefix** specifically (a single-extension control with `display_name: "EchoUpper"` → `mcp__EchoUpper__...` succeeds; a single-extension control with `display_name: "echo lower only"` → `mcp__echo_lower_only__...` fails). The underscores in `Notion_Extension_for_Waggle` came from whitespace-to-underscore normalization of the `display_name` string. Dropping `display_name` causes Cowork to derive the prefix from `name`, yielding the hyphenated `mcp__notion-extension__...` prefix that the bridge accepts. Verified end-to-end against the production-equivalent debug extension `experiments/mcpb-debug/06-notion-extension-clone/` (removed in #54; restorable from PR #53 history). Existing v0.4.x installs keep working from chat without re-installation; only Cowork Live Artifact usage requires upgrading to v0.5.0.
- **MCP tool name is no longer hardcoded** in `skills/viewing-tasks/SKILL.md`, `skills/managing-views/SKILL.md`, `skills/viewing-tasks/scripts/generate-cowork-artifact.sh`, or `skills/managing-views/scripts/generate-cowork-custom-artifact.sh`. Both generator scripts now require the full MCP tool name as a positional argument (5th for `generate-cowork-artifact.sh`, 6th for `generate-cowork-custom-artifact.sh`); the bundled adapter reads it from `window.__COWORK_QUERY_CONFIG__.mcpToolName` rather than calling a hardcoded string. Both SKILL.md files instruct the agent to resolve the notion-query tool name from its own available MCP tools at generation time. This makes the skills resilient to extension-manifest changes (display_name additions/removals, version bumps) and lets v0.4.x users keep working through the SKILL.md flow without touching their installation. The change is internal to the SKILL.md → generator → adapter pipeline; user-facing behavior is identical when the resolved name is valid.
- **Cold-start 400 banner copy** (`skills/viewing-tasks/SKILL.md`). The Troubleshooting entry that previously said "Windows only (Mac unaffected)" was updated — the cold-start race reproduces on macOS as well. The mitigation (invoke any Notion MCP tool from chat once before opening the artifact) is unchanged.

## [2.7.2] - 2026-05-15

### Fixed

- **Cowork Live Artifacts no longer fetch the entire workspace** (`skills/viewing-tasks/scripts/generate-cowork-artifact.sh`, `skills/managing-views/scripts/generate-cowork-custom-artifact.sh`). The bundled fetch adapter previously called `mcp__Notion_Extension_for_Waggle__notion-query` with only `{ database_id, page_size, start_cursor }` — no Notion `filter` — so the artifact pulled every task in the database (capped at 1000) and left all narrowing to the client-side `filter-bar.js`. On a multi-person workspace that meant opening the dashboard surfaced everyone's backlog and finished work, swamping the user's actual open items. The adapter now applies a server-side filter: `Assignee contains <assigneeUserId>` (when configured, baked at generation time) AND `Status != Done` AND `Status != Cancelled`. The `__COWORK_QUERY_CONFIG__` block gains an `assigneeUserId` field; both generators accept a new optional positional arg for it (`viewing-tasks` 4th, `managing-views` 5th). Both SKILL.md flows now default to `current_user.id` and document an explicit "show another person's view" override via the `looking-up-members` skill. Empty assignee degrades to status-only filtering with an informational banner rather than silently going blank.

## [2.7.1] - 2026-05-15

### Fixed

- **Intake Log load no longer stalls `running-daily-tasks` Step 1 for ~12 minutes** (`skills/ingesting-messages`, `providers/notion/extension`). Step 0 previously did `notion-query` on the Intake Log with no `page_size` or date filter, asking the server to aggregate every record server-side. Once the log grew past ~200 records (~250KB of full-page JSON) the MCP host's token cap kicked in and spilled the response to a host-side file (`/var/folders/.../tool-results/*.txt` on macOS). On Cowork — where the agent runs inside a Linux VM that cannot reach host paths — recovery via Read / Grep / a subagent went nowhere; one reported session burned 74 tool calls over 719 seconds before giving up and proceeding without dedup. Step 0 now performs a date-windowed paginated load: `filter: Processed At >= now - 30d`, `page_size: 50`, iterating `start_cursor` / `has_more` until exhausted. The dedup set stays correct because messaging-MCP searches never surface anything older than the retention window anyway.
- **Intake Log FIFO replaced with TTL** (`skills/ingesting-messages` Step 4). The old "if > 1000 entries, delete the oldest" rule required knowing the total record count, which is incompatible with paginated date-windowed loads. Step 4 now archives records whose `Processed At` is older than `intake_log_retention_days` — the same window Step 0 uses for the load — so retention and dedup never drift apart within a run. The 1000-entry cap was also calibrated wrong for the actual payload size: at ~1,255 chars per Notion page object, 1000 entries was already ~1.25 MB, far past the MCP cap.
- **Retention window scales with `lookback_period`** (`skills/ingesting-messages` Steps 0 and 4). The dedup window must always cover what the messaging MCP can re-surface in the current run, so `intake_log_retention_days` is now derived as `max(30, ceil(lookback_period_in_days) + 7)` rather than a flat 30. The `+ 7` buffer absorbs Step 4's exclusive `before:` cutoff and the off-by-one day adjustments in the Slack date filter. A documented cross-run edge case remains: if a single run uses a `lookback_period` materially longer than recent prior runs, prior runs' TTL cleanups may already have archived rows in the extended window and those messages can re-classify as new — surface this as a known trade-off rather than silently producing duplicates.
- **Pagination-version detection** (`providers/notion/skills/notion-provider`, `skills/health-checking`). The tool name `mcp__notion-extension__notion-query` did not change between v0.3.x and v0.4.0, so its presence does not imply pagination support; v0.3.x silently ignores `page_size` and returns the aggregated full result set, which would defeat the new intake load path. The provider skill now documents a runtime probe (check for `has_more` in the response after passing `page_size`) and halts the calling step rather than continuing with a possibly-truncated aggregate. The health-checking skill's Check 4 was updated to a v0.4.0 floor and now actively probes pagination support against a small DB rather than only checking tool name availability.
- **`notion-query` MCP gains real pagination support** (`providers/notion/extension`, v0.4.0). The server's `handleQuery` previously hard-coded an internal `while (has_more)` loop and always returned the aggregated full result set, ignoring `page_size` / `start_cursor` even when callers passed them (the Cowork view-artifact generators in `viewing-tasks` / `managing-views` were already written to drive pagination, so their `if (!data.has_more) break;` branch was always taken after the first iteration — they silently fetched everything in one shot and were prone to the same overflow). The server now branches: when `page_size` is supplied, it returns one Notion API page along with `has_more` and `next_cursor` and lets the caller iterate; when omitted, legacy aggregate behavior is preserved so existing callers are unaffected. Also accepts the Notion API's `filter_properties` parameter to project a subset of columns (note: only the `properties` object shrinks; Notion still returns per-page metadata).

### Changed

- **`Notion Extension for Waggle` v0.3.0 → v0.4.0** (`providers/notion/extension`). New optional input fields on `notion-query`: `page_size`, `start_cursor`, `filter_properties`. No breaking change — calls that omit these run on the legacy aggregate path.
- **Provider docs** (`providers/notion/skills/notion-provider/SKILL.md`). The Path 2 description now lists the new pagination parameters and recommends paginating any query against databases that may grow past ~200 rows.

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

