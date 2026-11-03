// Phase 1 (Security): unauthorized access + branch isolation matrix for the LIVE rules (firebase/firestore.rules).
// Runs the SAME checks against EVERY synced collection, so a collection added to the allow-list later is covered too.
// Nothing here touches production (Firestore emulator only).
import { readFileSync } from 'node:fs';
import { test, before, after, beforeEach } from 'node:test';
import { initializeTestEnvironment, assertFails, assertSucceeds } from '@firebase/rules-unit-testing';
import { doc, getDoc, setDoc, updateDoc, deleteDoc } from 'firebase/firestore';

const rules = readFileSync(new URL('../firestore.rules', import.meta.url), 'utf8');

// Keep in sync with isSyncedCollection() in firestore.rules + 'due_followups' (own validated block).
const COLLECTIONS = [
  'customers', 'suppliers', 'products', 'users', 'sales', 'purchases', 'payments', 'expenses',
  'cash_transactions', 'cash_register', 'units', 'categories', 'zakat_years', 'zakat_payments',
  'returns', 'stock_movements', 'app_settings', 'shell_customers', 'shell_transactions',
  'shop_empty_shell_log', 'workers', 'worker_attendance', 'worker_advances',
  'worker_salary_payments', 'shop_rents', 'shop_rent_ledger', 'utility_bills',
  'utility_bill_payments', 'due_followups',
];

// method/outcome satisfy the due_followups validation; harmless extra fields elsewhere.
const base = (branchId) => ({ branchId, method: 'note', outcome: 'note', total: 1 });

let env;
before(async () => {
  env = await initializeTestEnvironment({
    projectId: 'demo-ah-branch-isolation',
    firestore: { rules, host: '127.0.0.1', port: 8080 },
  });
});
after(async () => { await env.cleanup(); });
beforeEach(async () => {
  await env.clearFirestore();
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await setDoc(doc(db, 'branch_members/uid-b1'), { branchId: 'b1' });
    await setDoc(doc(db, 'branch_members/uid-b2'), { branchId: 'b2' });
    for (const c of COLLECTIONS) {
      await setDoc(doc(db, `${c}/own`), base('b1'));
      await setDoc(doc(db, `${c}/foreign`), base('b2'));
    }
  });
});

const as = (uid) => env.authenticatedContext(uid).firestore();
const anon = () => env.unauthenticatedContext().firestore();

for (const c of COLLECTIONS) {
  test(`${c}: signed-out and unprovisioned users are denied`, async () => {
    await assertFails(getDoc(doc(anon(), `${c}/own`)));
    await assertFails(setDoc(doc(anon(), `${c}/new`), base('b1')));
    await assertFails(getDoc(doc(as('unprovisioned'), `${c}/own`)));
    await assertFails(setDoc(doc(as('unprovisioned'), `${c}/new`), base('b1')));
    await assertFails(deleteDoc(doc(as('unprovisioned'), `${c}/own`)));
  });

  test(`${c}: member of b1 can use own branch only`, async () => {
    const db = as('uid-b1');
    await assertSucceeds(getDoc(doc(db, `${c}/own`)));
    await assertSucceeds(getDoc(doc(db, `${c}/does-not-exist`))); // sync push reads before create
    await assertSucceeds(setDoc(doc(db, `${c}/new`), base('b1')));
    await assertSucceeds(updateDoc(doc(db, `${c}/own`), { total: 2 }));
    await assertSucceeds(deleteDoc(doc(db, `${c}/own`)));
  });

  test(`${c}: member of b1 cannot touch branch b2 data or move records`, async () => {
    const db = as('uid-b1');
    await assertFails(getDoc(doc(db, `${c}/foreign`)));
    await assertFails(updateDoc(doc(db, `${c}/foreign`), { total: 9 }));
    await assertFails(deleteDoc(doc(db, `${c}/foreign`)));
    await assertFails(setDoc(doc(db, `${c}/new-wrong`), base('b2')));      // create in another branch
    await assertFails(setDoc(doc(db, `${c}/new-none`), { total: 1, method: 'note', outcome: 'note' })); // no branchId
    await assertFails(updateDoc(doc(db, `${c}/own`), { branchId: 'b2' })); // move own record away
  });

  test(`${c}: member of b2 cannot read or change b1 data`, async () => {
    const db = as('uid-b2');
    await assertFails(getDoc(doc(db, `${c}/own`)));
    await assertFails(updateDoc(doc(db, `${c}/own`), { total: 9 }));
    await assertFails(deleteDoc(doc(db, `${c}/own`)));
  });
}

test('branch_members: a user reads only their own membership and nobody writes it', async () => {
  await assertSucceeds(getDoc(doc(as('uid-b1'), 'branch_members/uid-b1')));
  await assertFails(getDoc(doc(as('uid-b1'), 'branch_members/uid-b2')));
  await assertFails(getDoc(doc(anon(), 'branch_members/uid-b1')));
  await assertFails(setDoc(doc(as('uid-b1'), 'branch_members/uid-b1'), { branchId: 'b2' }));
  await assertFails(setDoc(doc(as('uid-b1'), 'branch_members/uid-new'), { branchId: 'b1' }));
  await assertFails(deleteDoc(doc(as('uid-b1'), 'branch_members/uid-b1')));
});

test('server-only / unlisted collections are closed to every client', async () => {
  await env.withSecurityRulesDisabled(async (ctx) => {
    for (const c of ['credit_reservations', 'staff_accounts', '_auth_rate_limits', 'unlisted']) {
      await setDoc(doc(ctx.firestore(), `${c}/x`), { branchId: 'b1' });
    }
  });
  for (const c of ['credit_reservations', 'staff_accounts', '_auth_rate_limits', 'unlisted']) {
    await assertFails(getDoc(doc(as('uid-b1'), `${c}/x`)));
    await assertFails(setDoc(doc(as('uid-b1'), `${c}/y`), { branchId: 'b1' }));
    await assertFails(deleteDoc(doc(as('uid-b1'), `${c}/x`)));
  }
});

test('due_followups: validation still rejects bad fields (own branch)', async () => {
  const db = as('uid-b1');
  await assertFails(setDoc(doc(db, 'due_followups/bad1'), { branchId: 'b1', method: 'call', outcome: 'bogus' }));
  await assertFails(setDoc(doc(db, 'due_followups/bad2'), { branchId: 'b1', method: 'pigeon', outcome: 'note' }));
  await assertFails(setDoc(doc(db, 'due_followups/bad3'), { branchId: 'b1', method: 'call', outcome: 'paid', amount: -5 }));
});
