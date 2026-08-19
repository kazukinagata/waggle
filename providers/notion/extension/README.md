# notion-extension Desktop Extension

MCP server for Notion database operations that the hosted Notion MCP cannot handle:
- **Query** with people property filters (e.g., Assignee)
- **Update relation properties** (e.g., Blocked By, Parent Task) with replace/append modes
- **Upload images** into a page body (local file via the Notion File Upload API, or external URL)
- **Read images** from a page body as inline image content the model can see
- **Set files properties** (e.g., Attachments) from local files and/or external URLs with replace/append modes

## Build

```bash
cd providers/notion/extension
npm install
npx @anthropic-ai/mcpb pack .
```

This produces `extension.mcpb` (named after the directory).

## Install

Open the `.mcpb` file in Claude Desktop or Cowork. You will be prompted to enter your Notion internal integration token.

### Creating the token

1. Go to https://www.notion.so/profile/integrations
2. Click **New integration**
3. Capabilities: **Read content**, **Update content**, and **Insert content**
   (Insert content is required for `notion-upload-image` — without it Notion
   returns `403 restricted_resource` when appending blocks)
4. Copy the token (`ntn_...`)
5. In Notion, open your **Waggle** page → **⋯** → **Connections** → connect the integration

## Tool: notion-query

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `database_id` | string | yes | Notion database UUID |
| `filter` | object | no | Notion filter object |
| `sorts` | array | no | Notion sorts array |

Returns `{"results": [...]}` with full page objects across all pages (pagination handled automatically).

### Filter examples

```json
// Tasks assigned to a user
{"property":"Assignee","people":{"contains":"<user_id>"}}

// Ready tasks by assignee
{"and":[{"property":"Status","select":{"equals":"Ready"}},{"property":"Assignee","people":{"contains":"<user_id>"}}]}
```

## Tool: notion-update-relation

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `page_id` | string | yes | Notion page UUID to update |
| `property_name` | string | yes | Relation property name (e.g., "Blocked By") |
| `mode` | string | yes | `"replace"` or `"append"` |
| `relation_ids` | string[] | no | Page IDs for the relation (default: `[]`) |

- **replace**: Sets the relation to exactly the provided IDs. Empty array clears the relation.
- **append**: Merges with existing relation values and deduplicates. Empty array is a no-op (returns the existing relation IDs without writing). To clear the relation use `mode: "replace"` with `relation_ids: []`.

Returns a minimal confirmation echo:

```json
{
  "ok": true,
  "page_id": "<uuid>",
  "property_name": "Blocked By",
  "mode": "append",
  "relation_ids": ["<id1>", "<id2>", "<id3>"]
}
```

`relation_ids` is the **post-update final state** of the relation (for `append`, this is the merged + deduplicated list). If callers need other page fields (properties, `last_edited_time`, `archived`), fetch the page separately via `notion-fetch` or `notion-query`. This shape was chosen over returning the full Page object to keep MCP tool output small — relation updates are frequent in Waggle workflows.

### Examples

```json
// Set Blocked By to multiple tasks
{"page_id":"<page_id>","property_name":"Blocked By","mode":"replace","relation_ids":["<id1>","<id2>"]}

// Append a blocker
{"page_id":"<page_id>","property_name":"Blocked By","mode":"append","relation_ids":["<new_id>"]}

// Clear a relation
{"page_id":"<page_id>","property_name":"Blocked By","mode":"replace","relation_ids":[]}
```

## Tool: notion-upload-image

Appends an image block to a page body. Requires the integration's **Insert content** capability.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `page_id` | string | yes | Notion page (or block) UUID to append the image to |
| `file_path` | string | one of | Absolute path to a local image file. Uploaded via the Notion File Upload API (single-part, max 20MB; free workspaces are capped lower by Notion). Mutually exclusive with `external_url`. |
| `external_url` | string | one of | Publicly reachable image URL, embedded as an external image block (no upload). Mutually exclusive with `file_path`. |
| `caption` | string | no | Caption text for the image block |

Supported file extensions: png, jpg, jpeg, gif, webp, svg, bmp, tif, tiff, heic, ico.

Returns a minimal confirmation echo:

```json
{"ok": true, "page_id": "<uuid>", "block_id": "<uuid>", "image_type": "file_upload", "filename": "screenshot.png"}
```

`image_type` is `"file_upload"` for local files and `"external"` for URLs.

### Examples

```json
// Paste a local screenshot
{"page_id":"<page_id>","file_path":"/tmp/screenshot.png","caption":"build failure"}

// Embed an external image
{"page_id":"<page_id>","external_url":"https://example.com/mockup.png"}
```

## Tool: notion-read-images

Reads images from a page body and returns them as **inline image content** the model can see directly — no URL handling needed (Notion's `file`-type URLs are signed and expire after ~1 hour; this tool downloads them immediately).

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `page_id` | string | yes | Notion page (or block) UUID to read images from |
| `max_images` | integer | no | Max images returned inline (default 10, max 20). Overflow is listed in `skipped`. |
| `block_ids` | string[] | no | Only return images whose block ID is in this list (with or without dashes) |
| `include_nested` | boolean | no | Recurse into container blocks (toggles, columns, callouts), depth capped at 3. Default `true`. Child pages/databases are never descended into. |

The response is a mixed content array: first a text part with a JSON summary, then the image parts in the same order as the summary's `images` array:

```json
{
  "count": 2,
  "total_found": 3,
  "images": [
    {"index": 0, "block_id": "<uuid>", "mime_type": "image/png", "size_bytes": 48211, "caption": "mockup", "source_type": "file"}
  ],
  "skipped": [
    {"block_id": "<uuid>", "mime_type": "image/svg+xml", "url": "https://...", "reason": "not a raster type the model can view inline (png/jpeg/gif/webp)"}
  ]
}
```

Images over 5MB, non-raster types (svg, tiff, heic), and requested `block_ids` that match no image block are listed in `skipped` (with a reason) instead of returned inline. `total_found` always counts every image discovered on the page before filtering.

## Tool: notion-read-files-property

Reads the **contents** of a Notion files-type page property. The mirror of `notion-set-files-property`: the write side has existed since v2.13.0, the read side did not, so an executor holding only a task could see *that* a file was attached but never what it said.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `page_id` | string | yes | Notion page UUID to read from |
| `property_name` | string | yes | files-type property name (e.g., "Attachments") |
| `names` | string[] | no | Display names to read. **Omit** to read every entry up to `max_files`; an explicitly empty list selects nothing. |
| `max_files` | number | no | Maximum entries to retrieve (default 5) |
| `out_dir` | string | no | Directory for downloaded non-text files. Defaults to a **fresh private directory** created per invocation under the system temp dir. |
| `metadata_only` | boolean | no | List entries without retrieving content (default `false`) |

Works on any files-type property, not only a waggle Tasks DB.

### Two kinds of entry, handled differently

A Notion files property holds two things, and the difference decides the behavior:

| Entry | Where the bytes live | What this tool does |
|---|---|---|
| **Notion-hosted** (`type: file` / `file_upload`, from an upload) | Notion's storage, reachable only through a **signed URL that expires after ~1h** | Fetches it and returns the content. This is the case that needed a tool. |
| **External** (`type: external`, a URL someone pasted) | Not in Notion at all — Notion stores only the URL | **Not fetched.** Returns the name and URL so the caller can fetch it with a general-purpose tool. |

Not fetching external URLs is deliberate. The bytes were never in Notion, the URL is not a secret (it is visible in Notion's own UI), and the caller already has a general-purpose fetcher — there is no reason for this server to become one, and every reason not to make it reach arbitrary hosts.

### Signed URLs are treated as credentials

A Notion-hosted entry resolves to a pre-signed storage URL. Possession *is* authorization, for about an hour. So:

- **The URL is never returned.** Not in the result, not in an error message, not in a log line. Entries are identified by name and index. Download errors are scrubbed of any URL before they surface, because the fetch layer routinely embeds the failing URL in its own messages.
- **The Notion token is never sent to it.** The URL points at Notion's storage host, not `api.notion.com`; the signature is the authorization, and attaching a bearer token would hand the integration credential to a host with no business holding it.
- **Expiry is checked before fetching**, with a 60s skew so a download does not fail mid-transfer. If any selected entry has an expired URL, the page is re-retrieved **once** and *every* selected entry is remapped from the fresh list, keyed on the stored entry index rather than the display name (names are not unique, so a name-keyed remap maps every duplicate onto the first match and returns one attachment's contents several times) — refreshing only the entry being looked at left a second expired attachment in the same call reported as expired despite a usable URL having just been fetched.
- **Redirects are followed manually**, up to 5 hops, re-checking each. The first URL comes from Notion; a redirect target does not, so every hop is validated twice over: syntactically (https only, and not an internal literal — including IPv4-mapped IPv6, since the URL parser rewrites `::ffff:127.0.0.1` into hextets and a naive check would pass it to loopback), and by **resolving the hostname** and rejecting it if any address lands in loopback, private, link-local, CGNAT, or multicast space — IPv4 and IPv6 alike.

  Residual risk, stated rather than papered over: the resolution check is a check-then-connect, so a name that resolves differently between the lookup and the fetch (DNS rebinding) is not prevented. Closing that needs pinning the resolved address into the connection through a custom agent. What is closed is the straightforward path — a redirect to an internal literal, or to a name that simply points at one.
- **Display names never decide the path.** A name like `../../etc/passwd` is reduced to its basename before it is joined with `out_dir`.
- **The default download directory is created with `mkdtemp`, 0700, per invocation** — not a predictable `notion-attachments-<page_id>` path. A predictable path in a shared temp directory lets another local user pre-create it and plant a symlink at the filename about to be written, turning a download into an overwrite of any file this process can write. It also stops one invocation from overwriting an earlier one's downloads for the same page.
- **Files are created exclusively (`O_EXCL`), never overwritten.** This tool does not replace a file it did not create, and the exclusive flag also refuses to follow a planted symlink. In a caller-supplied `out_dir`, a pre-existing file at the target path is reported in the result rather than silently replaced.
- **Each download hop carries a 120s abort budget**, so a stalled storage host or redirect target cannot block the MCP request for as long as the peer keeps the socket open. It is a separate, longer budget than the 30s used for API calls — this covers transferring up to the 50MB cap, not a JSON round trip — and it does not reuse the shared timeout helper, because that helper names the URL in its timeout message and here the URL is a credential.

### Delivery

- **Text-bearing** (`text/*`, `application/json`, `application/xml`, yaml): returned inline as content, capped at 256KB with truncation reported in the summary. A 40MB log must not silently become 40MB of context. The type comes from the response header, except that a **generic** header (`application/octet-stream` and friends) falls back to the filename extension — object storage routinely serves that for anything whose type was not set at upload, and trusting it would send a `.csv` to disk as binary.
- **Everything else**: written under `out_dir`; only the local path is returned. A PDF or spreadsheet inlined as bytes costs tokens without conveying the file. The filename is prefixed with the entry index (`00-spec.pdf`), because display names are not unique on a Notion files property — two entries called `spec.pdf` would otherwise resolve to one path and the second download would overwrite the first.
- Entries over 50MB, unrecognized entry types, and requested `names` that match nothing are reported with a reason instead of being silently dropped. The size cap is enforced **while reading** — refused up front on a declared `Content-Length`, and otherwise stopped mid-stream — so an oversized attachment cannot exhaust the extension process's memory on its way to being rejected.

The response is a JSON summary followed by one text part per inline file:

```json
{
  "ok": true,
  "page_id": "<uuid>",
  "property_name": "Attachments",
  "total_found": 3,
  "files": [
    {"index": 0, "name": "targets.csv", "source": "notion_hosted", "url": null,
     "retrieved": true, "delivery": "inline", "mime_type": "text/csv", "size_bytes": 812, "truncated": false},
    {"index": 1, "name": "spec.pdf", "source": "notion_hosted", "url": null,
     "retrieved": true, "delivery": "file", "path": "/tmp/notion-attachments-<uuid>/spec.pdf",
     "mime_type": "application/pdf", "size_bytes": 148213},
    {"index": 2, "name": "Figma board", "source": "external", "url": "https://www.figma.com/file/...",
     "retrieved": false, "reason": "external entry; fetch the url with a general-purpose tool"}
  ],
  "skipped": []
}
```

Note `"url": null` on both hosted entries. That is the signed URL being withheld, not a missing value.

### A tool is not a substitute for a readable spec

waggle's protocol requires a task to be self-contained: an executor holding only the task's fields must be able to tell what is required without opening an attachment. This tool makes an attachment *reachable*; it does not make a spec that lives inside one reviewable or hashable, and the quality reviewer judges the spec, not the attachment. Inline text-bearing attachments into the page body and summarize what a binary one establishes — then use this tool for the detail.

## Tool: notion-set-files-property

Sets or appends files on a Notion **files-type page property** (e.g. `Attachments`). `notion-update-page` cannot set files properties — use this tool. Local-file uploads require the integration's **Insert content** capability.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `page_id` | string | yes | Notion page UUID to update |
| `property_name` | string | yes | files-type property name (e.g., "Attachments") |
| `mode` | string | yes | `"replace"` or `"append"` |
| `files` | object[] | no | File entries (default: `[]`). Each is `{ file_path }` (local upload) or `{ name, url }` (external; `name` required). |

- **replace**: sets the property to exactly the provided files. Empty array clears the property.
- **append**: merges with existing entries (read-modify-write). Empty array is a no-op (returns existing without writing).

Each `files` entry carries exactly one of `file_path` (a local file uploaded via the Notion File Upload API, max 20MB single-part) or `url` (an external file stored as-is). For `file_path`, `name` defaults to the basename.

Returns the post-update file list in read shape. Uploaded entries get a Notion-hosted **signed URL that expires after ~1 hour**; external entries keep their stable URL:

```json
{
  "ok": true,
  "page_id": "<uuid>",
  "property_name": "Attachments",
  "mode": "append",
  "files": [
    {"name": "spec.pdf", "url": "https://prod-files.notion-static.com/...signed..."},
    {"name": "Figma board", "url": "https://www.figma.com/file/..."}
  ]
}
```

### Examples

```json
// Attach a local file (replace)
{"page_id":"<page_id>","property_name":"Attachments","mode":"replace","files":[{"file_path":"/tmp/spec.pdf"}]}

// Append an external link
{"page_id":"<page_id>","property_name":"Attachments","mode":"append","files":[{"name":"Figma board","url":"https://www.figma.com/file/..."}]}

// Clear the property
{"page_id":"<page_id>","property_name":"Attachments","mode":"replace","files":[]}
```
