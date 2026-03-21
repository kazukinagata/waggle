#!/usr/bin/env node

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { Client } from "@notionhq/client";

const NOTION_TOKEN = process.env.NOTION_TOKEN;
if (!NOTION_TOKEN) {
  console.error("Error: NOTION_TOKEN environment variable is not set.");
  process.exit(1);
}

const notion = new Client({ auth: NOTION_TOKEN });

const server = new Server(
  { name: "notion-query", version: "0.1.0" },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: "notion-query",
      description:
        "Query a Notion database with server-side filtering, sorting, and pagination. Supports people property filters (Assignees) that the Notion hosted MCP cannot handle.",
      inputSchema: {
        type: "object",
        properties: {
          database_id: {
            type: "string",
            description: "Notion database UUID (with or without dashes)",
          },
          filter: {
            type: "object",
            description:
              'Notion filter object. Example: {"property":"Assignees","people":{"contains":"<user_id>"}}',
          },
          sorts: {
            type: "array",
            description:
              'Notion sorts array. Example: [{"property":"Priority","direction":"ascending"}]',
          },
        },
        required: ["database_id"],
      },
    },
  ],
}));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  if (request.params.name !== "notion-query") {
    throw new Error(`Unknown tool: ${request.params.name}`);
  }

  const { database_id, filter, sorts } = request.params.arguments;
  const allResults = [];
  let startCursor = undefined;
  let hasMore = true;

  while (hasMore) {
    const queryParams = { database_id };
    if (filter) queryParams.filter = filter;
    if (sorts) queryParams.sorts = sorts;
    if (startCursor) queryParams.start_cursor = startCursor;

    const response = await notion.databases.query(queryParams);
    allResults.push(...response.results);
    hasMore = response.has_more;
    startCursor = response.next_cursor;
  }

  return {
    content: [
      {
        type: "text",
        text: JSON.stringify({ results: allResults }),
      },
    ],
  };
});

const transport = new StdioServerTransport();
server.connect(transport);

console.error("notion-query MCP server running...");
