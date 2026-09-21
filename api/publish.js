// Create / replace / delete a question set. Requires the host session cookie.
import { put } from "@vercel/blob";
import { BLOB_PATH, requireAuth } from "./_lib.js";
import { readDoc } from "./sets.js";

const LANGS = ["en", "rw", "ar"];
const isStr = (v) => typeof v === "string" && v.trim().length > 0;

function validate(set) {
  const err = [];
  if (!isStr(set?.id) || !/^[a-z0-9][a-z0-9-]{1,63}$/.test(set.id))
    err.push("id must be lowercase letters, numbers and hyphens (2-64 chars).");
  if (!isStr(set?.title?.en)) err.push("An English title is required.");

  const opens = Date.parse(set?.opensAt);
  const closes = Date.parse(set?.closesAt);
  if (!Number.isFinite(opens)) err.push("opensAt must be a valid date.");
  if (!Number.isFinite(closes)) err.push("closesAt must be a valid date.");
  if (Number.isFinite(opens) && Number.isFinite(closes) && closes <= opens)
    err.push("closesAt must be after opensAt.");

  const secs = Number(set?.secondsPerQuestion);
  if (!Number.isFinite(secs) || secs < 5 || secs > 600)
    err.push("secondsPerQuestion must be between 5 and 600.");

  if (!Array.isArray(set?.questions) || set.questions.length === 0) {
    err.push("Add at least one question.");
  } else {
    set.questions.forEach((q, i) => {
      const n = i + 1;
      if (!isStr(q?.q?.en)) err.push(`Question ${n}: English text is required.`);
      const opts = q?.o?.en;
      if (!Array.isArray(opts) || opts.length < 2)
        err.push(`Question ${n}: at least two options are required.`);
      else if (!Number.isInteger(q?.c) || q.c < 0 || q.c >= opts.length)
        err.push(`Question ${n}: mark which option is correct.`);
      for (const L of LANGS) {
        const o = q?.o?.[L];
        if (o !== undefined && (!Array.isArray(o) || (Array.isArray(opts) && o.length !== opts.length)))
          err.push(`Question ${n}: ${L} options must match the English count.`);
      }
    });
  }
  return err;
}

export default async function handler(req, res) {
  if (!requireAuth(req, res)) return;

  try {
    const doc = await readDoc();

    if (req.method === "DELETE") {
      const id = req.query?.id;
      if (!isStr(id)) return res.status(400).json({ error: "Which set?" });
      const before = doc.sets.length;
      doc.sets = doc.sets.filter(s => s.id !== id);
      if (doc.sets.length === before) return res.status(404).json({ error: "No such set." });
    } else if (req.method === "POST") {
      const set = req.body?.set;
      const errors = validate(set);
      if (errors.length) return res.status(400).json({ error: errors[0], errors });

      const clean = {
        id: set.id,
        title: Object.fromEntries(LANGS.map(L => [L, isStr(set.title?.[L]) ? set.title[L] : set.title.en])),
        opensAt: new Date(set.opensAt).toISOString(),
        closesAt: new Date(set.closesAt).toISOString(),
        secondsPerQuestion: Math.round(Number(set.secondsPerQuestion)),
        questions: set.questions,
        updatedAt: new Date().toISOString()
      };
      const i = doc.sets.findIndex(s => s.id === clean.id);
      if (i >= 0) doc.sets[i] = clean; else doc.sets.push(clean);
    } else {
      return res.status(405).json({ error: "Use POST or DELETE." });
    }

    doc.sets.sort((a, b) => Date.parse(b.opensAt) - Date.parse(a.opensAt));
    await put(BLOB_PATH, JSON.stringify(doc), {
      access: "public", addRandomSuffix: false,
      contentType: "application/json", allowOverwrite: true
    });
    return res.status(200).json({ ok: true, sets: doc.sets.length });
  } catch (e) {
    return res.status(500).json({ error: "Could not save. " + (e?.message || "") });
  }
}
