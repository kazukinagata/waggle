import { serve } from "@hono/node-server";
import app from "./app.js";

const PORT = parseInt(process.env.PORT || "3456", 10);

const server = serve({ fetch: app.fetch, port: PORT }, (info) => {
  console.log(`Agentic Tasks view server running on http://localhost:${info.port}`);
});

const shutdown = () => {
  server.close(() => {
    console.log("Server shut down");
    process.exit(0);
  });
};

process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
