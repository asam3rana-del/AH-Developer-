# AH-Developer — implemented source improvements

Date: 30 October 2026

## Changes applied in this revision

### 1. CI release gate (P0)

- Android, iOS and Windows build jobs now declare `needs: analyze-test`.
- A failed analysis/test job therefore blocks all three platform build jobs.
- The analysis job now fails if the `test/` directory or Dart test files are missing. Tests can no longer be silently skipped because the suite disappeared.
- The test command uses the expanded reporter to make CI failure output easier to diagnose.

## Deliberately not changed

### Firebase production rules

The repository documentation describes the current anonymous Firebase identity and local SQLite staff-login model. The stricter custom-claims rules draft is explicitly marked non-deployable until staff authentication and cashier server-side business operations are migrated.

For safety, this revision does **not** replace `firebase/firestore.rules` with either draft rules file. Doing so prematurely could break existing cloud sync and legitimate cashier workflows. Follow `docs/FIREBASE_ROLE_SECURITY_MIGRATION.md` and `docs/ROLE_SECURITY_TEST_PLAN.md` before cutover.

### Dependency lockfile

`pubspec.lock` is not included in the supplied source archive. It was not fabricated. Generate it with the project's approved Flutter SDK by running `flutter pub get`, review it, and commit it. Then CI can safely be switched to enforced lockfile mode.

### Database, accounting, sync and restore

No database migration, financial transaction, synchronization, or backup implementation was changed in this revision. These require targeted regression tests against the actual database schema and workflows; broad automated edits would risk financial data integrity.

## Validation status

- Source-level workflow patch applied.
- YAML syntax and GitHub Actions execution have not been run in this environment.
- Flutter/Dart tests and platform builds have not been executed here.
- Treat this as a targeted CI safety improvement, not a production certification.

## Next implementation sequence

1. Generate and commit `pubspec.lock` using the approved Flutter SDK.
2. Add Firebase Emulator tests and complete staff custom-token/claims migration before deploying stricter rules.
3. Add populated-database migration tests for supported schema upgrades.
4. Add end-to-end financial reconciliation tests for sale, purchase, returns, payments, expenses and party balances.
5. Add two-device/offline retry tests and a full backup/restore drill.

## Update 2 — lockfile check in CI (P0)

- All four `flutter pub get` steps now run a lockfile check: if `pubspec.lock` exists and `pub get` changes it, CI fails.
- If `pubspec.lock` is missing, CI now fails (lockfile was committed on 31 Oct 2026).
- **Manual step:** run `flutter pub get` with Flutter 3.24.0, commit `pubspec.lock`. After that, change the "missing" branch in `build.yml` from `::warning::` to `::error::` + `exit 1`.
- Not validated: the Dart SDK could not be downloaded in the authoring environment, so the lockfile could not be generated and the workflow has not been run.

## Update 3 — lockfile artifact

- The Analyze + Test job uploads the lockfile it resolved as an artifact named `pubspec-lock`.
- Download it from the Actions run page and commit `pubspec.lock` to the repository root.

## Update 4 — database migration tests (P0 #4), NOT YET RUN

- `test/db_migration_test.dart`: fresh install check; upgrades from v20, v29, v31, v33 to v34 (schema must equal a fresh install, no seeded row changed, integrity_check ok, foreign_key_check empty); repeated-upgrade safety.
- Old schemas are produced by rewinding a fresh DB using the migration code, not from real old database files. Starting versions below 20 are not covered.
- Runs in its own workflow `.github/workflows/migration-tests.yml` (not part of the release gate). After it is green, move the test into `test/`.

## Update 5 — Windows fix

- The lockfile check step is bash; Windows runners default to PowerShell, so Build #514 failed on Windows. All four lock steps now declare `shell: bash` and ignore CR/LF differences.

## Update 6 — financial gap tests (P1 #5), NOT YET RUN

- `test/financial_gaps_test.dart`: sale edit, sale delete, sale return then delete (no double reversal), double return refused, purchase edit, purchase delete. Each checks stock, party balance, cash book and stock ledger together.
- Runs in the same non-gating `migration-tests.yml` workflow (`flutter test test_migration`). Move into `test/` once green.
- Not covered yet: duplicate-submission idempotency (the app only warns via `findDuplicateSale`, it does not block), expense and opening-balance edits, payment reassignment.

## Update 7 — backup/restore drill (P1 #7), NOT YET RUN

- `test/backup_restore_drill_test.dart` (real AppDatabase + real BackupHelper; only path_provider and flutter_secure_storage are faked): encrypted backup; backup -> modify -> restore returns exactly the original rows (integrity + FK check ok); wrong password, missing password, corrupted file and a non-database file all fail and leave the live database untouched.
- Observation (not changed): backup file names have minute resolution, so a safety backup taken during a restore within the same minute as the picked backup can overwrite that same file in the app backup folder. The test restores from a copy for this reason.
- Not covered: restoring an older-schema backup (migration after restore), clean-install restore on a different device.

## Update 8 — first test run (31 Oct 2026)

- test_migration run #1: 13 passed, 5 failed. Passed: all 6 financial gap tests, all 6 backup/restore drill tests, fresh install. The 5 failures (4 upgrade tests + idempotency) were a typing bug in the test helper `rowsOf` (dynamic sort comparator), not an app bug; fixed.

## Update 9 — tests moved into the release gate (31 Oct 2026)

- After run #2 of "Migration tests" passed 18/18, `db_migration_test.dart`, `financial_gaps_test.dart` and `backup_restore_drill_test.dart` moved from `test_migration/` to `test/`, so `flutter test` in the release gate (build.yml) runs them before any platform build.
- The separate `migration-tests.yml` workflow and its trigger step in `import-zip.yml` were removed.
- If the old `test_migration/` folder or `migration-tests.yml` still exist in the repository, delete them (a zip import never deletes files).

## Update 10 — duplicate-save guard (P1 sale/purchase "no duplicate invoice save"), app code change, NOT YET RUN

- Finding: in `sale_screen.dart` and `purchase_screen.dart`, `_saving` becomes true only after the duplicate-check query (and confirm dialogs). A quick double tap, or F9/Ctrl+S plus a tap, could start two saves of the same bill and create two invoices.
- Fix: `_save()` now has a synchronous `_saveEntered` re-entry guard (set before the first await, released in `finally`). The credit-limit retry calls `_saveImpl` directly so it is not blocked by the guard.
- Not changed: Quick Sale submit path, and there is still no database-level idempotency key (an invoice number is generated per save). Verified only by CI compile/analyze; no UI test exists for the double tap.

## Update 11 — migration fixtures test fixed (1 Nov 2026)

- Failure: `db_migration_fixtures_test.dart` expected the old file's `sync_queue` row count to be unchanged (0), but the v11 opening-stock ledger backfill (`StockLedger.backfillOpening`) legitimately enqueues one `stock_movement` upsert per backfilled ledger row (2 rows for the demo fixtures). Not an app bug; the test expectation was stale.
- Fix: `sync_queue` is compared separately: old queue rows must be unchanged, fixtures older than v11 must add exactly two `stock_movement` upserts, newer fixtures must add none.
- The test exists twice (`test/` and `test_migration/`, the latter run by the "Migration tests" workflow). Both copies were fixed. Update 9 says `test_migration/` and `migration-tests.yml` were removed; in this repository they still exist and are used (the folder holds the newer, not-yet-gating tests below).
- Open design question (not changed): upgrade-created opening-stock rows are synced. If two devices each upgrade the same pre-v11 file, both would push their own opening rows and ledger sums could double. Only affects files older than v11.

## Update 12 — Firebase rules security tests and staging project (P0 #1, partly)

- `firebase/rules-tests/` runs 16 tests in the local Firestore emulator against `firebase/firestore.staff-claims.rules` (no login or anonymous token denied, inactive or invalid role denied, other branch denied, cashier direct write denied, manager cannot delete or move a record to another branch, admin limited to own branch, `staff_accounts` and `branch_members` closed to clients, unknown collections denied). Result: all 16 pass (workflow "Firebase rules test", manual trigger only).
- GitHub workflow files are NOT imported by the zip importer (it excludes `.github`), so `.github/workflows/firebase-rules-test.yml` has to be created by hand in GitHub.
- Staging Firebase project `ah-staging-a1b2c` (Spark plan) created; rules and indexes deployed there; one admin account provisioned in `staff_accounts`. See `docs/STAGING_FIREBASE.md`. Production project untouched.
- Still not done: `staffLogin` / `getMyStaffContext` Cloud Functions need the Blaze plan on staging (decision pending, not enabled); app-side login and App Check; the live project still uses the anonymous `branch_members` rules, so role enforcement on the server is still missing.

## Update 13 — financial gaps part 2, `test_migration/financial_gaps2_test.dart` (P1 #5)

- Expense: one `expenses` row plus one cash OUT row of the same amount, delete removes both; zero, negative and unknown-method entries are refused and write nothing.
- Opening balance: a sale adds to it, sale edit and sale delete keep it exactly once, a payment reduces it and deleting the payment restores it.
- Payment re-assignment: moving a bill-linked payment from bill A to bill B restores A's `paid`, raises B's, leaves the party balance and cash book unchanged; a payment larger than the target bill can take is refused and changes nothing; deleting a bill-linked payment restores both bill and balance.
- All 7 tests pass (Migration tests workflow). Lives in `test_migration/`, not yet moved into the release gate.

## Update 14 — multi-device sync tests, `test_migration/two_device_sync_test.dart` (P1 #6)

- Two simulated phones, each with its own local database and checkpoint, against one in-memory cloud. Real code: `SyncRepository.syncNow`, `SyncQueueDao`, `planIncrement` / `stampPayload` / `shouldApplyUpsert`, `assemblePullResult`, `applyServerChangesToDb`. Only the Firestore transaction itself is replaced by a small fake that repeats the decisions in `SyncApi.push`.
- Covered (all pass): two phones billing the same customer offline (balance = opening + both bills everywhere); two phones selling the same product (stock = cloud minus both); offline phone keeps its bill with `retryCount` 0 and it is counted once after reconnecting; cloud applied a push but the reply was lost (retry skipped by `opId`, no double); repeated syncs change nothing while the pull overlap window re-delivers documents; a phone with an unsent bill pulls the other phone's bill first (cloud + own pending).
- Not covered: sales, payments and expenses as documents across two phones, delete versus edit conflicts, clock skew between phones, real Firestore transactions (needs the emulator).

## Update 15 — test status summary (1 Nov 2026)

| Plan item | Status |
|---|---|
| CI release gate, `pubspec.lock` | done |
| Database migration safety | done for real legacy files v1 to v32 -> v34; a real customer file is still to be added |
| Financial regression | done (sale, purchase, expense, opening balance, payment reassignment) |
| Multi-device sync | done for customer balance and product stock (see Update 14) |
| Backup / restore | 6 tests pass; older-schema backup and clean-install restore still to do |
| Firebase security | rules tests and staging ready; Cloud Functions and app login need Blaze; production unchanged |
| Business intelligence | not started |

## Update 16 — backup/restore drill part 2, `test_migration/backup_restore_drill2_test.dart` (P1 #7), NOT YET RUN

- Restoring OLDER-schema databases (real fixtures `legacy_v10.db`, `legacy_v25.db`, `legacy_v32.db`): restore succeeds, the file then migrates to the current schema (integrity ok, no FK violations) and the old rows (products, customer balances, supplier balance) are intact; rows of the previous live data are gone.
- `legacy_v1.db`: either restored and migrated, or refused with a clear error and the live database untouched (the restore check requires the 11 tables in `BackupHelper._requiredTables`; whether the very first schema has them is what this test shows).
- A backup from a NEWER app version (user_version above the app's) is refused with the "naye version" message and the live database is untouched.
- Clean install on another device: no database file and an empty secure store; restoring the encrypted backup with its password returns the exact original rows.
