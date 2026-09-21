// Hero background upload. Raw image bytes in the body; requires the host cookie.
import { put, del } from "@vercel/blob";
import { BLOB_PATH, requireAuth } from "./_lib.js";
import { readDoc } from "./sets.js";

export const config = { api: { bodyParser: false } };

const OK_TYPES = { "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp", "image/avif": "avif" };
const MAX_BYTES = 4 * 1024 * 1024;

function readRaw(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let n = 0;
    req.on("data", c => {
      n += c.length;
      if (n > MAX_BYTES) { reject(new Error("Image must be 4MB or smaller.")); req.destroy(); return; }
      chunks.push(c);
    });
    req.on("end", () => resolve(Buffer.concat(chunks)));
    req.on("error", reject);
  });
}

export default async function handler(req, res) {
  if (!requireAuth(req, res)) return;

  // Clear the hero photo and put the gradient-only background back.
  if (req.method === "DELETE") {
    try {
      const doc = await readDoc();
      const old = doc.hero;
      doc.hero = null;
      await put(BLOB_PATH, JSON.stringify(doc), {
        access: "public", addRandomSuffix: false,
        contentType: "application/json", allowOverwrite: true
      });
      if (old) { try { await del(old); } catch { /* already gone */ } }
      return res.status(200).json({ ok: true, hero: null });
    } catch (e) {
      return res.status(500).json({ error: e?.message || "Could not clear the photo." });
    }
  }

  if (req.method !== "POST") return res.status(405).json({ error: "Use POST or DELETE." });

  const type = (req.headers["content-type"] || "").split(";")[0].trim();
  const ext = OK_TYPES[type];
  if (!ext) return res.status(400).json({ error: "Use a JPEG, PNG, WebP or AVIF image." });

  try {
    const body = await readRaw(req);
    if (!body.length) return res.status(400).json({ error: "Empty upload." });

    // Cache-busting name so the CDN serves the new photo immediately.
    const { url } = await put(`data/hero-${Date.now()}.${ext}`, body, {
      access: "public", addRandomSuffix: false, contentType: type
    });

    const doc = await readDoc();
    const previous = doc.hero;
    doc.hero = url;
    await put(BLOB_PATH, JSON.stringify(doc), {
      access: "public", addRandomSuffix: false,
      contentType: "application/json", allowOverwrite: true
    });

    if (previous) { try { await del(previous); } catch { /* already gone */ } }
    return res.status(200).json({ ok: true, hero: url });
  } catch (e) {
    return res.status(400).json({ error: e?.message || "Upload failed." });
  }
}
