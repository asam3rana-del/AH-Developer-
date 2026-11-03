// Run: npm run build && node --test test/   (from functions/)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as L from '../lib/syncLogic.js';

test('cashier matrix', () => {
  assert.equal(L.roleMayDo('cashier', 'sale', 'upsert'), true);
  assert.equal(L.roleMayDo('cashier', 'sale', 'delete'), false);
  assert.equal(L.roleMayDo('cashier', 'product', 'upsert'), false);
  assert.equal(L.roleMayDo('cashier', 'product', 'increment_stock'), true);
  assert.equal(L.roleMayDo('cashier', 'product', 'set_stock'), false);
  assert.equal(L.roleMayDo('cashier', 'customer', 'increment_balance'), true);
  assert.equal(L.roleMayDo('cashier', 'supplier', 'increment_balance'), false);
  assert.equal(L.roleMayDo('cashier', 'user', 'upsert'), false);
  assert.equal(L.roleMayDo('cashier', 'app_setting', 'upsert'), false);
  assert.equal(L.roleMayDo('cashier', 'purchase', 'upsert'), false);
  assert.equal(L.roleMayDo('cashier', 'cash_register', 'create_if_absent'), true);
  assert.equal(L.roleMayDo('cashier', 'cash_register', 'upsert'), false);
  assert.equal(L.roleMayDo('manager', 'user', 'upsert'), false);
  assert.equal(L.roleMayDo('manager', 'product', 'upsert'), true);
  assert.equal(L.roleMayDo('admin', 'user', 'upsert'), true);
  assert.equal(L.roleMayDo('admin', 'nonsense', 'upsert'), false);
  assert.equal(L.roleMayDo('admin', 'sale', 'drop_table'), false);
});

test('ids', () => {
  assert.equal(L.validEntityId('sale:dev-1'), true);
  assert.equal(L.validEntityId('a/b'), false);
  assert.equal(L.validEntityId('..'), false);
  assert.equal(L.validEntityId('__x__'), false);
  assert.equal(L.validEntityId(''), false);
  assert.equal(L.validOpId('dev-12-1700000000000'), true);
  assert.equal(L.validOpId('a.b'), false);
});

test('upsert hygiene', () => {
  const raw = { name: 'x', balance: 5, stock: 9, appliedOps: {a: 1}, pushedAt: 1, upsertAt: 1, _deleted: true, creditLimit: 99, openingBalance: 1, stuckBalance: 2, branchId: 'evil' };
  const cust = L.sanitizeUpsertPayload('customer', 'cashier', raw, true);
  for (const k of ['balance', 'appliedOps', 'pushedAt', 'upsertAt', '_deleted', 'creditLimit', 'openingBalance', 'stuckBalance'])
    assert.equal(k in cust, false, k);
  const fresh = L.sanitizeUpsertPayload('customer', 'cashier', raw, false);
  assert.equal(fresh.creditLimit, 99);
  assert.equal('stuckBalance' in fresh, false);
  const prod = L.sanitizeUpsertPayload('product', 'manager', raw, true);
  assert.equal('stock' in prod, false);
  assert.throws(() => L.sanitizeUpsertPayload('customer', 'cashier', { _restore: true }, true), L.SyncRuleError);
  assert.throws(() => L.sanitizeUpsertPayload('sale', 'cashier', [1], true), L.SyncRuleError);
  // branch is always overwritten from the verified claim
  assert.equal(L.stampPayload(cust, 'b1', 5).map.branchId, 'b1');
});

test('stamp / last-write-wins / delete / create_if_absent', () => {
  assert.equal(L.stampPayload({ updatedAt: 100 }, 'b1', 500).incomingUpdatedAt, 100);
  assert.equal(L.stampPayload({}, 'b1', 500).incomingUpdatedAt, 500);
  const r = L.stampPayload({ _restore: true, x: 1 }, 'b1', 500);
  assert.equal(r.map._deleted, false);
  assert.equal('_restore' in r.map, false);
  assert.equal(L.shouldApplyUpsert(10, null), true);
  assert.equal(L.shouldApplyUpsert(10, 11), false);
  assert.equal(L.upsertClock({ upsertAt: 7, _deleted: true, updatedAt: 9 }), 7);
  assert.equal(L.upsertClock({ _deleted: true, updatedAt: 9 }), 9);
  assert.equal(L.upsertClock({ updatedAt: 9 }), null);
  assert.equal(L.canCreateIfAbsent(false, undefined), true);
  assert.equal(L.canCreateIfAbsent(true, { _deleted: true }), true);
  assert.equal(L.canCreateIfAbsent(true, { x: 1 }), false);
});

test('appliedOps pruning keeps newest 999 + new, drops >30d', () => {
  const now = 1_800_000_000_000;
  const applied = { old: now - 31 * 86400000, a: now - 1000, b: now - 500 };
  const k = L.pruneAppliedOps(applied, 'new', now);
  assert.deepEqual(Object.keys(k).sort(), ['a', 'b', 'new']);
  const many = {};
  for (let i = 0; i < 1200; i++) many['op' + i] = now - 5000 + i;
  const k2 = L.pruneAppliedOps(many, 'new', now);
  assert.equal(Object.keys(k2).length, 1000);
  assert.equal('op0' in k2, false);
  assert.equal('op1199' in k2, true);
});

test('delta limits and rounding', () => {
  assert.equal(L.checkDelta('increment_stock', -2.5), -2.5);
  assert.throws(() => L.checkDelta('increment_stock', 1e7), L.SyncRuleError);
  assert.throws(() => L.checkDelta('increment_balance', NaN), L.SyncRuleError);
  assert.throws(() => L.checkDelta('increment_balance', '5'), L.SyncRuleError);
  assert.equal(L.roundQty(0.1 + 0.2), 0.3);
});
