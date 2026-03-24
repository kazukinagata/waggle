import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdirSync, writeFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import app from "./app.js";
import type { Task, TasksResponse } from "./types.js";

// Minimal valid Task with all Core fields
function makeTask(overrides: Partial<Task> = {}): Task {
  return {
    id: "task-1",
    title: "Test Task",
    description: "desc",
    acceptanceCriteria: "criteria",
    status: "Ready",
    blockedBy: [],
    priority: "Medium",
    executor: "cli",
    requiresReview: true,
    executionPlan: "step 1, step 2",
    workingDirectory: "/home/user/project",
    sessionReference: "",
    dispatchedAt: null,
    agentOutput: "",
    errorMessage: "",
    context: "",
    artifacts: "",
    repository: null,
    dueDate: null,
    tags: [],
    parentTaskId: null,
    project: null,
    team: null,
    assignees: [],
    url: "https://notion.so/task-1",
    ...overrides,
  };
}

describe("GET /api/health", () => {
  it("returns ok status", async () => {
    const res = await app.request("/api/health");
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.status).toBe("ok");
    expect(body.timestamp).toBeDefined();
  });
});

describe("GET /api/tasks (no data)", () => {
  it("returns empty tasks array before any data is posted", async () => {
    const res = await app.request("/api/tasks");
    expect(res.status).toBe(200);
    const body = await res.json() as TasksResponse;
    expect(body.tasks).toEqual([]);
    expect(body.updatedAt).toBeDefined();
  });
});

describe("POST /api/data and GET /api/tasks", () => {
  it("stores and returns posted task data", async () => {
    const task = makeTask();
    const payload: TasksResponse = {
      tasks: [task],
      updatedAt: "2026-03-05T00:00:00.000Z",
    };

    const postRes = await app.request("/api/data", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    expect(postRes.status).toBe(200);

    const getRes = await app.request("/api/tasks");
    const body = await getRes.json() as TasksResponse;
    expect(body.tasks).toHaveLength(1);
    expect(body.tasks[0].id).toBe("task-1");
  });

  it("preserves all Core fields through the data pipeline", async () => {
    const task = makeTask({
      executor: "claude-desktop",
      requiresReview: false,
      executionPlan: "Build the feature",
      workingDirectory: "packages/api",
      sessionReference: "scheduled-task-42",
      dispatchedAt: "2026-03-05T10:00:00.000Z",
      errorMessage: "",
    });
    const payload: TasksResponse = { tasks: [task], updatedAt: "2026-03-05T10:00:00.000Z" };

    await app.request("/api/data", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });

    const getRes = await app.request("/api/tasks");
    const body = await getRes.json() as TasksResponse;
    const returned = body.tasks[0];

    expect(returned.executor).toBe("claude-desktop");
    expect(returned.requiresReview).toBe(false);
    expect(returned.executionPlan).toBe("Build the feature");
    expect(returned.workingDirectory).toBe("packages/api");
    expect(returned.sessionReference).toBe("scheduled-task-42");
    expect(returned.dispatchedAt).toBe("2026-03-05T10:00:00.000Z");
  });

  it("preserves Blocked status and errorMessage", async () => {
    const task = makeTask({
      status: "Blocked",
      errorMessage: "tsc failed: cannot find module './foo'",
      agentOutput: "",
    });
    const payload: TasksResponse = { tasks: [task], updatedAt: "2026-03-05T10:00:00.000Z" };

    await app.request("/api/data", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });

    const getRes = await app.request("/api/tasks");
    const body = await getRes.json() as TasksResponse;
    const returned = body.tasks[0];

    expect(returned.status).toBe("Blocked");
    expect(returned.errorMessage).toBe("tsc failed: cannot find module './foo'");
    // Error info must NOT bleed into agentOutput
    expect(returned.agentOutput).toBe("");
  });

  it("stores multiple tasks preserving per-task executor types", async () => {
    const tasks: Task[] = [
      makeTask({ id: "t1", executor: "cli", requiresReview: true }),
      makeTask({ id: "t2", executor: "human", requiresReview: false }),
      makeTask({ id: "t3", executor: "claude-desktop", requiresReview: true }),
      makeTask({ id: "t4", executor: "cowork", requiresReview: true }),
    ];
    const payload: TasksResponse = { tasks, updatedAt: "2026-03-05T12:00:00.000Z" };

    await app.request("/api/data", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });

    const getRes = await app.request("/api/tasks");
    const body = await getRes.json() as TasksResponse;

    expect(body.tasks).toHaveLength(4);
    const byId = Object.fromEntries(body.tasks.map((t) => [t.id, t]));
    expect(byId["t1"].executor).toBe("cli");
    expect(byId["t2"].executor).toBe("human");
    expect(byId["t3"].executor).toBe("claude-desktop");
    expect(byId["t4"].executor).toBe("cowork");
    expect(byId["t2"].requiresReview).toBe(false);
  });

  it("overwrites cached data on second POST", async () => {
    const first: TasksResponse = { tasks: [makeTask({ id: "old" })], updatedAt: "2026-03-05T00:00:00.000Z" };
    const second: TasksResponse = { tasks: [makeTask({ id: "new" })], updatedAt: "2026-03-05T01:00:00.000Z" };

    await app.request("/api/data", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(first),
    });
    await app.request("/api/data", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(second),
    });

    const getRes = await app.request("/api/tasks");
    const body = await getRes.json() as TasksResponse;
    expect(body.tasks).toHaveLength(1);
    expect(body.tasks[0].id).toBe("new");
  });
});

describe("Custom views", () => {
  const testDir = join(tmpdir(), `waggle-test-${Date.now()}`);

  beforeEach(() => {
    process.env.CUSTOM_VIEWS_DIR = testDir;
  });

  afterEach(() => {
    delete process.env.CUSTOM_VIEWS_DIR;
    try {
      rmSync(testDir, { recursive: true, force: true });
    } catch {
      // ignore
    }
  });

  describe("GET /api/views", () => {
    it("returns empty array when custom views dir does not exist", async () => {
      const res = await app.request("/api/views");
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.views).toEqual([]);
    });

    it("returns views with parsed metadata", async () => {
      mkdirSync(testDir, { recursive: true });
      writeFileSync(
        join(testDir, "my-dashboard.html"),
        '<html><head><meta name="view-name" content="My Dashboard"><meta name="view-description" content="A test dashboard"></head><body>test</body></html>',
      );

      const res = await app.request("/api/views");
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.views).toHaveLength(1);
      expect(body.views[0]).toEqual({
        slug: "my-dashboard",
        name: "My Dashboard",
        description: "A test dashboard",
        filename: "my-dashboard.html",
      });
    });
  });

  describe("GET /custom/:filename", () => {
    it("returns 404 for nonexistent file", async () => {
      mkdirSync(testDir, { recursive: true });
      const res = await app.request("/custom/nonexistent.html");
      expect(res.status).toBe(404);
    });

    it("blocks path traversal attempts", async () => {
      const res = await app.request("/custom/..%2F..%2Fetc%2Fpasswd");
      expect(res.status).toBe(404);
    });

    it("rejects non-html files", async () => {
      const res = await app.request("/custom/script.js");
      expect(res.status).toBe(404);
    });

    it("serves existing custom view HTML", async () => {
      mkdirSync(testDir, { recursive: true });
      writeFileSync(join(testDir, "test.html"), "<html><body>Hello</body></html>");

      const res = await app.request("/custom/test.html");
      expect(res.status).toBe(200);
      const body = await res.text();
      expect(body).toContain("Hello");
    });
  });
});
