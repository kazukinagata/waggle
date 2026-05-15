#!/usr/bin/env bash
# generate-cowork-custom-artifact.sh
#
# Wraps a single user-authored custom view HTML (~/.waggle/views/<slug>.html)
# into a Cowork-ready artifact by replacing the `<!-- COWORK_BOOT -->` marker
# with the live-fetch adapter (window.__COWORK_QUERY_CONFIG__ +
# window.__coworkFetch). Single-renderer — no IIFE bundling like the
# multi-view dashboard generator, because each custom view ships as its own
# standalone artifact with its own render() in its own scope.
#
# Usage:
#   generate-cowork-custom-artifact.sh <slug> <tasksDatabaseId> [team_id] [team_name] [assignee_user_id]
#
# Output: writes the standalone HTML to stdout.
#
# When [assignee_user_id] is provided, the bundle's runtime fetch is scoped
# server-side to that assignee (people.contains). Status is always restricted
# to non-terminal — Done and Cancelled are excluded by a fixed select clause.
# When [assignee_user_id] is empty, the Assignee predicate is omitted (degraded
# unscoped mode); the status exclusion still applies.
#
# A second Cowork artifact generator (owned by a different skill) carries an
# independent copy of the cowork adapter. Per the project's skill-independence
# rule, scripts owned by one skill cannot source files from another skill's
# directory, so the adapter is duplicated by design. Keep the adapter
# logically in sync manually when changes are needed across generators.

set -euo pipefail

USAGE="Usage: generate-cowork-custom-artifact.sh <slug> <tasksDatabaseId> [team_id] [team_name] [assignee_user_id]"
SLUG="${1:?$USAGE}"
DB_ID="${2:?$USAGE}"
TEAM_ID="${3:-}"
TEAM_NAME="${4:-}"
ASSIGNEE_USER_ID="${5:-}"

# Slug must be filesystem-safe AND artifact-id-safe (kebab-case lowercase).
# Reject anything that could escape the path or produce a confusing artifact
# id. SKILL.md asks the agent to derive slugs this way, but enforce it here
# too in case callers come from another path.
if ! printf '%s' "$SLUG" | grep -qE '^[a-z0-9][a-z0-9-]{0,63}$'; then
  echo "Error: slug '$SLUG' must match ^[a-z0-9][a-z0-9-]{0,63}$ (kebab-case, lowercase, alphanum/dash)." >&2
  exit 1
fi

TEMPLATE="$HOME/.waggle/views/${SLUG}.html"

if [ ! -f "$TEMPLATE" ]; then
  echo "Error: custom view template not found: $TEMPLATE" >&2
  exit 1
fi

if ! head -3 "$TEMPLATE" | grep -qi '<!doctype html>'; then
  echo "Error: $TEMPLATE missing <!DOCTYPE html> (mojibake guard)" >&2
  exit 1
fi
if ! grep -qi '<meta charset="utf-8">' "$TEMPLATE"; then
  echo "Error: $TEMPLATE missing <meta charset=\"UTF-8\"> (mojibake guard)" >&2
  exit 1
fi
if ! grep -q '<!-- COWORK_BOOT -->' "$TEMPLATE"; then
  echo "Error: $TEMPLATE missing <!-- COWORK_BOOT --> marker. The marker must" >&2
  echo "       appear inside <head> for the live-fetch adapter to be injected." >&2
  echo "       See the Reference Template in skills/managing-views/SKILL.md." >&2
  exit 1
fi

# Build the COWORK_BOOT replacement into a tempfile so the python substitution
# step can swap it into the template. The config line is emitted by Python
# below to avoid relying on bash heredoc expansion semantics (which would do
# one pass over the JSON value, surviving today but brittle if a maintainer
# adds a literal `$X` or backtick to the heredoc body in the future).
BOOT_FILE=$(mktemp)
trap 'rm -f "$BOOT_FILE"' EXIT

# Emit the config block from Python (writes to BOOT_FILE).
python3 -c '
import json, sys
db = sys.argv[1]
team_id = sys.argv[2] or ""
team_name = sys.argv[3] or ""
assignee_user_id = sys.argv[4] or ""
team = {"id": team_id, "name": team_name} if (team_id and team_name) else None
cfg = {
    "databaseId": db,
    "currentTeam": team,
    "assigneeUserId": assignee_user_id or None,
}
with open(sys.argv[5], "w", encoding="utf-8") as f:
    f.write("<script>\n")
    f.write("window.__COWORK_QUERY_CONFIG__ = " + json.dumps(cfg, ensure_ascii=False) + ";\n")
    f.write("</script>\n")
' "$DB_ID" "$TEAM_ID" "$TEAM_NAME" "$ASSIGNEE_USER_ID" "$BOOT_FILE"

# Append the adapter script with a quoted heredoc so nothing in the body is
# bash-interpolated.
cat >> "$BOOT_FILE" <<'COWORK_BOOT'
<script>
/* Cowork live-fetch adapter (custom view) */
(function () {
  'use strict';
  var COLD_START_TIMEOUT_MS = 3000;
  var COLD_START_POLL_INTERVAL_MS = 50;
  var PAGE_SIZE = 100;
  var MAX_ROWS = 1000;

  function waitForCowork() {
    return new Promise(function (resolve, reject) {
      var start = Date.now();
      (function poll() {
        if (window.cowork && typeof window.cowork.callMcpTool === 'function') {
          resolve();
        } else if (Date.now() - start > COLD_START_TIMEOUT_MS) {
          reject(new Error('Cowork runtime unavailable (timed out). Reload the panel, or call any Notion MCP tool from chat once before reopening.'));
        } else {
          setTimeout(poll, COLD_START_POLL_INTERVAL_MS);
        }
      })();
    });
  }

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
      description: rtText(pick('Description').rich_text),
      acceptanceCriteria: rtText(pick('Acceptance Criteria').rich_text),
      status: (pick('Status').select && pick('Status').select.name) || 'Backlog',
      blockedBy: (pick('Blocked By').relation || []).map(function (r) { return r.id; }),
      priority: (pick('Priority').select && pick('Priority').select.name) || null,
      executor: (pick('Executor').select && pick('Executor').select.name) || null,
      requiresReview: pick('Requires Review').checkbox === true,
      executionPlan: rtText(pick('Execution Plan').rich_text),
      workingDirectory: rtText(pick('Working Directory').rich_text),
      sessionReference: rtText(pick('Session Reference').rich_text),
      dispatchedAt: (pick('Dispatched At').date && pick('Dispatched At').date.start) || null,
      agentOutput: rtText(pick('Agent Output').rich_text),
      errorMessage: rtText(pick('Error Message').rich_text),
      context: rtText(pick('Context').rich_text),
      artifacts: rtText(pick('Artifacts').rich_text),
      repository: pick('Repository').url || null,
      dueDate: (pick('Due Date').date && pick('Due Date').date.start) || null,
      tags: (pick('Tags').multi_select || []).map(function (t) { return t.name; }),
      parentTaskId: ((pick('Parent Task').relation || [])[0] || {}).id || null,
      project: (pick('Project').select && pick('Project').select.name) || null,
      team: (pick('Team').select && pick('Team').select.name) || null,
      assignee: (pick('Assignee').people || []).map(function (u) { return { id: u.id, name: u.name || '' }; }),
      acknowledgedAt: (pick('Acknowledged At').date && pick('Acknowledged At').date.start) || null,
      createdAt: pick('Created At').created_time || p.created_time || null
    };
  }

  // Build the Notion filter object. Status is always restricted to
  // non-terminal (Done / Cancelled excluded). When assigneeUserId is set,
  // narrow further to "Assignee contains <id>". Empty assigneeUserId =
  // degraded unscoped mode (status-only) so the view still renders.
  function buildFilter(assigneeUserId) {
    var clauses = [
      { property: 'Status', select: { does_not_equal: 'Done' } },
      { property: 'Status', select: { does_not_equal: 'Cancelled' } }
    ];
    if (assigneeUserId) {
      clauses.unshift({ property: 'Assignee', people: { contains: assigneeUserId } });
    }
    return { and: clauses };
  }

  async function paginatedQuery(databaseId, assigneeUserId) {
    var filter = buildFilter(assigneeUserId);
    var rows = [];
    var cursor;
    var truncated = false;
    var loops = 0;
    while (true) {
      loops++;
      if (loops > 20) break;
      var args = { database_id: databaseId, page_size: PAGE_SIZE, filter: filter };
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
    try {
      await waitForCowork();
    } catch (e) {
      console.error('[waggle-view] cowork runtime unavailable:', e);
      window.__coworkLastError = e;
      return { tasks: [], updatedAt: new Date().toISOString(), error: e.message || String(e) };
    }
    var cfg = window.__COWORK_QUERY_CONFIG__ || {};
    if (!cfg.databaseId) {
      var err = new Error('Missing tasksDatabaseId — regenerate via /managing-views.');
      window.__coworkLastError = err;
      return { tasks: [], updatedAt: new Date().toISOString(), error: err.message };
    }
    try {
      var out = await paginatedQuery(cfg.databaseId, cfg.assigneeUserId);
      var tasks = out.rows.map(parseNotionPageToTask);
      return {
        tasks: tasks,
        updatedAt: new Date().toISOString(),
        currentTeam: cfg.currentTeam || null,
        assigneeUserId: cfg.assigneeUserId || null,
        truncated: out.truncated
      };
    } catch (e) {
      console.error('[waggle-view] fetch failed:', e);
      window.__coworkLastError = e;
      return { tasks: [], updatedAt: new Date().toISOString(), error: e.message || String(e) };
    }
  }

  // Custom views call window.__coworkFetch() themselves and use the returned
  // { tasks, updatedAt } to populate their own state. Unlike the bundled
  // dashboard, there is no shared.js / W.updateData here — the custom view
  // template owns its data plumbing.
  window.__coworkFetch = coworkFetch;
})();
</script>
COWORK_BOOT

# Filter wiring self-tests — mirror the checks in generate-cowork-artifact.sh.
# The boot block is fully assembled at this point (config via Python + adapter
# via heredoc), so validating it directly catches future edits to either half
# that silently drop the filter. The top-of-file note ("keep the adapter
# logically in sync manually") is a developer convention; these machine checks
# are the safety net.
if ! grep -q '"assigneeUserId"' "$BOOT_FILE"; then
  echo "Self-test FAILED: BOOT_FILE missing assigneeUserId key" >&2
  exit 1
fi

if ! grep -q "does_not_equal: 'Done'" "$BOOT_FILE"; then
  echo "Self-test FAILED: Status != Done clause missing from buildFilter" >&2
  exit 1
fi

if ! grep -q "does_not_equal: 'Cancelled'" "$BOOT_FILE"; then
  echo "Self-test FAILED: Status != Cancelled clause missing from buildFilter" >&2
  exit 1
fi

# Substitute the COWORK_BOOT marker with the generated block.
# Read the boot block into a python variable (via env) for safe substitution —
# sed can't easily handle multi-line replacements with shell special chars.
BOOT_CONTENT=$(cat "$BOOT_FILE")
export BOOT_CONTENT
python3 -c '
import os, sys
template = open(sys.argv[1], "r", encoding="utf-8").read()
boot = os.environ["BOOT_CONTENT"]
if "<!-- COWORK_BOOT -->" not in template:
    sys.stderr.write("Error: marker missing at substitution time\n")
    sys.exit(1)
out = template.replace("<!-- COWORK_BOOT -->", boot, 1)
sys.stdout.write(out)
' "$TEMPLATE"
