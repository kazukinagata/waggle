import { describe, it, expect, beforeEach } from "vitest";

describe("API", () => {
  let app: any;

  beforeEach(async () => {
    const mod = await import("../src/app.js");
    app = mod.default;
  });

  it("GET /api/health returns ok", async () => {
    const res = await app.request("/api/health");
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.status).toBe("ok");
  });

  it("GET /api/tasks returns empty when no data pushed", async () => {
    const res = await app.request("/api/tasks");
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.tasks).toEqual([]);
    expect(body.updatedAt).toBeDefined();
  });

  it("POST /api/data stores data and GET /api/tasks returns it", async () => {
    const payload = {
      tasks: [{ id: "task-1", title: "Test task", status: "Ready", priority: "High" }],
      updatedAt: "2026-03-05T00:00:00Z",
    };

    const postRes = await app.request("/api/data", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    expect(postRes.status).toBe(200);
    const postBody = await postRes.json();
    expect(postBody.status).toBe("ok");

    const getRes = await app.request("/api/tasks");
    expect(getRes.status).toBe(200);
    const getBody = await getRes.json();
    expect(getBody.tasks).toHaveLength(1);
    expect(getBody.tasks[0].title).toBe("Test task");
    expect(getBody.updatedAt).toBe("2026-03-05T00:00:00Z");
  });
});
