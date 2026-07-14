// Pure helpers for the notion-extension MCP server. No network or environment
// access here — everything is unit-testable without NOTION_TOKEN.

// Image extensions Notion accepts for image blocks, mapped to MIME types used
// for the File Upload API's multipart send.
const MIME_BY_EXTENSION = {
  png: "image/png",
  jpg: "image/jpeg",
  jpeg: "image/jpeg",
  gif: "image/gif",
  webp: "image/webp",
  svg: "image/svg+xml",
  bmp: "image/bmp",
  tif: "image/tiff",
  tiff: "image/tiff",
  heic: "image/heic",
  ico: "image/x-icon",
};

// Raster types Claude vision can consume. Other Notion-supported image types
// (svg, tiff, heic, ...) are reported in the read-images summary as skipped
// instead of being returned as image content.
export const READABLE_MIME_TYPES = new Set([
  "image/png",
  "image/jpeg",
  "image/gif",
  "image/webp",
]);

// Claude vision rejects images larger than ~5 MB; skip them on read.
export const MAX_READ_IMAGE_BYTES = 5 * 1024 * 1024;

// Notion File Upload API single-part cap.
export const MAX_UPLOAD_BYTES = 20 * 1024 * 1024;

// Failure detail for a non-OK Notion API response. Notion's own errors carry
// a JSON body with message/code. A 403 without one never reached Notion: the
// WAF in front of api.notion.com serves an HTML block page when the request
// body matches an attack signature (e.g. "javascript:" URIs inside an
// uploaded HTML file trigger this on /send).
export function apiErrorDetail(status, json) {
  const detail = json?.message || json?.code;
  if (detail) return detail;
  if (status === 403) {
    return (
      "HTTP 403 with a non-JSON body — the request was blocked by the WAF in front of the Notion API, " +
      "not rejected by Notion itself (a permissions error would carry a restricted_resource JSON body). " +
      'File contents matching attack signatures (e.g. "javascript:" URIs in HTML) trigger this on upload. ' +
      "Compress the file to .zip and retry."
    );
  }
  return `HTTP ${status}`;
}

export function mimeFromFilename(filename) {
  const match = /\.([A-Za-z0-9]+)$/.exec(filename || "");
  if (!match) return null;
  return MIME_BY_EXTENSION[match[1].toLowerCase()] ?? null;
}

// Attachments (files property) accept arbitrary file types, not just images.
// Extends the image map with common document types; unknown extensions fall
// back to application/octet-stream so any file can still be uploaded.
const ATTACHMENT_MIME_BY_EXTENSION = {
  ...MIME_BY_EXTENSION,
  pdf: "application/pdf",
  txt: "text/plain",
  log: "text/plain",
  csv: "text/csv",
  md: "text/markdown",
  json: "application/json",
  zip: "application/zip",
  doc: "application/msword",
  docx: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  xls: "application/vnd.ms-excel",
  xlsx: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
};

export function mimeForAttachment(filename) {
  const match = /\.([A-Za-z0-9]+)$/.exec(filename || "");
  if (!match) return "application/octet-stream";
  return ATTACHMENT_MIME_BY_EXTENSION[match[1].toLowerCase()] ?? "application/octet-stream";
}

// Validate notion-set-files-property input. Returns an error message string, or
// null when valid. Each files entry must carry exactly one of file_path (local
// upload) or url (external); external entries require a name.
export function validateSetFilesInput({ page_id, property_name, mode, files } = {}) {
  if (!page_id) return "page_id is required.";
  if (!property_name) return "property_name is required.";
  if (mode !== "replace" && mode !== "append") {
    return 'mode must be "replace" or "append".';
  }
  if (!Array.isArray(files)) return "files must be an array.";
  for (const f of files) {
    if (!f || typeof f !== "object") return "each files entry must be an object.";
    const hasPath = typeof f.file_path === "string" && f.file_path.length > 0;
    const hasUrl = typeof f.url === "string" && f.url.length > 0;
    if (hasPath && hasUrl) {
      return "each files entry needs exactly one of file_path or url, not both.";
    }
    if (!hasPath && !hasUrl) {
      return "each files entry needs file_path (local upload) or url (external).";
    }
    if (hasUrl && !(typeof f.name === "string" && f.name.length > 0)) {
      return "external (url) entries require a name.";
    }
  }
  return null;
}

// Convert a Notion files property's READ representation into the WRITE shape so
// existing entries can be round-tripped in append mode. external by url;
// file_upload by id; file-type (Notion-hosted) entries re-sent with their
// signed url.
//
// NOTE: Notion officially documents only the `file_upload` and `external` write
// shapes for a files property. The `type:"file"` round-trip below is
// undocumented-but-accepted today (verified live) and works only because the
// read-modify-write happens immediately, while the signed url is still valid
// (~1h). If Notion ever tightens write validation to reject the `file` shape,
// pre-existing hosted attachments would be silently dropped on append — re-fetch
// and diff after an append if that ever regresses.
export function toWritableFiles(entries) {
  return (entries || [])
    .map((e) => {
      if (!e || typeof e !== "object") return null;
      if (e.type === "external") {
        return { type: "external", name: e.name, external: { url: e.external?.url } };
      }
      if (e.type === "file") {
        return { type: "file", name: e.name, file: { url: e.file?.url } };
      }
      if (e.type === "file_upload") {
        return { type: "file_upload", name: e.name, file_upload: { id: e.file_upload?.id } };
      }
      return null;
    })
    .filter(Boolean);
}

// Validate notion-upload-image input: exactly one of file_path / external_url.
// Returns an error message string, or null when valid.
export function validateUploadInput({ file_path, external_url } = {}) {
  if (file_path && external_url) {
    return "Provide either file_path or external_url, not both.";
  }
  if (!file_path && !external_url) {
    return "Provide one of file_path (local image) or external_url (public image URL).";
  }
  return null;
}

// Normalize a Notion UUID for comparison (strip dashes, lowercase).
export function normalizeId(id) {
  return (id || "").replace(/-/g, "").toLowerCase();
}

// Apply a caller-supplied block_ids filter to collected images. Returns the
// matching images plus the requested IDs (as given by the caller) that matched
// nothing — so the response can report them instead of silently returning a
// smaller set.
export function filterByBlockIds(images, blockIds) {
  const wanted = new Map(blockIds.map((id) => [normalizeId(id), id]));
  const selected = (images || []).filter((img) => {
    const key = normalizeId(img.block_id);
    if (wanted.has(key)) {
      wanted.delete(key);
      return true;
    }
    return false;
  });
  return { selected, missing: [...wanted.values()] };
}

// Split one page of block-children results into image entries and container
// block IDs to recurse into. child_page / child_database are never descended
// into — images inside subpages belong to those pages, not this body.
export function collectImageBlocks(blocks) {
  const images = [];
  const containers = [];
  for (const block of blocks || []) {
    if (block.type === "image") {
      const image = block.image ?? {};
      images.push({
        block_id: block.id,
        source_type: image.type,
        url: image.type === "file" ? image.file?.url : image.external?.url,
        caption: (image.caption ?? [])
          .map((part) => part.plain_text ?? "")
          .join(""),
      });
    } else if (
      block.has_children &&
      block.type !== "child_page" &&
      block.type !== "child_database"
    ) {
      containers.push(block.id);
    }
  }
  return { images, containers };
}
