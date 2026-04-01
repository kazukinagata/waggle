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
  { name: "notion-extension", version: "0.2.0" },
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

async function handleQuery(args) {
  const { database_id, filter, sorts } = args;
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

  return { results: allResults };
}

async function handleUpdateRelation(args) {
  const { page_id, property_name, mode, relation_ids = [] } = args;

  let finalIds = relation_ids;

  if (mode === "append" && relation_ids.length > 0) {
    const page = await notion.pages.retrieve({ page_id });
    const existing = page.properties[property_name]?.relation ?? [];
    const existingIds = existing.map((r) => r.id);
    const seen = new Set(existingIds);
    for (const id of relation_ids) {
      if (!seen.has(id)) {
        existingIds.push(id);
        seen.add(id);
      }
    }
    finalIds = existingIds;
  }

  const relation = finalIds.map((id) => ({ id }));
  const result = await notion.pages.update({
    page_id,
    properties: { [property_name]: { relation } },
  });

  return result;
}

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  let result;
  switch (name) {
    case "notion-query":
      result = await handleQuery(args);
      break;
    case "notion-update-relation":
      result = await handleUpdateRelation(args);
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

console.error("notion-extension MCP server running...");
