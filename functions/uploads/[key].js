// Cloudflare Pages Function — serves files previously saved by /api/upload back out of R2.
// Requires the same "UPLOADS" R2 binding as functions/api/upload.js.

export async function onRequestGet({ params, env }) {
  const obj = await env.UPLOADS.get(params.key);
  if (!obj) return new Response("Not found", { status: 404 });
  const headers = new Headers();
  obj.writeHttpMetadata(headers);
  headers.set("etag", obj.httpEtag);
  headers.set("Cache-Control", "public, max-age=31536000, immutable");
  return new Response(obj.body, { headers });
}
