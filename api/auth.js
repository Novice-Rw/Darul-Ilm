// Host passphrase -> signed, HttpOnly session cookie.
// This is the real lock: every write route checks the cookie, so the
// in-page gate is only a convenience.
import { sha256, safeEqual, setSessionCookie, clearSessionCookie, isAuthed } from "./_lib.js";

export default async function handler(req, res) {
  if (req.method === "GET") return res.status(200).json({ authed: isAuthed(req) });

  if (req.method === "DELETE") {
    clearSessionCookie(res);
    return res.status(200).json({ authed: false });
  }

  if (req.method !== "POST") return res.status(405).json({ error: "Use POST." });

  const expected = process.env.HOST_PASS_HASH;
  if (!expected) return res.status(500).json({ error: "HOST_PASS_HASH is not configured." });

  const passphrase = (req.body && req.body.passphrase) || "";
  if (!passphrase) return res.status(400).json({ error: "Enter the passphrase." });

  // Uniform delay so timing does not distinguish wrong from missing.
  await new Promise(r => setTimeout(r, 400));

  if (!safeEqual(sha256(String(passphrase)), expected)) {
    return res.status(401).json({ error: "Incorrect passphrase." });
  }

  setSessionCookie(res);
  return res.status(200).json({ authed: true });
}
