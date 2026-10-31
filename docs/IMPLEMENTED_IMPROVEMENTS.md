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
