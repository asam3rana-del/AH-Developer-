// Pure (no imports, no Firebase) rules for the server-mediated sync push. Mirrors lib/sync/sync_push_plan.dart
// (last-write-wins upsert, tombstone delete, create_if_absent, idempotent increments) plus the role matrix.
// Kept dependency-free so it can be unit tested: functions/test/sync_logic.test.mjs.

export type Obj = Record<string, unknown>;
export type StaffRole = "admin" | "manager" | "cashier";

export class SyncRuleError extends Error {
  constructor(public code: "permission-denied" | "invalid-argument", message: string) {
    super(message);
  }
}

// entityType -> Firestore collection (same map as pushCollections in sync_push_plan.dart).
export const SYNC_COLLECTIONS: Record<string, string> = {
  customer: "customers", supplier: "suppliers", product: "products", user: "users", sale: "sales",
  purchase: "purchases", payment: "payments", expense: "expenses", cash_transaction: "cash_transactions",
  unit: "units", category: "categories", zakat_year: "zakat_years", zakat_payment: "zakat_payments",
  return: "returns", stock_movement: "stock_movements", app_setting: "app_settings",
  cash_register: "cash_register", shell_customer: "shell_customers", shell_transaction: "shell_transactions",
  shop_empty_shell_log: "shop_empty_shell_log", worker: "workers", worker_attendance: "worker_attendance",
  worker_advance: "worker_advances", worker_salary_payment: "worker_salary_payments", shop_rent: "shop_rents",
  shop_rent_entry: "shop_rent_ledger", utility_bill: "utility_bills",
  utility_bill_payment: "utility_bill_payments", due_followup: "due_followups",
};

export const OPERATIONS = ["upsert", "delete", "create_if_absent", "increment_stock", "increment_balance", "set_stock"];

export const isObj = (v: unknown): v is Obj => typeof v === "object" && v !== null && !Array.isArray(v);
export const asMillis = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) ? Math.trunc(v) : null);
export const roundQty = (v: number): number => Math.round(v * 1e6) / 1e6;

export function validEntityId(v: unknown): v is string {
  return typeof v === "string" && v.length >= 1 && v.length <= 400 && !v.includes("/") &&
    v !== "." && v !== ".." && !/^__.*__$/.test(v);
}
export const validOpId = (v: unknown): v is string => typeof v === "string" && /^[A-Za-z0-9:_-]{1,200}$/.test(v);

// ---- who may do what (server side; the local UI RoleGuard is NOT authorization) ----
const CASHIER_UPSERT = new Set([
  "customer", "sale", "payment", "expense", "cash_transaction", "return", "stock_movement",
  "shell_customer", "shell_transaction", "shop_empty_shell_log", "due_followup",
]);
export function roleMayDo(role: StaffRole, type: string, op: string): boolean {
  if (!(type in SYNC_COLLECTIONS) || !OPERATIONS.includes(op)) return false;
  if (role === "admin") return true;
  if (type === "user") return false; // staff directory: admin only
  if (role === "manager") return true;
  // cashier: no delete, no set_stock (stock take), no product/price/settings/supplier/purchase/payroll writes
  switch (op) {
    case "upsert": return CASHIER_UPSERT.has(type);
    case "create_if_absent": return type === "cash_register";
    case "increment_stock": return type === "product";
    case "increment_balance": return type === "customer";
    default: return false;
  }
}

// ---- payload hygiene ----
const SERVER_ONLY = ["appliedOps", "pushedAt", "upsertAt"];
const CASHIER_CUSTOMER_PROTECTED = ["creditLimit", "openingBalance", "stuckBalance"];

/** Removes fields a client must never set directly. Throws SyncRuleError when the role may not do it at all. */
export function sanitizeUpsertPayload(type: string, role: StaffRole, raw: unknown, docExists: boolean): Obj {
  if (!isObj(raw)) throw new SyncRuleError("invalid-argument", "payload must be an object");
  if (JSON.stringify(raw).length > 200000) throw new SyncRuleError("invalid-argument", "payload too large");
  const p: Obj = {...raw};
  for (const k of SERVER_ONLY) delete p[k];
  if (p._restore === true && role === "cashier") throw new SyncRuleError("permission-denied", "Restore is not allowed for this role.");
  if (p._restore !== true) delete p._deleted; // tombstones only via the delete operation
  if (type === "customer" || type === "supplier") delete p.balance; // balance changes only via increment_balance
  if (type === "product") delete p.stock; // stock changes only via increment_stock / set_stock
  if (role === "cashier" && type === "customer") {
    for (const k of docExists ? CASHIER_CUSTOMER_PROTECTED : ["stuckBalance"]) delete p[k];
  }
  return p;
}

/** Seed fields only fill a NEW (or tombstoned) doc created by an increment; same hygiene, no reserved keys. */
export function sanitizeSeed(type: string, role: StaffRole, raw: unknown): Obj {
  if (raw === undefined || raw === null) return {};
  if (!isObj(raw)) throw new SyncRuleError("invalid-argument", "seedFields must be an object");
  if (JSON.stringify(raw).length > 50000) throw new SyncRuleError("invalid-argument", "seedFields too large");
  const s = sanitizeUpsertPayload(type, role, raw, false);
  for (const k of ["serverId", "branchId", "updatedAt", "_restore", "stock", "balance"]) delete s[k];
  return s;
}

// ---- last-write-wins etc. (ported 1:1 from sync_push_plan.dart) ----
export function stampPayload(raw: Obj, branchId: string, nowMs: number): {map: Obj; incomingUpdatedAt: number} {
  if (raw._restore === true) {
    const m: Obj = {...raw};
    delete m._restore;
    return {map: {...m, branchId, updatedAt: nowMs, _deleted: false}, incomingUpdatedAt: nowMs};
  }
  const incoming = asMillis(raw.updatedAt) ?? nowMs;
  return {map: {...raw, branchId, updatedAt: incoming}, incomingUpdatedAt: incoming};
}
export const shouldApplyUpsert = (incoming: number, server: number | null): boolean =>
  incoming >= (server ?? Number.NEGATIVE_INFINITY);
export const shouldApplyDelete = shouldApplyUpsert;
export function upsertClock(data: Obj | undefined): number | null {
  const up = asMillis(data?.upsertAt);
  if (up !== null) return up;
  if (data?._deleted === true) return asMillis(data?.updatedAt);
  return null;
}
export const canCreateIfAbsent = (exists: boolean, data: Obj | undefined): boolean => !(exists && data?._deleted !== true);

export function pruneAppliedOps(applied: Obj, opId: string, nowTs: number): Obj {
  const cutoff = nowTs - 30 * 24 * 60 * 60 * 1000;
  const entries = Object.entries(applied)
    .filter(([, v]) => { const t = asMillis(v); return t !== null && t >= cutoff; })
    .sort((a, b) => {
      const c = (asMillis(a[1]) as number) - (asMillis(b[1]) as number);
      return c !== 0 ? c : a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0;
    });
  const tail = entries.length > 999 ? entries.slice(entries.length - 999) : entries;
  const kept: Obj = {};
  for (const [k, v] of tail) kept[k] = v;
  kept[opId] = nowTs;
  return kept;
}

export function checkDelta(op: string, delta: unknown): number {
  const lim = op === "increment_stock" ? 1e6 : 1e10;
  if (typeof delta !== "number" || !Number.isFinite(delta) || Math.abs(delta) > lim)
    throw new SyncRuleError("invalid-argument", "delta must be a finite number within limits");
  return delta;
}
