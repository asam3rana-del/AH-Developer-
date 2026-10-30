import { initializeApp } from "firebase-admin/app";
import { getAuth } from "firebase-admin/auth";
import { FieldValue, getFirestore } from "firebase-admin/firestore";
import { createHash, pbkdf2Sync, timingSafeEqual } from "node:crypto";
import { HttpsError, onCall } from "firebase-functions/v2/https";

initializeApp();
const db = getFirestore();
type Role = "admin" | "manager" | "cashier";
const ROLES: Role[] = ["admin", "manager", "cashier"];
const USERNAME = /^[a-zA-Z0-9_.-]{3,40}$/;

function usernameOf(v: unknown): string {
  if (typeof v !== "string") throw new HttpsError("invalid-argument", "Invalid credentials");
  const u = v.trim().toLowerCase();
  if (!USERNAME.test(u)) throw new HttpsError("invalid-argument", "Invalid credentials");
  return u;
}
// Exact format from lib/utils/password_hasher.dart: PBKDF2-HMAC-SHA256,
// 120,000 iterations, 16-byte salt, 32-byte key.
function verifyPassword(password: unknown, stored: unknown): boolean {
  if (typeof password !== "string" || password.length < 1 || password.length > 256 ||
      typeof stored !== "string") return false;
  const m = /^pbkdf2\$([0-9a-f]{32})\$([0-9a-f]{64})$/.exec(stored);
  if (!m) return false; // reject legacy plaintext hashes
  return timingSafeEqual(
    pbkdf2Sync(password, Buffer.from(m[1], "hex"), 120000, 32, "sha256"),
    Buffer.from(m[2], "hex")
  );
}
const key = (v: string) => createHash("sha256").update(v).digest("hex");

export const staffLogin = onCall({ enforceAppCheck: true, maxInstances: 20 }, async (request) => {
  const username = usernameOf(request.data?.username);
  const password = request.data?.password;
  if (typeof password !== "string" || password.length < 1 || password.length > 256)
    throw new HttpsError("unauthenticated", "Invalid username or password");

  const windowId = Math.floor(Date.now() / 900000);
  const ip = request.rawRequest.ip ?? "unknown";
  const accountRef = db.collection("_auth_rate_limits").doc(key(username));
  const ipRef = db.collection("_auth_rate_limits").doc(key(`ip:${ip}:${username}`));
  const allowed = await db.runTransaction(async tx => {
    const [a, i] = await Promise.all([tx.get(accountRef), tx.get(ipRef)]);
    const ac = a.data()?.window === windowId ? Number(a.data()?.count ?? 0) : 0;
    const ic = i.data()?.window === windowId ? Number(i.data()?.count ?? 0) : 0;
    if (ac >= 8 || ic >= 20) return false;
    tx.set(accountRef, {window: windowId, count: ac + 1, updatedAt: FieldValue.serverTimestamp()});
    tx.set(ipRef, {window: windowId, count: ic + 1, updatedAt: FieldValue.serverTimestamp()});
    return true;
  });
  if (!allowed) throw new HttpsError("resource-exhausted", "Too many attempts. Try again later.");

  const ref = db.collection("staff_accounts").doc(username);
  const snap = await ref.get();
  const s = snap.data();
  if (!snap.exists || s?.active !== true || !verifyPassword(password, s?.passwordHash))
    throw new HttpsError("unauthenticated", "Invalid username or password");
  const staffId = s.staffId, branchId = s.branchId, role = s.role as Role;
  if (typeof staffId !== "string" || !staffId || typeof branchId !== "string" ||
      !branchId || !ROLES.includes(role))
    throw new HttpsError("failed-precondition", "Staff account requires administrator repair.");

  const customToken = await getAuth().createCustomToken(staffId, {staffId, branchId, role, active: true});
  await ref.update({lastLoginAt: FieldValue.serverTimestamp()});
  return {customToken, staffId, branchId, role};
});

export const getMyStaffContext = onCall({enforceAppCheck: true}, async request => {
  if (!request.auth) throw new HttpsError("unauthenticated", "Sign-in required.");
  const c = request.auth.token;
  if (c.active !== true || typeof c.staffId !== "string" || typeof c.branchId !== "string" ||
      !ROLES.includes(c.role as Role))
    throw new HttpsError("permission-denied", "Valid staff claims required.");
  return {staffId: c.staffId, branchId: c.branchId, role: c.role};
});
