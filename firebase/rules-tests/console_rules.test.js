// Tests for firebase/firestore.console.rules (the hard-coded "dusri-branch" rules live in the Console).
import { readFileSync } from 'node:fs';
import { test, before, after, beforeEach } from 'node:test';
import { initializeTestEnvironment, assertFails, assertSucceeds } from '@firebase/rules-unit-testing';
import { doc, getDoc, setDoc, updateDoc, deleteDoc } from 'firebase/firestore';

let env;
const rules = readFileSync(new URL('../firestore.console.rules', import.meta.url), 'utf8');
const B = 'dusri-branch';

before(async () => {
  env = await initializeTestEnvironment({
    projectId: 'demo-ah-console-rules',
    firestore: { rules, host: '127.0.0.1', port: 8080 },
  });
});
after(async () => { await env.cleanup(); });
beforeEach(async () => {
  await env.clearFirestore();
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await setDoc(doc(db, 'sales/s1'), { branchId: B, total: 100 });
    await setDoc(doc(db, 'sales/s2'), { branchId: 'other', total: 50 });
  });
});

const db = () => env.authenticatedContext('any-uid').firestore();

test('unauthenticated cannot read or write', async () => {
  const u = env.unauthenticatedContext().firestore();
  await assertFails(getDoc(doc(u, 'sales/s1')));
  await assertFails(setDoc(doc(u, 'sales/new'), { branchId: B }));
});

test('signed-in reads/creates only dusri-branch records', async () => {
  await assertSucceeds(getDoc(doc(db(), 'sales/s1')));
  await assertFails(getDoc(doc(db(), 'sales/s2')));
  await assertSucceeds(setDoc(doc(db(), 'sales/new'), { branchId: B, total: 1 }));
  await assertFails(setDoc(doc(db(), 'sales/wrong'), { branchId: 'other', total: 1 }));
  await assertFails(setDoc(doc(db(), 'sales/missing'), { total: 1 }));
});

test('update cannot move a record to another branch; unknown collections denied', async () => {
  await assertSucceeds(updateDoc(doc(db(), 'sales/s1'), { total: 101 }));
  await assertFails(updateDoc(doc(db(), 'sales/s1'), { branchId: 'other' }));
  await assertFails(setDoc(doc(db(), 'unlisted/x'), { branchId: B }));
});

test('due_followups: valid entry works, invalid fields rejected', async () => {
  await assertSucceeds(setDoc(doc(db(), 'due_followups/f1'), { branchId: B, partyServerId: 'customer:T-1', method: 'call', outcome: 'promised', amount: 500 }));
  await assertSucceeds(getDoc(doc(db(), 'due_followups/f1')));
  await assertFails(setDoc(doc(db(), 'due_followups/bad1'), { branchId: B, method: 'call', outcome: 'bogus' }));
  await assertFails(setDoc(doc(db(), 'due_followups/bad2'), { branchId: B, method: 'pigeon', outcome: 'note' }));
  await assertFails(setDoc(doc(db(), 'due_followups/bad3'), { branchId: B, method: 'call', outcome: 'paid', amount: -5 }));
  await assertFails(setDoc(doc(db(), 'due_followups/wrong'), { branchId: 'other', method: 'note', outcome: 'note' }));
});

test('due_followups: update keeps branch, delete works', async () => {
  await assertSucceeds(setDoc(doc(db(), 'due_followups/ok'), { branchId: B, method: 'whatsapp', outcome: 'sent' }));
  await assertSucceeds(updateDoc(doc(db(), 'due_followups/ok'), { outcome: 'paid', amount: 250 }));
  await assertFails(updateDoc(doc(db(), 'due_followups/ok'), { branchId: 'other' }));
  await assertSucceeds(deleteDoc(doc(db(), 'due_followups/ok')));
});
