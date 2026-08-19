// Unit tests for the notion-extension server's pure helpers (no network, no
// NOTION_TOKEN). Run via run.sh; prints one ok/FAIL line per case and exits
// non-zero if any case fails.
import {
  EXPIRY_SKEW_MS,
  MAX_DOWNLOAD_BYTES,
  MAX_INLINE_TEXT_BYTES,
  MAX_READ_IMAGE_BYTES,
  MAX_UPLOAD_BYTES,
  READABLE_MIME_TYPES,
  apiErrorDetail,
  attachmentFilename,
  collectImageBlocks,
  describeFileEntry,
  filterByBlockIds,
  filterByNames,
  hostedUrl,
  isAllowedDownloadUrl,
  expandIpv6,
  isBlockedAddress,
  isExpired,
  isTextualMime,
  mimeForAttachment,
  mimeFromFilename,
  normalizeId,
  readCapped,
  resolveMime,
  safeFilename,
  scrubUrls,
  toWritableFiles,
  validateReadFilesInput,
  validateSetFilesInput,
  validateUploadInput,
} from "../../extension/server/helpers.js";

let PASS = 0;
let FAIL = 0;
function check(label, condition) {
  if (condition) {
    console.log(`ok    ${label}`);
    PASS += 1;
  } else {
    console.log(`FAIL  ${label}`);
    FAIL += 1;
  }
}

console.log("== mimeFromFilename ==");
check("png", mimeFromFilename("shot.png") === "image/png");
check("uppercase JPG", mimeFromFilename("photo.JPG") === "image/jpeg");
check("jpeg", mimeFromFilename("photo.jpeg") === "image/jpeg");
check("webp", mimeFromFilename("img.webp") === "image/webp");
check("svg", mimeFromFilename("icon.svg") === "image/svg+xml");
check("multi-dot name", mimeFromFilename("a.b.tiff") === "image/tiff");
check("unsupported ext -> null", mimeFromFilename("doc.pdf") === null);
check("no extension -> null", mimeFromFilename("README") === null);
check("empty -> null", mimeFromFilename("") === null);
check("undefined -> null", mimeFromFilename(undefined) === null);

console.log("== validateUploadInput ==");
check("file_path only -> valid", validateUploadInput({ file_path: "/tmp/a.png" }) === null);
check("external_url only -> valid", validateUploadInput({ external_url: "https://x/y.png" }) === null);
check(
  "both -> error",
  /not both/.test(validateUploadInput({ file_path: "/tmp/a.png", external_url: "https://x" }) ?? "")
);
check("neither -> error", /Provide one of/.test(validateUploadInput({}) ?? ""));
check("no args -> error", /Provide one of/.test(validateUploadInput() ?? ""));

console.log("== normalizeId ==");
check(
  "strips dashes + lowercases",
  normalizeId("32E23A46-1f6c-8192-B603-fbd32bf35c8e") === "32e23a461f6c8192b603fbd32bf35c8e"
);
check("empty input", normalizeId(undefined) === "");

console.log("== collectImageBlocks ==");
const blocks = [
  {
    id: "img-file",
    type: "image",
    has_children: false,
    image: {
      type: "file",
      file: { url: "https://s3.example/signed.png", expiry_time: "2026-06-05T06:00:00Z" },
      caption: [{ plain_text: "a " }, { plain_text: "mockup" }],
    },
  },
  {
    id: "img-external",
    type: "image",
    has_children: false,
    image: { type: "external", external: { url: "https://cdn.example/x.png" }, caption: [] },
  },
  { id: "toggle-1", type: "toggle", has_children: true },
  { id: "col-list", type: "column_list", has_children: true },
  { id: "sub-page", type: "child_page", has_children: true },
  { id: "sub-db", type: "child_database", has_children: true },
  { id: "para-1", type: "paragraph", has_children: false },
];
const { images, containers } = collectImageBlocks(blocks);
check("finds both image blocks", images.length === 2);
check("file image: signed url", images[0]?.url === "https://s3.example/signed.png");
check("file image: source_type", images[0]?.source_type === "file");
check("file image: caption joined", images[0]?.caption === "a mockup");
check("external image: url", images[1]?.url === "https://cdn.example/x.png");
check("external image: empty caption", images[1]?.caption === "");
check(
  "containers: toggle + column_list only",
  containers.length === 2 && containers.includes("toggle-1") && containers.includes("col-list")
);
check("child_page not descended into", !containers.includes("sub-page"));
check("child_database not descended into", !containers.includes("sub-db"));
check("empty input -> empty result", collectImageBlocks([]).images.length === 0);
check("undefined input -> empty result", collectImageBlocks(undefined).images.length === 0);
check(
  "image with missing url -> url undefined, still listed",
  collectImageBlocks([{ id: "x", type: "image", image: { type: "file" } }]).images[0].url === undefined
);

console.log("== filterByBlockIds ==");
const pool = [
  { block_id: "32e23a46-1f6c-8192-b603-fbd32bf35c8e" },
  { block_id: "aaaa1111-2222-3333-4444-555566667777" },
];
const f1 = filterByBlockIds(pool, ["32E23A461F6C8192B603FBD32BF35C8E"]);
check("dash-insensitive match", f1.selected.length === 1 && f1.selected[0].block_id === pool[0].block_id);
check("matched id not reported missing", f1.missing.length === 0);
const f2 = filterByBlockIds(pool, ["aaaa1111-2222-3333-4444-555566667777", "dead-beef"]);
check("partial match selects only existing", f2.selected.length === 1);
check("unmatched id reported as given", f2.missing.length === 1 && f2.missing[0] === "dead-beef");
const f3 = filterByBlockIds([], ["x"]);
check("empty pool -> all missing", f3.selected.length === 0 && f3.missing.length === 1);

console.log("== mimeForAttachment ==");
check("png (image)", mimeForAttachment("shot.png") === "image/png");
check("pdf", mimeForAttachment("spec.pdf") === "application/pdf");
check("csv", mimeForAttachment("data.csv") === "text/csv");
check("docx", mimeForAttachment("doc.docx") === "application/vnd.openxmlformats-officedocument.wordprocessingml.document");
check("uppercase PDF", mimeForAttachment("REPORT.PDF") === "application/pdf");
check("unknown ext -> octet-stream", mimeForAttachment("archive.rar") === "application/octet-stream");
check("no extension -> octet-stream", mimeForAttachment("LICENSE") === "application/octet-stream");
check("undefined -> octet-stream", mimeForAttachment(undefined) === "application/octet-stream");

console.log("== validateSetFilesInput ==");
check("file_path entry -> valid", validateSetFilesInput({ page_id: "p", property_name: "Attachments", mode: "replace", files: [{ file_path: "/tmp/a.pdf" }] }) === null);
check("url entry with name -> valid", validateSetFilesInput({ page_id: "p", property_name: "Attachments", mode: "append", files: [{ name: "spec", url: "https://x/y" }] }) === null);
check("empty files -> valid", validateSetFilesInput({ page_id: "p", property_name: "Attachments", mode: "replace", files: [] }) === null);
check("missing page_id -> error", /page_id/.test(validateSetFilesInput({ property_name: "A", mode: "replace", files: [] }) ?? ""));
check("missing property_name -> error", /property_name/.test(validateSetFilesInput({ page_id: "p", mode: "replace", files: [] }) ?? ""));
check("bad mode -> error", /replace.*append/.test(validateSetFilesInput({ page_id: "p", property_name: "A", mode: "merge", files: [] }) ?? ""));
check("files not array -> error", /must be an array/.test(validateSetFilesInput({ page_id: "p", property_name: "A", mode: "replace", files: "x" }) ?? ""));
check("entry with both file_path and url -> error", /not both/.test(validateSetFilesInput({ page_id: "p", property_name: "A", mode: "replace", files: [{ file_path: "/a", url: "https://x" }] }) ?? ""));
check("entry with neither -> error", /file_path .* or url/.test(validateSetFilesInput({ page_id: "p", property_name: "A", mode: "replace", files: [{ name: "x" }] }) ?? ""));
check("url entry without name -> error", /require a name/.test(validateSetFilesInput({ page_id: "p", property_name: "A", mode: "replace", files: [{ url: "https://x" }] }) ?? ""));

console.log("== toWritableFiles ==");
const readEntries = [
  { type: "external", name: "ext", external: { url: "https://cdn/x.pdf" } },
  { type: "file", name: "hosted", file: { url: "https://s3/signed.pdf", expiry_time: "2026-06-08T06:00:00Z" } },
  { type: "file_upload", name: "up", file_upload: { id: "u-1" } },
  { type: "unknown", name: "drop" },
];
const written = toWritableFiles(readEntries);
check("drops unknown types", written.length === 3);
check("external round-trips url", written[0].type === "external" && written[0].external.url === "https://cdn/x.pdf");
check("file strips expiry_time", written[1].type === "file" && written[1].file.url === "https://s3/signed.pdf" && written[1].file.expiry_time === undefined);
check("file_upload keeps id", written[2].type === "file_upload" && written[2].file_upload.id === "u-1");
check("empty input -> empty array", toWritableFiles([]).length === 0);
check("undefined input -> empty array", toWritableFiles(undefined).length === 0);

console.log("== apiErrorDetail ==");
check("json message wins", apiErrorDetail(400, { message: "Date type must be expanded", code: "validation_error" }) === "Date type must be expanded");
check("json code as fallback", apiErrorDetail(403, { code: "restricted_resource" }) === "restricted_resource");
check("403 without json -> WAF hint", /WAF/.test(apiErrorDetail(403, null)) && /\.zip/.test(apiErrorDetail(403, null)));
check("non-403 without json -> plain status", apiErrorDetail(502, null) === "HTTP 502");
check("json without message/code -> plain status", apiErrorDetail(500, { object: "error" }) === "HTTP 500");

console.log("== constants ==");
check("readable: png/jpeg/gif/webp", ["image/png", "image/jpeg", "image/gif", "image/webp"].every((m) => READABLE_MIME_TYPES.has(m)));
check("svg not inline-readable", !READABLE_MIME_TYPES.has("image/svg+xml"));
check("read cap is 5MB", MAX_READ_IMAGE_BYTES === 5 * 1024 * 1024);
check("upload cap is 20MB", MAX_UPLOAD_BYTES === 20 * 1024 * 1024);

console.log("== describeFileEntry: signed URLs must not escape ==");
// The whole point of this tool's design: a Notion-hosted entry's URL is a bearer
// credential, so it must not appear in anything returned to the caller. An
// external entry's URL is a string the user typed into Notion and is visible in
// its UI, so it is returned — and returning it is what makes fetching it here
// unnecessary.
const hosted = describeFileEntry(
  { type: "file", name: "spec.pdf", file: { url: "https://s3.example.com/x?X-Amz-Signature=SECRET" } },
  0
);
check("hosted entry: url is null", hosted.url === null);
check("hosted entry: no field anywhere holds the signature", !JSON.stringify(hosted).includes("SECRET"));
check("hosted entry: source is notion_hosted", hosted.source === "notion_hosted");
const uploadShape = describeFileEntry(
  { type: "file_upload", name: "a.bin", file_upload: { url: "https://s3.example.com/y?sig=SECRET" } },
  1
);
check("file_upload entry: url is null too", uploadShape.url === null && !JSON.stringify(uploadShape).includes("SECRET"));
const ext = describeFileEntry({ type: "external", name: "ref", external: { url: "https://ex.com/a" } }, 2);
check("external entry: url IS returned", ext.url === "https://ex.com/a");
check("external entry: source is external", ext.source === "external");
check("unknown type -> source unknown, url null", (() => {
  const u = describeFileEntry({ type: "wat", name: "x" }, 3);
  return u.source === "unknown" && u.url === null;
})());
check("hostedUrl reaches the url the describe shape hides", hostedUrl({ type: "file", file: { url: "https://s/1" } }) === "https://s/1");
check("hostedUrl on external -> null (never fetched by us)", hostedUrl({ type: "external", external: { url: "https://ex.com/a" } }) === null);

console.log("== scrubUrls ==");
check("strips an https url", scrubUrls("HTTP 403 fetching https://s3/x?sig=SECRET") === "HTTP 403 fetching [url redacted]");
check("strips http too", !/http:/.test(scrubUrls("failed http://a/b")));
check("strips every url in one message", (scrubUrls("https://a/1 and https://b/2").match(/\[url redacted\]/g) || []).length === 2);
check("leaves url-free text alone", scrubUrls("too many redirects") === "too many redirects");
check("handles null", scrubUrls(null) === "");

console.log("== isExpired ==");
const now = Date.parse("2026-08-20T12:00:00Z");
check("expiry well in the future -> usable", !isExpired({ type: "file", file: { expiry_time: "2026-08-20T13:00:00Z" } }, now));
check("already past -> expired", isExpired({ type: "file", file: { expiry_time: "2026-08-20T11:59:00Z" } }, now));
// A download starting 30s before expiry would fail mid-transfer; the skew makes
// that a refresh instead of a confusing 403.
check("inside the skew window -> treated as expired", isExpired({ type: "file", file: { expiry_time: "2026-08-20T12:00:30Z" } }, now));
check("just outside the skew -> usable", !isExpired({ type: "file", file: { expiry_time: "2026-08-20T12:02:00Z" } }, now));
check("missing expiry_time -> usable, not a hard failure", !isExpired({ type: "file", file: {} }, now));
check("unparseable expiry -> usable", !isExpired({ type: "file", file: { expiry_time: "not a date" } }, now));
check("skew is 60s", EXPIRY_SKEW_MS === 60 * 1000);

console.log("== isAllowedDownloadUrl ==");
check("https public host -> allowed", isAllowedDownloadUrl("https://prod-files.notion-static.com/a/b.pdf"));
check("http -> refused", !isAllowedDownloadUrl("http://prod-files.notion-static.com/a"));
check("localhost -> refused", !isAllowedDownloadUrl("https://localhost/a"));
check("sub.localhost -> refused", !isAllowedDownloadUrl("https://x.localhost/a"));
check("127.0.0.1 -> refused", !isAllowedDownloadUrl("https://127.0.0.1/a"));
check("10/8 -> refused", !isAllowedDownloadUrl("https://10.0.0.5/a"));
check("192.168/16 -> refused", !isAllowedDownloadUrl("https://192.168.1.1/a"));
check("172.16/12 -> refused", !isAllowedDownloadUrl("https://172.20.0.1/a"));
check("172.32 is public -> allowed", isAllowedDownloadUrl("https://172.32.0.1/a"));
check("169.254 link-local -> refused", !isAllowedDownloadUrl("https://169.254.169.254/latest/meta-data/"));
check("100.64 CGNAT -> refused", !isAllowedDownloadUrl("https://100.64.0.1/a"));
check("0.0.0.0 -> refused", !isAllowedDownloadUrl("https://0.0.0.0/a"));
check("IPv6 loopback -> refused", !isAllowedDownloadUrl("https://[::1]/a"));
check("IPv6 link-local -> refused", !isAllowedDownloadUrl("https://[fe80::1]/a"));
check("IPv6 unique-local -> refused", !isAllowedDownloadUrl("https://[fd00::1]/a"));
check("garbage -> refused", !isAllowedDownloadUrl("not a url"));
// IPv4-mapped IPv6 reaches the same host as the bare IPv4 address. Both spellings
// must be blocked: the URL parser normalizes the dotted form into hextets, so a
// check that only knew "::ffff:127.0.0.1" would pass "[::ffff:7f00:1]" to loopback.
check("mapped IPv6 loopback (dotted) -> refused", !isAllowedDownloadUrl("https://[::ffff:127.0.0.1]/a"));
check("mapped IPv6 loopback (hextet) -> refused", !isAllowedDownloadUrl("https://[::ffff:7f00:1]/a"));
check("mapped IPv6 private -> refused", !isAllowedDownloadUrl("https://[::ffff:10.0.0.1]/a"));
check("mapped IPv6 metadata IP -> refused", !isAllowedDownloadUrl("https://[::ffff:169.254.169.254]/a"));
check("mapped IPv6 public -> allowed", isAllowedDownloadUrl("https://[::ffff:8.8.8.8]/a"));
// IPv4-COMPATIBLE (no ffff group) is the sibling of the mapped form, and the URL
// parser normalizes it the same way: [::127.0.0.1] -> ::7f00:1, and
// [::169.254.169.254] -> ::a9fe:a9fe. Two rounds of prefix-matching bugs came from
// testing these as strings, which is why IPv6 is now expanded and judged numerically.
check("compat IPv6 loopback (dotted) -> refused", !isAllowedDownloadUrl("https://[::127.0.0.1]/a"));
check("compat IPv6 loopback (hextet) -> refused", !isAllowedDownloadUrl("https://[::7f00:1]/a"));
check("compat IPv6 metadata IP -> refused", !isAllowedDownloadUrl("https://[::169.254.169.254]/a"));
check("compat IPv6 metadata IP (hextet) -> refused", !isAllowedDownloadUrl("https://[::a9fe:a9fe]/a"));
check("compat IPv6 private -> refused", !isAllowedDownloadUrl("https://[::10.0.0.1]/a"));
check("real public IPv6 -> allowed", isAllowedDownloadUrl("https://[2606:4700::1111]/a"));
check("febf is still link-local -> refused", !isAllowedDownloadUrl("https://[febf::1]/a"));
check("fe70 is NOT link-local -> allowed", isAllowedDownloadUrl("https://[fe70::1]/a"));
check("IPv6 unspecified -> refused", !isAllowedDownloadUrl("https://[::]/a"));
check("fe80-febf link-local range -> refused", !isAllowedDownloadUrl("https://[feb0::1]/a"));
check("multicast -> refused", !isAllowedDownloadUrl("https://224.0.0.1/a"));
check("IPv6 multicast (ff02::1) -> refused", !isAllowedDownloadUrl("https://[ff02::1]/a"));
check("IPv6 multicast (ff05::1:3) -> refused", !isAllowedDownloadUrl("https://[ff05::1:3]/a"));
check("octet over 255 -> refused", !isAllowedDownloadUrl("https://999.1.1.1/a"));

console.log("== isBlockedAddress (same predicate for literals and resolved IPs) ==");
// One predicate covers a literal in the URL and an address the hostname resolves
// to, so the two rule sets cannot drift apart.
check("resolved loopback -> blocked", isBlockedAddress("127.0.0.53"));
check("resolved private -> blocked", isBlockedAddress("172.31.255.254"));
check("resolved public -> allowed", !isBlockedAddress("8.8.8.8"));
check("resolved CGNAT -> blocked", isBlockedAddress("100.100.1.1"));
check("resolved IPv6 multicast -> blocked", isBlockedAddress("ff02::1"));
check("resolved IPv6 unique-local -> blocked", isBlockedAddress("fd12:3456::1"));
check("resolved IPv6 public -> allowed", !isBlockedAddress("2606:4700::1111"));
check("172.32 is public -> allowed", !isBlockedAddress("172.32.0.1"));
check("empty/undefined -> blocked (fail closed)", isBlockedAddress("") && isBlockedAddress(undefined));
check("resolved compat-IPv6 metadata -> blocked", isBlockedAddress("::a9fe:a9fe"));
check("resolved mapped-IPv6 loopback -> blocked", isBlockedAddress("::ffff:7f00:1"));
check("zone id ignored", isBlockedAddress("fe80::1%eth0"));
// A hostname is not an address: this predicate returns false and assertPublicHost
// decides by resolving it. Returning true here would refuse every real download.
check("hostname is not judged here", !isBlockedAddress("prod-files.notion-static.com"));

console.log("== expandIpv6 ==");
check("full form", expandIpv6("2001:db8:0:0:0:0:0:1")?.length === 8);
check("compressed", JSON.stringify(expandIpv6("::1")) === JSON.stringify([0, 0, 0, 0, 0, 0, 0, 1]));
check("all-zero", JSON.stringify(expandIpv6("::")) === JSON.stringify([0, 0, 0, 0, 0, 0, 0, 0]));
check("dotted tail folded into two groups", JSON.stringify(expandIpv6("::ffff:127.0.0.1")) === JSON.stringify([0, 0, 0, 0, 0, 0xffff, 0x7f00, 1]));
check("compat dotted tail", JSON.stringify(expandIpv6("::127.0.0.1")) === JSON.stringify([0, 0, 0, 0, 0, 0, 0x7f00, 1]));
check("brackets tolerated", expandIpv6("[::1]") !== null);
check("plain IPv4 is not IPv6", expandIpv6("127.0.0.1") === null);
check("two :: is invalid", expandIpv6("::1::2") === null);
check("too many groups is invalid", expandIpv6("1:2:3:4:5:6:7:8:9") === null);
check("non-hex group is invalid", expandIpv6("::zz") === null);
check("dotted octet over 255 is invalid", expandIpv6("::ffff:999.1.1.1") === null);
check("file: -> refused", !isAllowedDownloadUrl("file:///etc/passwd"));

console.log("== safeFilename ==");
check("plain name kept", safeFilename("spec.pdf", 0) === "spec.pdf");
// Notion display names are user-authored, so they must not decide the path.
check("traversal stripped", safeFilename("../../etc/passwd", 0) === "passwd");
check("backslash path stripped", safeFilename("a\\b\\c.txt", 0) === "c.txt");
check("leading dots stripped", safeFilename("...hidden", 0) === "hidden");
check("control chars replaced", !/\x00/.test(safeFilename("a\x00b.txt", 0)));
check("empty -> indexed fallback", safeFilename("", 7) === "attachment-7");
check("null -> indexed fallback", safeFilename(null, 2) === "attachment-2");
check("only-separators -> indexed fallback", safeFilename("///", 1) === "attachment-1");
check("very long name truncated", safeFilename("x".repeat(300), 0).length === 120);

console.log("== isTextualMime ==");
check("text/plain", isTextualMime("text/plain"));
check("csv with charset param", isTextualMime("text/csv; charset=utf-8"));
check("application/json", isTextualMime("application/json"));
check("yaml", isTextualMime("application/x-yaml"));
check("unenumerated text/* still text", isTextualMime("text/tab-separated-values"));
check("uppercase", isTextualMime("TEXT/PLAIN"));
check("pdf is not text", !isTextualMime("application/pdf"));
check("png is not text", !isTextualMime("image/png"));
check("octet-stream is not text", !isTextualMime("application/octet-stream"));
check("null/undefined", !isTextualMime(null) && !isTextualMime(undefined));

console.log("== resolveMime ==");
// Object storage routinely serves application/octet-stream for anything whose type
// was not set at upload. Trusting a present-but-generic header sends a .csv to disk
// as binary instead of returning it inline, which is the documented contract.
check("specific header wins", resolveMime("text/csv", "data.bin") === "text/csv");
check("header params stripped", resolveMime("text/csv; charset=utf-8", "x") === "text/csv");
check("octet-stream falls back to the extension", resolveMime("application/octet-stream", "notes.md") === "text/markdown");
check("binary/octet-stream also generic", resolveMime("binary/octet-stream", "data.csv") === "text/csv");
check("*/* also generic", resolveMime("*/*", "a.txt") === "text/plain");
check("missing header falls back", resolveMime(null, "a.json") === "application/json");
check("empty header falls back", resolveMime("", "a.txt") === "text/plain");
check("generic header + unknown extension -> octet-stream", resolveMime("application/octet-stream", "a.weird") === "application/octet-stream");
check("uppercase header normalized", resolveMime("TEXT/CSV", "x") === "text/csv");
// The end-to-end property that matters: a text file served generically is inline.
check("octet-stream .csv is treated as text", isTextualMime(resolveMime("application/octet-stream", "targets.csv")));
check("octet-stream .pdf is still not text", !isTextualMime(resolveMime("application/octet-stream", "spec.pdf")));

console.log("== filterByNames ==");
const entries = [
  { type: "file", name: "a.txt" },
  { type: "external", name: "b" },
  { type: "file", name: "c.pdf" },
];
check("selects requested", filterByNames(entries, ["a.txt", "c.pdf"]).selected.length === 2);
// A requested name that matches nothing must be reported, not silently dropped —
// otherwise the caller reads 2 of 3 files and believes it read everything.
check("reports a name matching nothing", filterByNames(entries, ["a.txt", "nope"]).missing[0] === "nope");
check("no missing when all match", filterByNames(entries, ["b"]).missing.length === 0);
check("empty names selects nothing", filterByNames(entries, []).selected.length === 0);

console.log("== validateReadFilesInput ==");
check("valid minimal", validateReadFilesInput({ page_id: "p", property_name: "Attachments" }) === null);
check("missing page_id", /page_id/.test(validateReadFilesInput({ property_name: "A" })));
check("missing property_name", /property_name/.test(validateReadFilesInput({ page_id: "p" })));
check("max_files 0 rejected", /max_files/.test(validateReadFilesInput({ page_id: "p", property_name: "A", max_files: 0 })));
check("max_files non-integer rejected", /max_files/.test(validateReadFilesInput({ page_id: "p", property_name: "A", max_files: 1.5 })));
check("max_files string rejected", /max_files/.test(validateReadFilesInput({ page_id: "p", property_name: "A", max_files: "3" })));
check("max_files omitted is fine", validateReadFilesInput({ page_id: "p", property_name: "A" }) === null);
// names is validated, not coerced. `names: "spec.pdf"` is a plausible mistake, and
// accepting it skips the filter — silently widening "read this one file" into
// "download the first max_files attachments". Failing in the widening direction on
// malformed input is the wrong way round.
check("bare string names rejected", /names must be an array/.test(validateReadFilesInput({ page_id: "p", property_name: "A", names: "spec.pdf" })));
check("non-string element rejected", /non-empty strings/.test(validateReadFilesInput({ page_id: "p", property_name: "A", names: ["a", 7] })));
check("empty-string element rejected", /non-empty strings/.test(validateReadFilesInput({ page_id: "p", property_name: "A", names: ["a", ""] })));
check("object names rejected", /names must be an array/.test(validateReadFilesInput({ page_id: "p", property_name: "A", names: { 0: "a" } })));
check("valid names array accepted", validateReadFilesInput({ page_id: "p", property_name: "A", names: ["a.txt"] }) === null);
check("explicitly empty names array accepted", validateReadFilesInput({ page_id: "p", property_name: "A", names: [] }) === null);
check("names null treated as omitted", validateReadFilesInput({ page_id: "p", property_name: "A", names: null }) === null);
check("non-string out_dir rejected", /out_dir/.test(validateReadFilesInput({ page_id: "p", property_name: "A", out_dir: 5 })));
check("non-boolean metadata_only rejected", /metadata_only/.test(validateReadFilesInput({ page_id: "p", property_name: "A", metadata_only: "yes" })));
check("valid out_dir and metadata_only accepted", validateReadFilesInput({ page_id: "p", property_name: "A", out_dir: "/tmp/x", metadata_only: true }) === null);

console.log("== read-files constants ==");
check("inline text cap is 256KB", MAX_INLINE_TEXT_BYTES === 256 * 1024);
check("download cap is 50MB", MAX_DOWNLOAD_BYTES === 50 * 1024 * 1024);

console.log("== attachmentFilename ==");
// Display names are not unique on a Notion files property. Two entries called
// "spec.pdf" must not resolve to one path, or the second download overwrites the
// first and both results point at the same file.
check("index prefixes the name", attachmentFilename("spec.pdf", 0) === "00-spec.pdf");
check("same name, different index -> different path", attachmentFilename("spec.pdf", 0) !== attachmentFilename("spec.pdf", 1));
check("traversal still stripped", attachmentFilename("../../etc/passwd", 3) === "03-passwd");
check("empty name still gets a filename", attachmentFilename("", 4) === "04-attachment-4");
check("index zero-padded for sort order", attachmentFilename("a.bin", 7).startsWith("07-"));

console.log("== readCapped ==");
// Build a Response-like object with a real ReadableStream body.
function fakeResponse(chunks, headers = {}) {
  const encoded = chunks.map((c) => (typeof c === "string" ? Buffer.from(c) : c));
  let i = 0;
  return {
    headers: { get: (k) => headers[k.toLowerCase()] ?? null },
    body: {
      getReader: () => ({
        read: async () => (i < encoded.length ? { done: false, value: encoded[i++] } : { done: true }),
        cancel: async () => {},
        releaseLock: () => {},
      }),
    },
    arrayBuffer: async () => Buffer.concat(encoded),
  };
}
async function throws(fn, code) {
  try {
    await fn();
    return false;
  } catch (error) {
    return code ? error.code === code : true;
  }
}

const smallBody = await readCapped(fakeResponse(["hello ", "world"]), 1024);
check("streams a small body", smallBody.toString() === "hello world");
check("no content-length needed when a stream is present", smallBody.length === 11);

// A declared length over the cap is refused before a byte is read.
check(
  "declared content-length over cap -> attachment_too_large",
  await throws(() => readCapped(fakeResponse(["x"], { "content-length": "999999" }), 10), "attachment_too_large")
);

// The streaming limit is what actually enforces the cap: Content-Length is optional
// and self-reported, so a body that lies about (or omits) its size must still be
// stopped mid-read rather than buffered in full and measured afterwards.
check(
  "stream exceeding cap with no content-length -> attachment_too_large",
  await throws(() => readCapped(fakeResponse(["aaaaa", "bbbbb", "ccccc"]), 8), "attachment_too_large")
);
check(
  "stream exceeding cap while UNDER-declaring its length -> still stopped",
  await throws(() => readCapped(fakeResponse(["aaaaa", "bbbbb"], { "content-length": "2" }), 8), "attachment_too_large")
);
// Exactly at the cap is allowed; one byte over is not.
check("body exactly at the cap is accepted", (await readCapped(fakeResponse(["12345678"]), 8)).length === 8);
check(
  "body one byte over the cap is rejected",
  await throws(() => readCapped(fakeResponse(["123456789"]), 8), "attachment_too_large")
);
// No stream and no length: there is no safe way to buffer, so refuse rather than
// read an unbounded body.
check(
  "no stream and no content-length -> refused, not buffered",
  await throws(() => readCapped({ headers: { get: () => null }, arrayBuffer: async () => Buffer.from("x") }, 10))
);
check(
  "no stream but a safe content-length -> buffered",
  (await readCapped({ headers: { get: (k) => (k === "content-length" ? "3" : null) }, arrayBuffer: async () => Buffer.from("abc") }, 10)).toString() === "abc"
);

console.log("");
console.log(`PASS=${PASS} FAIL=${FAIL}`);
process.exit(FAIL === 0 ? 0 : 1);
