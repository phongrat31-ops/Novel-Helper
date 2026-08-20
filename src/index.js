// Cloudflare Worker entry point.
// Serves the static app (public/) and implements the same JSON API contract
// as the local server.ps1 (GET/POST /api/data, POST /api/upload, GET /uploads/:key),
// backed by D1 (binding "DB") and R2 (binding "UPLOADS") instead of the local filesystem.

async function handleGetData(env) {
  const row = await env.DB.prepare("SELECT content FROM data WHERE id = 1").first();
  const body = row ? row.content : "null";
  return new Response(body, {
    headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" },
  });
}

async function handlePostData(request, env) {
  const text = await request.text();
  try {
    JSON.parse(text);
  } catch (e) {
    return new Response(JSON.stringify({ ok: false, error: "invalid json" }), {
      status: 400,
      headers: { "Content-Type": "application/json; charset=utf-8" },
    });
  }
  await env.DB.prepare(
    "INSERT INTO data (id, content) VALUES (1, ?1) ON CONFLICT(id) DO UPDATE SET content = ?1"
  ).bind(text).run();
  return new Response(JSON.stringify({ ok: true }), {
    headers: { "Content-Type": "application/json; charset=utf-8" },
  });
}

async function handleUpload(request, env) {
  let rawName = "file";
  try {
    rawName = decodeURIComponent(request.headers.get("X-File-Name") || "file");
  } catch (e) {}
  const safeName = rawName.replace(/[\\/:*?"<>|]/g, "_").trim() || "file";
  const id = crypto.randomUUID().replace(/-/g, "").slice(0, 10);
  const key = `${id}_${safeName}`;

  const bytes = await request.arrayBuffer();
  const contentType = request.headers.get("Content-Type") || "application/octet-stream";
  await env.UPLOADS.put(key, bytes, { httpMetadata: { contentType } });

  return new Response(JSON.stringify({ ok: true, url: `/uploads/${key}`, name: rawName }), {
    headers: { "Content-Type": "application/json; charset=utf-8" },
  });
}

async function handleServeUpload(key, env) {
  const obj = await env.UPLOADS.get(key);
  if (!obj) return new Response("Not found", { status: 404 });
  const headers = new Headers();
  obj.writeHttpMetadata(headers);
  headers.set("etag", obj.httpEtag);
  headers.set("Cache-Control", "public, max-age=31536000, immutable");
  return new Response(obj.body, { headers });
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const path = url.pathname;

    if (path === "/api/data" && request.method === "GET") return handleGetData(env);
    if (path === "/api/data" && request.method === "POST") return handlePostData(request, env);
    if (path === "/api/upload" && request.method === "POST") return handleUpload(request, env);
    if (path.startsWith("/uploads/") && request.method === "GET") {
      // url.pathname stays percent-encoded (e.g. Thai characters, spaces), but the R2 key
      // was stored as the raw decoded string in handleUpload() — decode here to match it.
      const key = decodeURIComponent(path.slice("/uploads/".length));
      return handleServeUpload(key, env);
    }

    // everything else (index.html, thai-words.js, ...) is served from public/ via the ASSETS binding
    return env.ASSETS.fetch(request);
  },
};
