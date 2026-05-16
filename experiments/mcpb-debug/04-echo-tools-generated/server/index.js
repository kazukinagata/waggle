#!/usr/bin/env node

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";

const server = new Server(
  { name: "mcpb-debug-echo-tools-generated", version: "0.0.1" },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: "echo_test",
      description: "Echo back the input string.",
      inputSchema: {
        type: "object",
        properties: {
          input: {
            type: "string",
            description: "Text to echo back",
          },
        },
        required: ["input"],
      },
    },
  ],
}));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  if (name !== "echo_test") {
    throw new Error(`Unknown tool: ${name}`);
  }

  return {
    content: [{ type: "text", text: String(args?.input ?? "") }],
  };
});

const transport = new StdioServerTransport();
server.connect(transport);

console.error("mcpb-debug-echo-tools-generated MCP server running...");
