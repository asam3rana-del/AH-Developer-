# Production release gate

## Changes applied in this source package

- Android, iOS, and Windows build jobs now depend on the `analyze-test` job.
- The test job runs `flutter test` directly; a missing/empty test suite no longer silently skips validation.
- Android release signing now fails closed unless `KEYSTORE_BASE64`, `KEYSTORE_PASSWORD`, and `KEY_PASSWORD` are present and the decoded keystore contains alias `ahkey`.
- Signing material and Flutter-generated files are ignored by Git.

## Required before a commercial release

1. Configure GitHub Actions secrets `KEYSTORE_BASE64`, `KEYSTORE_PASSWORD`, and `KEY_PASSWORD` using the same long-lived Android upload keystore used for every future update. The alias must be `ahkey`. Back up this keystore and its passwords securely; losing them can prevent updating installed copies.
2. Generate and commit `pubspec.lock` using the project's approved Flutter/Dart SDK, then use `flutter pub get --enforce-lockfile` in CI. This package did not include a lockfile; one must not be fabricated without resolving the dependency graph.
3. Firebase currently authenticates anonymously and maps Firebase UID to a branch in `branch_members/{uid}`. That UID is device-scoped, while Admin/Manager/Cashier roles are local application users. Do not enforce role-specific Firestore permissions using a guessed role field until the identity model is changed to authenticate each staff member (or a trusted backend issues verified custom claims). Otherwise a device can change its local role without changing its Firebase identity.
4. Review and deploy Firestore rules in a staging Firebase project first. Confirm that every active device UID has a provisioned `branch_members/{uid}` document with the correct `branchId`.
5. Run the full test suite, staging sync tests on two devices, duplicate/retry tests, backup-and-restore tests, and accounting reconciliation before importing live shop data.
6. Keep the previous accounting system and a verified export/backup until the new system has completed a parallel-run period and opening balances, stock, customer/supplier balances, cash, profit, and balance sheet reconcile.

## Validation performed for this patch

- `bash -n tools/android_fix.sh`
- Workflow dependency and test-gate source inspection

Flutter analysis, Flutter tests, Android release build, keystore signing, and live Firebase integration were not run in this environment. This patch is not a production certification.
