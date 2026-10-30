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
- If `pubspec.lock` is still missing, CI prints a warning only (so builds are not blocked before the first commit).
- **Manual step:** run `flutter pub get` with Flutter 3.24.0, commit `pubspec.lock`. After that, change the "missing" branch in `build.yml` from `::warning::` to `::error::` + `exit 1`.
- Not validated: the Dart SDK could not be downloaded in the authoring environment, so the lockfile could not be generated and the workflow has not been run.
