// Unit tests for the notion-extension server's pure helpers (no network, no
// NOTION_TOKEN). Run via run.sh; prints one ok/FAIL line per case and exits
// non-zero if any case fails.
import {
  MAX_READ_IMAGE_BYTES,
  MAX_UPLOAD_BYTES,
  READABLE_MIME_TYPES,
  collectImageBlocks,
  filterByBlockIds,
  mimeForAttachment,
  mimeFromFilename,
  normalizeId,
  toWritableFiles,
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

console.log("== constants ==");
check("readable: png/jpeg/gif/webp", ["image/png", "image/jpeg", "image/gif", "image/webp"].every((m) => READABLE_MIME_TYPES.has(m)));
check("svg not inline-readable", !READABLE_MIME_TYPES.has("image/svg+xml"));
check("read cap is 5MB", MAX_READ_IMAGE_BYTES === 5 * 1024 * 1024);
check("upload cap is 20MB", MAX_UPLOAD_BYTES === 20 * 1024 * 1024);

console.log("");
console.log(`PASS=${PASS} FAIL=${FAIL}`);
process.exit(FAIL === 0 ? 0 : 1);
