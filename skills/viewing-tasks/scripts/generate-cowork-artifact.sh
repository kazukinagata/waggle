#!/usr/bin/env bash
# generate-cowork-artifact.sh
#
# Bundles the four view HTMLs (kanban / list / calendar / gantt) into a single
# Cowork Live Artifact. The output is a self-contained HTML document that
# fetches Notion data via window.cowork.callMcpTool("...notion-query", ...)
# and renders one of the four views via a top tab strip.
#
# Usage:
#   generate-cowork-artifact.sh <tasksDatabaseId> [team_id] [team_name]
#
# Output: writes the standalone HTML to stdout.
#
# See skills/viewing-tasks/SKILL.md "Cowork Live Artifact Mode" for the
# protocol-level invocation. The generator enforces structural invariants
# (DOCTYPE / charset / IIFE wrap) and exits non-zero on any failure.

set -euo pipefail

DB_ID="${1:?Usage: generate-cowork-artifact.sh <tasksDatabaseId> [team_id] [team_name]}"
TEAM_ID="${2:-}"
TEAM_NAME="${3:-}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATIC_DIR="$SCRIPT_DIR/../server/static"

VIEWS=(kanban list calendar gantt)
ASSETS=(shared.css shared.js filter-bar.css filter-bar.js detail-panel.css detail-panel.js)

# ── Pre-flight validation ─────────────────────────────────────────────────

for v in "${VIEWS[@]}"; do
  f="$STATIC_DIR/${v}.html"
  if [ ! -f "$f" ]; then
    echo "Error: Missing view template: $f" >&2
    exit 1
  fi
  if ! head -3 "$f" | grep -qi '<!doctype html>'; then
    echo "Error: $f missing <!DOCTYPE html> (mojibake guard)" >&2
    exit 1
  fi
  if ! grep -qi '<meta charset="utf-8">' "$f"; then
    echo "Error: $f missing <meta charset=\"UTF-8\"> (mojibake guard)" >&2
    exit 1
  fi
done

for a in "${ASSETS[@]}"; do
  if [ ! -f "$STATIC_DIR/$a" ]; then
    echo "Error: Missing shared asset: $STATIC_DIR/$a" >&2
    exit 1
  fi
done

# ── Helpers ───────────────────────────────────────────────────────────────

# Extract per-view inline <style> body (everything between the
# `<link rel="stylesheet" href="detail-panel.css">` line and `</head>`).
# The result is the per-view CSS only, without the shared CSS link tags.
extract_view_style() {
  awk '
    /<link rel="stylesheet" href="detail-panel\.css">/ { active=1; next }
    active && /<\/head>/ { exit }
    active { print }
  ' "$1"
}

# Extract the view-specific body content (between `<div id="filter-bar"></div>`
# and `<div class="toast"`). The shared header, filter-bar placeholder, and
# toast are reconstructed once at the bundle level.
extract_view_body() {
  awk '
    /<div id="filter-bar"><\/div>/ { active=1; next }
    active && /<div class="toast"/ { exit }
    active { print }
  ' "$1"
}

# Extract the inline <script> body (the last `<script>` block, which has no
# src attribute). All four view HTMLs put this immediately after the three
# `<script src="...">` external loads.
extract_view_inline_script() {
  awk '
    /^<script>[[:space:]]*$/ { in_script=1; next }
    in_script && /^<\/script>/ { exit }
    in_script { print }
  ' "$1"
}

# Scope per-view "broad" CSS selectors (body / main at start of rule) to the
# view's pane attribute so they do not leak across panes when bundled. Other
# rules use unique class names and need no rewriting.
scope_view_style() {
  local view="$1"
  awk -v view="$view" '
    /^[[:space:]]*body[[:space:]]*\{/ {
      sub(/body/, "[data-view-pane=\"" view "\"]")
      print; next
    }
    /^[[:space:]]*main[[:space:]]*\{/ {
      sub(/main/, "[data-view-pane=\"" view "\"] main")
      print; next
    }
    { print }
  '
}

# Wrap a view's inline script body in an IIFE with the defensive preamble.
# Rewrites `W.onDataUpdate = render` → multiplex push and strips per-view
# `W.initData()` calls (the bundle triggers initData() once at the end).
wrap_view_script() {
  local view="$1"
  printf '<script>(function () {\n'
  printf '  // Cowork bundle preamble (view: %s)\n' "$view"
  printf '  var W = window.Waggle = window.Waggle || {};\n'
  printf '  W._renderers = W._renderers || [];\n'
  # Transform the inline script body:
  #   - replace renderer registration with multiplex push
  #   - drop standalone W.initData() lines
  # Use `#` as the sed delimiter so the `||` in the replacement doesn't collide.
  sed -E \
    -e 's#W\.onDataUpdate[[:space:]]*=[[:space:]]*render[[:space:]]*;#(W._renderers = W._renderers || []).push(render);#' \
    -e '/^[[:space:]]*W\.initData\(\)[[:space:]]*;[[:space:]]*$/d'
  printf '})();</script>\n'
}

# ── Build inlined shared assets (single read each) ───────────────────────

SHARED_CSS=$(cat "$STATIC_DIR/shared.css")
SHARED_JS=$(cat "$STATIC_DIR/shared.js")
FILTER_CSS=$(cat "$STATIC_DIR/filter-bar.css")
FILTER_JS=$(cat "$STATIC_DIR/filter-bar.js")
DETAIL_CSS=$(cat "$STATIC_DIR/detail-panel.css")
DETAIL_JS=$(cat "$STATIC_DIR/detail-panel.js")

# ── Build the COWORK_QUERY_CONFIG JSON ───────────────────────────────────

if [ -n "$TEAM_ID" ] && [ -n "$TEAM_NAME" ]; then
  TEAM_JSON=$(printf '{"id":"%s","name":"%s"}' "$TEAM_ID" "$TEAM_NAME")
else
  TEAM_JSON="null"
fi

# ── Emit the bundle ──────────────────────────────────────────────────────

OUT=$(mktemp)
trap 'rm -f "$OUT"' EXIT

{
  cat <<'HTML_HEAD'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Waggle — Tasks Dashboard</title>
  <style>
HTML_HEAD

  # Shared CSS (always first)
  printf '/* shared.css */\n'
  printf '%s\n' "$SHARED_CSS"
  printf '/* filter-bar.css */\n'
  printf '%s\n' "$FILTER_CSS"
  printf '/* detail-panel.css */\n'
  printf '%s\n' "$DETAIL_CSS"

  # Per-view styles, scoped to data-view-pane
  for v in "${VIEWS[@]}"; do
    printf '/* per-view CSS: %s (scoped) */\n' "$v"
    extract_view_style "$STATIC_DIR/${v}.html" | scope_view_style "$v"
  done

  # Tab strip + view-pane visibility
  cat <<'TAB_CSS'

/* Cowork tab strip (added by generate-cowork-artifact.sh) */
.tab-strip { display: flex; gap: 4px; padding: 0 24px; border-bottom: 0.5px solid var(--separator); background: var(--surface-primary); }
.tab-strip button { background: none; border: none; padding: 10px 14px; font-size: 13px; color: var(--label-secondary); cursor: pointer; border-bottom: 2px solid transparent; }
.tab-strip button:hover { color: var(--label-primary); }
.tab-strip button.active { color: var(--label-primary); border-bottom-color: var(--accent-blue, #4f8df0); font-weight: 600; }
[data-view-pane][hidden] { display: none !important; }
.cowork-banner { padding: 8px 24px; font-size: 12px; color: var(--label-secondary); background: var(--surface-secondary); border-bottom: 0.5px solid var(--separator); }
TAB_CSS

  printf '  </style>\n'
  printf '</head>\n'
  printf '<body>\n'

  # ── Shared header ──
  cat <<'HEADER_HTML'
<header>
  <div class="header-title-group">
    <h1>Tasks</h1>
    <div class="header-meta">
      <div class="sse-indicator">
        <span class="sse-dot disconnected" id="sse-dot"></span>
        <span id="sse-status">Connecting...</span>
      </div>
      <div class="header-stats">
        <span class="task-count" id="task-count"></span>
        <span id="updated-at"></span>
      </div>
      <button class="refresh-btn" id="refresh-btn" onclick="Waggle.refreshTasks()" title="Refresh"><span class="refresh-icon">&#x21BB;</span></button>
    </div>
  </div>
</header>

<nav class="tab-strip" id="waggle-tabs" role="tablist">
  <button type="button" data-tab="kanban" role="tab" aria-selected="true">Kanban</button>
  <button type="button" data-tab="list" role="tab">List</button>
  <button type="button" data-tab="calendar" role="tab">Calendar</button>
  <button type="button" data-tab="gantt" role="tab">Gantt</button>
</nav>

<div id="cowork-status-banner" class="cowork-banner" hidden></div>

<div id="filter-bar"></div>
HEADER_HTML

  # ── View panes ──
  for v in "${VIEWS[@]}"; do
    printf '<section data-view-pane="%s" hidden>\n' "$v"
    extract_view_body "$STATIC_DIR/${v}.html"
    printf '</section>\n'
  done

  # ── Shared toast ──
  printf '<div class="toast" id="toast"></div>\n'

  # ── Inline shared JS ──
  printf '<script>\n/* shared.js */\n'
  printf '%s\n' "$SHARED_JS"
  printf '</script>\n'
  printf '<script>\n/* filter-bar.js */\n'
  printf '%s\n' "$FILTER_JS"
  printf '</script>\n'
  printf '<script>\n/* detail-panel.js */\n'
  printf '%s\n' "$DETAIL_JS"
  printf '</script>\n'

  # ── Cowork query config + adapter ──
  cat <<COWORK_CONFIG
<script>
window.__COWORK_QUERY_CONFIG__ = {
  databaseId: "${DB_ID}",
  currentTeam: ${TEAM_JSON}
};
</script>
COWORK_CONFIG

  cat <<'COWORK_ADAPTER'
<script>
/* Cowork live-fetch adapter (injected by generate-cowork-artifact.sh) */
(function () {
  'use strict';

  var COLD_START_TIMEOUT_MS = 3000;
  var COLD_START_POLL_INTERVAL_MS = 50;
  var PAGE_SIZE = 100;
  var MAX_ROWS = 1000;

  function setBanner(msg, kind) {
    var el = document.getElementById('cowork-status-banner');
    if (!el) return;
    if (!msg) { el.hidden = true; el.textContent = ''; return; }
    el.hidden = false;
    el.textContent = msg;
    el.dataset.kind = kind || 'info';
  }

  function setStatus(text, live) {
    var status = document.getElementById('sse-status');
    var dot = document.getElementById('sse-dot');
    if (status) status.textContent = text;
    if (dot) {
      if (live) dot.classList.remove('disconnected');
      else dot.classList.add('disconnected');
    }
  }

  function waitForCowork() {
    return new Promise(function (resolve, reject) {
      var start = Date.now();
      (function poll() {
        if (window.cowork && typeof window.cowork.callMcpTool === 'function') {
          resolve();
        } else if (Date.now() - start > COLD_START_TIMEOUT_MS) {
          reject(new Error('Cowork runtime unavailable (timed out after ' + COLD_START_TIMEOUT_MS + 'ms). Reload the panel, or call any Notion MCP tool from the Cowork chat once before reopening this artifact.'));
        } else {
          setTimeout(poll, COLD_START_POLL_INTERVAL_MS);
        }
      })();
    });
  }

  // Defensive unwrap — callMcpTool returns one of several shapes.
  function extractJson(maybe) {
    var v = maybe;
    if (v && typeof v === 'object' && Array.isArray(v.content)) {
      var textPart = v.content.find(function (c) { return c && c.type === 'text' && typeof c.text === 'string'; });
      if (textPart) v = textPart.text;
    }
    if (typeof v === 'string' && (v.indexOf('Tool call failed') === 0 || v.indexOf('Error:') === 0)) {
      throw new Error(v);
    }
    if (v && typeof v === 'object' && (v.results || v.object === 'list')) return v;
    if (typeof v !== 'string') v = JSON.stringify(v);
    var first = v.indexOf('{');
    var last = v.lastIndexOf('}');
    if (first < 0 || last <= first) throw new Error('No JSON span in MCP response: ' + v.slice(0, 200));
    return JSON.parse(v.substring(first, last + 1));
  }

  function rtText(rt) {
    if (!Array.isArray(rt)) return '';
    return rt.map(function (x) { return x.plain_text || ''; }).join('');
  }

  function parseNotionPageToTask(p) {
    var props = p.properties || {};
    var pick = function (k) { return props[k] || {}; };
    return {
      id: p.id,
      url: p.url || null,
      title: ((pick('Title').title) || []).map(function (x) { return x.plain_text || ''; }).join(''),
      description: rtText(pick('Description').rich_text).slice(0, 400),
      acceptanceCriteria: rtText(pick('Acceptance Criteria').rich_text).slice(0, 200),
      status: (pick('Status').select && pick('Status').select.name) || 'Backlog',
      blockedBy: (pick('Blocked By').relation || []).map(function (r) { return r.id; }),
      priority: (pick('Priority').select && pick('Priority').select.name) || null,
      executor: (pick('Executor').select && pick('Executor').select.name) || null,
      requiresReview: pick('Requires Review').checkbox === true,
      executionPlan: rtText(pick('Execution Plan').rich_text).slice(0, 200),
      workingDirectory: rtText(pick('Working Directory').rich_text),
      sessionReference: rtText(pick('Session Reference').rich_text),
      dispatchedAt: (pick('Dispatched At').date && pick('Dispatched At').date.start) || null,
      agentOutput: rtText(pick('Agent Output').rich_text).slice(0, 200),
      errorMessage: rtText(pick('Error Message').rich_text),
      context: '',
      artifacts: '',
      repository: pick('Repository').url || null,
      dueDate: (pick('Due Date').date && pick('Due Date').date.start) || null,
      tags: (pick('Tags').multi_select || []).map(function (t) { return t.name; }),
      parentTaskId: ((pick('Parent Task').relation || [])[0] || {}).id || null,
      project: null,
      team: null,
      assignee: (pick('Assignee').people || []).map(function (u) { return { id: u.id, name: u.name || '' }; }),
      acknowledgedAt: (pick('Acknowledged At').date && pick('Acknowledged At').date.start) || null,
      createdAt: pick('Created At').created_time || p.created_time || null
    };
  }

  async function paginatedQuery(databaseId) {
    var rows = [];
    var cursor;
    var truncated = false;
    var loops = 0;
    while (true) {
      loops++;
      if (loops > 20) break;
      var args = { database_id: databaseId, page_size: PAGE_SIZE };
      if (cursor) args.start_cursor = cursor;
      var res = await window.cowork.callMcpTool('mcp__Notion_Extension_for_Waggle__notion-query', args);
      var data = extractJson(res);
      var results = data.results || [];
      for (var i = 0; i < results.length && rows.length < MAX_ROWS; i++) rows.push(results[i]);
      if (rows.length >= MAX_ROWS) { truncated = true; break; }
      if (!data.has_more) break;
      cursor = data.next_cursor;
      if (!cursor) break;
    }
    return { rows: rows, truncated: truncated };
  }

  async function coworkFetch() {
    setStatus('Loading…', false);
    setBanner('');
    try {
      await waitForCowork();
    } catch (e) {
      setStatus('Error', false);
      setBanner(e.message || String(e), 'error');
      return;
    }
    var cfg = window.__COWORK_QUERY_CONFIG__ || {};
    if (!cfg.databaseId) {
      setStatus('Error', false);
      setBanner('Missing tasksDatabaseId — regenerate the artifact via /viewing-tasks.', 'error');
      return;
    }
    try {
      var out = await paginatedQuery(cfg.databaseId);
      var tasks = out.rows.map(parseNotionPageToTask);
      if (window.Waggle && typeof window.Waggle.updateData === 'function') {
        window.Waggle.updateData({ tasks: tasks, updatedAt: new Date().toISOString(), currentTeam: cfg.currentTeam || null });
      }
      setStatus('Live (Cowork)', true);
      if (out.truncated) setBanner('Showing first ' + MAX_ROWS + ' tasks (workspace exceeds cap).', 'warn');
    } catch (e) {
      setStatus('Error', false);
      setBanner('Failed to load tasks: ' + (e.message || String(e)), 'error');
    }
  }

  window.__coworkFetch = coworkFetch;
})();
</script>
COWORK_ADAPTER

  # ── Tab switcher + visibility controller ──
  cat <<'TAB_JS'
<script>
(function () {
  'use strict';
  var STORAGE_KEY = 'waggle-tasks-active-tab-v1';
  var DEFAULT_TAB = 'kanban';
  var VIEWS = ['kanban', 'list', 'calendar', 'gantt'];

  function readTab() {
    try {
      var v = window.localStorage.getItem(STORAGE_KEY);
      if (v && VIEWS.indexOf(v) !== -1) return v;
    } catch (e) {}
    return DEFAULT_TAB;
  }

  function writeTab(v) {
    try { window.localStorage.setItem(STORAGE_KEY, v); } catch (e) {}
  }

  function showTab(v) {
    var panes = document.querySelectorAll('[data-view-pane]');
    for (var i = 0; i < panes.length; i++) {
      panes[i].hidden = (panes[i].getAttribute('data-view-pane') !== v);
    }
    var btns = document.querySelectorAll('#waggle-tabs button');
    for (var j = 0; j < btns.length; j++) {
      var on = btns[j].getAttribute('data-tab') === v;
      btns[j].classList.toggle('active', on);
      btns[j].setAttribute('aria-selected', on ? 'true' : 'false');
    }
  }

  document.addEventListener('click', function (e) {
    var btn = e.target.closest && e.target.closest('#waggle-tabs button[data-tab]');
    if (!btn) return;
    var v = btn.getAttribute('data-tab');
    writeTab(v);
    showTab(v);
  });

  // Initial tab restore — must run before W.initData() so renderers paint into
  // the visible pane on first paint.
  showTab(readTab());
})();
</script>
TAB_JS

  # ── Per-view IIFE-wrapped scripts ──
  for v in "${VIEWS[@]}"; do
    extract_view_inline_script "$STATIC_DIR/${v}.html" | wrap_view_script "$v"
  done

  # ── Trailing global init ──
  cat <<'TRAILER'
<script>
(function () {
  if (window.Waggle && typeof window.Waggle.initData === 'function') {
    window.Waggle.initData();
  }
})();
</script>
</body>
</html>
TRAILER
} > "$OUT"

# ── Self-test ─────────────────────────────────────────────────────────────

iife_count=$(grep -c '^<script>(function ()' "$OUT" || true)
if [ "$iife_count" -lt 4 ]; then
  echo "Self-test FAILED: expected >=4 IIFE-wrapped view scripts, got $iife_count" >&2
  exit 1
fi

preamble_count=$(grep -c 'var W = window.Waggle = window.Waggle || {};' "$OUT" || true)
if [ "$preamble_count" -lt 4 ]; then
  echo "Self-test FAILED: expected >=4 defensive preambles, got $preamble_count" >&2
  exit 1
fi

# Every view contributes exactly one `function render(` to the bundle. With 4
# IIFE openings + 4 defensive preambles in place above, having exactly 4
# `function render(` declarations proves each render is paired with one IIFE.
# A higher count would mean a view inlined helpers named `render`; a lower
# count means a view's script was lost during bundling.
render_count=$(grep -cE 'function render[[:space:]]*\(' "$OUT" || true)
if [ "$render_count" -ne 4 ]; then
  echo "Self-test FAILED: expected exactly 4 'function render(' declarations, got $render_count" >&2
  exit 1
fi

# Every per-view W.onDataUpdate=render must be rewritten to the multiplex push.
# If sed missed one, that view's renderer wouldn't subscribe.
if grep -q 'W\.onDataUpdate = render' "$OUT"; then
  echo "Self-test FAILED: leftover 'W.onDataUpdate = render' — multiplex rewrite incomplete" >&2
  exit 1
fi

push_count=$(grep -c '(W._renderers = W._renderers || \[\]).push(render);' "$OUT" || true)
if [ "$push_count" -lt 4 ]; then
  echo "Self-test FAILED: expected >=4 multiplex push calls, got $push_count" >&2
  exit 1
fi

if ! head -3 "$OUT" | grep -qi '<!doctype html>'; then
  echo "Self-test FAILED: output missing <!DOCTYPE html>" >&2
  exit 1
fi

if ! grep -qi '<meta charset="utf-8">' "$OUT"; then
  echo "Self-test FAILED: output missing <meta charset=\"UTF-8\">" >&2
  exit 1
fi

cat "$OUT"
