# ANDROID_CHANGELOG — Android/Web mein jo badla, Flutter mein port hona baaki

## Flutter side (2026-09-29) — Repo repair: Sale/Product/Purchase/main.dart wapas restore
- **Masla mila**: is upload ke `lib/db/sale_repository.dart` (245 lines), `lib/screens/sale_screen.dart`
  (488 lines), `lib/models/product.dart`, `lib/models/sale.dart`, `lib/widgets/unit_dialog.dart`,
  `lib/widgets/premium_widgets.dart` aur `lib/main.dart` — sab EK PURANI (Phase 0-3) halat mein
  the, jab ke `lib/db/app_database.dart` (v9), `lib/screens/day_book_screen.dart`,
  `lib/screens/sale_quick_sale.dart`, `lib/widgets/held_bills_dialog.dart`,
  `lib/screens/item_search_screen.dart`, `lib/screens/purchase_screen.dart` (item search line) —
  in sab ne pehle se hi aage wali cheezein use karni shuru kar di thi (`Product.matchesQuery`,
  `SaleItem.conversionFactor`, `SaleScreen(editInvoice:)`, `SaleRepository.saveQuickSale/holdBill/
  loadForEdit/...`). Matlab **repo compile hi nahi hota** is halat mein — kisi purani commit se
  in 6 files ka wapas aa jaana (galat merge/reset) lagta hai.
- **Fix**: `lib/db/sale_repository.dart`, `lib/screens/sale_screen.dart`, `lib/screens/product_screen.dart`,
  `lib/screens/purchase_screen.dart`, `lib/widgets/unit_dialog.dart`, `lib/main.dart` — is chat ki
  pichli (sab se advanced) copy se wapas laga diye (Split Payment samet). `lib/models/product.dart`
  (searchTag/defaultUnitIndex/quickSaleDefaultUnitIndex + `matchesQuery`), `lib/models/sale.dart`
  (`conversionFactor`), `lib/widgets/premium_widgets.dart` (`PremiumLabeledField.enabled`) —
  additively patch kiye taake naya `Customer.stuckBalance` waghera na chhute. `lib/utils/split_payment.dart`
  bhi missing tha, wapas add kiya. `test/split_payment_test.dart` + `test/sale_edit_and_draft_test.dart`
  wapas add kiye.
- **DB migration ki zaroorat NAHI thi** — `app_database.dart` ka fresh-install schema (v9) mein
  `products.searchTag/defaultUnitIndex/quickSaleDefaultUnitIndex` aur `sale_items.conversionFactor`
  columns pehle se maujood the; sirf Dart model classes unhe padh/likh nahi rahe the.
- Parties (Phase 6), Cash/Cash Register/Expenses/Day Book/Balance Sheet/Zakat/Shell Ledger/Payments
  (Phase 8-9), Hijri calendar, dashboard tiles — yeh sab is upload ki halat mein hi (untouched) rakhe
  gaye, kisi cheez ka koi nuksan nahi hua.
- Cross-checked: har jagah jo `SaleRepository.instance.*` / `ProductRepository.instance.*` call
  hoti hai (dashboard, day book, party repo) — sab methods restored `sale_repository.dart` mein
  maujood hain. Manual brace/paren-balance check kiya (Flutter SDK sandbox mein nahi hai) —
  `flutter analyze && flutter test` zaroor chalayein push karne se pehle.
- Suggestion: GitHub par ab se force-push/reset se bachein jab tak commit history confirm na ho;
  agli baar zip lene se pehle `git status`/`git log -1` check kar lein taake yeh dobara na ho.

---

Har Android tabdeeli yahan sabse upar likhein (naya pehle). Flutter mein port ho jaye to
`[ ]` ko `[x]` karein aur `python3 tools/port_status.py --accept <File>.kt` chalayein.

## 2026-09-28 — Item Rate Search: sale rates pehle, cost chhupa
- [x] `ItemSearchActivity.kt`: search list mein har item ke neeche Ctn/Dzn/Pcs sale rates;
  item kholne par bara Sale Rate card + wholesale; purchase/supplier/profit-margin sirf
  admin/manager ko "Show cost" button ke peeche. Spec: `docs/specs/item_rate_search.md`
- [ ] Web `rateComparison.js`: same badlav; screen ka naam "Rate Search".
- Flutter dependency: role/session (Phase 4) pehle chahiye, warna cost gate nahi lag sakta.
- Note: purani web Rate Comparison screen cashier ko bhi supplier rates dikhati thi — Flutter mein yeh galti na dohrayein.

---
## Flutter side (2026-09-29) — Parties list (Phase 6)
- [x] `PartyActivity.kt`: `lib/screens/party_screen.dart` (Customers/Suppliers tabs, add form, search, "Dues only", tap-for-history dialog, Call, edit/delete, Fix Balances / Merge Duplicates / Cleanup Payments / Cleanup Orphaned chips). Dashboard ka "Customers & Suppliers" tile jura. Sab roles (Kotlin jaisa).
- [x] `PartyRepository.kt` + `PartyUseCases.kt` (ViewModel/Factory skip): `lib/db/party_repository.dart`. CRUD + sync-queue, `liveCustomerBalances()/liveSupplierBalances()` (+ single-party versions), `recalculateBalances(dryRun)`, `mergeDuplicateParties()`, `find/cleanupDuplicatePayments`, `find/cleanupOrphanedPayments`. Har write ek transaction mein. Tests `test/party_test.dart`.
- **DB v9:** `customers.stuckBalance` (Kotlin "Stuck Balance", purani rows 0) + `Customer.stuckBalance/totalPayable/copyWith`. Stuck sirf admin/manager set/badal sakta hai — form mein chhupa hai AUR `PartyRepository` bhi cashier ke liye ignore karta hai (edit par purani DB value rehti hai).
- `PartyLedger` / `trueBalance` / `countBalanceDrift` ab `party_repository.dart` mein (ek hi copy); `balance_sheet_repository.dart` unhe re-export karta hai aur `PartyRepository.ledgers()` se ledger leta hai (purana `_ledgers` hata diya).
- Screen par closing figure hamesha LIVE ledger balance se (stored `balance` se nahi). Delete confirm mein bhi live balance dikhta hai (Kotlin stored `c.totalPayable()` dikhata tha).
- Chhote farq: "Dues only" mein 0.009 ki tolerance (Kotlin `!= 0.0` tha, float noise se "Rs 0.00" party due dikhti); edit dialog mein khali naam par dialog band nahi hota, wahin error dikhta hai; `pubspec.yaml` mein `url_launcher` (Call). iPad par dialer nahi hota — "Couldn't open dialer" toast aata hai.
- [ ] Contact picker (phone field ke saath icon): `flutter_contacts` + Android `READ_CONTACTS` / iOS `NSContactsUsageDescription` — CI har build par `flutter create` chalata hai, is liye permissions `tools/android_fix.sh` / iOS step mein patch karni hongi.
- [ ] Party par tap: abhi history dialog; Party Dashboard / Party Transaction screens port hone par wahan link karein.
- [ ] Phase 10: sync entityId DeviceTag ke saath (`customer:<device>-<id>`), `increment_balance` ka asal payload (abhi `{delta}`), `upsert` + serverId stamp.
- Sawal: Fix Balances / Merge / Cleanup chips Kotlin mein sab roles ko dikhte hain (yahan bhi). Ye data badalte/hatate hain — chahen to admin/manager tak mehdood kar dein.
- Note: yeh code compile/test nahi hua (Flutter SDK nahi tha) — `flutter analyze && flutter test` chalayein.

---
## Flutter side (2026-09-28) — Cash Register (Phase 8)
- [x] `CashRegisterActivity.kt`: `lib/screens/cash_register_screen.dart` + `lib/db/cash_register_repository.dart` (pure `registerExpected()`, `registerFigures()`, `registerDateKey()`; tests `test/cash_register_test.dart`). Dashboard par "Cash Register" tile (sab roles — Kotlin mein koi role check nahi).
- Kotlin ke audit fixes barqarar: opening balance sabse recent CLOSED register se carry-forward (chhutti wale din par bhi); OPEN ka check+insert ek transaction (double-tap safe) aur sync op `create_if_absent`; close dialog mein shortage/excess taaza cash_transactions se (`freshExpected`); counted amounts default expected par.
- Chhote farq: har change (open/edit/close/reopen) aur uski sync entry ek hi DB transaction mein; close/edit ab band register par error deta hai; din ki hadd `< agla midnight` (DST-safe); history save ke baad dobara load hoti hai.
- [ ] Kotlin ka history "Matched" cash aur bank ka farq jama karta hai — cash mein 500 kam aur bank mein 500 zyada ho to bhi "Matched" dikhta hai. Flutter mein abhi Kotlin jaisa hi rakha; chahein to dono ko alag alag check karwa dein.
- [ ] Phase 10: sync payload ka asal shape `SyncQueueHelper.cashRegisterJson` se mila lena (abhi `CashRegister.toMap()`).
- Note: yeh code compile/test nahi hua (Flutter SDK nahi tha) — `flutter analyze && flutter test` chalayein.

---
## Flutter side (2026-09-28) — Expenses (Phase 8)
- [x] `ExpenseActivity.kt`: `lib/screens/expense_screen.dart` + `lib/db/expense_repository.dart` (`ExpenseRepository.save/delete/totals/recent`, `insertExpenseWithCash`). Dashboard par "Expenses" tile (sab roles). Test `test/expense_test.dart`.
- Kotlin ke audit fixes barqarar: Expense + linked cash OUT row (`reference = expense:<id>`, reason `Expense: <category>`) save aur delete dono mein ek transaction; delete par cash row bhi hatti hai (Cash in Hand kam nahi rehta); "Paid From" cash/bank; double-tap guard.
- `CashRepository.save` (Cash Out + category) ab isi `ExpenseRepository.insertExpenseWithCash` se likhta hai — pehle wahi code do jagah copy tha.
- Categories 11 hain (Salaries + Zakat samet); Cash screen ki list alag hai (Non-expense, bina Salaries/Zakat) — Kotlin jaisa hi.
- Chhote farq: din/mahine ki hadd `< agla midnight/mahina` (DST-safe, Kotlin `+24h` tha); list save/delete ke baad dobara load hoti hai (Kotlin Flow ki jagah).
- [ ] Phase 10: `reference`/sync entityId DeviceTag ke saath (`expense:<device>-<id>`) + legacy `expense:<localId>` cleanup on delete (Kotlin `madeHere` check) + `upsert`/serverId stamp.
- Note: yeh code compile/test nahi hua (Flutter SDK nahi tha) — `flutter analyze && flutter test` chalayein.

---
## Flutter side (2026-09-28) — Balance Sheet (Phase 8)
- [x] `BalanceSheetActivity.kt`: `lib/screens/balance_sheet_screen.dart` + `lib/db/balance_sheet_repository.dart` (pure `buildBalanceSheet()`, `stockValueAtCost()`, `trueBalance()`, `countBalanceDrift()`; tests `test/balance_sheet_test.dart`). Sirf admin/manager (RoleGuard + repository check).
- Stock value: `stock * (cost / smallestUnitFactor)` (Kotlin FIX) — kabhi `stock * cost` nahi.
- Drift warning ("Fix Balances chalayein"): Kotlin `recalculateBalances(dryRun)` ka read-only hissa repository mein; **PartyRepository (Phase 6) port hote waqt isi logic ko wahan le jayen** taake do copy na rahein.
- Dashboard par abhi "Balance Sheet" tile (admin/manager) — Kotlin mein ye Reports ke andar hai, Phase 9 mein wahan shift karein.
- Farq: header `palette.navy` (dark mode mein white text ke liye).
- [ ] Sale (COGS) `sale_items.cost` ko Kotlin jaisa hi sum kiya hai — Android ke number se ek sample par mila lein.
- Note: yeh code compile/test nahi hua (Flutter SDK nahi tha) — `flutter analyze && flutter test` chalayein.

## Flutter side (2026-09-28) — Cash In / Cash Out (Phase 8)
- [x] `CashActivity.kt`: `lib/screens/cash_screen.dart` + `lib/db/cash_repository.dart` (`planCashEntry()` pure function, tests `test/cash_test.dart`). Dashboard ka "Cash" tile jura.
- **DB v6:** `expenses.method` ('cash'/'bank', purani rows 'cash') + `Expense.method` — Kotlin MIGRATION_41_42 jaisa. Ye ExpenseActivity (agla screen) ko bhi chahiye.
- Kotlin ke audit fixes barqarar: Cash Out + category => Expense + linked cash row (`reference = expense:<id>`, reason `Expense: <category>`) ek transaction mein; "Non-expense (Withdrawal / Transfer)" sirf plain cash row; Cash In par category ignore; double-tap guard.
- Chhote farq: category dropdown Cash In par bhi nazar aata hai (Kotlin ka comment kehta tha hidden, code mein hidden nahi tha) — ab neeche "Used for Cash Out only" likha hai; din ki hadd `< agla midnight` (DST-safe); list dobara load hoti hai save ke baad (Kotlin Flow ki jagah).
- [ ] Phase 10: expense/cash ka `reference` aur sync entityId DeviceTag ke saath (`expense:<device>-<id>`) karna, aur Kotlin ki tarah `upsert` + serverId stamp.
- Note: yeh code compile/test nahi hua (Flutter SDK nahi tha) — `flutter analyze && flutter test` chalayein.

## Flutter side (2026-09-28) — Day Book (Phase 8)
- [x] `DayBookActivity.kt`: `lib/screens/day_book_screen.dart` + `lib/db/day_book_repository.dart` (hisaab `buildDayBook()` pure function, tests `test/day_book_test.dart`). Dashboard ka "Day book" tile jura.
- Kotlin ke double-count fixes barqarar: bill se linked payment bill ke `paid` se nikal kar sirf apni date par gini jati hai; cash rows mein sirf blank / `manual-` / `return:` dikhte hain; returned bills list mein hain magar totals mein nahi.
- Chhote farq: din ki hadd `>= start AND < next midnight` (DST-safe, Kotlin `+24h` inclusive tha); header rang `palette.teal` (dark mode mein white text ke liye); Net card par "(Today)" sirf aaj ke din, warna "(This Day)"; "Today" button; RETURNED/Due text ab Loc se.
- [ ] Row tap: sale = sirf admin (`SaleScreen(editInvoice:)`); purchase row abhi tap nahi hoti — Phase 7 mein "edit saved purchase" ke saath.
- Note: yeh code is session mein compile/test nahi hua (Flutter SDK maujood nahi tha) — `flutter analyze && flutter test` chalayein.

## Flutter side (2026-09-28) — Phase 4 ka baqi hissa
- [x] Item Rate Search Flutter mein pehle se `lib/screens/item_search_screen.dart` (spec ke mutabiq).
- [x] AppLock / fingerprint (Login: fingerprint-only + both; Manage Users lock; Settings radios) — `local_auth` chahiye.
- [x] ThemeManager (dark mode toggle Settings mein), NumericKeypad, MenuRow widgets.
- [ ] Purani screens ko `AppColors` se `ThemeManager.palette` par migrate karna (tab dark mode poori app mein chalega).
- [x] ~~Sale/Purchase ko `NumericKeypadField` par lana~~ — zaroorat nahi: Kotlin mein sirf `StockTakingActivity` custom keypad use karti hai; Sale/Quick Sale system keyboard par hi rehti hain.
- [ ] Dashboard/Settings rows ko `MenuRow` par lana.

## Flutter side (2026-09-28) — Sale (Phase 3/5)
- [x] `SaleCart.kt` (helpers): `lib/utils/sale_cart.dart` — default unit (Auto / manual / Quick-Sale alag), Retail<->Wholesale par cart lines reprice, margin/loss warning (cost figures sirf admin/manager ko).
- [x] `SaleQuickSale.kt`: `lib/screens/sale_quick_sale.dart` + `SaleRepository.saveQuickSale` (ek transaction), top-30-din items pehle.
- [x] `SaleHoldRecall.kt`: `lib/services/sale_hold_recall.dart` + `lib/widgets/held_bills_dialog.dart` (held_bills `HOLD%` sirf Sale ke liye).
- [x] Credit limit: Sale aur Quick Sale dono mein "Save Anyway?" confirm (`SaleCreditLimitException`).
- [x] Product: `defaultUnitIndex` / `quickSaleDefaultUnitIndex` (DB v3 migration, safe ALTER) + unit dialog mein "Default Unit for Sale / Quick Sale" chips.
- [x] `sync_queue.payloadJson` ab asal JSON (`jsonEncode`), pehle `Map.toString()` tha.
- **Unit order yaad rahe:** Sale mein units primary-first hain (`saleUnitChoices`), `unitLadder()` smallest-first hai — default-unit index hamesha pehli list ka hai.
- [x] Saved sale edit / return / delete (sirf admin): `SaleScreen(editInvoice: '<invoice>')` + `SaleRepository.saveSale(editInvoice:)`, `returnSale`, `deleteSale`.
  Edit sirf badli hui lines ka stock chhoota hai (`lib/utils/stock_touch_policy.dart`); `sale_items.conversionFactor` (DB v4) purani unit-ladder se galat reverse hone se bachata hai.
  History screens (Phase 7) ko bas `Navigator.push(SaleScreen(editInvoice: ...))` karna hai.
- [x] Draft autosave (`lib/services/sale_draft.dart`) — bill beech mein band ho to wapas milta hai (date restore nahi hoti, Kotlin FIX ki tarah).
- [x] Customer ka apna rate auto-suggest (`SaleRepository.lastRateForCustomerItem`).
- [x] Rs (amount) mode, Bill Items mein inline line edit (tap / edit icon).
- [x] Print: save ke baad + Print pill par text Bill Preview (Copy). Bluetooth print/WhatsApp share Phase 12.
- [ ] Sale ke baqi chhote items: Split Payment dialog, naye sale par Cash/Bank picker, duplicate-bill warning, inline 'add customer' popup.
- [ ] Bill se linked payments (`voidLinkedPayments` / `linkedPaidForBill`) — Phase 6/8 (Payments) ke saath.
- [ ] `BulkDefaultUnitActivity.kt` / `BulkMissingRatesActivity.kt` (Phase 5) — default unit ab column mein hai, screen baaki.
- Note: yeh code is session mein compile/test nahi hua (Flutter SDK maujood nahi tha) — `flutter analyze && flutter test` chalayein.
