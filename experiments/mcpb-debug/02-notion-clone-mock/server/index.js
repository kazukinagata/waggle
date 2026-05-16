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

// Imported but never used. Kept to mirror the real notion-extension's
// dependency-loading and startup cost.
// eslint-disable-next-line no-unused-vars
const notion = new Client({ auth: NOTION_TOKEN });

const server = new Server(
  { name: "mcpb-debug-notion-clone-mock", version: "0.0.1" },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: "notion-query",
      description:
        "Query a Notion database with server-side filtering, sorting, and pagination. Supports people property filters (Assignee) that the Notion hosted MCP cannot handle. Pass page_size to fetch one page at a time and avoid MCP token-cap errors on large databases; the response will then include has_more and next_cursor for the caller to drive pagination. When page_size is omitted, all pages are aggregated server-side (legacy behavior).",
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
              'Notion filter object. Example: {"property":"Assignee","people":{"contains":"<user_id>"}}',
          },
          sorts: {
            type: "array",
            description:
              'Notion sorts array. Example: [{"property":"Priority","direction":"ascending"}]',
          },
          page_size: {
            type: "integer",
            description:
              "Notion API page_size (1-100). When set, this tool returns a single page along with has_more and next_cursor so the caller can paginate. When omitted, the server aggregates all pages internally and returns the full result set (legacy behavior; risks exceeding MCP token caps on large databases).",
            minimum: 1,
            maximum: 100,
          },
          start_cursor: {
            type: "string",
            description:
              "Notion API start_cursor, taken from a prior response's next_cursor. Only meaningful when page_size is set.",
          },
          filter_properties: {
            type: "array",
            items: { type: "string" },
            description:
              "Notion property IDs to include in each returned page's properties object. Other properties are omitted from the response. Use to reduce payload size when only a subset of columns is needed. Page-level metadata (id, created_time, parent, url, etc.) is still returned by the Notion API regardless of this list.",
          },
        },
        required: ["database_id"],
      },
    },
    {
      name: "notion-update-relation",
      description:
        "Update a relation property on a Notion page. Supports replace (set exact list) and append (merge with existing, dedup) modes.",
      inputSchema: {
        type: "object",
        properties: {
          page_id: {
            type: "string",
            description: "Notion page UUID to update",
          },
          property_name: {
            type: "string",
            description:
              'Relation property name (e.g., "Blocked By", "Parent Task")',
          },
          mode: {
            type: "string",
            enum: ["replace", "append"],
            description:
              '"replace" sets exact list (empty array clears the relation), "append" merges with existing and deduplicates',
          },
          relation_ids: {
            type: "array",
            items: { type: "string" },
            description: "Page IDs for the relation",
            default: [],
          },
        },
        required: ["page_id", "property_name", "mode"],
      },
    },
  ],
}));

async function handleQueryMock(_args) {
  return {
    results: [],
    has_more: false,
    next_cursor: null,
    _mock: true,
  };
}

async function handleUpdateRelationMock(args) {
  return {
    object: "page",
    id: args?.page_id ?? "mock-page-id",
    properties: {
      [args?.property_name ?? "Mock Relation"]: {
        relation: (args?.relation_ids ?? []).map((id) => ({ id })),
      },
    },
    _mock: true,
  };
}

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  let result;
  switch (name) {
    case "notion-query":
      result = await handleQueryMock(args);
      break;
    case "notion-update-relation":
      result = await handleUpdateRelationMock(args);
      break;
    default:
      throw new Error(`Unknown tool: ${name}`);
  }

  return {
    content: [{ type: "text", text: JSON.stringify(result) }],
  };
});

const transport = new StdioServerTransport();
server.connect(transport);

console.error("mcpb-debug-notion-clone-mock MCP server running...");
