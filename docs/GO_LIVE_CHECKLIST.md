# Go-live checklist — jo ho chuka hai

Aakhri update: 2026-10-30 (CI Build #485 tak). Device test ke saboot 2026-10-07 tak ke hain; uske baad ka code naya hai (neeche section 3 aur 4). "User" = dukaan wale ki apni device-testing; CI = GitHub Actions.

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
| Reports screen saaf | ✅ Code shamil (2026-10-30). Duplicate summary cards aur 4 insight rows hatayin; Stock Rebuild (Sep) row hata di; sections: Sale & purchase / Party / Stock / Financial. Action tools (Stock Adjustment, Stock Taking, Fix Bill Cost) Items mein, Cash Register Cash & Bank mein, Zakat Settings mein gaye. Device test baaki |
| Per-user access rules | ✅ Code shamil (2026-10-30). Manage Users → Access se har user ke liye 15 reports + 5 tools ON/OFF; role defaults purane jaise; Admin kabhi lock nahi. DB version 33 → 34 (`users.permissions`), users ke saath sync. `test/permissions_test.dart` shamil; CI par chalna baaki |

## 4. Abhi baaki — release se pehle verify karna hai (sab ⬜ = abhi proof nahi)
Ye audit (2026-10-30) ke nateeje hain. Sirf screen ka sahi khulna ya bill ka print hona hisaab ki durusti ka saboot nahi — sale, purchase, payment, return aur stock movement ke baad related balances alag se milane honge.

| Cheez | Kya check karna hai | Halat |
|-------|---------------------|-------|
| Naya CI build | Build #485 (`26dbc4d`) pass hai. Is ke baad ki tabdeeliyan (Per-user access rules, DB v34, docs) ke liye nayi build chalani hai | ⬜ |
| Tests (85 test files) | Is mahol mein Flutter SDK nahi, to naye code ke tests yahan nahi chale; CI par `flutter test` pass hona chahiye | ⬜ |
| Update test | Purani app ke upar nayi app install karke purana data (DB 33 → 34 migration) salamat | ⬜ |
| Backup / restore | Backup lo → data mita do / naya device → restore → totals wahi | ⬜ |
| Do devices par ek saath sale | Dono par ek waqt sale karke stock aur balance dono mein ek jaisa | ⬜ |
| Firebase production | Har device ka `branch_members/{uid}` bana ho (dekhein `docs/CLOUD_SYNC_SETUP.md`), real backend par sync test | ⬜ |
| Login / roles / access | Cashier reports nahi khol sakta; Access mein diya gaya item khulta hai; admin ka diya hua access dusre device par bhi lagta hai | ⬜ |
| Sales, sale history, returns | Sale → return → history: totals, stock, customer balance milen | ⬜ |
| Purchases aur supplier balances | Purchase → payment: supplier balance aur stock milen | ⬜ |
| Cash, expenses, payments | Cash / bank ledger ka har entry par balance sahi | ⬜ |
| Stock, units, cost | Unit conversion, minus stock, cost backfill ke edge cases (Stock Audit mein koi mismatch nahi) | ⬜ |
| Customer / supplier balances | Opening balance + payments + returns ka cross-check (Party Reports ke saath) | ⬜ |
| Profit, reports, balance sheet | Profit & Loss aur Balance Sheet ke totals haath se milaye hue numbers se barabar | ⬜ |
| Android / iOS / Windows release | Naye build par har platform ka install test | ⬜ |

## 5. Production se pehle priority (audit 2026-10-30)
Audit ka nateeja: "abhi production approval nahi" — iska matlab bugs milna nahi, balki saboot adhura hona hai (audit mein bhi Flutter nahi chala). Jab tak ye poora na ho, asli dukaan ke data ka alag backup rakhein.

**P0 — Data safety aur Firebase**
- ⬜ Har device par UID aur `branch_members/{uid}` mapping (`docs/CLOUD_SYNC_SETUP.md`)
- ⬜ Unauthorized branch access aur failed sync ka test
- ⬜ Backup bana kar doosri test installation par restore (data barabar)
- ⬜ Sync queue mein pending / failed entries ka record dekhna

**P1 — Accounting regression tests**
| Cheez | Maujooda automatic test | Kami |
|-------|-------------------------|------|
| Sale → receipt → cash / customer balance → stock | ✅ `financial_regression_integration_test.dart` | profit ka cross-check |
| Purchase → supplier payment → stock / payable / cash | ✅ `financial_regression_integration_test.dart` + naya `accounting_purchase_opening_test.dart` (weighted-average cost, supplier due, stock ledger, purchase → sale profit) | CI par chalna baaki |
| Linked payment edit / delete, edit refusal, NaN / zero | ✅ `financial_regression_integration_test.dart`, `payment_logic_test.dart`, `split_payment_test.dart` | — |
| Return, cancellation, edited bill | ✅ Naya `accounting_reconciliation_test.dart` (sale → return → stock / customer due / cash / profit / returns report / stock ledger) + `return_entry_test.dart`, `settle_return_test.dart`, `returned_bill_guard_test.dart`, `sale_edit_and_draft_test.dart` | CI par chalna baaki |
| Opening balances, expenses, balance sheet | ✅ Naya `accounting_reconciliation_test.dart` (sale + expense → report net profit = balance sheet, receivables, stock value, balance drift 0) + `balance_sheet_test.dart`, `due_balance_cap_test.dart`; opening balance (customer + supplier → receivables / payables) ka test `accounting_purchase_opening_test.dart` mein | CI par chalna baaki |
| Duplicate submission, do devices par concurrent transactions | ✅ Double-save alert ka test `accounting_reconciliation_test.dart` mein; sync ke liye `sync_*_test.dart` (queue / push / apply) | ⬜ asli do devices par ek saath sale (device test) |

**P2 — Release aur recovery**
- ⬜ Nayi CI build (Analyze + Test + 3 builds) — Build #485 `26dbc4d` pass; baad ki tabdeeliyan baaki
- ⬜ Update ke baad purane database ki integrity (DB 33 → 34)
- ⬜ Asli device par offline sale, reconnect aur sync conflict
- ⬜ Restore ke baad sales, stock, ledgers aur reports ka muqabla

## Note
- Month Close feature app se hata diya gaya hai (user ke kehne par). Unit screen wale changes Build #215 mein hain (pass). Baaki release checks (update test, backup-restore, do devices par ek saath sale) ab section 4 mein hain.
- CI ki "Node.js 20 is deprecated" warnings workflow actions ki thin, app ki nahi. 2026-10-25: `actions/checkout` v5 aur `actions/upload-artifact` v7 par update kiye — verify ho gaya: Build #485 ke annotations mein Node.js warnings nahi hain.
- Build #485 ke annotations (sirf notice, fail nahi): `ubuntu-latest` label jald Ubuntu 26 par migrate hoga, aur macOS arm64 jobs capacity ki wajah se der se chal sakti hain (iOS job 23m 56s lagi). Flutter version pinned hai, is liye Ubuntu migrate hone se pehle workflow mein `ubuntu-24.04` pin karna behtar hoga.
