// Runs the real functions/src/index.ts `reserveCredit` callable in the local Firebase emulators
// (Auth + Functions + Firestore, project demo-ah-credit). No billing, no deploy, nothing leaves the machine.
//   cd firebase/credit-check-test && npm install && npm test
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { initializeApp } from 'firebase-admin/app';
import { getFirestore } from 'firebase-admin/firestore';

const PROJECT = 'demo-ah-credit';
initializeApp({ projectId: PROJECT });
const db = getFirestore();
const authHost = process.env.FIREBASE_AUTH_EMULATOR_HOST ?? '127.0.0.1:9099';
const fnBase = `http://127.0.0.1:5001/${PROJECT}/us-central1`;
const BRANCH = 'b1';
let seq = 0;
const uniq = (p) => `${p}-${Date.now()}-${++seq}`;

async function device(branchId = BRANCH) {
  const r = await fetch(`http://${authHost}/identitytoolkit.googleapis.com/v1/accounts:signUp?key=fake-key`, {
    method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ returnSecureToken: true }),
  });
  const j = await r.json();
  assert.ok(r.ok, `anonymous sign-in failed: ${JSON.stringify(j)}`);
  if (branchId) await db.doc(`branch_members/${j.localId}`).set({ branchId });
  return { uid: j.localId, token: j.idToken };
}

async function call(dev, data) {
  const headers = { 'content-type': 'application/json' };
  if (dev) headers.authorization = `Bearer ${dev.token}`;
  const r = await fetch(`${fnBase}/reserveCredit`, { method: 'POST', headers, body: JSON.stringify({ data }) });
  const j = await r.json();
  return { status: r.status, result: j.result, error: j.error };
}

async function customer(extra = {}) {
  const id = uniq('customer:ali');
  await db.doc(`customers/${id}`).set({
    branchId: BRANCH, name: 'Ali', creditLimit: 1000, openingBalance: 0, balance: 800, stuckBalance: 0, ...extra,
  });
  return id;
}

test('two online devices: A allowed, B blocked because A holds a reservation', async () => {
  const [a, b, c] = [await device(), await device(), await customer()];
  const ra = await call(a, { customerId: c, reservationId: uniq('r'), amount: 150 });
  assert.equal(ra.result.allowed, true);
  assert.equal(ra.result.projected, 950);
  const rb = await call(b, { customerId: c, reservationId: uniq('r'), amount: 150 });
  assert.equal(rb.result.allowed, false);
  assert.equal(rb.result.enforced, true);
  assert.equal(rb.result.projected, 1100);
  assert.equal(rb.result.creditLimit, 1000);
});

test('retry of the SAME reservation is not counted twice', async () => {
  const [a, c, rid] = [await device(), await customer(), uniq('r')];
  assert.equal((await call(a, { customerId: c, reservationId: rid, amount: 150 })).result.projected, 950);
  const again = await call(a, { customerId: c, reservationId: rid, amount: 150 });
  assert.equal(again.result.allowed, true);
  assert.equal(again.result.projected, 950);
});

test('opening and stuck balance count towards the limit', async () => {
  const [a, c] = [await device(), await customer({ openingBalance: 100, stuckBalance: 50 })];
  const r = await call(a, { customerId: c, reservationId: uniq('r'), amount: 100 });
  assert.equal(r.result.allowed, false);
  assert.equal(r.result.projected, 1050);
});

test('expired reservations are ignored', async () => {
  const [a, c] = [await device(), await customer()];
  await db.doc(`credit_reservations/${BRANCH}__${uniq('old')}`).set({
    branchId: BRANCH, customerId: c, amount: 500, createdAt: 1, expiresAt: Date.now() - 60_000,
  });
  const r = await call(a, { customerId: c, reservationId: uniq('r'), amount: 150 });
  assert.equal(r.result.allowed, true);
  assert.equal(r.result.projected, 950);
});

test('no credit limit set: allowed, not enforced', async () => {
  const [a, c] = [await device(), await customer({ creditLimit: 0 })];
  const r = await call(a, { customerId: c, reservationId: uniq('r'), amount: 99999 });
  assert.deepEqual(r.result, { allowed: true, enforced: false });
});

test('unknown customer and customer of another branch: allowed, not enforced', async () => {
  const [a, other] = [await device(), await customer({ branchId: 'other-branch' })];
  const r1 = await call(a, { customerId: 'customer:nope', reservationId: uniq('r'), amount: 10 });
  assert.equal(r1.result.enforced, false);
  const r2 = await call(a, { customerId: other, reservationId: uniq('r'), amount: 900 });
  assert.equal(r2.result.allowed, true);
  assert.equal(r2.result.enforced, false);
});

test('not signed in is rejected', async () => {
  const c = await customer();
  const r = await call(null, { customerId: c, reservationId: uniq('r'), amount: 10 });
  assert.equal(r.status, 401);
});

test('signed in but not provisioned for a branch is rejected', async () => {
  const [d, c] = [await device(null), await customer()];
  const r = await call(d, { customerId: c, reservationId: uniq('r'), amount: 10 });
  assert.equal(r.status, 403);
});

test('bad input is rejected', async () => {
  const [a, c] = [await device(), await customer()];
  for (const data of [
    { customerId: c, reservationId: uniq('r'), amount: -5 },
    { customerId: c, reservationId: uniq('r'), amount: 0 },
    { customerId: c, reservationId: uniq('r'), amount: '100' },
    { customerId: 'bad id with spaces', reservationId: uniq('r'), amount: 10 },
    { customerId: c, amount: 10 },
  ]) {
    assert.equal((await call(a, data)).status, 400, JSON.stringify(data));
  }
});
