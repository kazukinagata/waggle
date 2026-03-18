import { readFileSync, readdirSync, existsSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import { Hono } from "hono";
import { cors } from "hono/cors";
import { streamSSE } from "hono/streaming";
import { serveStatic } from "@hono/node-server/serve-static";
import { EventBus } from "./sse.js";
import type { TasksResponse, SprintsResponse } from "./types.js";

function getCustomViewsDir(): string {
  return process.env.CUSTOM_VIEWS_DIR || join(homedir(), ".agentic-tasks", "views");
}

const eventBus = new EventBus();
const sprintEventBus = new EventBus();
let sseId = 0;
let cachedData: TasksResponse | null = null;
let cachedSprintData: SprintsResponse | null = null;

const app = new Hono();

app.use("*", cors());

app.get("/api/health", (c) => {
  return c.json({ status: "ok", timestamp: new Date().toISOString() });
});

app.get("/api/tasks", (c) => {
  if (!cachedData) {
    return c.json({ tasks: [], updatedAt: new Date().toISOString() });
  }
  return c.json(cachedData);
});

app.post("/api/data", async (c) => {
  const data = await c.req.json<TasksResponse>();
  cachedData = data;
  eventBus.emit(JSON.stringify(data));
  return c.json({ status: "ok" });
});

app.get("/api/sprint", (c) => {
  if (!cachedSprintData) {
    return c.json({ sprints: [], currentSprintId: null, updatedAt: new Date().toISOString() });
  }
  return c.json(cachedSprintData);
});

app.post("/api/sprint-data", async (c) => {
  const data = await c.req.json<SprintsResponse>();
  cachedSprintData = data;
  sprintEventBus.emit(JSON.stringify(data));
  return c.json({ status: "ok" });
});

app.get("/api/events", async (c) => {
  return streamSSE(c, async (stream) => {
    let running = true;

    stream.onAbort(() => {
      running = false;
    });

    // Send initial connection event
    await stream.writeSSE({
      data: JSON.stringify({ type: "connected" }),
      event: "connected",
      id: String(sseId++),
    });

    // Subscribe to refresh events
    const unsubscribe = eventBus.subscribe(async (data) => {
      if (!running) return;
      try {
        await stream.writeSSE({
          data,
          event: "refresh",
          id: String(sseId++),
        });
      } catch {
        running = false;
      }
    });

    // Keep connection alive with heartbeat
    while (running) {
      await stream.sleep(15000);
      if (!running) break;
      try {
        await stream.writeSSE({
          data: "",
          event: "heartbeat",
          id: String(sseId++),
        });
      } catch {
        running = false;
      }
    }

    unsubscribe();
  });
});

// Custom views API
app.get("/api/views", (c) => {
  const dir = getCustomViewsDir();
  if (!existsSync(dir)) {
    return c.json({ views: [] });
  }
  const files = readdirSync(dir).filter((f) => f.endsWith(".html"));
  const views = files.map((filename) => {
    const slug = filename.replace(/\.html$/, "");
    let name = slug;
    let description = "";
    try {
      const content = readFileSync(join(dir, filename), "utf-8");
      const nameMatch = content.match(/<meta\s+name="view-name"\s+content="([^"]*)"/);
      const descMatch = content.match(/<meta\s+name="view-description"\s+content="([^"]*)"/);
      if (nameMatch) name = nameMatch[1];
      if (descMatch) description = descMatch[1];
    } catch {
      // ignore read errors
    }
    return { slug, name, description, filename };
  });
  return c.json({ views });
});

// Serve custom view HTML files
app.get("/custom/:filename", (c) => {
  const dir = getCustomViewsDir();
  const filename = c.req.param("filename");
  if (!filename.endsWith(".html") || filename.includes("..")) {
    return c.notFound();
  }
  const filepath = join(dir, filename);
  if (!existsSync(filepath)) {
    return c.notFound();
  }
  const content = readFileSync(filepath, "utf-8");
  return c.html(content);
});

// Static files — AFTER API routes
app.get("/", (c) => c.redirect("/selector.html"));
app.use("*", serveStatic({ root: "./static" }));

export default app;
