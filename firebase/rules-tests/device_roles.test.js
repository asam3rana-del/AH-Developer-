// Device roles (no Cloud Functions needed): firebase/firestore.device-roles.rules, emulator only.
// A branch_members/{uid} document may carry role = admin | manager | cashier; no role = full access (today).
import { readFileSync } from 'node:fs';
import { test, before, after, beforeEach } from 'node:test';
import { initializeTestEnvironment, assertFails, assertSucceeds } from '@firebase/rules-unit-testing';
import { doc, getDoc, setDoc, updateDoc, deleteDoc, collection, query, where, getDocs } from 'firebase/firestore';

const rules = readFileSync(new URL('../firestore.device-roles.rules', import.meta.url), 'utf8');

const TILL = ['customers', 'products', 'sales', 'payments', 'expenses', 'cash_transactions', 'cash_register',
  'units', 'categories', 'returns', 'stock_movements', 'app_settings', 'shell_customers', 'shell_transactions',
  'shop_empty_shell_log'];
const NOT_TILL = ['users', 'suppliers', 'purchases', 'zakat_years', 'zakat_payments', 'workers', 'worker_attendance',
  'worker_advances', 'worker_salary_payments', 'shop_rents', 'shop_rent_ledger', 'utility_bills', 'utility_bill_payments'];

let env;
before(async () => {
  env = await initializeTestEnvironment({ projectId: 'demo-ah-device-roles', firestore: { rules, host: '127.0.0.1', port: 8080 } });
});
after(async () => { await env.cleanup(); });
beforeEach(async () => {
  await env.clearFirestore();
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore(); // once
    await setDoc(doc(db, 'branch_members/u-old'), { branchId: 'b1' });                    // no role = full access
    await setDoc(doc(db, 'branch_members/u-admin'), { branchId: 'b1', role: 'admin' });
    await setDoc(doc(db, 'branch_members/u-mgr'), { branchId: 'b1', role: 'manager' });
    await setDoc(doc(db, 'branch_members/u-cash'), { branchId: 'b1', role: 'cashier' });
    for (const c of [...TILL, ...NOT_TILL]) {
      await setDoc(doc(db, `${c}/x`), { branchId: 'b1', total: 1 });
      await setDoc(doc(db, `${c}/foreign`), { branchId: 'b2', total: 1 });
    }
    await setDoc(doc(db, 'products/p1'), { branchId: 'b1', name: 'Rice', salePrice: 100, cost: 80, stock: 10, appliedOps: {} });
    await setDoc(doc(db, 'customers/c1'), { branchId: 'b1', name: 'Ali', balance: 0, creditLimit: 500, openingBalance: 0, stuckBalance: 0 });
    await setDoc(doc(db, 'sales/s1'), { branchId: 'b1', total: 50 });
    await setDoc(doc(db, 'due_followups/f1'), { branchId: 'b1', method: 'note', outcome: 'note' });
  });
});
const as = (uid) => env.authenticatedContext(uid).firestore();

test('device without role keeps today\'s full access (rollout is safe)', async () => {
  const db = as('u-old');
  await assertSucceeds(getDoc(doc(db, 'users/x')));
  await assertSucceeds(updateDoc(doc(db, 'products/p1'), { salePrice: 120 }));
  await assertSucceeds(setDoc(doc(db, 'suppliers/new'), { branchId: 'b1', name: 'S' }));
  await assertSucceeds(deleteDoc(doc(db, 'sales/s1')));
});

test('manager and admin devices: full access in their branch, never another branch', async () => {
  for (const uid of ['u-mgr', 'u-admin']) {
    const db = as(uid);
    await assertSucceeds(getDoc(doc(db, 'users/x')));
    await assertSucceeds(updateDoc(doc(db, 'products/p1'), { salePrice: 120 }));
    await assertFails(getDoc(doc(db, 'sales/foreign')));
    await assertFails(updateDoc(doc(db, 'sales/foreign'), { total: 2 }));
  }
});

test('cashier reads the till collections (doc and pull query) but not the rest', async () => {
  const db = as('u-cash');
  for (const c of TILL) {
    await assertSucceeds(getDoc(doc(db, `${c}/x`)));
    await assertSucceeds(getDocs(query(collection(db, c), where('branchId', '==', 'b1'))));
  }
  for (const c of NOT_TILL) {
    await assertFails(getDoc(doc(db, `${c}/x`)));
    await assertFails(getDocs(query(collection(db, c), where('branchId', '==', 'b1'))));
  }
  await assertFails(getDoc(doc(db, 'sales/foreign')));
});

test('cashier creates sale / payment / customer / stock movement but not suppliers, products, settings, users', async () => {
  const db = as('u-cash');
  for (const c of ['sales', 'payments', 'customers', 'stock_movements', 'expenses', 'cash_register', 'returns'])
    await assertSucceeds(setDoc(doc(db, `${c}/new1`), { branchId: 'b1', total: 5 }));
  for (const c of ['suppliers', 'products', 'purchases', 'app_settings', 'users', 'units', 'workers'])
    await assertFails(setDoc(doc(db, `${c}/new1`), { branchId: 'b1', name: 'n' }));
  await assertFails(setDoc(doc(db, 'sales/new2'), { branchId: 'b2', total: 5 }));        // other branch
  await assertFails(setDoc(doc(db, 'sales/new3'), { total: 5 }));                        // no branchId
});

test('cashier stock increment: only stock/updatedAt/appliedOps on a product', async () => {
  const db = as('u-cash');
  await assertSucceeds(updateDoc(doc(db, 'products/p1'), { stock: 8, updatedAt: 5, appliedOps: { 'd-1-1': 5 } }));
  await assertFails(updateDoc(doc(db, 'products/p1'), { salePrice: 1 }));
  await assertFails(updateDoc(doc(db, 'products/p1'), { cost: 1 }));
  await assertFails(updateDoc(doc(db, 'products/p1'), { name: 'x' }));
  await assertFails(updateDoc(doc(db, 'products/p1'), { stock: 8, salePrice: 1 }));
});

test('cashier customer: balance changes ok, credit limit / opening / stuck balance never', async () => {
  const db = as('u-cash');
  await assertSucceeds(updateDoc(doc(db, 'customers/c1'), { balance: 40, updatedAt: 5, appliedOps: { a: 1 } }));
  await assertSucceeds(updateDoc(doc(db, 'customers/c1'), { name: 'Ali Khan', creditLimit: 500 })); // unchanged value = not a change
  await assertFails(updateDoc(doc(db, 'customers/c1'), { creditLimit: 999999 }));
  await assertFails(updateDoc(doc(db, 'customers/c1'), { openingBalance: 5 }));
  await assertFails(updateDoc(doc(db, 'customers/c1'), { stuckBalance: 5 }));
});

test('cashier can edit a sale but can never delete: no tombstone, no real delete, no branch change', async () => {
  const db = as('u-cash');
  await assertSucceeds(updateDoc(doc(db, 'sales/s1'), { total: 60, updatedAt: 9 }));
  await assertFails(updateDoc(doc(db, 'sales/s1'), { _deleted: true, updatedAt: 9 }));
  await assertFails(deleteDoc(doc(db, 'sales/s1')));
  await assertFails(updateDoc(doc(db, 'sales/s1'), { branchId: 'b2' }));
  await assertFails(updateDoc(doc(db, 'suppliers/x'), { total: 2 }));
  await assertFails(updateDoc(doc(db, 'users/x'), { total: 2 }));
  await assertFails(updateDoc(doc(db, 'purchases/x'), { total: 2 }));
});

test('due_followups: cashier can add / read, cannot delete; manager can delete', async () => {
  await assertSucceeds(setDoc(doc(as('u-cash'), 'due_followups/f2'), { branchId: 'b1', method: 'call', outcome: 'sent' }));
  await assertSucceeds(getDoc(doc(as('u-cash'), 'due_followups/f1')));
  await assertFails(deleteDoc(doc(as('u-cash'), 'due_followups/f1')));
  await assertSucceeds(deleteDoc(doc(as('u-mgr'), 'due_followups/f1')));
});

test('unprovisioned / unauthenticated: nothing; nobody can write branch_members', async () => {
  await assertFails(getDoc(doc(as('u-nobody'), 'sales/s1')));
  await assertFails(getDoc(doc(env.unauthenticatedContext().firestore(), 'sales/s1')));
  await assertFails(updateDoc(doc(as('u-cash'), 'branch_members/u-cash'), { role: 'admin' }));
  await assertFails(setDoc(doc(as('u-cash'), 'branch_members/u-cash'), { branchId: 'b1', role: 'admin' }));
});
