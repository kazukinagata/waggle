# Waggle

An async task coordination protocol for autonomous AI agents.

> Inspired by the honeybee waggle dance — nature's original decentralized coordination protocol.
> A bee returns to the hive and tells others where to work. No central controller needed.

## What is Waggle?

Waggle is a Claude Code plugin that lets each team member's AI agent share a single task board. Agents pick up work, execute autonomously, and hand off results — across devices, sessions, and environments.

A human creates a task on their laptop. Another member's agent on Claude Desktop picks it up. A third agent running in Cowork executes it overnight. The board is the only shared state.

## How it differs

AI agents today have several ways to collaborate. Waggle occupies a distinct space:

**Agent Teams** lets multiple Claude instances work together in real time within a single session. When the session ends, the collaboration ends. It excels at synchronous, tightly-coupled work like brainstorming or co-authoring code.

**Agent Memory** tools (Mem0, Claude-Mem, Engram, etc.) persist knowledge and context across sessions. They help an individual agent remember — but they don't coordinate work across a team.

**Waggle** coordinates work across team members and their agents. Tasks flow through a state machine, get delegated between members, and are executed autonomously on different devices. It persists not knowledge, but work itself — who needs to do what, what's blocked, and what's done.

| | Agent Teams | Agent Memory | Waggle |
|---|---|---|---|
| **Purpose** | Real-time collaboration | Cross-session recall | Team task coordination |
| **Scope** | Single session | Single agent | Multiple members and agents |
| **Persistence** | Ephemeral | Knowledge / context | Task lifecycle and state |
| **Coordination** | Synchronous | None | Asynchronous, cross-device |

These are complementary. Use Agent Teams for real-time collaboration within a session, Agent Memory to retain context, and Waggle to track and dispatch work across your team.

## Quick Start

### Prerequisites

- [Claude Code](https://claude.ai/code) CLI or Claude Desktop (v1.0.33+)

### Install

Add the marketplace and install:

```
/plugin marketplace add kazukinagata/waggle
/plugin install waggle@kazukinagata-waggle
```

Or browse interactively — run `/plugin`, go to **Discover**, and select **waggle**.

### Setup

```
/setting-up-tasks
```

Choose your provider:
- **SQLite** — instant local setup, zero external dependencies
- **Notion** — team collaboration via Notion workspace
- **Turso** — remote SQLite for multi-agent sync (requires Turso account)

### Use

```
"add a task to research competitor pricing"
"what's next?"
"execute tasks"
"show kanban"
"delegate API task to Alice"
```

## The Protocol

Waggle defines **15 core fields** and **9 extended fields** with a **6-state machine** that any backend can implement. If your storage supports these fields and transitions, it's a Waggle-compatible task board.

```
Backlog → Ready → In Progress → In Review → Done
                       ↓
                    Blocked
```

See [`skills/waggle-protocol/`](skills/waggle-protocol/) for the full specification.

## Providers

| Provider | Use Case | Status |
|---|---|---|
| **SQLite** | Local, instant, zero-setup | Available |
| **Notion** | Team collaboration via Notion workspace | Available |
| **Turso** | Remote SQLite, multi-agent sync | Available |

The provider abstraction means you can add your own backend. See [`skills/provider-contract/`](skills/provider-contract/) for the interface contract.

## Features

- **Natural Language CRUD** — create, update, query, and delete tasks by talking to Claude
- **Real-time Views** — Kanban, List, Calendar, and Gantt views at `http://localhost:3456`
- **Autonomous Execution** — dispatch tasks to parallel tmux sessions or Scheduled Tasks
- **Task Planning** — generate Acceptance Criteria and Execution Plans with brainstorming agents
- **Task Monitoring** — health checks on stagnation, field quality, blocked tasks, and executor ratio
- **Task Delegation** — hand off tasks to other team members
- **Custom Views** — create user-defined HTML visualizations beyond the built-in views
- **Pre-creation Checklist** — validation gate ensures task quality before creation
- **Message Intake** — auto-convert Slack/Teams/Discord DMs into categorized tasks
- **Daily Routine** — unified message intake + task refinement + dispatch

## Architecture

```
skills/
├── detecting-provider/       # (shared) Provider auto-detection
├── resolving-identity/       # (shared) User identity resolution
├── looking-up-members/       # (shared) Member lookup
├── validating-fields/        # (shared) Field validation for status transitions
├── setting-up-tasks/         # Setup wizard
├── managing-tasks/           # Task CRUD and state transitions
├── executing-tasks/          # Task dispatch (tmux / Scheduled Tasks)
├── viewing-tasks/            # Local view server (Hono + SSE)
├── managing-views/           # Custom view management
├── delegating-tasks/         # Task reassignment
├── ingesting-messages/       # Message-to-task conversion
├── planning-tasks/           # AC / Execution Plan generation
├── monitoring-tasks/         # Task health check and metrics
├── running-daily-tasks/      # Unified daily routine
├── provider-contract/        # Provider plugin development guide
└── waggle-protocol/          # Protocol v1 specification
providers/
├── notion/                   # Notion provider
├── sqlite/                   # SQLite provider
└── turso/                    # Turso provider
agents/
├── task-agent.md             # Autonomous task execution
├── code-planning-agent.md    # Code-level planning brainstorm
└── knowledge-planning-agent.md  # Knowledge-gathering brainstorm
```

## License

MIT
