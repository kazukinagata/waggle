#!/usr/bin/env node

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { Client } from "@notionhq/client";
import { readFile } from "node:fs/promises";
import { basename } from "node:path";
import {
  MAX_READ_IMAGE_BYTES,
  MAX_UPLOAD_BYTES,
  READABLE_MIME_TYPES,
  collectImageBlocks,
  filterByBlockIds,
  mimeForAttachment,
  mimeFromFilename,
  toWritableFiles,
  validateSetFilesInput,
  validateUploadInput,
} from "./helpers.js";

const NOTION_TOKEN = process.env.NOTION_TOKEN;
if (!NOTION_TOKEN) {
  console.error("Error: NOTION_TOKEN environment variable is not set.");
  process.exit(1);
}

// notion-upload-image / notion-read-images use the global fetch / FormData /
// Blob introduced in Node 18 (the @notionhq/client SDK pinned here predates
// the File Upload API, so those endpoints are called directly).
if (typeof fetch !== "function" || typeof FormData !== "function") {
  console.error("Error: notion-extension requires Node.js 18+ (built-in fetch).");
  process.exit(1);
}

const NOTION_API_VERSION = "2022-06-28";

// Without an explicit fetch, @notionhq/client falls back to its bundled
// node-fetch v2, which has a long-standing "Premature close" bug in its
// chunked-response termination detection (node-fetch/node-fetch#1576) that
// surfaces intermittently depending on TCP packet framing. Passing the
// built-in fetch (already required above) routes notion.databases.query()
// through the same undici-based client as the rest of this file.
const notion = new Client({ auth: NOTION_TOKEN, fetch });

const server = new Server(
  { name: "notion-extension", version: "1.2.1" },
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
    {
      name: "notion-upload-image",
      description:
        "Append an image block to a Notion page body. Provide exactly one of file_path (a local image file, uploaded via the Notion File Upload API; max 20MB single-part) or external_url (a publicly reachable image URL, embedded as an external image block). Requires the integration token to have the 'Insert content' capability.",
      inputSchema: {
        type: "object",
        properties: {
          page_id: {
            type: "string",
            description:
              "Notion page UUID (or block UUID) whose body the image is appended to",
          },
          file_path: {
            type: "string",
            description:
              "Absolute path to a local image file (png, jpg, jpeg, gif, webp, svg, bmp, tif, tiff, heic, ico). Mutually exclusive with external_url.",
          },
          external_url: {
            type: "string",
            description:
              "Publicly reachable image URL to embed without uploading. Mutually exclusive with file_path.",
          },
          caption: {
            type: "string",
            description: "Optional caption text for the image block",
          },
        },
        required: ["page_id"],
      },
    },
    {
      name: "notion-read-images",
      description:
        "Read images from a Notion page body and return them as inline image content the model can see, preceded by a text part with a JSON summary ({count, total_found, images:[{index, block_id, mime_type, size_bytes, caption, source_type}], skipped}) whose images array is in the same order as the image parts. total_found counts all images discovered on the page before any filtering. Recurses into nested blocks (toggles, columns, callouts; depth 3) but never into child pages/databases. Images over 5MB, non-raster types (svg, tiff, heic), and requested block_ids that match no image are listed in skipped with a reason instead of returned.",
      inputSchema: {
        type: "object",
        properties: {
          page_id: {
            type: "string",
            description: "Notion page UUID (or block UUID) to read images from",
          },
          max_images: {
            type: "integer",
            description:
              "Maximum number of images to return as inline content (default 10). Further images are listed in skipped.",
            minimum: 1,
            maximum: 20,
          },
          block_ids: {
            type: "array",
            items: { type: "string" },
            description:
              "Optional filter: only return images whose block ID is in this list (IDs accepted with or without dashes)",
          },
          include_nested: {
            type: "boolean",
            description:
              "Recurse into nested container blocks (toggles, columns, callouts). Default true; depth capped at 3.",
          },
        },
        required: ["page_id"],
      },
    },
    {
      name: "notion-set-files-property",
      description:
        "Set or append files on a Notion files-type page property (e.g. \"Attachments\"). Each files entry is either { file_path } (a local file uploaded via the Notion File Upload API; max 20MB single-part; requires the 'Insert content' capability) or { name, url } (an external file stored as-is). Mode replace sets the exact list (empty array clears); append merges with existing entries (read-modify-write). Uploaded files read back as signed URLs that expire ~1h. notion-update-page cannot set files properties — use this tool.",
      inputSchema: {
        type: "object",
        properties: {
          page_id: {
            type: "string",
            description: "Notion page UUID to update",
          },
          property_name: {
            type: "string",
            description: 'files-type property name (e.g., "Attachments")',
          },
          mode: {
            type: "string",
            enum: ["replace", "append"],
            description:
              '"replace" sets the exact list (empty array clears the property), "append" merges with existing entries',
          },
          files: {
            type: "array",
            description:
              "File entries. Each is { file_path } (local upload) or { name, url } (external; name required).",
            items: {
              type: "object",
              properties: {
                file_path: {
                  type: "string",
                  description: "Absolute path to a local file to upload. Mutually exclusive with url.",
                },
                url: {
                  type: "string",
                  description: "External file URL, stored as-is. Mutually exclusive with file_path.",
                },
                name: {
                  type: "string",
                  description: "Display filename. Required for url entries; defaults to the basename for file_path entries.",
                },
              },
            },
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

  // Guard: append with empty input is a no-op. Without this, the path below
  // would skip the merge (length 0), keep finalIds = [], and overwrite the
  // existing relation with an empty list — destroying data on what the caller
  // intended as "add nothing." Use `mode: "replace"` with `[]` to clear.
  if (mode === "append" && relation_ids.length === 0) {
    const page = await notion.pages.retrieve({ page_id });
    const existing = page.properties[property_name]?.relation ?? [];
    return {
      ok: true,
      page_id,
      property_name,
      mode,
      relation_ids: existing.map((r) => r.id),
    };
  }

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
  await notion.pages.update({
    page_id,
    properties: { [property_name]: { relation } },
  });

  return {
    ok: true,
    page_id,
    property_name,
    mode,
    relation_ids: finalIds,
  };
}

// A hung connection must not block the MCP server indefinitely — every raw
// fetch (Notion REST + image downloads) gets a hard timeout.
const FETCH_TIMEOUT_MS = 30_000;

async function fetchWithTimeout(url, options = {}) {
  try {
    return await fetch(url, {
      ...options,
      signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
    });
  } catch (error) {
    if (error?.name === "TimeoutError" || error?.name === "AbortError") {
      throw new Error(`Request timed out after ${FETCH_TIMEOUT_MS}ms: ${url}`);
    }
    throw error;
  }
}

// Direct REST call for endpoints the pinned @notionhq/client predates
// (File Upload API). Body may be a plain object (JSON) or FormData
// (multipart — fetch sets the boundary Content-Type itself).
async function notionApi(method, path, body) {
  const isForm = body instanceof FormData;
  const response = await fetchWithTimeout(`https://api.notion.com${path}`, {
    method,
    headers: {
      Authorization: `Bearer ${NOTION_TOKEN}`,
      "Notion-Version": NOTION_API_VERSION,
      ...(body && !isForm ? { "Content-Type": "application/json" } : {}),
    },
    body: body ? (isForm ? body : JSON.stringify(body)) : undefined,
  });
  const json = await response.json().catch(() => null);
  if (!response.ok) {
    const detail = json?.message || json?.code || `HTTP ${response.status}`;
    throw new Error(`Notion API ${method} ${path} failed: ${detail}`);
  }
  return json;
}

// Appending body blocks needs the integration's "Insert content" capability;
// without it Notion returns 403 restricted_resource. Re-throw with the fix.
function rethrowWithCapabilityHint(error) {
  const message = String(error?.message ?? error);
  if (error?.code === "restricted_resource" || message.includes("restricted_resource")) {
    throw new Error(
      `${message} — the integration token likely lacks the "Insert content" capability. Enable it at https://www.notion.so/profile/integrations (integration → Capabilities → Insert content), then retry.`
    );
  }
  throw error;
}

async function appendImageBlock(page_id, image) {
  try {
    const response = await notion.blocks.children.append({
      block_id: page_id,
      children: [{ type: "image", image }],
    });
    return response.results?.[0]?.id;
  } catch (error) {
    rethrowWithCapabilityHint(error);
  }
}

async function handleUploadImage(args) {
  const { page_id, file_path, external_url, caption } = args;

  const inputError = validateUploadInput(args);
  if (inputError) throw new Error(inputError);

  const captionParts = caption
    ? [{ type: "text", text: { content: caption } }]
    : [];

  if (external_url) {
    const block_id = await appendImageBlock(page_id, {
      type: "external",
      external: { url: external_url },
      caption: captionParts,
    });
    return { ok: true, page_id, block_id, image_type: "external" };
  }

  const filename = basename(file_path);
  const mimeType = mimeFromFilename(filename);
  if (!mimeType) {
    throw new Error(
      `Unsupported image extension in "${filename}". Supported: png, jpg, jpeg, gif, webp, svg, bmp, tif, tiff, heic, ico.`
    );
  }

  const data = await readFile(file_path);
  if (data.length > MAX_UPLOAD_BYTES) {
    throw new Error(
      `File is ${data.length} bytes; the Notion single-part upload cap is ${MAX_UPLOAD_BYTES} bytes (20MB). Resize or split the image.`
    );
  }

  // Notion File Upload flow: create the upload object, send the bytes
  // (multipart), then attach within 1 hour as an image block.
  const upload = await notionApi("POST", "/v1/file_uploads", {
    mode: "single_part",
    filename,
  });

  const form = new FormData();
  form.append("file", new Blob([data], { type: mimeType }), filename);
  await notionApi("POST", `/v1/file_uploads/${upload.id}/send`, form);

  const block_id = await appendImageBlock(page_id, {
    type: "file_upload",
    file_upload: { id: upload.id },
    caption: captionParts,
  });
  return { ok: true, page_id, block_id, image_type: "file_upload", filename };
}

// Upload one local file via the Notion File Upload flow; returns its upload id
// and the basename (the default display name).
async function uploadLocalFile(file_path) {
  const filename = basename(file_path);
  const mimeType = mimeForAttachment(filename);
  const data = await readFile(file_path);
  if (data.length > MAX_UPLOAD_BYTES) {
    throw new Error(
      `File "${filename}" is ${data.length} bytes; the Notion single-part upload cap is ${MAX_UPLOAD_BYTES} bytes (20MB).`
    );
  }
  const upload = await notionApi("POST", "/v1/file_uploads", {
    mode: "single_part",
    filename,
  });
  const form = new FormData();
  form.append("file", new Blob([data], { type: mimeType }), filename);
  await notionApi("POST", `/v1/file_uploads/${upload.id}/send`, form);
  return { id: upload.id, name: filename };
}

async function handleSetFilesProperty(args) {
  const { page_id, property_name, mode, files = [] } = args;

  const inputError = validateSetFilesInput(args);
  if (inputError) throw new Error(inputError);

  // Guard: append with no input is a read-only no-op. Returning early avoids an
  // unnecessary round-trip write of the existing entries (mirrors the
  // notion-update-relation guard that prevents clobbering on empty append).
  if (mode === "append" && files.length === 0) {
    const page = await notion.pages.retrieve({ page_id });
    const existing = page.properties[property_name]?.files ?? [];
    return {
      ok: true,
      page_id,
      property_name,
      mode,
      files: existing.map((e) => ({
        name: e.name,
        url: e.type === "file" ? e.file?.url : e.type === "external" ? e.external?.url : null,
      })),
    };
  }

  // Build the new entries in Notion's write shape (upload locals first).
  const newEntries = [];
  for (const f of files) {
    if (f.file_path) {
      const { id, name } = await uploadLocalFile(f.file_path);
      newEntries.push({ type: "file_upload", name: f.name || name, file_upload: { id } });
    } else {
      newEntries.push({ type: "external", name: f.name, external: { url: f.url } });
    }
  }

  let finalFiles = newEntries;
  if (mode === "append") {
    const page = await notion.pages.retrieve({ page_id });
    const existing = toWritableFiles(page.properties[property_name]?.files ?? []);
    finalFiles = [...existing, ...newEntries];
  }

  let updated;
  try {
    updated = await notionApi("PATCH", `/v1/pages/${page_id}`, {
      properties: { [property_name]: { files: finalFiles } },
    });
  } catch (error) {
    rethrowWithCapabilityHint(error);
  }

  // The PATCH response is the full updated page; return the resolved files in
  // read shape (signed URLs for uploads, stable URLs for external entries).
  const resolved = updated.properties[property_name]?.files ?? [];
  return {
    ok: true,
    page_id,
    property_name,
    mode,
    files: resolved.map((e) => ({
      name: e.name,
      url: e.type === "file" ? e.file?.url : e.type === "external" ? e.external?.url : null,
    })),
  };
}

async function handleReadImages(args) {
  const { page_id, max_images = 10, block_ids, include_nested = true } = args;

  // Walk the block tree breadth-first. Depth 1 is the page body itself;
  // containers (toggles, columns, callouts, ...) are descended into up to
  // maxDepth, child pages/databases never (see collectImageBlocks).
  const maxDepth = include_nested ? 3 : 1;
  const found = [];
  const queue = [{ id: page_id, depth: 1 }];
  while (queue.length > 0) {
    const { id, depth } = queue.shift();
    let cursor;
    do {
      const response = await notion.blocks.children.list({
        block_id: id,
        page_size: 100,
        ...(cursor ? { start_cursor: cursor } : {}),
      });
      const { images, containers } = collectImageBlocks(response.results);
      found.push(...images);
      if (depth < maxDepth) {
        queue.push(...containers.map((cid) => ({ id: cid, depth: depth + 1 })));
      }
      cursor = response.has_more ? response.next_cursor : undefined;
    } while (cursor);
  }

  const skipped = [];
  let selected = found;
  if (block_ids?.length) {
    const filtered = filterByBlockIds(found, block_ids);
    selected = filtered.selected;
    for (const missingId of filtered.missing) {
      skipped.push({
        block_id: missingId,
        reason:
          "no image block with this ID found on the page (or it sits below the recursion depth)",
      });
    }
  }
  if (selected.length > max_images) {
    for (const img of selected.slice(max_images)) {
      skipped.push({
        block_id: img.block_id,
        reason: `max_images (${max_images}) exceeded; call again with block_ids to fetch it`,
      });
    }
    selected = selected.slice(0, max_images);
  }

  const summary = [];
  const imageParts = [];
  for (const img of selected) {
    if (!img.url) {
      skipped.push({ block_id: img.block_id, reason: "image block has no URL" });
      continue;
    }
    // file-type URLs are pre-signed S3 links (valid ~1h); external URLs are
    // plain public links. Neither takes the Notion auth header.
    let response;
    try {
      response = await fetchWithTimeout(img.url);
    } catch (error) {
      skipped.push({
        block_id: img.block_id,
        reason: `download failed: ${error?.message ?? error}`,
      });
      continue;
    }
    if (!response.ok) {
      skipped.push({
        block_id: img.block_id,
        reason: `download failed: HTTP ${response.status}`,
      });
      continue;
    }
    const mimeType =
      (response.headers.get("content-type") ?? "").split(";")[0].trim() ||
      mimeFromFilename(new URL(img.url).pathname) ||
      "application/octet-stream";
    const data = Buffer.from(await response.arrayBuffer());
    if (data.length > MAX_READ_IMAGE_BYTES) {
      skipped.push({
        block_id: img.block_id,
        mime_type: mimeType,
        size_bytes: data.length,
        reason: `image exceeds the ${MAX_READ_IMAGE_BYTES}-byte (5MB) inline limit`,
      });
      continue;
    }
    if (!READABLE_MIME_TYPES.has(mimeType)) {
      skipped.push({
        block_id: img.block_id,
        mime_type: mimeType,
        url: img.url,
        reason: "not a raster type the model can view inline (png/jpeg/gif/webp)",
      });
      continue;
    }
    summary.push({
      index: imageParts.length,
      block_id: img.block_id,
      mime_type: mimeType,
      size_bytes: data.length,
      caption: img.caption,
      source_type: img.source_type,
    });
    imageParts.push({
      type: "image",
      data: data.toString("base64"),
      mimeType,
    });
  }

  return {
    content: [
      {
        type: "text",
        text: JSON.stringify({
          count: imageParts.length,
          total_found: found.length,
          images: summary,
          skipped,
        }),
      },
      ...imageParts,
    ],
  };
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
    case "notion-upload-image":
      result = await handleUploadImage(args);
      break;
    case "notion-read-images":
      // Returns a mixed text + image content array directly, not JSON text.
      return await handleReadImages(args);
    case "notion-set-files-property":
      result = await handleSetFilesProperty(args);
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
