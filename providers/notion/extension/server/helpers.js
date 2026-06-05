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

export function mimeFromFilename(filename) {
  const match = /\.([A-Za-z0-9]+)$/.exec(filename || "");
  if (!match) return null;
  return MIME_BY_EXTENSION[match[1].toLowerCase()] ?? null;
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
