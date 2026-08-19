#!/usr/bin/env node

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { Client } from "@notionhq/client";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { basename, join, resolve } from "node:path";
import { tmpdir } from "node:os";
import {
  MAX_DOWNLOAD_BYTES,
  MAX_INLINE_TEXT_BYTES,
  MAX_READ_IMAGE_BYTES,
  MAX_UPLOAD_BYTES,
  READABLE_MIME_TYPES,
  apiErrorDetail,
  collectImageBlocks,
  describeFileEntry,
  filterByBlockIds,
  filterByNames,
  hostedUrl,
  isAllowedDownloadUrl,
  isExpired,
  isTextualMime,
  mimeForAttachment,
  mimeFromFilename,
  safeFilename,
  scrubUrls,
  toWritableFiles,
  validateReadFilesInput,
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
  { name: "notion-extension", version: "1.2.3" },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: "notion-query",
      description:
        "Prefer this over the hosted Notion MCP's notion-search / notion-query-data-sources for any filtered or sorted database query: it runs raw Notion API filter/sorts objects server-side, including people-property filters (e.g. Assignee) that the hosted tools cannot express. Pass page_size to fetch one page at a time and avoid MCP token-cap errors on large databases; the response will then include has_more and next_cursor for the caller to drive pagination. When page_size is omitted, all pages are aggregated server-side (legacy behavior). Not for free-text search across a workspace — use the hosted notion-search for that.",
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
        "Use this instead of the hosted notion-update-page for relation properties: it writes relation page IDs directly with an explicit mode — replace sets the exact list (empty array clears) and append merges with existing entries and deduplicates, a read-modify-write the hosted tool cannot do safely. Only touches the single relation property named; not for other property types.",
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
        "The only tool that can put a local image file into a Notion page body — the hosted Notion MCP tools cannot upload local files at all. Appends an image block; provide exactly one of file_path (a local image file, uploaded via the Notion File Upload API; max 20MB single-part) or external_url (a publicly reachable image URL, embedded as an external image block). Requires the integration token to have the 'Insert content' capability. For non-image file attachments on a files-type property, use notion-set-files-property instead.",
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
        "The only tool that returns a Notion page's images as actual inline image content the model can see — the hosted notion-fetch returns text/markdown only. Returns the images preceded by a text part with a JSON summary ({count, total_found, images:[{index, block_id, mime_type, size_bytes, caption, source_type}], skipped}) whose images array is in the same order as the image parts. total_found counts all images discovered on the page before any filtering. Recurses into nested blocks (toggles, columns, callouts; depth 3) but never into child pages/databases. Images over 5MB, non-raster types (svg, tiff, heic), and requested block_ids that match no image are listed in skipped with a reason instead of returned.",
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
        "The only way to write a files-type page property (e.g. \"Attachments\") — the hosted notion-update-page cannot set files properties, and no hosted tool can upload a local file. Each files entry is either { file_path } (a local file uploaded via the Notion File Upload API; max 20MB single-part; requires the 'Insert content' capability) or { name, url } (an external file stored as-is). Mode replace sets the exact list (empty array clears); append merges with existing entries (read-modify-write). Uploaded files read back as signed URLs that expire ~1h.",
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
    {
      name: "notion-read-files-property",
      description:
        "The only way to READ the contents of a files-type page property (e.g. \"Attachments\") — the hosted notion-fetch reports that a file is attached but cannot retrieve it, so an executor holding only the task cannot see what the attachment says. The mirror of notion-set-files-property. Returns a JSON summary plus, per entry: text-bearing files (text/*, csv, json, xml, yaml, markdown) inline as content, and everything else downloaded to out_dir with only the local path returned. Notion-hosted files are fetched through their short-lived signed URL, which is never included in the result; external entries are NOT fetched — their name and URL are returned so the caller can fetch them with a general-purpose tool if it wants to. Inline text is capped at 256KB (truncation is reported); downloads over 50MB are skipped with a reason.",
      inputSchema: {
        type: "object",
        properties: {
          page_id: {
            type: "string",
            description: "Notion page UUID to read from",
          },
          property_name: {
            type: "string",
            description: 'files-type property name (e.g., "Attachments")',
          },
          names: {
            type: "array",
            items: { type: "string" },
            description:
              "Optional display names to read. Omit to read every entry (up to max_files). A requested name matching nothing is reported in skipped.",
          },
          max_files: {
            type: "number",
            description: "Maximum entries to retrieve (default 5). Entries beyond the cap are listed in skipped.",
            default: 5,
          },
          out_dir: {
            type: "string",
            description:
              "Directory for downloaded non-text files. Defaults to a per-run directory under the system temp dir. Created if absent.",
          },
          metadata_only: {
            type: "boolean",
            description:
              "List the entries without retrieving any content. Use to see what is attached before deciding what to read.",
            default: false,
          },
        },
        required: ["page_id", "property_name"],
      },
    },
  ],
}));

// notion-read-files-property — read the contents of a files-type property.
//
// SIGNED URLS ARE CREDENTIALS. A Notion-hosted entry resolves to a pre-signed
// storage URL: possession is authorization, for roughly an hour. So the URL is
// used inside this function and never escapes it — not in the result, not in an
// error message, not in a log line. Entries are identified to the caller by name
// and index. Errors from the download are re-raised with the URL stripped.
//
// The Notion token is likewise never sent to that URL. It points at Notion's
// storage host, not at api.notion.com; the signature is the authorization, and
// attaching a bearer token would hand our integration credential to a host that
// has no business holding it.
async function handleReadFilesProperty(args) {
  const {
    page_id,
    property_name,
    names,
    max_files = 5,
    out_dir,
    metadata_only = false,
  } = args;

  const inputError = validateReadFilesInput(args);
  if (inputError) throw new Error(inputError);

  let page = await notion.pages.retrieve({ page_id });
  const property = page.properties?.[property_name];
  if (!property) {
    throw new Error(
      `Page has no property named "${property_name}". Check the name, or use notion-fetch to list the page's properties.`
    );
  }
  if (!Array.isArray(property.files)) {
    throw new Error(
      `Property "${property_name}" is type "${property.type}", not files. notion-read-files-property only reads files-type properties.`
    );
  }

  const all = property.files;
  const skipped = [];
  let selected = all;

  if (names?.length) {
    const filtered = filterByNames(all, names);
    selected = filtered.selected;
    for (const missing of filtered.missing) {
      skipped.push({ name: missing, reason: "no entry with this name on the property" });
    }
  }
  if (selected.length > max_files) {
    for (const entry of selected.slice(max_files)) {
      skipped.push({
        name: entry.name ?? null,
        reason: `max_files (${max_files}) exceeded; call again with names to fetch it`,
      });
    }
    selected = selected.slice(0, max_files);
  }

  const described = selected.map((entry, i) => describeFileEntry(entry, all.indexOf(entry) >= 0 ? all.indexOf(entry) : i));

  if (metadata_only) {
    return {
      ok: true,
      page_id,
      property_name,
      total_found: all.length,
      metadata_only: true,
      files: described,
      skipped,
    };
  }

  const results = [];
  const textParts = [];
  let refreshed = false;

  for (let i = 0; i < selected.length; i += 1) {
    let entry = selected[i];
    const meta = described[i];

    if (meta.source === "external") {
      // Not fetched by design: the bytes are not in Notion, the URL is not a
      // secret, and the caller already has a general-purpose fetcher. Returning
      // the URL is both safe and sufficient.
      results.push({ ...meta, retrieved: false, reason: "external entry; fetch the url with a general-purpose tool" });
      continue;
    }
    if (meta.source === "unknown") {
      results.push({ ...meta, retrieved: false, reason: `unrecognized entry type "${entry.type}"` });
      continue;
    }

    // Refresh the page once if any signed URL has expired (or is about to).
    // Fetching a stale URL yields a 403 that reads like a permissions problem
    // and is not one, so it is cheaper to re-mint than to explain.
    if (isExpired(entry, Date.now()) && !refreshed) {
      page = await notion.pages.retrieve({ page_id });
      const fresh = page.properties?.[property_name]?.files ?? [];
      const match = fresh.find((f) => f.name === entry.name) ?? fresh[meta.index];
      if (match) entry = match;
      refreshed = true;
    }

    const url = hostedUrl(entry);
    if (!url) {
      results.push({ ...meta, retrieved: false, reason: "entry has no retrievable URL" });
      continue;
    }
    if (isExpired(entry, Date.now())) {
      results.push({
        ...meta,
        retrieved: false,
        reason: "signed URL expired and could not be refreshed; re-run to obtain a fresh one",
      });
      continue;
    }
    if (!isAllowedDownloadUrl(url)) {
      results.push({ ...meta, retrieved: false, reason: "download URL is not an allowed https destination" });
      continue;
    }

    let downloaded;
    try {
      downloaded = await downloadAttachment(url);
    } catch (error) {
      // Strip the URL from anything the fetch layer put in the message.
      results.push({ ...meta, retrieved: false, reason: `download failed: ${scrubUrls(error.message)}` });
      continue;
    }

    const mime = downloaded.mime || mimeForAttachment(meta.name);
    if (downloaded.bytes.length > MAX_DOWNLOAD_BYTES) {
      results.push({
        ...meta,
        retrieved: false,
        mime_type: mime,
        size_bytes: downloaded.bytes.length,
        reason: `exceeds the ${MAX_DOWNLOAD_BYTES} byte download cap`,
      });
      continue;
    }

    if (isTextualMime(mime)) {
      const truncated = downloaded.bytes.length > MAX_INLINE_TEXT_BYTES;
      const slice = truncated ? downloaded.bytes.subarray(0, MAX_INLINE_TEXT_BYTES) : downloaded.bytes;
      textParts.push({
        type: "text",
        text: `--- ${meta.name ?? `attachment-${meta.index}`} (${mime}${truncated ? ", truncated" : ""}) ---\n${slice.toString("utf8")}`,
      });
      results.push({
        ...meta,
        retrieved: true,
        delivery: "inline",
        mime_type: mime,
        size_bytes: downloaded.bytes.length,
        truncated,
      });
      continue;
    }

    const dir = out_dir ? resolve(out_dir) : join(tmpdir(), `notion-attachments-${page_id}`);
    await mkdir(dir, { recursive: true });
    const filePath = join(dir, safeFilename(meta.name, meta.index));
    await writeFile(filePath, downloaded.bytes);
    results.push({
      ...meta,
      retrieved: true,
      delivery: "file",
      path: filePath,
      mime_type: mime,
      size_bytes: downloaded.bytes.length,
    });
  }

  const summary = {
    ok: true,
    page_id,
    property_name,
    total_found: all.length,
    files: results,
    skipped,
  };

  return { __content: [{ type: "text", text: JSON.stringify(summary) }, ...textParts] };
}

// Fetch a pre-signed attachment URL. No Authorization header: the signature is
// the credential and the host is not api.notion.com. Redirects are followed
// manually so each hop can be re-checked — the first URL comes from Notion, a
// redirect target does not.
async function downloadAttachment(url) {
  let current = url;
  for (let hop = 0; hop < 5; hop += 1) {
    const response = await fetch(current, { redirect: "manual" });
    if (response.status >= 300 && response.status < 400) {
      const location = response.headers.get("location");
      if (!location) throw new Error(`HTTP ${response.status} with no Location header`);
      const next = new URL(location, current).toString();
      if (!isAllowedDownloadUrl(next)) throw new Error("redirected to a disallowed destination");
      current = next;
      continue;
    }
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const buffer = Buffer.from(await response.arrayBuffer());
    return { bytes: buffer, mime: response.headers.get("content-type") };
  }
  throw new Error("too many redirects");
}

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
    const error = new Error(
      `Notion API ${method} ${path} failed: ${apiErrorDetail(response.status, json)}`
    );
    // Genuine Notion errors carry a JSON code (e.g. restricted_resource);
    // expose it so callers can classify without string-matching the message.
    // A WAF block has no JSON body, so its error never gets a code.
    error.code = json?.code;
    throw error;
  }
  return json;
}

// Appending body blocks needs the integration's "Insert content" capability;
// without it Notion returns 403 restricted_resource. Re-throw with the fix.
// Classify by error code only — both the SDK's APIResponseError and notionApi
// errors carry .code, and message text can legitimately mention the code name
// (the WAF diagnostic does) without being a permissions error.
function rethrowWithCapabilityHint(error) {
  if (error?.code === "restricted_resource") {
    const message = String(error?.message ?? error);
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
  // The send must declare the content type Notion inferred from the filename
  // at create time; any other type is rejected with a 400 mismatch.
  form.append("file", new Blob([data], { type: upload.content_type || mimeType }), filename);
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
  // The send must declare the content type Notion inferred from the filename
  // at create time; any other type is rejected with a 400 mismatch. The local
  // extension map is only the fallback for filenames Notion cannot classify.
  form.append("file", new Blob([data], { type: upload.content_type || mimeType }), filename);
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
    case "notion-read-files-property": {
      // Returns a mixed text array (JSON summary + inline file contents), not a
      // single JSON text part, so it bypasses the shared wrapper below.
      const read = await handleReadFilesProperty(args);
      return { content: read.__content };
    }
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
