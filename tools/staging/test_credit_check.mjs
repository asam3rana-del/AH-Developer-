// End-to-end check of the deployed reserveCredit function in the STAGING project (simulates two devices).
//   node test_credit_check.mjs --api-key <staging Web API key> [--region us-central1]
// Needs: GOOGLE_APPLICATION_CREDENTIALS = staging service-account key (never commit it). Anonymous sign-in must be
// enabled in the staging project (Authentication > Sign-in method). Creates a throw-away customer/member under
// branch "credit-test" and deletes them at the end.
import { readFileSync } from 'node:fs';
import { initializeApp, applicationDefault } from 'firebase-admin/app';
import { getFirestore } from 'firebase-admin/firestore';

const args = process.argv.slice(2);
const opt = (n, d) => { const i = args.indexOf(n); return i >= 0 ? args[i + 1] : d; };
const apiKey = opt('--api-key');
const region = opt('--region', 'us-central1');
if (!apiKey) { console.error('usage: node test_credit_check.mjs --api-key <key> [--region us-central1]'); process.exit(1); }

const keyPath = process.env.GOOGLE_APPLICATION_CREDENTIALS;
if (!keyPath) { console.error('Set GOOGLE_APPLICATION_CREDENTIALS to the staging service-account key file.'); process.exit(1); }
const projectId = JSON.parse(readFileSync(keyPath, 'utf8')).project_id;
if (!/staging/i.test(projectId)) { console.error(`Refusing: key belongs to "${projectId}", not a staging project.`); process.exit(1); }

initializeApp({ credential: applicationDefault(), projectId });
const db = getFirestore();
const BRANCH = 'credit-test';
const CUSTOMER = 'customer:credit-test-ali';

async function signInAnonymously() {
  const r = await fetch(`https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=${apiKey}`, {
    method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ returnSecureToken: true }),
  });
  const j = await r.json();
  if (!r.ok) throw new Error(`anonymous sign-in failed: ${JSON.stringify(j)}`);
  return { uid: j.localId, token: j.idToken };
}
async function reserve(dev, reservationId, amount, customerId = CUSTOMER) {
  const r = await fetch(`https://${region}-${projectId}.cloudfunctions.net/reserveCredit`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: `Bearer ${dev.token}` },
    body: JSON.stringify({ data: { customerId, reservationId, amount } }),
  });
  const j = await r.json();
  if (!r.ok) return { error: j.error ?? j };
  return j.result;
}

let failed = 0;
const check = (name, ok, extra) => { console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${extra ? '  ' + JSON.stringify(extra) : ''}`); if (!ok) failed++; };

const devA = await signInAnonymously();
const devB = await signInAnonymously();
const created = [];
try {
  for (const d of [devA, devB]) { await db.doc(`branch_members/${d.uid}`).set({ branchId: BRANCH }); created.push(`branch_members/${d.uid}`); }
  await db.doc(`customers/${CUSTOMER}`).set({ branchId: BRANCH, name: 'Credit Test Ali', creditLimit: 1000, openingBalance: 0, balance: 800, stuckBalance: 0 });
  created.push(`customers/${CUSTOMER}`);

  const a = await reserve(devA, 'test-a', 150);
  check('device A: Rs 150 on balance 800 / limit 1000 is allowed', a.allowed === true, a);
  const b = await reserve(devB, 'test-b', 150);
  check('device B at the same time: blocked (800 + 150 reserved by A + 150 = 1100)', b.allowed === false && Math.abs(b.projected - 1100) < 0.01, b);
  const a2 = await reserve(devA, 'test-a', 150);
  check('device A retries the SAME reservation: still allowed (not counted twice)', a2.allowed === true && Math.abs(a2.projected - 950) < 0.01, a2);
  const none = await reserve(devB, 'test-c', 1, 'customer:does-not-exist');
  check('unknown customer: allowed, not enforced', none.allowed === true && none.enforced === false, none);
  const bad = await reserve(devB, 'test-d', -5);
  check('negative amount is rejected', !!bad.error, bad);
} catch (e) {
  console.error('ERROR', e);
  failed++;
} finally {
  for (const p of created) await db.doc(p).delete().catch(() => {});
  for (const id of ['test-a', 'test-b']) await db.doc(`credit_reservations/${BRANCH}__${id}`).delete().catch(() => {});
}
console.log(failed === 0 ? '\nALL PASSED' : `\n${failed} FAILED`);
process.exit(failed === 0 ? 0 : 1);
