# Server credit-limit check (cross-device) — opt-in, NOT yet staging-tested

## Problem
Sales are saved locally first and the balance change is pushed later as an increment. Two ONLINE devices can
both pass their local credit check against the same stale balance and together push the customer over the limit.

## What this adds
- Cloud Function `reserveCredit` (`functions/src/index.ts`). Under a Firestore transaction it computes
  `openingBalance + balance + stuckBalance + other devices' open reservations + this bill` for the customer's cloud
  document and answers allowed / blocked. When allowed it stores a short-lived reservation in
  `credit_reservations/{branchId}__{reservationId}` (TTL 5 min) so the next device sees it.
- The branch always comes from the signed-in identity (custom claim `branchId`, else `branch_members/{uid}`), never from
  the request. Clients cannot read or write `credit_reservations` (default-deny rules; covered by
  `firebase/rules-tests/baseline_rules.test.js`).
- App: `lib/services/credit_guard.dart`, called from `SaleRepository.saveSale` and `saveQuickSale` before anything is
  written. Settings > "Server credit-limit check" switch (default OFF = behaviour unchanged).
- Composite index `credit_reservations (branchId, customerId, expiresAt)` added to `firebase/firestore.indexes.json`.

## Deploy (staging project first)
**Prerequisite:** Cloud Functions need the **Blaze plan**; staging (`ah-staging-a1b2c`) is on Spark today
(`docs/STAGING_FIREBASE.md`). Enable Blaze on STAGING only and set a budget alert first. Anonymous sign-in must be
enabled there (the app's sync uses it).
1. Termux setup as in `docs/STAGING_FIREBASE.md` (Node, firebase-tools login, staging service-account key).
2. `bash tools/staging/deploy_credit_check.sh` - builds `functions/`, deploys only `reserveCredit` and the Firestore
   indexes to the staging project (project id is fixed in the script). Wait until the new index shows "Enabled".
3. `cd tools/staging && npm install && node test_credit_check.mjs --api-key <staging web API key>` - simulates two
   devices against the deployed function (allowed / blocked / retry not double-counted / unknown customer / bad amount),
   then cleans up its own test data. All lines must say PASS.
4. Real-device test: switch ON in Settings on two staging devices, same customer, balance just under the limit, save a
   credit bill on both at nearly the same time -> the second shows "Credit Limit Exceeded". Then go offline -> sale still saves.

## Known limits (be honest with the shop owner)
- **Offline is fail-open.** No internet / not signed in / 4 s timeout / any server error => the sale continues on the local
  check only. A device that is offline cannot be stopped, and its later sync can still push a customer over the limit.
- The server balance is only as fresh as what other devices have already pushed. Pending offline sales of another
  device are invisible until they sync.
- A reservation is not released when the sale syncs, so for up to 5 minutes the same bill can be counted twice (server
  balance + reservation). This can cause an occasional false "limit exceeded" right after a sale; "Save Anyway" works.
- A reservation is not released if the local save fails afterwards (stock error etc.); it simply expires.
- "Save Anyway" still lets the cashier override, exactly as before. Restricting the override to admin/manager is a
  business decision that is not made here.
- `enforceAppCheck` is OFF for `reserveCredit` (App Check is opt-in in this project). Sign-in is still required.
- Not compiled against the real SDKs and not run on staging in the authoring environment (no network): run
  `flutter analyze`, `flutter test` (`test/credit_guard_test.dart`), the rules test and the staging steps above.
