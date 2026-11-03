import { initializeApp } from "firebase-admin/app";
import { getAuth } from "firebase-admin/auth";
import { DocumentSnapshot, FieldValue, getFirestore } from "firebase-admin/firestore";
import { createHash, pbkdf2Sync, randomBytes, timingSafeEqual } from "node:crypto";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import {
  Obj, SYNC_COLLECTIONS, SyncRuleError, asMillis, canCreateIfAbsent, checkDelta, isObj, pruneAppliedOps,
  roleMayDo, roundQty, sanitizeSeed, sanitizeUpsertPayload, shouldApplyDelete, shouldApplyUpsert,
  stampPayload, upsertClock, validEntityId, validOpId,
} from "./syncLogic";

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

// ---------------------------------------------------------------------------
// Password management (server side). The app never writes staff_accounts itself: rules deny it.
// ---------------------------------------------------------------------------
function hashPassword(p: string): string {
  const salt = randomBytes(16);
  return `pbkdf2$${salt.toString("hex")}$${pbkdf2Sync(p, salt, 120000, 32, "sha256").toString("hex")}`;
}
function validNewPassword(v: unknown): string {
  if (typeof v !== "string" || v.length < 6 || v.length > 256)
    throw new HttpsError("invalid-argument", "Password must be 6 to 256 characters.");
  return v;
}
// Verified token claims only (never request.data) decide who is calling.
function staffClaimsOf(request: {auth?: {token: unknown}}): {staffId: string; branchId: string; role: Role} {
  const c = request.auth?.token as Record<string, unknown> | undefined;
  if (!c || c.active !== true || typeof c.staffId !== "string" || !c.staffId ||
      typeof c.branchId !== "string" || !c.branchId || !ROLES.includes(c.role as Role))
    throw new HttpsError("permission-denied", "Valid staff claims required.");
  return {staffId: c.staffId, branchId: c.branchId, role: c.role as Role};
}
async function throttle(scope: string, id: string, max: number): Promise<void> {
  const windowId = Math.floor(Date.now() / 900000);
  const ref = db.collection("_auth_rate_limits").doc(key(`${scope}:${id}`));
  const ok = await db.runTransaction(async tx => {
    const s = await tx.get(ref);
    const c = s.data()?.window === windowId ? Number(s.data()?.count ?? 0) : 0;
    if (c >= max) return false;
    tx.set(ref, {window: windowId, count: c + 1, updatedAt: FieldValue.serverTimestamp()});
    return true;
  });
  if (!ok) throw new HttpsError("resource-exhausted", "Too many attempts. Try again later.");
}

// A signed-in staff member changes THEIR OWN cloud password (must know the current one).
export const changeMyPassword = onCall({enforceAppCheck: true, maxInstances: 10}, async request => {
  const me = staffClaimsOf(request);
  const newPassword = validNewPassword(request.data?.newPassword);
  await throttle("chgpw", me.staffId, 8);
  const q = await db.collection("staff_accounts")
    .where("staffId", "==", me.staffId).where("branchId", "==", me.branchId).limit(1).get();
  const doc = q.docs[0];
  const s = doc?.data();
  if (!doc || s?.active !== true || !verifyPassword(request.data?.oldPassword, s?.passwordHash))
    throw new HttpsError("unauthenticated", "Current password is wrong.");
  await doc.ref.update({passwordHash: hashPassword(newPassword), passwordChangedAt: FieldValue.serverTimestamp()});
  await getAuth().revokeRefreshTokens(me.staffId); // other devices must sign in again with the new password
  return {ok: true};
});

// Admin creates / updates / deactivates / resets the password of a staff account IN THEIR OWN BRANCH.
export const adminSetStaffAccount = onCall({enforceAppCheck: true, maxInstances: 10}, async request => {
  const me = staffClaimsOf(request);
  if (me.role !== "admin") throw new HttpsError("permission-denied", "Admin only.");
  const username = usernameOf(request.data?.username);
  const role = request.data?.role as Role;
  const active = request.data?.active;
  const password = request.data?.password; // optional on update, required on create
  if (!ROLES.includes(role) || typeof active !== "boolean")
    throw new HttpsError("invalid-argument", "role (admin|manager|cashier) and active (true|false) are required.");
  await throttle("adminset", me.staffId, 60);

  const ref = db.collection("staff_accounts").doc(username);
  const snap = await ref.get();
  const old = snap.data() ?? {};
  let staffId: string;
  if (snap.exists) {
    if (old.branchId !== me.branchId) throw new HttpsError("permission-denied", "Account belongs to another branch.");
    if (typeof old.staffId !== "string" || !old.staffId)
      throw new HttpsError("failed-precondition", "Staff account requires administrator repair.");
    staffId = old.staffId;
    if (staffId === me.staffId && (role !== "admin" || !active))
      throw new HttpsError("failed-precondition", "You cannot demote or deactivate yourself.");
  } else {
    if (password === undefined) throw new HttpsError("invalid-argument", "Password is required for a new account.");
    staffId = `st_${randomBytes(12).toString("hex")}`;
  }
  const update: Record<string, unknown> = {
    staffId, branchId: me.branchId, role, active, updatedAt: FieldValue.serverTimestamp(),
  };
  if (password !== undefined) update.passwordHash = hashPassword(validNewPassword(password));
  await ref.set(update, {merge: true});
  // Existing tokens keep their old claims until refresh: revoke on any change that must take effect now.
  if (snap.exists && (password !== undefined || !active || role !== old.role)) await getAuth().revokeRefreshTokens(staffId);
  return {staffId};
});

// ---------------------------------------------------------------------------
// Server-mediated sync push. In secure mode a CASHIER has no direct Firestore write access (claims rules deny
// it); the app sends each offline-queue entry here instead and the server applies the SAME operation the app
// used to run itself (lib/sync/sync_api.dart push): upsert (last-write-wins), delete (tombstone),
// create_if_absent, increment_stock / increment_balance (idempotent via appliedOps), set_stock.
// What the server adds: branch and role come ONLY from verified claims; a per-role allow-list of (entity,
// operation); fields a client must never set (balance/stock/appliedOps/tombstones/credit limit of existing
// customers) are stripped; every touched document must belong to the caller's branch (Admin SDK bypasses
// rules, so this check is the isolation); delta/size limits. See functions/src/syncLogic.ts (unit tested).
// ---------------------------------------------------------------------------
export const pushSyncOp = onCall({enforceAppCheck: true, maxInstances: 20}, async request => {
  const me = staffClaimsOf(request);
  const d: Obj = isObj(request.data) ? request.data : {};
  const type = d.entityType, op = d.operation, entityId = d.entityId;
  if (typeof type !== "string" || typeof op !== "string" || !validEntityId(entityId))
    throw new HttpsError("invalid-argument", "entityType, operation and entityId are required.");
  if (!roleMayDo(me.role, type, op))
    throw new HttpsError("permission-denied", `Role ${me.role} may not ${op} ${type}.`);
  const ref = db.collection(SYNC_COLLECTIONS[type]).doc(entityId);
  const branch = me.branchId;
  const now = Date.now();
  const own = (snap: DocumentSnapshot) => {
    if (snap.exists && snap.data()?.branchId !== branch)
      throw new HttpsError("permission-denied", "Record belongs to another branch.");
  };

  try {
    switch (op) {
      case "delete":
        await db.runTransaction(async tx => {
          const snap = await tx.get(ref);
          own(snap);
          if (shouldApplyDelete(now, asMillis(snap.data()?.updatedAt)))
            tx.set(ref, {serverId: entityId, _deleted: true, updatedAt: now, branchId: branch, pushedAt: now}, {merge: true});
        });
        return {ok: true};

      case "create_if_absent":
        await db.runTransaction(async tx => {
          const snap = await tx.get(ref);
          own(snap);
          const st = stampPayload(sanitizeUpsertPayload(type, me.role, d.payload, snap.exists), branch, now);
          if (canCreateIfAbsent(snap.exists, snap.data())) tx.set(ref, {...st.map, pushedAt: now}, {merge: true});
        });
        return {ok: true};

      case "upsert": {
        let applied = true;
        await db.runTransaction(async tx => {
          applied = true;
          const snap = await tx.get(ref);
          own(snap);
          const st = stampPayload(sanitizeUpsertPayload(type, me.role, d.payload, snap.exists), branch, now);
          if (shouldApplyUpsert(st.incomingUpdatedAt, upsertClock(snap.data())))
            tx.set(ref, {...st.map, upsertAt: st.incomingUpdatedAt, pushedAt: now}, {merge: true});
          else applied = false; // newer edit already on the server: keep it (same as the app's stale skip)
        });
        return {ok: true, applied};
      }

      case "set_stock": {
        const stock = isObj(d.payload) ? d.payload.stock : undefined;
        if (type !== "product" || typeof stock !== "number" || !Number.isFinite(stock) || Math.abs(stock) > 1e9)
          throw new HttpsError("invalid-argument", "set_stock needs a product and a finite stock.");
        const seed = sanitizeSeed(type, me.role, d.seedFields);
        await db.runTransaction(async tx => {
          const snap = await tx.get(ref);
          own(snap);
          const isNew = !snap.exists || snap.data()?._deleted === true;
          tx.set(ref, {stock, updatedAt: now, pushedAt: now, branchId: branch,
                       ...(isNew ? {serverId: entityId, _deleted: false, ...seed} : {})}, {merge: true});
        });
        return {ok: true};
      }

      case "increment_stock":
      case "increment_balance": {
        const field = op === "increment_stock" ? "stock" : "balance";
        if ((field === "stock" && type !== "product") ||
            (field === "balance" && type !== "customer" && type !== "supplier"))
          throw new HttpsError("invalid-argument", `${op} does not apply to ${type}.`);
        const delta = checkDelta(op, isObj(d.payload) ? d.payload.delta : undefined);
        const opId = d.opId;
        if (!validOpId(opId)) throw new HttpsError("invalid-argument", "A valid opId is required.");
        const seed = sanitizeSeed(type, me.role, d.seedFields);
        let skipped = false;
        await db.runTransaction(async tx => {
          skipped = false;
          const snap = await tx.get(ref);
          own(snap);
          const data = snap.data();
          const rawApplied: unknown = data ? (data as Obj).appliedOps : undefined;
          const applied: Obj = isObj(rawApplied) ? rawApplied : {};
          if (opId in applied) { skipped = true; return; } // retry of an op that already landed
          const wasDeleted = snap.exists && data?._deleted === true;
          const isNew = !snap.exists || wasDeleted;
          const curRaw: unknown = data ? (data as Obj)[field] : undefined;
          const cur = typeof curRaw === "number" ? curRaw : 0;
          const write: Obj = {
            [field]: field === "stock" ? roundQty(cur + delta) : cur + delta,
            updatedAt: now, branchId: branch, appliedOps: pruneAppliedOps(applied, opId, now),
          };
          const fields = [field, "updatedAt", "branchId", "appliedOps"];
          if (isNew) {
            write.serverId = entityId; fields.push("serverId");
            if (wasDeleted) { write._deleted = false; fields.push("_deleted"); }
            for (const [k, v] of Object.entries(seed)) { write[k] = v; fields.push(k); }
          }
          // mergeFields (like the app): appliedOps is REPLACED by the pruned map, not deep-merged.
          tx.set(ref, write, {mergeFields: fields});
        });
        return {ok: true, skipped};
      }

      default:
        throw new HttpsError("invalid-argument", "Unknown operation.");
    }
  } catch (e) {
    if (e instanceof SyncRuleError) throw new HttpsError(e.code, e.message);
    throw e;
  }
});

// ---------------------------------------------------------------------------
// Cross-device credit-limit pre-check (opt-in from the app; see docs/SERVER_CREDIT_CHECK.md)
//
// The app is offline-first: a sale is always saved locally and its balance change is pushed later as an
// increment. Two ONLINE devices can therefore both pass their local credit check against the same stale
// balance. This callable closes that gap by holding short-lived "reservations" on the server:
//   projected = openingBalance + balance + stuckBalance + (other devices' open reservations) + this amount
// It does NOT stop an OFFLINE device (it cannot reach the server) - the app fails open in that case.
// ---------------------------------------------------------------------------
const RESERVATION_TTL_MS = 5 * 60 * 1000;
const ID_FIELD = /^[A-Za-z0-9:_.\-]{1,200}$/;

function num(v: unknown): number {
  const n = typeof v === "number" ? v : Number(v);
  return Number.isFinite(n) ? n : 0;
}

// Branch comes from the server, never from the request body.
async function branchOf(auth: {uid: string; token: Record<string, unknown>}): Promise<string> {
  const claim = auth.token.branchId;
  if (typeof claim === "string" && claim) return claim;
  const m = await db.collection("branch_members").doc(auth.uid).get();
  const b = m.data()?.branchId;
  if (typeof b !== "string" || !b) throw new HttpsError("permission-denied", "Device is not provisioned for a branch.");
  return b;
}

export const reserveCredit = onCall({enforceAppCheck: false, maxInstances: 20}, async request => {
  if (!request.auth) throw new HttpsError("unauthenticated", "Sign-in required.");
  const customerId = request.data?.customerId;
  const reservationId = request.data?.reservationId;
  const amount = request.data?.amount;
  if (typeof customerId !== "string" || !ID_FIELD.test(customerId) ||
      typeof reservationId !== "string" || !ID_FIELD.test(reservationId) ||
      typeof amount !== "number" || !Number.isFinite(amount) || amount <= 0 || amount > 1e9)
    throw new HttpsError("invalid-argument", "customerId, reservationId and a positive amount are required.");
  const branchId = await branchOf({uid: request.auth.uid, token: request.auth.token as Record<string, unknown>});

  const customerRef = db.collection("customers").doc(customerId);
  const resRef = db.collection("credit_reservations").doc(`${branchId}__${reservationId}`.slice(0, 400));
  return db.runTransaction(async tx => {
    const cSnap = await tx.get(customerRef);
    const c = cSnap.data();
    // Unknown customer / other branch: nothing to enforce here (the app's own local check still ran).
    if (!cSnap.exists || !c || c.branchId !== branchId) return {allowed: true, enforced: false};
    const limit = num(c.creditLimit);
    if (limit <= 0) return {allowed: true, enforced: false};

    const nowMs = Date.now();
    // Same reservationId again (retry of the same save) must not count twice.
    const others = await tx.get(db.collection("credit_reservations")
      .where("branchId", "==", branchId).where("customerId", "==", customerId).where("expiresAt", ">", nowMs));
    let reservedByOthers = 0;
    others.forEach(d => { if (d.id !== resRef.id) reservedByOthers += num(d.data().amount); });

    const projected = num(c.openingBalance) + num(c.balance) + num(c.stuckBalance) + reservedByOthers + amount;
    if (projected > limit + 0.009) return {allowed: false, enforced: true, creditLimit: limit, projected};

    tx.set(resRef, {branchId, customerId, amount, createdAt: nowMs, expiresAt: nowMs + RESERVATION_TTL_MS,
                    uid: request.auth!.uid});
    return {allowed: true, enforced: true, creditLimit: limit, projected};
  });
});
