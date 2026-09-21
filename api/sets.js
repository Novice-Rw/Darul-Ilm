// Public read of the published question sets.
// Cached at the edge, so repeat visitors cost no function invocation.
import { list } from "@vercel/blob";
import { BLOB_PATH, emptyDoc } from "./_lib.js";

export async function readDoc() {
  const { blobs } = await list({ prefix: BLOB_PATH, limit: 1 });
  const hit = blobs.find(b => b.pathname === BLOB_PATH);
  if (!hit) return emptyDoc();
  const r = await fetch(hit.url, { cache: "no-store" });
  if (!r.ok) return emptyDoc();
  try { return await r.json(); } catch { return emptyDoc(); }
}

export default async function handler(req, res) {
  if (req.method !== "GET") return res.status(405).json({ error: "Use GET." });
  try {
    const doc = await readDoc();
    res.setHeader("Cache-Control", "public, s-maxage=30, stale-while-revalidate=300");
    return res.status(200).json(doc);
  } catch (e) {
    // Never break the site over a storage hiccup; the client falls back to
    // its bundled set.
    res.setHeader("Cache-Control", "no-store");
    return res.status(200).json({ ...emptyDoc(), degraded: true });
  }
}
