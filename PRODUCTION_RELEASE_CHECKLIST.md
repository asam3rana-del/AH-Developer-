# Production release gate

## Status update 2026-11-02 (purani baatein jo ab badal chuki hain)

| Item | Pehle likha tha | Ab ki halat |
|------|-----------------|-------------|
| `pubspec.lock` | "package mein lockfile nahi" | ✅ Repo ke root mein maujood hai. `build.yml` har job par `flutter pub get` ke baad check karta hai ke file maujood hai aur pubspec.yaml se mutabiq (warna fail), aur CI jo lockfile banaye wo artifact `pubspec-lock` mein upload karta hai. Note: CI `--enforce-lockfile` flag nahi, balki "pub get + git diff" check use karti hai (nateeja wahi: lock se bahar jaana fail) |
| Android release signing secrets | "configure karna hai" | ✅ Android release build pass ho rahi hai (signing secrets na hon to build fail hoti), signed APK device par install aur update ho chuki hai. ⬜ Keystore aur passwords ka alag, mehfooz backup abhi bhi zaroori hai |
| Full test suite / CI | "run nahi hua" | ✅ CI par "Analyze + Test" chal kar Android/iOS/Windows builds uske baad chalti hain (build gate). Latest source ka naya run har tabdeeli ke baad dekhna hai |
| Two-device sync, duplicate/retry | "staging par karna hai" | ✅ Asli do devices par: ek saath sale, aeroplane mode mein sale phir sync (double nahi), sync status theek, admin ka diya Access dusre device par aaya (`docs/DEVICE_TEST_SHEET.md` items 10-13) |
| Backup-and-restore | "karna hai" | ✅ Encrypted backup dusre phone par restore, data theek (sheet item 14); update ke upar install, purana data salamat (item 15) |
| Accounting reconciliation (haath se) | "karna hai" | 🟡 Aaj ki P&L haath se mili (Sales 780, COGS 701, Expense 200, Net −121); sale/purchase partial return, Day Book, expense, supplier payable sab device par milte hain (sheet items 1-9). ⬜ Balance Sheet ke liye asli dukaan ka opening cash/bank aur Fix Balances baaki |
| Firebase `branch_members/{uid}` aur rules (items 3-4) | pending | ✅ 2026-11-03: live project (`my-grocery-pos-8a444`) par repo wali `firebase/firestore.rules` (branch_members wali secure rules, `canRead()` fix ke saath) publish; dono devices ka `branch_members/{uid}` (branchId `dusri-branch`) bana hua; dono devices par sync theek (user ne khud check kiya). `due_followups` ka index (`branchId` + `updatedAt`) live project mein bana. Hardcoded `"dusri-branch"` wali purani Console rules ab live nahi |
| Secure staff login / server credit check | pending | ⬜ Code opt-in switch ke saath maujood (default OFF); backend deploy aur staging test baaki |
| Parallel run (item 6) | pending | ⬜ Purana system dukaan par chalte rehna chahiye jab tak hisaab na mil jaye |

## Production roadmap tracker (2026-11-03)

Ye 4 phase ka kaam-ka-nakshah hai. "Kaun" = kaun kar sakta hai: **Code** (repo mein likha ja sakta hai), **Aap** (asli device / Firebase Console / dukaan ka data chahiye).

### Phase 1 — Security (P0)
| Kaam | Halat | Kaun | Agla qadam |
|------|-------|------|------------|
| Trusted staff authentication | 🟡 Code aur docs maujood (`docs/STAFF_AUTH_BACKEND_SETUP.md`, opt-in switch, default OFF) | Aap + Code | Cloud Functions backend deploy aur staging par test; tab tak live rules sirf branch-level hain |
| Server-side role permissions | ⬜ Rules draft (`firestore.secure-draft.rules`, `firestore.staff-claims.rules`) tayyar, live nahi | Aap + Code | Staff authentication live hone ke baad hi publish (warna cashier sync band ho jayega) |
| Firestore unauthorized access tests | ✅ Naya `firebase/rules-tests/branch_isolation.test.js`: har synced collection par signed-out / unprovisioned / doosri branch ke member ka matrix (parho, banao, badlo, mitao, branch badalna), `branch_members` aur server-only collections band | Code | GitHub Actions mein "Firebase rules test" chala kar pass dekhna (emulator par abhi chalaya nahi) |
| Branch isolation verification | 🟡 Emulator tests upar; live project par dono devices theek (2026-11-03) | Aap | Ek naya/unprovisioned device (bina `branch_members` document) sync kare to `permission-denied` aaye (ye sahi hai) |

### Phase 2 — Accounting (P1)  — yahan asli dukaan ke numbers chahiye
| Kaam | Halat | Kaun |
|------|-------|------|
| Actual opening cash/bank | ⬜ | Aap (asli raqam) |
| Customer / supplier opening balances | ⬜ (code aur automatic tests maujood: `accounting_purchase_opening_test.dart`) | Aap (asli list) |
| Stock quantity aur valuation audit | ⬜ Stock Audit screen maujood | Aap (ginti) |
| P&L aur Balance Sheet reconciliation | 🟡 P&L haath se pass (2026-11-02); Balance Sheet opening cash/bank ke baad | Aap |
| Stock Audit mismatch check | ⬜ | Aap |

### Phase 3 — Reliability (P1)
| Kaam | Halat | Kaun |
|------|-------|------|
| Latest full Flutter CI run | 🟡 Har import par "Build" chalti hai; latest source ka run dekhna | Aap (Actions tab) |
| Firebase staging tests | ⬜ Staging project (`ah-staging-a1b2c`) par rules + indexes deploy karke `docs/STAGING_FIREBASE.md` ke mutabiq | Aap |
| Failed sync queue verification | 🟡 Settings → Sync History mein failed entries nazar aati hain (2026-11-03: ek purane customer ka push fail dikha, `branchId` theek karne ka tareeqa `docs/CLOUD_SYNC_SETUP.md` mein) | Aap |
| Two-device conflict testing | 🟡 Ek saath sale pass (sheet items 10-12); ek hi record ko do devices par badalna baaki | Aap |
| Latest v36 device migration | 🟡 DB version ab 36; purani app ke upar nayi APK install test (sheet item 15 v34 par hua tha) dobara karna | Aap |
| Backup / restore drill | ✅ Dusre phone par restore pass (sheet item 14); latest build par dobara karna behtar | Aap |

### Phase 4 — Commercial release (P2)
| Kaam | Halat | Kaun |
|------|-------|------|
| Signed release APK | ✅ Android release build pass | — |
| Keystore aur password backup | ⬜ Alag, mehfooz jagah backup | Aap |
| Parallel accounting run | ⬜ Purana system chalta rahe jab tak hisaab na mil jaye | Aap |
| Final production sign-off | ⬜ Phase 1-3 ke baad | Aap |

Neeche ke purane sections audit ke waqt (2026-10-30) ke hain; sach ki taza halat upar ki table aur `docs/GO_LIVE_CHECKLIST.md` mein hai.

## Changes applied in this source package

- Android, iOS, and Windows build jobs now depend on the `analyze-test` job.
- The test job runs `flutter test` directly; a missing/empty test suite no longer silently skips validation.
- Android release signing now fails closed unless `KEYSTORE_BASE64`, `KEYSTORE_PASSWORD`, and `KEY_PASSWORD` are present and the decoded keystore contains alias `ahkey`.
- Signing material and Flutter-generated files are ignored by Git.

## Required before a commercial release

1. Configure GitHub Actions secrets `KEYSTORE_BASE64`, `KEYSTORE_PASSWORD`, and `KEY_PASSWORD` using the same long-lived Android upload keystore used for every future update. The alias must be `ahkey`. Back up this keystore and its passwords securely; losing them can prevent updating installed copies.
2. ~~Generate and commit `pubspec.lock`~~ — **done**: `pubspec.lock` is in the repository root and CI verifies it on every job (`flutter pub get` + `git diff` check). Keep it updated: after any `pubspec.yaml` change run `flutter pub get` and commit the new lockfile.
3. Firebase currently authenticates anonymously and maps Firebase UID to a branch in `branch_members/{uid}`. That UID is device-scoped, while Admin/Manager/Cashier roles are local application users. Do not enforce role-specific Firestore permissions using a guessed role field until the identity model is changed to authenticate each staff member (or a trusted backend issues verified custom claims). Otherwise a device can change its local role without changing its Firebase identity.
4. Review and deploy Firestore rules in a staging Firebase project first. Confirm that every active device UID has a provisioned `branch_members/{uid}` document with the correct `branchId`.
5. Run the full test suite, staging sync tests on two devices, duplicate/retry tests, backup-and-restore tests, and accounting reconciliation before importing live shop data.
6. Keep the previous accounting system and a verified export/backup until the new system has completed a parallel-run period and opening balances, stock, customer/supplier balances, cash, profit, and balance sheet reconcile.

## Follow-up hardening in this package

- Sale and quick-sale credit-limit checks now read the customer ledger inside the same SQLite transaction as the sale write. This protects against competing saves on the same device/database connection. It does NOT provide cross-device atomic credit enforcement on its own. An OPT-IN server pre-check (`reserveCredit` + Settings switch, default OFF) narrows the gap for ONLINE devices only; offline devices still rely on the local check. See `docs/SERVER_CREDIT_CHECK.md` (not yet staging-tested).
- Added Firestore emulator regression tests for the currently active `firebase/firestore.rules` baseline, alongside the existing tests for the separate staff-claims draft. The workflow tests both rule files and does not deploy either one.
- The staff-claims rules remain a draft. Do not deploy them to production until the Flutter authentication migration, cashier server-side sale endpoint, and full staging test plan are complete.

## Validation performed for this patch

- `bash -n tools/android_fix.sh`
- Workflow dependency and test-gate source inspection

Flutter analysis, Flutter tests, Android release build, keystore signing, and live Firebase integration were not run in this environment. This patch is not a production certification.
