# Firebase role security migration (production design)

**Status: design + non-deployable rules draft. Do not publish `firebase/firestore.secure-draft.rules` yet.**

## 1. Verified current architecture gap

- `lib/sync/sync_api.dart` calls `FirebaseAuth.signInAnonymously()` when no Firebase user exists.
- `lib/services/session.dart` loads `username`, `role`, and `permissions` from local `SharedPreferences`.
- `lib/screens/login_screen.dart` validates the normal username/password against the local SQLite `users` table (`UserRepository`).
- Therefore Firestore sees a device-level anonymous UID, not the currently logged-in local staff identity. A Firestore rule cannot securely distinguish Admin, Manager, and Cashier sessions on that device.
- OTP login uses Firebase Phone Auth, but the current flow resolves a phone number to a local SQLite user; it does not establish server-issued staff/branch/role custom claims.

**Consequence:** UI `RoleGuard` / local permissions are not server-side authorization. A modified client can bypass them while using the same device Firebase identity.

## 2. Target identity model

Every staff member must authenticate as a distinct Firebase Auth identity (or receive a Firebase custom token from a trusted backend). After verifying credentials and account status, trusted server code sets custom claims:

- `staffId`: immutable server-side staff identifier (not a mutable display name)
- `branchId`: authoritative branch identifier
- `role`: exactly `admin`, `manager`, or `cashier`
- `active`: boolean, true only for an enabled staff account

The app must stop using anonymous auth for production Firestore access. Local SQLite remains an offline cache, not the authority for identity or role. Password verification and role/branch assignment must happen on a trusted backend; never put Admin SDK credentials or signing secrets in the app.

## 3. Rules draft behavior

`firebase/firestore.secure-draft.rules` is deliberately fail-closed:

- rejects anonymous sessions and sessions without valid server-issued claims;
- checks every record against the claim's branch;
- denies client reads/writes to `users` (staff credentials/directory must be backend-managed);
- allows admin/manager branch-scoped writes; only admin can delete;
- limits cashier reads to operational collections;
- denies cashier writes until related sale, payment, stock and party-balance changes are moved to trusted server operations.

This means the draft is **not yet a usable release ruleset**: current cashier sale workflows may need several linked document writes. Allowing arbitrary cashier writes to `products` or `customers` would also let a modified client change prices or balances. Those writes need a callable/HTTPS backend that validates the business operation and applies all related changes atomically.

## 4. Required implementation sequence

1. Create a trusted staff-auth backend (Cloud Functions or another authenticated server) using Firebase Admin SDK.
2. Create a central staff directory with immutable staff IDs, branch, role, active status, and a secure credential/identity migration process. Existing local password hashes must not simply be copied into client-readable Firestore documents.
3. Migrate staff login to Firebase Auth/custom-token flow. Preserve a controlled offline mode, but do not treat offline local role checks as cloud authorization.
4. Issue/revoke custom claims on staff creation, role change, branch transfer, and deactivation. Force token refresh after changes; document token-revocation behavior.
5. Move cashier sale/payment operations and linked stock/customer balance updates to a trusted server transaction. Validate quantities, prices, branch, idempotency key, and allowed action server-side.
6. Add Admin SDK provisioning/migration tooling for existing device accounts. Inventory every existing anonymous UID and branch mapping before cutover.
7. Test the draft with Firebase Emulator Suite before deployment. Do not deploy until all app sync operations have matching authorized paths and no legitimate workflow is denied.

## 5. Mandatory security test matrix

| Scenario | Expected result |
|---|---|
| No Firebase auth | Deny |
| Anonymous Firebase auth | Deny |
| Authenticated token missing claims | Deny |
| `active=false` | Deny |
| Invalid role | Deny |
| Claim branch differs from document branch | Deny |
| Cashier reads allowed operational collection in own branch | Allow |
| Cashier reads purchases/suppliers/payroll/settings | Deny |
| Cashier directly writes sales/products/customer balances | Deny in draft; use trusted operation endpoint |
| Manager writes within own branch | Allow |
| Manager writes another branch | Deny |
| Manager deletes records | Deny |
| Admin writes own branch | Allow |
| Admin deletes own branch records | Allow |
| Client creates/edits `users` or `branch_members` | Deny |

## 6. Cutover safety

- Keep current live rules unchanged until backend auth, claims, server operations, emulator tests, and staging sync tests all pass.
- Back up Firestore and local databases before migration.
- Do not bulk-edit branch membership or deploy the draft during business hours.
- Run a two-device reconciliation for sales, purchases, payments, stock, customer/supplier balances, cash, expenses, returns, and reports.
- Keep rollback rules and a tested restore point available.

## 7. Files inspected

- `lib/sync/sync_api.dart`
- `lib/services/session.dart`
- `lib/services/otp_login.dart`
- `lib/screens/login_screen.dart`
- `lib/sync/sync_push_plan.dart`
- `docs/CLOUD_SYNC_SETUP.md`
- `firebase/firestore.rules`
