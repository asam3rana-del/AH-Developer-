// Regression tests for the currently active firebase/firestore.rules baseline.
// These tests intentionally do not enable the unfinished staff-claims migration.
import { readFileSync } from 'node:fs';
import { test, before, after, beforeEach } from 'node:test';
import { initializeTestEnvironment, assertFails, assertSucceeds } from '@firebase/rules-unit-testing';
import { doc, getDoc, setDoc, updateDoc, deleteDoc } from 'firebase/firestore';

let env;
const rules = readFileSync(new URL('../firestore.rules', import.meta.url), 'utf8');

before(async () => {
  env = await initializeTestEnvironment({
    projectId: 'demo-ah-baseline-rules',
    firestore: { rules, host: '127.0.0.1', port: 8080 },
  });
});
after(async () => { await env.cleanup(); });
beforeEach(async () => {
  await env.clearFirestore();
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await setDoc(doc(db, 'branch_members/uid-b1'), { branchId: 'b1' });
    await setDoc(doc(db, 'sales/s1'), { branchId: 'b1', total: 100 });
    await setDoc(doc(db, 'sales/s2'), { branchId: 'b2', total: 50 });
  });
});

const dbFor = (uid) => env.authenticatedContext(uid).firestore();

test('unauthenticated users cannot read or write synced records', async () => {
  const db = env.unauthenticatedContext().firestore();
  await assertFails(getDoc(doc(db, 'sales/s1')));
  await assertFails(setDoc(doc(db, 'sales/new'), { branchId: 'b1' }));
});

test('provisioned UID can read only its own branch', async () => {
  const db = dbFor('uid-b1');
  await assertSucceeds(getDoc(doc(db, 'sales/s1')));
  await assertFails(getDoc(doc(db, 'sales/s2')));
});

test('unprovisioned UID cannot access a branch', async () => {
  const db = dbFor('unprovisioned');
  await assertFails(getDoc(doc(db, 'sales/s1')));
  await assertFails(setDoc(doc(db, 'sales/new'), { branchId: 'b1' }));
});

test('create requires the mapped branch ID', async () => {
  const db = dbFor('uid-b1');
  await assertSucceeds(setDoc(doc(db, 'sales/new'), { branchId: 'b1', total: 1 }));
  await assertFails(setDoc(doc(db, 'sales/wrong'), { branchId: 'b2', total: 1 }));
  await assertFails(setDoc(doc(db, 'sales/missing'), { total: 1 }));
});

test('update cannot move a record between branches', async () => {
  const db = dbFor('uid-b1');
  await assertSucceeds(updateDoc(doc(db, 'sales/s1'), { total: 101 }));
  await assertFails(updateDoc(doc(db, 'sales/s1'), { branchId: 'b2' }));
});

test('clients cannot modify branch membership or unknown collections', async () => {
  const db = dbFor('uid-b1');
  await assertFails(setDoc(doc(db, 'branch_members/uid-b2'), { branchId: 'b2' }));
  await assertFails(deleteDoc(doc(db, 'branch_members/uid-b1')));
  await assertFails(setDoc(doc(db, 'unlisted/x'), { branchId: 'b1' }));
});

test('credit reservations are server-only (Admin SDK); clients cannot read or write them', async () => {
  await env.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), 'credit_reservations/b1__r1'), { branchId: 'b1', customerId: 'c1', amount: 10 });
  });
  const db = dbFor('uid-b1');
  await assertFails(getDoc(doc(db, 'credit_reservations/b1__r1')));
  await assertFails(setDoc(doc(db, 'credit_reservations/b1__r2'), { branchId: 'b1', customerId: 'c1', amount: 10 }));
  await assertFails(deleteDoc(doc(db, 'credit_reservations/b1__r1')));
});

test('due_followups follow the same branch rules (own branch only)', async () => {
  await env.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), 'due_followups/other'), { branchId: 'b2', method: 'note', outcome: 'note' });
  });
  const db = dbFor('uid-b1');
  await assertSucceeds(setDoc(doc(db, 'due_followups/f1'), { branchId: 'b1', partyServerId: 'customer:T-1', method: 'call', outcome: 'promised', amount: 500 }));
  await assertSucceeds(getDoc(doc(db, 'due_followups/f1')));
  await assertFails(getDoc(doc(db, 'due_followups/other')));
  await assertFails(setDoc(doc(db, 'due_followups/wrong'), { branchId: 'b2', method: 'note', outcome: 'note' }));
});

test('due_followups: invalid fields are rejected, branchId cannot change', async () => {
  const db = dbFor('uid-b1');
  await assertFails(setDoc(doc(db, 'due_followups/bad1'), { branchId: 'b1', method: 'call', outcome: 'bogus' }));
  await assertFails(setDoc(doc(db, 'due_followups/bad2'), { branchId: 'b1', method: 'pigeon', outcome: 'note' }));
  await assertFails(setDoc(doc(db, 'due_followups/bad3'), { branchId: 'b1', method: 'call', outcome: 'paid', amount: -5 }));
  await assertSucceeds(setDoc(doc(db, 'due_followups/ok'), { branchId: 'b1', method: 'whatsapp', outcome: 'sent' }));
  await assertSucceeds(updateDoc(doc(db, 'due_followups/ok'), { outcome: 'paid', amount: 250 }));
  await assertFails(updateDoc(doc(db, 'due_followups/ok'), { branchId: 'b2' }));
  await assertSucceeds(deleteDoc(doc(db, 'due_followups/ok')));
});
