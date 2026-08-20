// Cloudflare Pages Function — replaces server.ps1's GET/POST /api/data.
// Requires a D1 database bound to this Pages project as "DB" (Settings > Functions > D1 database bindings),
// containing: CREATE TABLE data (id INTEGER PRIMARY KEY, content TEXT);

export async function onRequestGet({ env }) {
  const row = await env.DB.prepare("SELECT content FROM data WHERE id = 1").first();
  const body = row ? row.content : "null";
  return new Response(body, {
    headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" },
  });
}

export async function onRequestPost({ request, env }) {
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
