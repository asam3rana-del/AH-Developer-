# Staff authentication backend — staged foundation

## Critical status
This is a backend foundation, not a completed app migration. The Flutter login still validates local SQLite credentials and `SyncApi.firestoreFor()` still uses anonymous Firebase Auth. **Do not deploy `firebase/firestore.staff-claims.rules` to the live project**: it will deny current anonymous sync and will deny all cashier writes.

## Included
- Callable `staffLogin` with Firebase App Check enforcement and per-account/IP rate limits.
- Custom Firebase token with server-issued `staffId`, `branchId`, `role`, `active` claims.
- PBKDF2-HMAC-SHA256 verification compatible with `lib/utils/password_hasher.dart` (120,000 rounds, 16-byte salt, 32-byte output).
- `getMyStaffContext` token self-check.
- Claims-based branch rules; cashier direct writes deliberately denied.

## Staff account provisioning
A trusted Admin SDK process must create `staff_accounts/{normalizedUsername}` with:
`staffId` (immutable ID), `branchId`, `role` (`admin|manager|cashier`), `active` (boolean), and `passwordHash` (`pbkdf2$<32-hex-salt>$<64-hex-hash>`).
Never make this collection client-readable/writable. Never accept plaintext legacy passwords. Do not put service-account keys in the app.

## Deploy to staging only
1. Install Node.js 20 and Firebase CLI; in `functions/` run `npm install` and `npm run build`.
2. Configure Firebase App Check for the actual app; use debug providers only in local development.
3. Deploy Functions to a separate staging Firebase project.
4. Provision a test staff account using a trusted Admin SDK tool.
5. Call `staffLogin`, exchange its token using `FirebaseAuth.signInWithCustomToken`, then call `getMyStaffContext`.
6. Verify wrong password, inactive user, unknown user, malformed hash, throttling, and App Check rejection.
7. Test rules in Firebase Emulator Suite before any production cutover.

## App wiring (added, OPT-IN, default OFF)
- `lib/services/staff_auth.dart`: password login -> `staffLogin` -> `signInWithCustomToken` -> claims verified from the ID token.
- Settings > "Secure Cloud Login (staff)" switch (default OFF). OFF = unchanged behaviour (local login + anonymous sync).
- ON: sync never uses anonymous sign-in; without a verified staff session sync reports "not signed in". Local login still works offline.
- Needs `cloud_functions` + `firebase_app_check` (added to pubspec). Configure App Check (Play Integrity / DeviceCheck) first. Windows desktop is not supported by these plugins: leave the switch OFF there.
- **OTP / fingerprint / \"none\" login (added):** these have no password, so the server never trusts them. After the local login the app asks ONCE for the cloud password (`LoginScreen._ensureCloudSession`); Skip = offline, sync shows \"not signed in\". The password path asks only once (no double prompt). Not covered: the `skip_login` (after restore/import) and \"none\"-session auto-entry skip the prompt, so those sessions have no cloud sign-in until the next normal login.
- **Password sync (added):** callable `changeMyPassword` (own account, old password checked on the server, refresh tokens revoked, app signs in again with the new password) and `adminSetStaffAccount` (admin only, own branch only: create / role / active / password reset; cannot demote or deactivate self). App: Settings > Update Login and Manage Users call them when Secure Cloud Login is ON. Local \"Forgot password\" (device PIN) changes ONLY the local password, never the cloud one. Renaming a username does not rename the cloud account.
- **First admin:** cannot be created by the app (rules deny `staff_accounts`). Use `tools/staging/provision_staff.mjs` once; for a production project add `--production --confirm-project=<project id>`. After that admins manage staff from the app.
- NOT done yet: cashier server-side sale (cashier direct writes stay denied by the claims rules). Do not deploy claims rules until it exists. Deploy `functions` to STAGING and run the staff test plan first.
- Not compiled or run here: run `flutter pub get`, `flutter analyze`, `flutter test`, then test on staging.

## Remaining app migration
- Add `cloud_functions`; call `staffLogin` from password login and sign in with returned custom token.
- Do not trust the callable response for authorization; trust verified token claims.
- Remove anonymous sign-in from `SyncApi.firestoreFor()` only after custom-token login is wired.
- Keep local SQLite roles as offline UI cache only; offline users must not write to cloud.
- First-admin setup, OTP, biometric, no-password, password change/reset and deactivation are now handled (see above); user switching signs the cloud session out. Do not silently fall back to anonymous cloud access.

## Cashier sales (server-mediated sync push)
Instead of re-writing the offline queue around one big \"sale\" function, the app keeps its queue and only the TRANSPORT changes: with Secure Cloud Login ON and a verified **cashier** session, `SyncApi.push` sends each queue entry to the callable `pushSyncOp` (admin/manager still write directly, allowed by the claims rules). The server applies the same operations the app used to run itself: upsert (last-write-wins), delete (tombstone), create_if_absent, increment_stock / increment_balance (idempotent via `appliedOps`, same opId), set_stock.

What the server enforces (`functions/src/syncLogic.ts`, unit tested in `functions/test/sync_logic.test.mjs`):
- branch and role come ONLY from verified token claims; every document touched must already belong to that branch (Admin SDK bypasses rules, so this is the isolation).
- cashier may: upsert customer, sale, payment, expense, cash_transaction, return, stock_movement, shell_customer, shell_transaction, shop_empty_shell_log, due_followup; create_if_absent cash_register; increment_stock on products; increment_balance on customers.
- cashier may NOT: delete anything, set_stock, upsert products (price/cost), suppliers, purchases, users, settings, units/categories, payroll, rent, utility, zakat. Manager: everything except `users`. Admin: everything. (If an admin grants a cashier an extra local permission, e.g. Stock Taking, that cashier's entries for it will show \"permission denied\" in Sync History until the cashier role list is widened here.)
- fields a client can never set: `balance` (customer/supplier) and `stock` (product) via upsert, `appliedOps`, `pushedAt`, `upsertAt`, tombstones (`_deleted`, `_restore` for cashier); for EXISTING customers a cashier cannot change creditLimit / openingBalance / stuckBalance (new customers: stuckBalance still protected).
- limits: |stock delta| <= 1e6, |balance delta| <= 1e10, payload <= 200 KB, valid ids.

Honest limits: each queue entry is still its own operation (sale, stock delta, balance delta are separate calls, exactly like before; idempotent so retries are safe) - the server does NOT validate that a sale's lines match its stock/balance deltas or its prices, so a modified cashier client could still write wrong amounts inside its own branch. That needs a true sale-aggregate function and is a later step. The branch code in Cloud Sync Setup must equal the staff account's `branchId` (the server stamps the claim's branch; a device pulling another code would not see those documents).

**Before publishing `firestore.staff-claims.rules`:** (1) the claims rules currently let EVERY role read `users` (incl. password hashes), suppliers, purchases and payroll in the branch - restrict cashier reads (see `firestore.secure-draft.rules` `cashierReadable`) AND make the pull skip a collection that is permission-denied, otherwise a cashier's pull fails; (2) test with the Emulator Suite on staging; (3) keep rollback rules ready.

## Rollback
Keep live rules unchanged. Back up Firestore and local databases. Use a separate staging project and a tested rollback plan.
