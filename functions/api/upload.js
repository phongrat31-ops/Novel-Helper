// Cloudflare Pages Function — replaces server.ps1's POST /api/upload.
// Requires an R2 bucket bound to this Pages project as "UPLOADS" (Settings > Functions > R2 bucket bindings).

export async function onRequestPost({ request, env }) {
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
