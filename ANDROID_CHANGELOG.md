# ANDROID_CHANGELOG — Android/Web mein jo badla, Flutter mein port hona baaki

## Flutter side (2026-09-29) — Purchase History (Phase 7, doosra screen)
- [x] `PurchaseHistoryActivity.kt`: `lib/screens/purchase_history_screen.dart` + `lib/db/purchase_history_repository.dart`
  (pure `summarizePurchases`, `filterPurchaseRows`, `parseReturnRequest`, `returnedLineAmount`; test `test/purchase_history_test.dart`;
  `buildPurchaseBillText` / `buildPurchaseShareText` in `lib/utils/bill_text.dart`). Dashboard tile "Purchase History" (admin).
- Total Purchases / Total Due (returned bills bahar, due kabhi negative nahi), search (bill no. ya supplier), DUE/PAID badge, Balance, Print / Share / ⋮ (Return, Delete).
- **Return = partial** (Kotlin FIX): har line par qty; sirf wahi qty stock + weighted cost + supplier balance se nikalti hai; `returns` row har line ki; line poori wapas => row delete; sab lines wapas => bill `returned` + cash ka dated reversal (`return:<bill>`) + payments/linked payments hatana; warna `paid` cap + cash/payment reduce. Stock bik chuka ho to rok (Kotlin jaisa message). Sab ek transaction + sync_queue (jsonEncode).
- **Delete**: stock+cost wapas (stock kam ho to rok), supplier balance (overpaid advance bhi), bill/items/payments/cash/linked payments + sync delete.
- Role: admin-only (RoleGuard + repository check).
- Farq: card tap Kotlin mein PurchaseActivity (edit saved purchase) kholta hai — Flutter mein wo screen nahi, isliye abhi lines ka detail dialog. Print = text preview + Copy; Share = clipboard. Line naam live product se (purchase_items par naam/conversionFactor snapshot nahi — upar unchecked migration item).
- Note: compile/test nahi hua (Flutter SDK nahi) — `flutter analyze && flutter test test/purchase_history_test.dart`.
- [ ] Phase 7 mein baaki: `HistoryActivity.kt`. Purchase card tap = edit saved purchase jab PurchaseScreen(editBillNo:) ban jaye.

## Flutter side (2026-09-29) — Sale History (Phase 7, pehla screen) + build fixes
- [x] `SaleHistoryActivity.kt`: `lib/screens/sale_history_screen.dart` + `lib/db/sale_history_repository.dart`
  (pure `groupSalesByCustomer`, `summarizeSales`, `filterGroups`; test `test/sale_history_test.dart`). Dashboard tile "Sale History".
  Customer ke hisaab se group, Total Sales / Total Returned cards, customer search, bill tap = items expand, Print (Bill Preview), Edit / Return / Delete.
- Role: sab dekh sakte hain (Kotlin jaisa). Profit (bill + customer) sirf admin — cashier/manager ke liye `saleProfits()` khali map deta hai (cost load hi nahi hota). Edit/Return/Delete sirf admin (`SaleRepository` bhi dobara check karta hai).
- Return/Delete `SaleRepository.returnSale/deleteSale` se hi hote hain (stock, customer balance, cash reversal, sync_queue ek transaction mein).
- Farq: Material icons; Print = text Bill Preview + Copy (Bluetooth Phase 12).
- **Build fix:** `Expense.method` model mein add ('cash' default) — `expense_repository.dart` compile error. iOS workflow mein Pods ka code signing band (`CODE_SIGNING_ALLOWED=NO`).
- Note: compile/test nahi hua (Flutter SDK nahi) — `flutter analyze && flutter test test/sale_history_test.dart`.
- [ ] Phase 7 mein baaki: `PurchaseHistoryActivity.kt`, `HistoryActivity.kt`; sale row ka "Return" ab bill-linked payments void nahi karta jab tak `voidLinkedPayments` Flutter mein na ho (upar Sale section ka unchecked item).

## Flutter side (2026-09-29) — PartyQuickAddMenu + Due Reminders (Phase 6, chautha/paanchwan)
- [x] `PartyQuickAddMenu.kt`: `lib/widgets/party_quick_add_menu.dart` (`showPartyMenuSheet`, `PartyMenuItem`, `showPartyPickerForPayment`, pure `pickerCandidates`; test `test/party_quick_add_test.dart`).
  Party Dashboard ka "+" menu ab isi sheet se; Payment Received/Made => party chunein => `PartyTransactionScreen(openPayment: true)`. Payment Made sirf admin/manager (supplier screen cashier ke liye band).
- [x] `DueRemindersActivity.kt`: `lib/screens/due_reminders_screen.dart` + `lib/db/due_reminders_repository.dart`
  (pure `dueBucket`, `summarizeDue`, `sortDueBills`, `overdueCustomerStatus`, `whatsAppDigits`, `reminderMessage`; test `test/due_reminders_test.dart`).
- **DB v10** (migration): `sales.dueDate`, `purchases.dueDate` (INTEGER NOT NULL DEFAULT 0; 0 = date set nahi). `Sale`/`Purchase` models mein `dueDate`.
  `SaleRepository.saveSale` edit par original `dueDate` carry karta hai (Kotlin FIX: edit par reset-to-0 nahi). Date set karna: dirty + updatedAt + poori row `sync_queue` mein (Kotlin FIX).
- [x] Overdue ab asli: Party Transaction ka Overdue stat (bill `dueDate` guzri + paisa baqi) aur Party Dashboard par customer ka Overdue / Due Today badge.
- Role: Due Reminders admin + manager (Kotlin mein Reports ke andar, jahan role check hai); Dashboard tile abhi wahi (Reports Phase 9 mein aayega). Badge sab roles ko dikhta hai.
- Farq: Material icons; WhatsApp/Call `url_launcher` se; sale checkout mein due date field abhi nahi (Kotlin mein bhi nahi — sirf yahin se set hoti hai).
- Note: compile/test nahi hua (Flutter SDK nahi) — `flutter analyze && flutter test`. Purani DB par pehli launch mein v9->v10 migration chalegi.
- [ ] Phase 6 mein sirf baaki: `PartyActivity` ka contact picker (flutter_contacts + permissions) + party row tap se Dashboard/Transaction.

## Flutter side (2026-09-29) — Party Reports (Phase 6, teesra screen)
- [x] `PartyReportsActivity.kt`: `lib/screens/party_reports_screen.dart` + `lib/db/party_reports_repository.dart`
  (pure `buildLedgerLines`, `runLedger`, `aggregateItems`, `paymentEntries`, `customerPL`, `supplierSummary`; test `test/party_reports_test.dart`).
  Customers/Suppliers tabs -> party tap -> 6 reports: Item, Ledger (Dr/Cr), Payment History, Statement, Sale/Purchase by Party, P&L / Purchase Summary.
- Kotlin FIX rules saath aaye: returned bills sab reports se bahar; general (bill-unlinked) payments Ledger/Statement mein; bill-embedded payments dobara nahi; stuck balance ka Daily/Stuck/Total split.
- Role: admin + manager (RoleGuard; P&L mein cost hai, repository `allowCost` bhi check karta hai). Abhi Dashboard tile se khulta hai (Reports Phase 9 mein aayega, Balance Sheet jaisa).
- Farq: Kotlin ke `ic_*` ki jagah Material icons; supplier item ka naam live product se (Flutter `PurchaseItem` mein naam snapshot nahi).
- Note: yeh code compile/test nahi hua (Flutter SDK maujood nahi) — `flutter analyze && flutter test test/party_reports_test.dart` chalayein.
- [ ] Phase 6 mein baaki: `PartyQuickAddMenu.kt`, `DueRemindersActivity.kt` (+ sales/purchases `dueDate` DB migration), `PartyActivity` ka contact picker + row tap.

## Flutter side (2026-09-29) — Party Transaction (Phase 6, doosra screen)
- [x] `PartyTransactionActivity.kt`: `lib/screens/party_transaction_screen.dart` + `lib/db/party_transaction_repository.dart`
  (pure `computePartyTxStats`, `filterTxEntries`, `standalonePayments`, `reconcilePaid`, `reversePurchaseLineCost`/`addPurchaseLineCost`; test `test/party_transaction_test.dart`).
  Balance card (Opening + You'll Get/Give), Stuck split, stat grid, Share Statement, search + All/Bills/Payments, bills + standalone payments ki merged list.
- [x] Billed Items dialog: har line Edit (qty/rate) / Delete, sirf admin (screen + data layer). Ek transaction mein: stock (sale = frozen conversionFactor; rate-only edit stock nahi chhoota),
  purchase par weighted-average cost, line, bill total/paid (paid sirf cap hota hai + cash reversal `return:<ref>`), party balance, sync_queue. Aakhri line = poori bill delete (cash + linked payments samet).
- [x] Party Dashboard: party row tap ab `PartyTransactionScreen` kholta hai. `openPayment` parameter tayyar (PartyQuickAddMenu ke liye).
- [x] FIX: `Payment` model mein `billReference` + `copyWith` nahi the (payment_repository / payments_screen unhe istemal karte the => compile nahi hota) — ab model mein hain.
- `PaymentRepository.update/delete` ab data layer par bhi admin-only (Kotlin `requireAdminOrAbort`).
- Farq: Share Statement / Share receipt clipboard mein copy (share plugin nahi); payment save ke baad "Share receipt?" offer nahi (har payment row par Share chip); Overdue Rs 0 (dueDate column nahi);
  `purchase_items` mein conversionFactor / itemName nahi => purchase line ki smallest qty product ki MAUJUDA ladder se; supplier screen cashier ke liye band.
- [ ] Sales/Purchases mein `dueDate` column (Overdue + Due Reminders) — DB migration + Sale/Purchase screens.
- [ ] `purchase_items.conversionFactor` + `itemName` (Kotlin snapshot) — DB migration.
- Note: yeh code compile/test nahi hua (Flutter SDK nahi tha) — `flutter analyze && flutter test` chalayein.

## Flutter side (2026-09-29) — Party Dashboard (Phase 6, pehla screen)
- [x] `PartyDashboardActivity.kt`: `lib/screens/party_dashboard_screen.dart` + `lib/db/party_dashboard_repository.dart`
  (pure `partyTotals`, `filterPartyRows`, `sortPartyRows`, `filterTxRows`, `filterItemAggs`; test `test/party_dashboard_test.dart`).
  You'll Get / You'll Give cards (tap se receivable/payable filter), Parties / Transactions / Items tabs, search, filter dialog,
  item detail + Edit Rates, main menu, "+" quick add, neeche Add Purchase / Add Sale. Dashboard par "Party Dashboard" tile.
- Closing hamesha live ledger se (`PartyRepository.liveCustomerBalances`); customer aur supplier ka sign rule ulta (Kotlin FIX jaisa).
- `ProductRepository.setAllRates()` naya (cost + retail + wholesale + sync_queue, ek transaction). Edit Rates sirf admin; cashier ko cost / purchase data load hi nahi hota.
- Farq: transaction item-name search ka key `S:<invoice>` / `P:<billNo>` (Kotlin sirf reference); Share summary clipboard mein copy hota hai (share plugin nahi).
- [x] Party row tap => `PartyTransactionScreen` (Party Transaction entry dekhein).
- [ ] Overdue / Due Today badge: `sales` table mein `dueDate` column nahi — Due Reminders (DueRemindersActivity) ke saath.
- [ ] Transactions tab mein Purchase row tap = edit-saved-purchase (Phase 7). "+" menu: Sale/Purchase Return (Phase 7 History).
- [ ] "+" menu ka Payment Received/Made abhi Payments screen kholta hai; party picker + openPayment PartyQuickAddMenu.kt ke saath.
- Note: yeh code compile/test nahi hua (Flutter SDK nahi tha) — `flutter analyze && flutter test` chalayein.

## Flutter side (2026-09-29) — Items + Bulk Missing Rates + Bulk Default Unit (Phase 5 mukammal)
- [x] `ItemsActivity.kt`: `lib/screens/items_screen.dart` + `lib/db/items_repository.dart` (pure `buildCategoryRows`, `filterProducts`; test `test/items_test.dart`).
  3 tabs (Products / Categories / Units), search (200ms debounce), category drill-down (Edit / Change Category / Delete), category rename/delete
  (products "Items Not in Any Category" mein), unit add/delete. Dashboard par "Items" tile (admin-only, RoleGuard). Har write + sync_queue entry ek transaction mein.
- [x] `BulkMissingRatesActivity.kt`: `lib/screens/bulk_missing_rates_screen.dart` — queue = salePrice<=0 ya wholesalePrice<=0; dono rate + unit chips (typed rate primary unit par convert).
- [x] `BulkDefaultUnitActivity.kt`: `lib/screens/bulk_default_unit_screen.dart` — queue = secondaryUnit!='' aur defaultUnitIndex=-1; Auto (`autoDefaultUnitIndexFor`) pehle se highlight.
- `ProductScreen(editBarcode:)` naya (Kotlin EXTRA_EDIT_BARCODE) — Items se edit seedha form mein khulta hai.
- `ProductRepository`: `needingDefaultUnitReview()`, `withMissingRates()`, `setDefaultUnitIndex()`, `setRates()`.
- Farq (Kotlin jaisa hi rakha): unit delete sirf local hai (sync delete nahi). Farq (Kotlin se behtar): "Change Category" ab sync queue mein bhi jati hai (Kotlin sirf upsert karta tha).
- [ ] Items ka "Import" (Rate List CSV): `file_picker` dependency + CSV parse chahiye — abhi nahi.
- [ ] Items ka "Translate" button: BulkTranslateActivity (Phase 13) port hone par jorein (abhi "Coming soon").
- [ ] `ProductScreen` ka apna save/delete abhi bhi sync queue mein nahi likhta (TODO wahan maujood) — Phase 10 mein.
- Note: yeh code compile/test nahi hua (Flutter SDK nahi tha) — `flutter analyze && flutter test` chalayein.

## Flutter side (2026-09-29) — Rate Comparison (Phase 5)
- [x] `RateComparisonActivity.kt`: `lib/screens/rate_comparison_screen.dart` + `lib/db/rate_comparison_repository.dart`
  (pure `buildSupplierRateRows()`, test `test/rate_comparison_test.dart`). Dashboard par "Rate Comparison" tile (sirf admin/manager, RoleGuard).
- Rate hamesha product ke PRIMARY unit par normalize (`toPrimaryUnitRate`); supplier ke hisaab se Last/Lowest/Highest/kitni dafa;
  sab se sasta last-rate "Best Rate". Kotlin ki tarah sirf supplier wali purchases (Cash Purchase shamil nahi), status filter nahi (returned bhi).
- Cashier ke liye repository `[]` deta hai (data layer par role check, spec jaisa).
- Kotlin mein yeh Reports ke andar hai; Reports (Phase 9) port hone par tile wahan shift karein.
- [ ] Web `rateComparison.js` abhi baaki (upar wali Android entry dekhein).
- Note: yeh code compile/test nahi hua (Flutter SDK nahi tha) — `flutter analyze && flutter test` chalayein.

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
