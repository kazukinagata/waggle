#!/usr/bin/env bash
# Initialize waggle tables in a Turso database.
#
# Environment:
#   TURSO_URL        (required)
#   TURSO_AUTH_TOKEN (required)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

"$SCRIPT_DIR/turso-exec.sh" \
  "CREATE TABLE IF NOT EXISTS tasks (
    id TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
    title TEXT NOT NULL,
    description TEXT DEFAULT '',
    acceptance_criteria TEXT DEFAULT '',
    status TEXT DEFAULT 'Backlog' CHECK(status IN ('Backlog','Ready','In Progress','In Review','Done','Blocked')),
    priority TEXT CHECK(priority IN ('Urgent','High','Medium','Low')),
    executor TEXT CHECK(executor IN ('claude-desktop','cli','cowork','human')),
    requires_review INTEGER DEFAULT 0,
    execution_plan TEXT DEFAULT '',
    working_directory TEXT DEFAULT '',
    session_reference TEXT DEFAULT '',
    dispatched_at TEXT,
    agent_output TEXT DEFAULT '',
    error_message TEXT DEFAULT '',
    context TEXT DEFAULT '',
    artifacts TEXT DEFAULT '',
    repository TEXT,
    due_date TEXT,
    tags TEXT DEFAULT '[]',
    parent_task_id TEXT REFERENCES tasks(id),
    project TEXT,
    team TEXT,
    assignees TEXT DEFAULT '[]',
    issuer TEXT DEFAULT '',
    complexity_score INTEGER,
    backlog_order INTEGER,
    sprint_id TEXT,
    branch TEXT DEFAULT '',
    source_message_id TEXT,
    created_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
  )" \
  "CREATE TABLE IF NOT EXISTS task_dependencies (
    task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    blocked_by_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    PRIMARY KEY (task_id, blocked_by_id)
  )" \
  "CREATE TABLE IF NOT EXISTS teams (
    id TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
    name TEXT NOT NULL,
    members TEXT DEFAULT '[]'
  )" \
  "CREATE TABLE IF NOT EXISTS sprints (
    id TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
    name TEXT NOT NULL,
    goal TEXT DEFAULT '',
    status TEXT DEFAULT 'Planning' CHECK(status IN ('Planning','Active','Completed','Closed')),
    max_concurrent_agents INTEGER DEFAULT 3,
    velocity INTEGER,
    team_id TEXT REFERENCES teams(id),
    created_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
  )" \
  "CREATE TABLE IF NOT EXISTS intake_log (
    message_id TEXT PRIMARY KEY,
    tool_name TEXT CHECK(tool_name IN ('slack','teams','discord')),
    processed_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
  )" \
  "CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status)" \
  "CREATE INDEX IF NOT EXISTS idx_tasks_priority ON tasks(priority)" \
  "CREATE INDEX IF NOT EXISTS idx_tasks_executor ON tasks(executor)" \
  "CREATE INDEX IF NOT EXISTS idx_tasks_sprint ON tasks(sprint_id)" > /dev/null

echo "Turso database initialized."
