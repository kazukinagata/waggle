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

// ---------------------------------------------------------------------------
// notion-read-files-property
// ---------------------------------------------------------------------------

// Text-bearing MIME types whose content is returned inline. Everything else is
// written to disk and only the path is returned: a spreadsheet or a PDF is not
// useful as a wall of mojibake in the model's context, and inlining one costs
// tokens without conveying the file.
export const TEXTUAL_MIME_TYPES = new Set([
  "text/plain",
  "text/csv",
  "text/markdown",
  "text/html",
  "text/xml",
  "application/json",
  "application/xml",
  "application/x-yaml",
  "application/yaml",
]);

// Inline text is capped and truncation is reported. A 40MB log attached to a
// task must not silently become 40MB of context.
export const MAX_INLINE_TEXT_BYTES = 256 * 1024;

// Ceiling on a single downloaded attachment. Above this the entry is skipped
// with a reason rather than streamed to disk: an attachment this large is not
// a task requirement, and the caller asked to read a spec, not to mirror a blob.
export const MAX_DOWNLOAD_BYTES = 50 * 1024 * 1024;

// A signed URL is treated as expired this many ms before its stated expiry, so
// a download that starts just under the wire does not fail mid-transfer.
export const EXPIRY_SKEW_MS = 60 * 1000;

export function isTextualMime(mime) {
  if (!mime) return false;
  const base = String(mime).split(";")[0].trim().toLowerCase();
  if (TEXTUAL_MIME_TYPES.has(base)) return true;
  // text/* not enumerated above (e.g. text/tab-separated-values) is still text.
  return base.startsWith("text/");
}

// Validate notion-read-files-property input. Returns an error message string,
// or null when valid.
export function validateReadFilesInput({
  page_id,
  property_name,
  names,
  max_files,
  out_dir,
  metadata_only,
} = {}) {
  if (!page_id) return "page_id is required.";
  if (!property_name) return "property_name is required.";
  // names is validated rather than coerced. A plausible mistake — names: "spec.pdf"
  // instead of ["spec.pdf"] — would otherwise be neither an array nor undefined, so
  // the filter is skipped and the call silently widens from "read this one file" to
  // "download the first max_files attachments". Widening an operation because its
  // input was malformed is the wrong direction to fail in; refusing is not.
  if (names !== undefined && names !== null) {
    if (!Array.isArray(names)) {
      return "names must be an array of strings (a bare string is not accepted: use [\"name\"]).";
    }
    if (names.some((n) => typeof n !== "string" || n.length === 0)) {
      return "names must contain only non-empty strings.";
    }
  }
  if (max_files !== undefined) {
    if (typeof max_files !== "number" || !Number.isInteger(max_files) || max_files < 1) {
      return "max_files must be a positive integer.";
    }
  }
  if (out_dir !== undefined && out_dir !== null && (typeof out_dir !== "string" || out_dir.length === 0)) {
    return "out_dir must be a non-empty string.";
  }
  if (metadata_only !== undefined && metadata_only !== null && typeof metadata_only !== "boolean") {
    return "metadata_only must be a boolean.";
  }
  return null;
}

// Describe a raw Notion files-property entry without resolving its content.
//
// The `url` field is populated ONLY for external entries. A Notion-hosted entry
// carries a signed URL that is itself a bearer credential — anyone holding it
// can read the file until it expires — so it is deliberately dropped here and
// never travels to the caller, into a tool result, or into a log. An external
// entry's URL is a string the user typed into Notion and is visible in its UI,
// so returning it is safe, and returning it is also sufficient: the caller has
// a general-purpose fetcher and does not need this server to act as one.
export function describeFileEntry(entry, index) {
  const type = entry?.type;
  const name = entry?.name ?? null;
  if (type === "external") {
    return { index, name, source: "external", url: entry.external?.url ?? null };
  }
  if (type === "file" || type === "file_upload") {
    return { index, name, source: "notion_hosted", url: null };
  }
  return { index, name, source: "unknown", url: null };
}

// The signed URL of a Notion-hosted entry, or null. Kept separate from
// describeFileEntry so the value never rides along in a returned object by
// accident — a caller has to ask for it explicitly, and only the download path
// does.
export function hostedUrl(entry) {
  if (entry?.type === "file") return entry.file?.url ?? null;
  if (entry?.type === "file_upload") return entry.file_upload?.url ?? null;
  return null;
}

// True when a Notion-hosted entry's signed URL is expired or about to be.
// A missing expiry_time is treated as usable: Notion supplies it for hosted
// files, and refusing to try on its absence would break the tool on any shape
// change rather than degrading to one wasted request.
export function isExpired(entry, nowMs) {
  const raw = entry?.file?.expiry_time ?? entry?.file_upload?.expiry_time;
  if (!raw) return false;
  const at = Date.parse(raw);
  if (Number.isNaN(at)) return false;
  return at - EXPIRY_SKEW_MS <= nowMs;
}

// Select entries by display name. Returns { selected, missing } so a requested
// name that matches nothing is reported rather than silently yielding fewer
// files than the caller asked for.
export function filterByNames(entries, names) {
  const wanted = new Set(names.map((n) => String(n)));
  const seen = new Set();
  const selected = (entries || []).filter((e) => {
    if (wanted.has(e.name)) {
      seen.add(e.name);
      return true;
    }
    return false;
  });
  return { selected, missing: names.filter((n) => !seen.has(String(n))) };
}

// Guard the host a download may reach. The signed URL comes from Notion's own
// API response, but it is still followed with redirects, and a redirect is
// attacker-influenceable in a way the original URL is not. https only, and no
// private, loopback, or link-local destination — a download has no business
// reaching a host that is only reachable from inside this network.
// --- address classification -------------------------------------------------
//
// One predicate decides whether a download may reach an address, and it is used
// both for a literal in the URL and for an address a hostname resolves to, so the
// two cannot drift apart.
//
// IPv6 is expanded and inspected numerically rather than matched as a string. Two
// rounds of prefix-matching bugs came from doing it textually: `::ffff:127.0.0.1`
// is normalized by the URL parser to `::ffff:7f00:1`, and the un-prefixed
// IPv4-compatible form `::127.0.0.1` to `::7f00:1` — neither of which matches a
// naive `::ffff:` or `f[cd]`/`fe80`/`ff` test, so loopback and the cloud metadata
// address both sailed through. Expanding to eight groups and testing the numbers
// covers every spelling of every one of these at once. The prefixes that carry an
// embedded IPv4 address are enumerated explicitly below rather than claimed to be
// exhaustive — NAT64 was the fourth one found in this filter, and there is no
// reason to assume it is the last.

function isBlockedIpv4(a, b, c, d) {
  if ([a, b, c, d].some((o) => !Number.isInteger(o) || o < 0 || o > 255)) return true;
  if (a === 0 || a === 10 || a === 127) return true;      // this-host, private, loopback
  if (a === 192 && b === 168) return true;                // private
  if (a === 172 && b >= 16 && b <= 31) return true;       // private
  if (a === 169 && b === 254) return true;                // link-local, incl. metadata
  if (a === 100 && b >= 64 && b <= 127) return true;      // CGNAT
  if (a >= 224) return true;                              // multicast / reserved
  return false;
}

// Expand an IPv6 literal to eight 16-bit groups, or null if it is not one.
// Handles `::` compression and a trailing embedded dotted quad.
export function expandIpv6(input) {
  let host = String(input ?? "").trim().toLowerCase().replace(/^\[|\]$/g, "");
  if (!host.includes(":")) return null;
  host = host.replace(/%[^\]]*$/, ""); // drop any zone id

  // A trailing dotted quad becomes the final two groups.
  const dotted = /:(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(host);
  if (dotted) {
    const o = dotted.slice(1).map(Number);
    if (o.some((n) => n > 255)) return null;
    host = `${host.slice(0, dotted.index)}:${(((o[0] << 8) | o[1]) >>> 0).toString(16)}:${(((o[2] << 8) | o[3]) >>> 0).toString(16)}`;
  }

  const halves = host.split("::");
  if (halves.length > 2) return null;
  const head = halves[0] ? halves[0].split(":") : [];
  const tail = halves.length === 2 ? (halves[1] ? halves[1].split(":") : []) : [];
  let groups;
  if (halves.length === 2) {
    const fill = 8 - head.length - tail.length;
    if (fill < 0) return null;
    groups = [...head, ...Array(fill).fill("0"), ...tail];
  } else {
    groups = head;
  }
  if (groups.length !== 8) return null;
  const nums = groups.map((g) => (g === "" ? 0 : parseInt(g, 16)));
  if (nums.some((n) => !Number.isInteger(n) || Number.isNaN(n) || n < 0 || n > 0xffff)) return null;
  if (groups.some((g) => g !== "" && !/^[0-9a-f]{1,4}$/.test(g))) return null;
  return nums;
}

// Is this IP address one a download must never reach?
//
// Exported because the same rules apply to a literal in the URL and to an address
// the hostname resolves to; one predicate for both keeps them from diverging.
export function isBlockedAddress(addr) {
  if (!addr) return true;
  const host = String(addr).trim().toLowerCase().replace(/^\[|\]$/g, "");

  const v4 = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(host);
  if (v4) return isBlockedIpv4(...v4.slice(1).map(Number));

  const g = expandIpv6(host);
  if (g) {
    // An IPv4 address carried in the low 32 bits. Judge it by the IPv4 rules,
    // because that is the host the address names. Three prefixes put it there:
    //
    //   ::a.b.c.d        IPv4-compatible   (high 96 zero, group 5 == 0)
    //   ::ffff:a.b.c.d   IPv4-mapped       (high 96 zero, group 5 == 0xffff)
    //   64:ff9b::/96     NAT64 well-known prefix (RFC 6052 §2.1)
    //
    // `::` and `::1` land in the first case and are caught by the a === 0 rule.
    //
    // The NAT64 well-known prefix is unwrapped rather than blocked: on an IPv6-only
    // network a DNS64 resolver returns 64:ff9b::<v4> for a perfectly legitimate
    // public IPv4 host, so refusing the prefix would break downloads there. What
    // must not pass is 64:ff9b::7f00:1 — loopback wearing that prefix — and
    // unwrapping catches it for the same reason it catches ::ffff:7f00:1.
    //
    // Only /96 is unwrapped, and that is deliberate. RFC 6052 §2.2 stores the v4
    // address contiguously in the low 32 bits ONLY at /96; at every shorter prefix
    // length it is split around a mandatory-zero octet at bit 64. The well-known
    // prefix is defined at /96 (§2.1), so /96 is the only length that can appear
    // here without a network-specific prefix we could not know anyway.
    const embeddedV4 =
      (g[0] === 0 && g[1] === 0 && g[2] === 0 && g[3] === 0 && g[4] === 0 &&
       (g[5] === 0 || g[5] === 0xffff)) ||
      (g[0] === 0x0064 && g[1] === 0xff9b && g[2] === 0 && g[3] === 0 && g[4] === 0 && g[5] === 0);
    if (embeddedV4) {
      return isBlockedIpv4((g[6] >> 8) & 0xff, g[6] & 0xff, (g[7] >> 8) & 0xff, g[7] & 0xff);
    }

    // RFC 8215 reserves 64:ff9b:1::/48 for LOCAL-USE NAT64. Blocked wholesale
    // rather than decoded.
    //
    // Two reasons. It is a /48, so the embedded v4 address is split around the u
    // octet — loopback under it is 64:ff9b:1:7f00:0:100::, not 64:ff9b:1::7f00:1 —
    // and an earlier version of this code reused the /96 shape here, which meant a
    // genuinely encoded loopback fell straight through as allowed while only a
    // hand-written form no real gateway produces was caught. And the prefix is
    // local-use by definition: it is not globally routed, so unlike the well-known
    // prefix there is no legitimate public host behind it to preserve access to.
    // Refusing the range is both simpler and more correct than decoding it.
    if (g[0] === 0x0064 && g[1] === 0xff9b && g[2] === 0x0001) return true;
    if ((g[0] & 0xfe00) === 0xfc00) return true;   // fc00::/7  unique-local
    if ((g[0] & 0xffc0) === 0xfe80) return true;   // fe80::/10 link-local
    if ((g[0] & 0xff00) === 0xff00) return true;   // ff00::/8  multicast
    return false;
  }

  // Neither a v4 nor a v6 literal: not an address, so not this function's call.
  // A hostname is judged by what it resolves to (see assertPublicHost).
  return false;
}

// Syntactic check on a download URL: https, and not an obviously internal literal.
// This is the cheap half. A hostname that *resolves* to a private address passes it
// — see assertPublicHost in the server for the resolution check that closes that.
export function isAllowedDownloadUrl(raw) {
  let u;
  try {
    u = new URL(raw);
  } catch {
    return false;
  }
  if (u.protocol !== "https:") return false;
  const host = u.hostname.toLowerCase().replace(/^\[|\]$/g, "");
  if (host === "localhost" || host.endsWith(".localhost")) return false;
  return !isBlockedAddress(host);
}

// Filesystem-safe basename for a downloaded attachment. Notion names are
// user-authored, so a name like "../../etc/passwd" or "a/b.txt" must not decide
// where the file lands.
export function safeFilename(name, index) {
  const base = String(name ?? "").split(/[\\/]/).pop() ?? "";
  const cleaned = base.replace(/[\x00-\x1f<>:"|?*]/g, "_").replace(/^\.+/, "").trim();
  if (!cleaned) return `attachment-${index}`;
  return cleaned.length > 120 ? cleaned.slice(0, 120) : cleaned;
}

// Remove any URL from a string before it reaches the caller or a log. Error
// messages from the fetch layer routinely embed the URL that failed, and for a
// pre-signed attachment URL that means a credential in a transcript. Applied to
// every download error rather than to a known set of messages, because the set
// of messages is whatever the runtime decides to produce.
export function scrubUrls(text) {
  return String(text ?? "").replace(/\bhttps?:\/\/\S+/gi, "[url redacted]");
}

// Error marking an attachment that exceeds the download cap. Distinguishable from
// a transport failure so the caller reports the cap rather than a generic failure.
export function tooLargeError(maxBytes, sizeBytes) {
  const error = new Error(`attachment exceeds the ${maxBytes} byte cap`);
  error.code = "attachment_too_large";
  error.sizeBytes = sizeBytes;
  return error;
}

// Read a fetch Response body into a Buffer, enforcing maxBytes *while reading*.
//
// The cap has to be applied before the bytes are held, not after. Buffering the
// whole body and checking its length afterwards lets an oversized attachment
// exhaust this process's memory despite the advertised limit — the check would run
// only once the damage was done. Content-Length is consulted first because it lets
// us refuse without reading anything, but it is optional and self-reported, so the
// streaming limit is what actually enforces the cap.
export async function readCapped(response, maxBytes) {
  // A missing header must read as "unknown", not as zero: Number(null) is 0, which
  // is finite, so a naive conversion makes an absent Content-Length look like a
  // declared length of 0 — and the no-stream fallback below would then buffer an
  // unbounded body believing it had been told the size was safe.
  const rawLength = response.headers?.get?.("content-length");
  const declared = rawLength == null || rawLength === "" ? Number.NaN : Number(rawLength);
  if (Number.isFinite(declared) && declared > maxBytes) throw tooLargeError(maxBytes, declared);

  const body = response.body;
  if (!body || typeof body.getReader !== "function") {
    // No stream: buffering is only safe when a declared length says it is.
    if (!Number.isFinite(declared)) {
      throw new Error("response has neither a readable stream nor a Content-Length");
    }
    const buffer = Buffer.from(await response.arrayBuffer());
    if (buffer.length > maxBytes) throw tooLargeError(maxBytes, buffer.length);
    return buffer;
  }

  const reader = body.getReader();
  const chunks = [];
  let total = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > maxBytes) {
        await reader.cancel().catch(() => {});
        throw tooLargeError(maxBytes, total);
      }
      chunks.push(Buffer.from(value));
    }
  } finally {
    reader.releaseLock?.();
  }
  return Buffer.concat(chunks);
}

// Path-safe, collision-resistant filename for a downloaded attachment. The entry
// index prefixes the name because display names are not unique on a Notion files
// property: two attachments called "spec.pdf" would otherwise resolve to one path,
// so the second download would overwrite the first and both results would point at
// the same file. It also makes clobbering an unrelated pre-existing file in a
// caller-supplied out_dir far less likely.
export function attachmentFilename(name, index) {
  return `${String(index).padStart(2, "0")}-${safeFilename(name, index)}`;
}

// Decide an attachment's MIME type from the response header and the filename.
//
// The header is preferred but cannot simply be trusted when present: object storage
// routinely serves `application/octet-stream` for anything whose type was not set at
// upload time. Treating that as authoritative sends a .csv or .md attachment to disk
// as "binary" instead of returning it inline, so a generic or absent header falls
// back to the extension.
const GENERIC_MIME_TYPES = new Set([
  "application/octet-stream",
  "binary/octet-stream",
  "application/unknown",
  "*/*",
]);

export function resolveMime(headerValue, filename) {
  const base = String(headerValue ?? "").split(";")[0].trim().toLowerCase();
  if (base && !GENERIC_MIME_TYPES.has(base)) return base;
  return mimeForAttachment(filename);
}
