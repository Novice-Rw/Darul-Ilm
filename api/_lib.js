// Shared helpers for the host API routes.
import crypto from "node:crypto";

export const BLOB_PATH = "data/sets.json";
const COOKIE = "dil_host";
const TTL_MS = 8 * 60 * 60 * 1000; // 8 hours

const secret = () => {
  const s = process.env.HOST_SECRET;
  if (!s) throw new Error("HOST_SECRET is not set");
  return s;
};

export const sha256 = (s) =>
  crypto.createHash("sha256").update(s, "utf8").digest("hex");

/** Constant-time compare that tolerates unequal lengths. */
export function safeEqual(a, b) {
  const ab = Buffer.from(String(a));
  const bb = Buffer.from(String(b));
  if (ab.length !== bb.length) return false;
  return crypto.timingSafeEqual(ab, bb);
}

export function signToken(expiresAt) {
  const payload = String(expiresAt);
  const mac = crypto.createHmac("sha256", secret()).update(payload).digest("hex");
  return `${payload}.${mac}`;
}

export function verifyToken(token) {
  if (!token || typeof token !== "string") return false;
  const i = token.lastIndexOf(".");
  if (i < 1) return false;
  const payload = token.slice(0, i);
  const mac = token.slice(i + 1);
  const expected = crypto.createHmac("sha256", secret()).update(payload).digest("hex");
  if (!safeEqual(mac, expected)) return false;
  const exp = Number(payload);
  return Number.isFinite(exp) && Date.now() < exp;
}

export function setSessionCookie(res) {
  const exp = Date.now() + TTL_MS;
  const token = signToken(exp);
  res.setHeader("Set-Cookie",
    `${COOKIE}=${token}; HttpOnly; Secure; SameSite=Strict; Path=/; Max-Age=${Math.floor(TTL_MS / 1000)}`);
}

export function clearSessionCookie(res) {
  res.setHeader("Set-Cookie", `${COOKIE}=; HttpOnly; Secure; SameSite=Strict; Path=/; Max-Age=0`);
}

export function isAuthed(req) {
  const raw = req.headers.cookie || "";
  const hit = raw.split(";").map(s => s.trim()).find(s => s.startsWith(COOKIE + "="));
  return hit ? verifyToken(decodeURIComponent(hit.slice(COOKIE.length + 1))) : false;
}

export function requireAuth(req, res) {
  if (isAuthed(req)) return true;
  res.status(401).json({ error: "Not authorised." });
  return false;
}

/** Empty document used before anything has been published. */
export const emptyDoc = () => ({ version: 1, hero: null, sets: [] });
