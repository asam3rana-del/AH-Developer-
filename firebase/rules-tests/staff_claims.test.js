// Security matrix from docs/FIREBASE_ROLE_SECURITY_MIGRATION.md, section 5, run against
// firebase/firestore.staff-claims.rules in the Firestore emulator. Nothing here touches production.
import { readFileSync } from 'node:fs';
import { test, before, after, beforeEach } from 'node:test';
import { initializeTestEnvironment, assertFails, assertSucceeds } from '@firebase/rules-unit-testing';
import { doc, getDoc, setDoc, deleteDoc, updateDoc } from 'firebase/firestore';

let env;
const rules = readFileSync(new URL('../firestore.staff-claims.rules', import.meta.url), 'utf8');

before(async () => {
  env = await initializeTestEnvironment({ projectId: 'demo-ah-rules', firestore: { rules, host: '127.0.0.1', port: 8080 } });
});
after(async () => { await env.cleanup(); });
beforeEach(async () => {
  await env.clearFirestore();
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await setDoc(doc(db, 'sales/s1'), { branchId: 'b1', total: 100 });
    await setDoc(doc(db, 'sales/other'), { branchId: 'b2', total: 5 });
    await setDoc(doc(db, 'products/p1'), { branchId: 'b1', salePrice: 10 });
    await setDoc(doc(db, 'staff_accounts/ali'), { branchId: 'b1', role: 'admin' });
    await setDoc(doc(db, 'branch_members/u1'), { branchId: 'b1' });
  });
});

const claims = (role, extra = {}) => ({ staffId: 'st1', branchId: 'b1', role, active: true, ...extra });
const as = (c) => env.authenticatedContext('uid1', c).firestore();

test('no auth: deny', async () => {
  await assertFails(getDoc(doc(env.unauthenticatedContext().firestore(), 'sales/s1')));
});
test('anonymous / token without claims: deny', async () => {
  await assertFails(getDoc(doc(env.authenticatedContext('anon').firestore(), 'sales/s1')));
});
test('active=false: deny', async () => {
  await assertFails(getDoc(doc(as(claims('admin', { active: false })), 'sales/s1')));
});
test('invalid role: deny', async () => {
  await assertFails(getDoc(doc(as(claims('owner')), 'sales/s1')));
});
test('claim branch differs from document branch: deny', async () => {
  await assertFails(getDoc(doc(as(claims('admin')), 'sales/other')));
});
test('cashier reads own-branch sale: allow', async () => {
  await assertSucceeds(getDoc(doc(as(claims('cashier')), 'sales/s1')));
});
test('cashier direct write sales/products: deny', async () => {
  const db = as(claims('cashier'));
  await assertFails(setDoc(doc(db, 'sales/new'), { branchId: 'b1', total: 1 }));
  await assertFails(updateDoc(doc(db, 'products/p1'), { salePrice: 1 }));
});
test('manager writes own branch: allow', async () => {
  await assertSucceeds(setDoc(doc(as(claims('manager')), 'sales/new'), { branchId: 'b1', total: 1 }));
});
test('manager writes another branch: deny', async () => {
  await assertFails(setDoc(doc(as(claims('manager')), 'sales/new'), { branchId: 'b2', total: 1 }));
});
test('manager cannot move a record to another branch: deny', async () => {
  await assertFails(updateDoc(doc(as(claims('manager')), 'sales/s1'), { branchId: 'b2' }));
});
test('manager delete: deny', async () => {
  await assertFails(deleteDoc(doc(as(claims('manager')), 'sales/s1')));
});
test('admin writes and deletes own branch: allow', async () => {
  const db = as(claims('admin'));
  await assertSucceeds(setDoc(doc(db, 'sales/new'), { branchId: 'b1', total: 1 }));
  await assertSucceeds(deleteDoc(doc(db, 'sales/s1')));
});
test('admin writes another branch: deny', async () => {
  await assertFails(setDoc(doc(as(claims('admin')), 'sales/new'), { branchId: 'b2', total: 1 }));
});
test('client touches staff_accounts / branch_members: deny', async () => {
  const db = as(claims('admin'));
  await assertFails(getDoc(doc(db, 'staff_accounts/ali')));
  await assertFails(setDoc(doc(db, 'staff_accounts/new'), { role: 'admin' }));
  await assertFails(setDoc(doc(db, 'branch_members/u9'), { branchId: 'b1' }));
});
test('unknown collection: deny', async () => {
  await assertFails(setDoc(doc(as(claims('admin')), 'random/x'), { branchId: 'b1' }));
});
