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
