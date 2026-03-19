# Waggle

An async task coordination protocol for autonomous AI agents.

> Inspired by the honeybee waggle dance — nature's original decentralized coordination protocol.
> A bee returns to the hive and tells others where to work. No central controller needed.

## What is Waggle?

Waggle lets independent AI agents coordinate through a shared task board. Agents discover tasks, claim them, execute, and hand off results — all asynchronously, without tight coupling.

Unlike orchestration frameworks that run agents in the same process, Waggle agents are fully independent. They can be on different machines, run at different times, and use different backends. The only thing they share is the task board.

## How it differs

| | Waggle | CrewAI / Swarms | A2A (Google) |
|---|---|---|---|
| **Coupling** | Loosely coupled, async | Same process, tight | Transport layer |
| **Task semantics** | Full lifecycle — 14 fields, state machine, stall detection | Framework-specific | None |
| **Backend** | Any (Notion, SQLite, Turso...) | In-memory | N/A |
| **Agents** | Independent processes | Managed by orchestrator | Peer-to-peer |

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

Waggle defines **14 core fields** and a **6-state machine** that any backend can implement. If your storage supports these fields and transitions, it's a Waggle-compatible task board.

```
Backlog → Ready → In Progress → In Review → Done
                       ↓
                    Blocked
```

See [`spec/protocol.md`](spec/protocol.md) for the full specification.

## Providers

| Provider | Use Case | Status |
|---|---|---|
| **SQLite** | Local, instant, zero-setup | Available |
| **Notion** | Team collaboration via Notion workspace | Available |
| **Turso** | Remote SQLite, multi-agent sync | Available |

The provider abstraction means you can add your own backend. Implement the [Provider Interface](spec/protocol.md#provider-interface) and register it.

## Features

- **Natural Language CRUD** — create, update, query, and delete tasks by talking to Claude
- **Real-time Views** — Kanban, List, Calendar, and Gantt views at `http://localhost:3456`
- **Autonomous Execution** — dispatch tasks to parallel tmux sessions or Scheduled Tasks
- **Sprint Management** — objective-based sprints with backlog ordering and velocity tracking
- **Stall Detection** — automatic detection of stuck agents via complexity-aware thresholds
- **Task Delegation** — hand off tasks to other team members
- **Message Intake** — auto-convert Slack/Teams DMs into categorized tasks
- **Daily Routine** — unified message intake + task refinement + dispatch

## Architecture

```
skills/
├── detecting-provider/       # Provider auto-detection
├── resolving-identity/       # User identity resolution
├── looking-up-members/       # Member lookup
├── setting-up-tasks/         # Setup wizard
├── managing-tasks/           # Task CRUD and state transitions
├── executing-tasks/          # Task dispatch (tmux / Scheduled Tasks)
├── delegating-tasks/         # Task reassignment
├── viewing-tasks/            # Local view server (Hono + SSE)
├── managing-sprints/         # Sprint lifecycle
├── managing-views/           # Custom view management
└── providers/
    ├── notion/               # Notion provider
    ├── sqlite/               # SQLite provider
    └── turso/                # Turso provider
spec/
└── protocol.md               # Waggle Protocol v1
agents/
└── task-agent.md             # Agent definition for autonomous execution
```

## License

MIT
