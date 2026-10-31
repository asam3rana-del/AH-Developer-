// Creates/updates staff_accounts/{username} in the STAGING Firestore project only.
//   node provision_staff.mjs staff.json                (dry run: prints what would be written, writes nothing)
//   node provision_staff.mjs staff.json --apply        (really writes)
// Needs: GOOGLE_APPLICATION_CREDENTIALS = service-account key of the STAGING project (never commit it).
// staff.json: [{ "username": "asim", "role": "admin", "branchId": "main", "password": "..." }, ...]
//   instead of "password" you may give "passwordHash": "pbkdf2$<32hex>$<64hex>" (same format as the app).
import { readFileSync } from 'node:fs';
import { randomBytes, pbkdf2Sync } from 'node:crypto';

const args = process.argv.slice(2);
const file = args.find((a) => !a.startsWith('--'));
const apply = args.includes('--apply');
if (!file) { console.error('usage: node provision_staff.mjs staff.json [--apply]'); process.exit(1); }

const keyPath = process.env.GOOGLE_APPLICATION_CREDENTIALS;
if (!keyPath) { console.error('Set GOOGLE_APPLICATION_CREDENTIALS to the staging service-account key file.'); process.exit(1); }
const projectId = JSON.parse(readFileSync(keyPath, 'utf8')).project_id;
if (!/staging/i.test(projectId)) {
  console.error(`Refusing: key belongs to project "${projectId}", which is not a staging project.`);
  process.exit(1);
}

const ROLES = ['admin', 'manager', 'cashier'];
const USERNAME = /^[a-zA-Z0-9_.-]{3,40}$/;
const HASH = /^pbkdf2\$[0-9a-f]{32}\$[0-9a-f]{64}$/;
const hashPassword = (p) => {
  const salt = randomBytes(16);
  return `pbkdf2$${salt.toString('hex')}$${pbkdf2Sync(p, salt, 120000, 32, 'sha256').toString('hex')}`;
};

const rows = JSON.parse(readFileSync(file, 'utf8'));
const plan = rows.map((r, i) => {
  const username = String(r.username ?? '').trim().toLowerCase();
  if (!USERNAME.test(username)) throw new Error(`row ${i}: bad username`);
  if (!ROLES.includes(r.role)) throw new Error(`row ${i} (${username}): role must be admin|manager|cashier`);
  if (!r.branchId || typeof r.branchId !== 'string') throw new Error(`row ${i} (${username}): branchId required`);
  let passwordHash = r.passwordHash;
  if (passwordHash === undefined) {
    if (typeof r.password !== 'string' || r.password.length < 4) throw new Error(`row ${i} (${username}): password (min 4 chars) or passwordHash required`);
    passwordHash = hashPassword(r.password);
  } else if (!HASH.test(passwordHash)) throw new Error(`row ${i} (${username}): passwordHash format is wrong`);
  return { username, role: r.role, branchId: r.branchId, active: r.active !== false, passwordHash };
});

console.log(`Project: ${projectId}  |  mode: ${apply ? 'APPLY' : 'DRY RUN (nothing written)'}`);
for (const p of plan) console.log(` - ${p.username}  role=${p.role}  branch=${p.branchId}  active=${p.active}`);
if (!apply) { console.log('\nDry run only. Add --apply to write.'); process.exit(0); }

const { initializeApp, applicationDefault } = await import('firebase-admin/app');
const { getFirestore, FieldValue } = await import('firebase-admin/firestore');
initializeApp({ credential: applicationDefault(), projectId });
const db = getFirestore();
for (const p of plan) {
  const ref = db.collection('staff_accounts').doc(p.username);
  const snap = await ref.get();
  // staffId is immutable: keep the existing one when the account already exists
  const staffId = snap.exists ? snap.data().staffId : `st_${randomBytes(12).toString('hex')}`;
  await ref.set({ staffId, branchId: p.branchId, role: p.role, active: p.active, passwordHash: p.passwordHash,
                  updatedAt: FieldValue.serverTimestamp() }, { merge: true });
  console.log(`written: ${p.username}`);
}
