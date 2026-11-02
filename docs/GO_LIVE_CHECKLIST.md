# Go-live checklist — jo ho chuka hai

Aakhri update: 2026-11-02 (asli device tests items 1-15 pass; section 4 aur 5 ki halat neeche update ki gayi). Device test ke saboot 2026-10-07 tak ke hain; uske baad ka code naya hai (neeche section 3 aur 4). "User" = dukaan wale ki apni device-testing; CI = GitHub Actions.

## 1. Build aur tests
| Item | Natija | Saboot |
|------|--------|--------|
| Flutter SDK se clean build (2026-10-07) | ✅ Pass | CI Build #215 (main, `3f055ed`, manual) — pehle #213 (`fb5c296`) bhi pass |
| `flutter analyze` | ✅ Pass | Build #215, job "Analyze + Test" (2m 1s) |
| `flutter test` (sab tests) | ✅ Pass | Build #215, job "Analyze + Test" |
| Android release APK | ✅ Build hua | Build #215 (7m 45s) |
| iOS (unsigned) aur Windows (exe) | ✅ Build hue | Build #215 (18m 25s / 6m 10s) |
| Upload ke baad auto builds | ✅ Pass | Build #214 aur Import zip #99 (commit `a77542a`) |
| Naya build (2026-10-30) | ✅ Pass | Build #485 (main, `26dbc4d`, manual): Analyze + Test (1m 26s), Android APK (9m 40s), iOS unsigned (23m 56s), Windows exe (5m 47s); total 25m 28s, 3 artifacts. Sirf info notices (neeche Note) |

## 2. Device par test (user)
| Item | Natija |
|------|--------|
| Multi-device sync (2 devices) | ✅ Sab kuch theek sync ho raha hai |
| Printer physical testing | ✅ Theek chal raha hai |
| Urdu print | ✅ Theek |
| Bill print (Urdu naam, hisaab, totals) | ✅ Theek — 07/10/2026 ki asli slip dekhi gayi |
| Lambi qty ("0.615 Qtr" / "9.091 Gram") | ✅ Fix shamil (qty column chaura, 2 lines tak) — user: print ok |
| PDF reports (Urdu) | ✅ Theek |

## 3. Features jo main mein shamil hain
| Feature | Halat |
|---------|-------|
| Default Sale + Quick Sale Unit screen | ✅ Code shamil. "Review" (ek ek) aur "All Products" (category chips, search, "Apply to shown"); sab badlav sync queue mein |
| Rate Search (cost) saaf kiya | ✅ Code shamil. Cost kholne par sirf Last Cost, Profit Margin (maujooda sale rate par) aur Purchase Rate History; Average Cost aur Supplier Comparison hata diye |
| Recycle Bin | ✅ Code shamil (sale/purchase bills, expenses, payments, cash, customers/suppliers, items, workers, shop rents ko delete ke baad wapas laya ja sakta hai). Device test baaki |
| Reports screen saaf | ✅ Code shamil (2026-10-30), device par khula aur chala (2026-11-02). Duplicate summary cards aur 4 insight rows hatayin; Stock Rebuild (Sep) row hata di; sections: Sale & purchase / Party / Stock / Financial. Action tools (Stock Adjustment, Stock Taking, Fix Bill Cost) Items mein, Cash Register Cash & Bank mein, Zakat Settings mein gaye. Device test baaki |
| Per-user access rules | ✅ Code shamil aur device par pass (2026-11-02): Manage Users → Access se cashier ko Daily Bills diya, sirf wohi dikha, dusre device par bhi sync se aaya. Role defaults purane jaise; Admin kabhi lock nahi. Ab Expense aur Shell Ledger ke bhi Access switch hain (cashier ko default mein khule). DB version 33 → 34 (`users.permissions`) |
| Sale partial return | ✅ Device par pass (2026-11-02). History > Return se har line ki qty; stock, bill total/paid, customer balance, cash refund, Returns Report, Day Book milte hain; poori qty = poori bill return. Discount wali bill par bhi sahi (`test/sale_partial_return_test.dart`) |
| Purchase partial return dialog (shared) | ✅ Device par pass (2026-11-02): udhaar aur poori paid dono cases (stock, supplier payable, Day Book Cash In) |
| Day Book (partial / poori return ke baad) | ✅ Device par pass: Cash In wahi jo asal mein aaya, refund Cash Out mein ek hi dafa (Net sahi) |

## 4. Abhi baaki — release se pehle verify karna hai (sab ⬜ = abhi proof nahi)
Ye audit (2026-10-30) ke nateeje hain. Sirf screen ka sahi khulna ya bill ka print hona hisaab ki durusti ka saboot nahi — sale, purchase, payment, return aur stock movement ke baad related balances alag se milane honge.

| Cheez | Kya check karna hai | Halat |
|-------|---------------------|-------|
| Naya CI build | ✅ Android build pass (2026-11-02, Java 17 pin ke baad `build.yml` mein `actions/setup-java`), saath mein Analyze + Test. Latest source (Expense/Shell Ledger Access) ka ek aur run dekhna baaki | 🟡 |
| Tests | CI par `flutter test` chal kar hi Android build shuru hoti hai (build gate), isliye naye tests (`sale_partial_return_test`, `day_book_test`, `permissions_test`) bhi pass hue jab tak build chali. Latest source ka run dekhna baaki | 🟡 |
| Update test | Purani app ke upar nayi app install karke purana data (DB 33 → 34 migration) salamat | ✅ Asli phone par pass (sheet item 15): purani app ke upar nayi APK, data salamat. Automatic: 12 purane DB → v34 migration test (Migration tests #10) |
| Backup / restore | Backup lo → data mita do / naya device → restore → totals wahi | ✅ Asli phone par pass (sheet item 14): encrypted backup dusre phone par restore, data theek. Automatic tests bhi pass (Migration tests #10) |
| Do devices par ek saath sale | Dono par ek waqt sale karke stock aur balance dono mein ek jaisa | ✅ Asli 2 devices par pass (sheet items 10-12): ek saath sale, aeroplane mode mein sale phir sync (koi double nahi), sync status theek |
| Firebase production | Har device ka `branch_members/{uid}` bana ho (dekhein `docs/CLOUD_SYNC_SETUP.md`), real backend par sync test | 🟡 Sync dono devices par chal raha hai; production rules / `branch_members` ki alag verification baaki |
| Login / roles / access | Cashier reports nahi khol sakta; Access mein diya gaya item khulta hai; admin ka diya hua access dusre device par bhi lagta hai | ✅ Pass (sheet item 13): Daily Bills Access dono devices par; cashier ko Reports, cost, profit, Cash & Bank nahi dikhte |
| Sales, sale history, returns | Sale → return → history: totals, stock, customer balance milen | ✅ Pass (sheet items 1, 7, 8): cash/udhaar/discount bill par partial aur poori return |
| Purchases aur supplier balances | Purchase → payment: supplier balance aur stock milen | ✅ Pass (sheet items 2, 9): payable 600, purchase partial return ke baad payable/stock/Day Book |
| Cash, expenses, payments | Cash / bank ledger ka har entry par balance sahi | 🟡 Pass: expense (Cash Out +200), supplier payment, sale/purchase return refund, Day Book (sheet 3, 8, 9). Baaki: asli opening cash/bank entry |
| Stock, units, cost | Unit conversion, minus stock, cost backfill ke edge cases (Stock Audit mein koi mismatch nahi) | 🟡 Unit (box/Jar) sale+return pass (sheet 4); Stock History mein return rows sahi. Stock Audit ka alag mismatch check baaki |
| Customer / supplier balances | Opening balance + payments + returns ka cross-check (Party Reports ke saath) | 🟡 Ledger (asim customer aur supplier) return ke baad sahi. Balance Sheet par "14 customers / 13 suppliers ka stored balance nahi milta" warning: test data mein delete kiye gaye parties ki wajah se; backup ke baad Fix Balances chalana baaki |
| Profit, reports, balance sheet | Profit & Loss aur Balance Sheet ke totals haath se milaye hue numbers se barabar | 🟡 P&L haath se pass (2026-11-02: Sales 780, COGS 701, Expense 200, Net −121; returns 660 = Returns Report). Balance Sheet ke totals milte hain magar Cash/Bank minus: asli dukaan par opening cash/bank daalna baaki |
| Android / iOS / Windows release | Naye build par har platform ka install test | 🟡 Android ✅ (APK install, update ke upar install). iOS/Windows jab zaroorat ho |

## 5. Production se pehle priority (audit 2026-10-30)
Audit ka nateeja: "abhi production approval nahi" — iska matlab bugs milna nahi, balki saboot adhura hona hai (audit mein bhi Flutter nahi chala). Jab tak ye poora na ho, asli dukaan ke data ka alag backup rakhein.

**P0 — Data safety aur Firebase**
- ⬜ Har device par UID aur `branch_members/{uid}` mapping (`docs/CLOUD_SYNC_SETUP.md`)
- ⬜ Unauthorized branch access aur failed sync ka test
- ✅ Backup bana kar doosri device par restore (data barabar) — asli device par pass (sheet item 14)
- ⬜ Sync queue mein pending / failed entries ka record dekhna

**P1 — Accounting regression tests**
| Cheez | Maujooda automatic test | Kami |
|-------|-------------------------|------|
| Sale → receipt → cash / customer balance → stock | ✅ `financial_regression_integration_test.dart` | profit ka cross-check |
| Purchase → supplier payment → stock / payable / cash | ✅ `financial_regression_integration_test.dart` + naya `accounting_purchase_opening_test.dart` (weighted-average cost, supplier due, stock ledger, purchase → sale profit) | CI par chalna baaki |
| Linked payment edit / delete, edit refusal, NaN / zero | ✅ `financial_regression_integration_test.dart`, `payment_logic_test.dart`, `split_payment_test.dart` | — |
| Return, cancellation, edited bill | ✅ Naya `accounting_reconciliation_test.dart` (sale → return → stock / customer due / cash / profit / returns report / stock ledger) + `return_entry_test.dart`, `settle_return_test.dart`, `returned_bill_guard_test.dart`, `sale_edit_and_draft_test.dart` | CI par chalna baaki |
| Opening balances, expenses, balance sheet | ✅ Naya `accounting_reconciliation_test.dart` (sale + expense → report net profit = balance sheet, receivables, stock value, balance drift 0) + `balance_sheet_test.dart`, `due_balance_cap_test.dart`; opening balance (customer + supplier → receivables / payables) ka test `accounting_purchase_opening_test.dart` mein | CI par chalna baaki |
| Duplicate submission, do devices par concurrent transactions | ✅ Double-save alert ka test `accounting_reconciliation_test.dart` mein; sync ke liye `sync_*_test.dart` (queue / push / apply) | ✅ asli do devices par ek saath sale pass (sheet item 10) |

**P2 — Release aur recovery**
- 🟡 Nayi CI build (Analyze + Test + 3 builds) — Android build pass (2026-11-02); latest source ka ek aur run, aur iOS/Windows jab zaroorat ho
- ✅ Update ke baad purane database ki integrity (DB 33 → 34) — migration tests pass aur asli phone par update ke baad data salamat (sheet item 15)
- 🟡 Asli device par offline sale aur reconnect ✅ (sheet item 11, double nahi); sync conflict ka alag test baaki
- ✅ Restore ke baad data har lihaaz se theek (sheet item 14); reports ka ek aur muqabla asli dukaan ke data par karna

## Update 2026-11-01
| Cheez | Halat | Saboot |
|-------|-------|--------|
| Credit limit server pre-check (`reserveCredit`, opt-in, default OFF) | 🟡 Code + emulator test pass; real deploy baaki (staging par Blaze chahiye) | Credit check function test #2 (emulator); `docs/SERVER_CREDIT_CHECK.md` |
| "Only admin/manager can Save Anyway" (default OFF) | 🟡 Code shamil; `test/credit_override_policy_test.dart` CI par chalna baaki | — |
| Rate Search: cost/margin bade aur chhote dono unit mein | 🟡 Code shamil; device nazar-e-saani baaki | — |
| CI (upload `7a93bec`) | ✅ Build #564, Migration tests #13, Firebase rules test #4 pass | GitHub Actions |
| Asli phone test | ✅ Sheet ke items 1–15 pass (2026-11-02): sale/purchase partial return, Day Book, P&L/Balance Sheet milan, cashier Access (dusre device par bhi). iOS/Windows jab zaroorat ho | `docs/DEVICE_TEST_SHEET.md` |
| Returns Report (Reports hub) | ✅ Sale aur Purchase returns line-wise, device par dekha | `lib/screens/returns_report_screen.dart` |

## Note
- Month Close feature app se hata diya gaya hai (user ke kehne par). Unit screen wale changes Build #215 mein hain (pass). Baaki release checks (update test, backup-restore, do devices par ek saath sale) ab section 4 mein hain.
- CI ki "Node.js 20 is deprecated" warnings workflow actions ki thin, app ki nahi. 2026-10-25: `actions/checkout` v5 aur `actions/upload-artifact` v7 par update kiye — verify ho gaya: Build #485 ke annotations mein Node.js warnings nahi hain.
- Build #485 ke annotations (sirf notice, fail nahi): `ubuntu-latest` label jald Ubuntu 26 par migrate hoga, aur macOS arm64 jobs capacity ki wajah se der se chal sakti hain (iOS job 23m 56s lagi). Flutter version pinned hai, is liye Ubuntu migrate hone se pehle workflow mein `ubuntu-24.04` pin karna behtar hoga.

## Update 2026-11-01
- "Migration tests" #10 pass: migration (12 purane DB), financial gaps, backup/restore drill 1+2, two-device sync. Teen suites ab `test/` mein bhi hain (release gate).
- 🟡 = automatic test pass, asli device par check baaki. Sync History (Settings) pehle se maujood hai: pending/stuck entries wahin dikhti hain, Retry Now bhi.
- Is dauran ek asli bug mila aur theek hua: naye app version ka backup restore karne par woh Kotlin backup samajh kar import ho jata tha (live data badal sakta tha); ab saaf refuse hota hai.
