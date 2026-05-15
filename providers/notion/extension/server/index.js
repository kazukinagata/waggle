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
  { name: "notion-extension", version: "0.4.0" },
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

async function handleQuery(args) {
  const { database_id, filter, sorts, page_size, start_cursor, filter_properties } = args;

  const baseParams = { database_id };
  if (filter) baseParams.filter = filter;
  if (sorts) baseParams.sorts = sorts;
  if (filter_properties) baseParams.filter_properties = filter_properties;

  // Caller-driven pagination: return one page plus cursors so the caller can
  // iterate. This keeps each MCP response under the host's token cap on large
  // databases (Intake Log, Tasks DB with hundreds of rows, etc.).
  if (page_size !== undefined) {
    const response = await notion.databases.query({
      ...baseParams,
      page_size,
      ...(start_cursor ? { start_cursor } : {}),
    });
    return {
      results: response.results,
      has_more: response.has_more,
      next_cursor: response.next_cursor,
    };
  }

  // Legacy mode: aggregate all pages server-side. Preserved for callers that
  // do not yet drive pagination; will overflow MCP token caps on large DBs.
  const allResults = [];
  let cursor = undefined;
  let hasMore = true;
  while (hasMore) {
    const response = await notion.databases.query({
      ...baseParams,
      ...(cursor ? { start_cursor: cursor } : {}),
    });
    allResults.push(...response.results);
    hasMore = response.has_more;
    cursor = response.next_cursor;
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
