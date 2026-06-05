// Unit tests for the notion-extension server's pure helpers (no network, no
// NOTION_TOKEN). Run via run.sh; prints one ok/FAIL line per case and exits
// non-zero if any case fails.
import {
  MAX_READ_IMAGE_BYTES,
  MAX_UPLOAD_BYTES,
  READABLE_MIME_TYPES,
  collectImageBlocks,
  mimeFromFilename,
  normalizeId,
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

console.log("== constants ==");
check("readable: png/jpeg/gif/webp", ["image/png", "image/jpeg", "image/gif", "image/webp"].every((m) => READABLE_MIME_TYPES.has(m)));
check("svg not inline-readable", !READABLE_MIME_TYPES.has("image/svg+xml"));
check("read cap is 5MB", MAX_READ_IMAGE_BYTES === 5 * 1024 * 1024);
check("upload cap is 20MB", MAX_UPLOAD_BYTES === 20 * 1024 * 1024);

console.log("");
console.log(`PASS=${PASS} FAIL=${FAIL}`);
process.exit(FAIL === 0 ? 0 : 1);
