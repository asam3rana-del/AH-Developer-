# ANDROID_CHANGELOG — Android/Web mein jo badla, Flutter mein port hona baaki

## Flutter side (2026-09-29) — Phase 10 mukammal (Cloud sync + Phone OTP login)
- [x] `SyncQueueHelper` (+ `enqueueLegacy`) aur `SettingsSync` (+ `SyncSection` UI) pehle hi port ho chuke the — tracker mein 'todo' reh gaya tha; ab `done`. `installSyncWiring()` `main()` mein chalti hai (`SyncRepository.backend = SyncApi`, `afterApply = mergeOwnDuplicateExpenses`, `onQueued = SyncWorker.triggerNow`).
- [x] Phone OTP login: `lib/services/otp_login.dart` + login screen panel + Settings mein "OTP (Phone Number)" radio; `UserRepository.findByPhone` / `activeUsers`. Naya test: `test/otp_login_test.dart` (resolveOtpUser, verifyLinkPassword hashed + plain, 6-digit code, phone check).
- [x] **Bug fix (Kotlin ExpenseActivity audit ke mutabiq):** Expense ke saath bana cash-OUT ka `reference` ab device-unique hai (`expense:<DeviceTag>-<id>`, serverId ho to wahi) — pehle `expense:<localId>` tha, aur do devices par expense #7 hone se ek device ka delete doosre ka cash-out bhi uda deta tha. Delete purani rows ko bhi saaf karta hai (`legacyExpenseCashReference`, sirf usi expense ke liye jo isi device par bana — Kotlin `madeHere`). Purana TODO comment hata diya. Test: `test/expense_test.dart`.
- [x] **Bug fix (login):** `_askPasswordBeforeFirstPhoneLink` mein dialog band hote hi `field.dispose()` chal jata tha (animation ke dauran "TextEditingController used after being disposed" ka crash) — hata diya.
- Note: `lib/screens/login_screen.dart` line 281 ka `\'s` (backslash + quote) DURUST hai — pichli chat ke markdown ne dikhane mein double backslash dikhaya, file mein ek hi backslash hai. Koi syntax ghalti nahi.
- Farq: workmanager plugin nahi — sync/backup sirf app zinda hone par (Phase 10 SyncWorker note).
- [ ] Device par: Firebase (`flutterfire configure`, `firebase_options.dart`), Firestore Rules + branch_members/{uid} approval, Phone Auth enable — phir 2 devices (Android + iPad) par ek sale/purchase sync karke number mila lein.
- [ ] Phase 10 mukammal. Agla: Phase 11 (Backup/Crypto/Scheduler — dekhein PORT_STATUS) aur Phase 12/4 ke baqi items.
- Note: yeh code is session mein compile/test nahi hua (Flutter SDK maujood nahi tha) — `flutter pub get && flutter analyze && flutter test`.

## Flutter side (2026-09-29) — Phase 10 (6/x): SyncApi mukammal — apply hissa 2 + branch cleanup
- [x] `applyServerChanges` HISSA 2 -> `lib/sync/sync_apply_rest.dart`: sales (+items), purchases (+items), expenses, payments, cash_transactions, units, categories, zakat years (payments se PEHLE) + payments, returns, stock_movements, shell customers/transactions/log, app_settings, cash_register. Kotlin ki tarteeb aur guards: pending local edit ho to pull skip + total/paid farq par `sync_conflict` audit; doosre device ka delete pending edit ko nahi khata (audit); stock_movements mein apni unclaimed row claim (duplicate PURCHASE/SALE row nahi); payment ki party `partyServerId` se resolve (doosre device ka raw id ghalat party par nahi lagta); app_setting/cash_register par apna pending push ho to skip.
- [x] `UnimplementedError` guard hata diya — ab sab 20 collections apply hoti hain, sab ek transaction mein (beech mein ghalti => kuch nahi likha, checkpoint nahi barhta).
- [x] `SyncApi.countDocsByBranchId` / `deleteDocsByBranchId` (admin cleanup: ghalat branchId ke docs, 16 collections, `users` nahi, 400 ke batch).
- [x] **DB v13:** `returns` par `serverId` / `updatedAt` / `dirty` (returns pull ko idempotent karne ke liye; purani rows serverId NULL, dirty=1).
- Farq: `saleUid` / `lineUid` / `purchaseUid` (Kotlin P2) Flutter mein nahi — pull unhein ignore karta hai. purchases ke Flutter-only columns (`dueDate`, `supplierInvoiceNo`) server doc mein na hon to local barqarar.
- Test: `test/sync_apply_rest_test.dart` (naya), `test/sync_apply_test.dart` (guard test hata).
- **ZAROORI:** `SyncRepository.backend = SyncApi.instance` abhi bhi mat lagayein — Flutter repositories ki purani queue rows (`entityType 'sale'`, entityId invoice, op 'create'/'update', raw `toMap` payload) Android schema jaisi nahi; pehle `SyncQueueHelper` (entity ids `sale:<invoice>` waghera, `...Json()` builders, `increment_*`) port hokar sab repositories mein jurna hai.
- Note: compile/test nahi hua (Flutter SDK nahi) — `flutter pub get && flutter analyze && flutter test test/sync_apply_test.dart test/sync_apply_rest_test.dart`.
- [ ] Agla (one by one): `SyncQueueHelper` (entity ids + payload builders + enqueue* + repositories mein wiring) -> `SettingsSync` -> Settings ka Cloud Sync Setup screen -> phir `SyncRepository.backend` / `afterApply` jorna.

## Flutter side (2026-09-29) — Phase 10 (5/x): SyncApi — PULL + apply hissa 1
- [x] `SyncApi.pull()` -> `lib/sync/sync_api.dart` (+ `sync_pull_plan.dart`): 20 collections `branchId == current && updatedAt > since` (server se), checkpoint = sab se bara `updatedAt`. Branch code na ho => `BranchNotConfiguredException` pehle (farq: Kotlin mein khali "Already up to date" aata tha).
- [x] `applyServerChanges` hissa 1 -> `lib/sync/sync_apply.dart`: customers, suppliers, products, users. Server snapshot ke upar abhi tak na bheje gaye local deltas (increment_balance / increment_stock, stuck samet), pending "upsert" ho to us row ko skip, dirty row ka naam/qeemat badle to `sync_conflict` audit, `_deleted` tombstone se hata do. Naye user ka password bekaar random hash. Sab ek transaction mein.
- Naye supplier par pending delta nahi lagta (Kotlin jaisa jaan boojh kar).
- **Guard:** baaki collections (sales, purchases, payments, expenses, cash_transactions, units, categories, zakat*, returns, stock_movements, shell*, app_settings, cash_register) mein data aaye to `UnimplementedError`, kuch likhe baghair. `SyncRepository.backend = SyncApi.instance` abhi mat lagayein.
- Test: `test/sync_apply_test.dart`. Note: compile/test nahi hua (Flutter SDK nahi) — `flutter pub get && flutter analyze && flutter test test/sync_apply_test.dart`.

## Flutter side (2026-09-29) — Phase 10 (4/4): SyncApi — PUSH hissa
- [x] `SyncApi.kt` (header + push) -> `lib/sync/sync_api.dart` (`SyncApi.instance`, `SyncBackend` implement): `firestoreFor()` (branch configure + custom/default Firebase app + anonymous sign-in), `isPermissionDenied` / `permissionDeniedMessage` (Eng/Urdu) / `currentUid()` (async), `push()`.
- Push ops: `delete` (tombstone `_deleted:true`, transaction, sirf jab deleteAt >= server updatedAt), `create_if_absent` (cash register), `increment_stock` / `increment_balance` (transaction + `appliedOps` opId = `<DeviceTag>-<queueId>-<createdAt>`, 30 din / 999 ki safai; naya doc seedFields ke saath — customer/supplier/product ki pehchan, serverId khali ho to entityId se local id), baaki upsert (last-write-wins, payload par hamesha maujooda branchId). Fail par audit `sync_push_failed`.
- Saaf hissa (Firestore ke baghair test ho sake): `lib/sync/sync_push_plan.dart`; local lookup `lib/sync/sync_seed_fields.dart`.
- pubspec: `firebase_auth`. Test: `test/sync_push_test.dart`.
- **ZAROORI:** `pull()` / `applyServerChanges()` abhi `UnimplementedError` — `SyncRepository.backend = SyncApi.instance` abhi mat lagayein (agla hissa).
- Note: compile/test nahi hua (Flutter SDK nahi) — `flutter pub get && flutter analyze && flutter test test/sync_push_test.dart`. Asli Firestore transactions ke liye Firebase project + Firestore rules (Kotlin `firestore.rules`) chahiye.

## Flutter side (2026-09-29) — Phase 10 (3/4): SyncWorker
- [x] `SyncWorker.kt` -> `lib/sync/sync_worker.dart` (`SyncWorker.instance`): `schedulePeriodic()` (15 min, dobara bulane par duplicate nahi), `triggerNow()` (KEEP — chalti sync par no-op, offline par skip; NetworkMonitor.onOnline yahin jura), `syncNowOnce()` (manual; chalti sync khatam hone ke baad taaza run, kabhi overlap nahi), `isRunning` / `lastOutcome` (Kotlin `observeManualSync` + KEY_SUMMARY).
- Kotlin ka `NetworkType.CONNECTED` constraint: offline par sync nahi chalti (warna push fail hoke entries retryCount 10 par "stuck" ho jati).
- Farq: `workmanager` plugin nahi — sirf app zinda ho (Timer + resume). Band app ka background sync baad ka optional hissa (BackupScheduler jaisa).
- `main()`: `NetworkMonitor.onOnline = SyncWorker.instance.triggerNow`, `SyncWorker.instance.schedulePeriodic()`.
- Test: `test/sync_worker_test.dart`. Note: compile/test nahi hua (Flutter SDK nahi) — `flutter pub get && flutter analyze && flutter test test/sync_worker_test.dart`.
- Baaki jorna: SyncQueueHelper enqueue ke baad `triggerNow()`; Settings "Sync Now" par `syncNowOnce()` + `lastOutcome`.

## Flutter side (2026-09-29) — Phase 10 (2/4): SyncRepository (+ SyncQueueDao, SyncBackend)
- [x] `SyncRepository.kt` -> `lib/sync/sync_repository.dart`: `syncNow()` = PUSH (200 pending, kamyab => markSynced, nakaam => markFailed) -> PULL (last_sync_time checkpoint) -> APPLY -> 7 din se purani synced rows saaf. Branch code/permission-denied/koi bhi ghalti => `SyncResult(pulledOk:false, error)`; `summary()` Kotlin jaisi line. `resetSyncCheckpoint()` (Resync from a specific time).
- [x] `SyncQueueDao` (Database.kt) -> `lib/sync/sync_queue_dao.dart` (enqueue/pending/pendingForEntity/AnyRetry/pendingCountForEntity/markSynced/markFailed/pruneSynced/pendingCount/stuck/resetRetry/resetAllStuck; db ya txn dono par).
- [x] `lib/sync/sync_types.dart`: `PullResult`, `BranchNotConfiguredException`, `SyncBackend` (SyncApi isay implement karegi).
- Jorna baaki (agli files ke saath): `SyncRepository.backend = SyncApi`, `SyncRepository.afterApply = SyncQueueHelper.mergeOwnDuplicateExpenses`.
- pubspec dev: `sqflite_common_ffi`. Test: `test/sync_repository_test.dart`.
- Note: compile/test nahi hua (Flutter SDK nahi) — `flutter pub get && flutter analyze && flutter test test/sync_repository_test.dart`.

## Flutter side (2026-09-29) — Phase 10 (1/4): DeviceTag / BranchConfigStore / CloudConfigStore / NetworkMonitor
- [x] `DeviceTag.kt` -> `lib/sync/device_tag.dart`, `BranchConfigStore.kt` -> `lib/sync/branch_config_store.dart`, `CloudConfigStore.kt` -> `lib/sync/cloud_config_store.dart` (custom `custom_cloud` FirebaseApp), `NetworkMonitor.kt` -> `lib/sync/network_monitor.dart` (20 s debounce). `main()` mein DeviceTag/BranchConfigStore init + NetworkMonitor.register.
- pubspec: `connectivity_plus`. Test: `test/sync_config_test.dart`.
- Note: compile/test nahi hua (Flutter SDK nahi) — `flutter pub get && flutter analyze && flutter test test/sync_config_test.dart`.
- [ ] Agla (one by one): `SyncApi` applyServerChanges ke baaki hisse (sales, purchases ... cashRegisters) -> `SyncQueueHelper` -> `SettingsSync`; phir Settings ka Cloud Sync Setup screen.

## Flutter side (2026-09-29) — Phase 12: Print & Scan (Bluetooth print / Bill Preview / Bill Scan)
- [x] `PrinterHelper.kt` -> `lib/services/printer_service.dart` + `receipt_renderer.dart` + `lib/utils/escpos.dart` + `receipt_lines.dart`. Bill `TextPainter` se bitmap banta hai (Urdu shaping/RTL Flutter khud), phir ESC/POS `GS v 0` raster chhoti strips (24px) mein, Kotlin FIX 5 wali pacing (200ms floor, 10ms/row, 128B pieces / 20ms gap, settle 150ms), `ESC @` + feed&cut. Lambi bill kai slips (18 item/slip): har slip par header + table header, "Continued on next slip", footer sirf aakhri par. Print width 384/448/512/576 (`printer_dots`). Settings keys Kotlin wali: `printer_name/mac/width/dots`, `receipt_footer`.
- [x] `BillPreviewActivity.kt` -> `lib/screens/bill_preview_screen.dart` + `lib/utils/bill_doc.dart`. PRINT, WhatsApp (wa.me + bill text; number nahi to poochta hai), Copy, DONE, "+ NAYI SALE/PURCHASE BILL", Prev/Net Balance (party mile to). Sale/Purchase save ke baad aur Sale/Purchase History ke Print isi screen par.
- [x] `BillScanActivity.kt` -> `lib/screens/bill_scan_screen.dart` + `lib/utils/bill_scan_parser.dart`. Purchase screen par "Scan Bill": photo -> ML Kit OCR -> review/edit -> naam se product match, warna naya product (pcs) -> purchase lines.
- Settings: Printer Setup card (Select Printer / Test Print / Print Width / Receipt footer).
- pubspec: `print_bluetooth_thermal`, `permission_handler`, `image_picker`, `google_mlkit_text_recognition`. CI: iOS deployment target 15.5 (ML Kit), Info.plist camera/photos/Bluetooth strings; `tools/android_fix.sh` Bluetooth + camera permissions manifest mein jodta hai.
- Farq: USB printer nahi; WhatsApp par text jata hai (image nahi); OCR parser heuristic hai (har row review hoti hai).
- Test: `test/print_scan_test.dart` (escpos raster/strips, paging, footer balance, scan parser).
- Note: compile/test nahi hua (Flutter SDK nahi) aur asli printer par test nahi — `flutter pub get && flutter analyze && flutter test test/print_scan_test.dart`, phir TEST PRINT.
- [ ] Agar print garbled/overlap ho: `EscPos.maxStripHeightPx` aur `btWritePieceGapMs` kam/zyada karein (Kotlin comments dekhein).

## Flutter side (2026-09-29) — Phase 13: Maintenance tools (Bulk Translate / Merge Duplicates / Duplicate Unit Fix)
- [x] `BulkTranslateActivity.kt` -> `lib/screens/bulk_translate_screen.dart` + `lib/db/bulk_translate_repository.dart`. Items screen ka "Translate" pill ab chalta hai (admin-only, RoleGuard). Categories / Units: Urdu values ek baar, English saamne; Save = master row + har product (category / unit / secondaryUnit / tertiaryUnit) + sync_queue, ek transaction. Items: ek waqt ek naam, "Save & Next" (comma se kayi English naam). Item tag sirf un products par lagta hai jin ka tag khali ho.
- [x] `DuplicateUnitFix.kt` -> `lib/utils/duplicate_unit_fix.dart` ("Box\nBox" -> "Box", teeno unit columns, sab products). Farq: `units` master list ki gandi rows bhi saaf.
- [x] `MergeDuplicateProductsFix.kt` -> `lib/utils/merge_duplicate_products.dart`. Sirf wahi merge jin ka naam AUR poora unit setup barabar ho; baqi "skipped". Farq (ehtiyat): pehle preview dialog, phir encrypted backup (fail ho to poochta hai), khali naam kabhi merge nahi, plan transaction ke andar taaza data se dobara banta hai, stock_movements par dirty=1, audit `merge_duplicate_products`. Sale/purchase items, returns, stock_movements keeper ke barcode par; held_bills nahi chhote (Kotlin jaisa).
- Test: `test/maintenance_test.dart` (pure: dedupedUnitName, looksUrdu/urduValues, planProductMerge).
- Note: compile/test nahi hua (Flutter SDK nahi) — `flutter pub get && flutter analyze && flutter test test/maintenance_test.dart`.
- [ ] Merge sirf EK device par chalayein aur pehle sync mukammal ho lene dein (Phase 10 mein loser barcodes ke sync-delete ke saath doosri device par purana stock wapas push ho sakta hai).
- [ ] Phase 13 mukammal. Baqi: Phase 10 (Cloud sync).

## Flutter side (2026-09-29) — Phase 11: Backup / Export / Crypto / Scheduler
- [x] `BackupCrypto.kt` -> `lib/backup/backup_crypto.dart`: IBB1 AES-256-GCM (magic + salt16 + iv12 + ct+tag16, PBKDF2-HMAC-SHA256 120k) — Android ke saath byte-compatible; purana `IBAKV001` (AES-CBC, 100k) sirf restore ke liye. `test/backup_test.dart` mein asli Java JCE se bane fixtures (Dart <-> Android saboot).
- [x] `BackupPasswordStore.kt` -> `lib/backup/backup_password_store.dart` (flutter_secure_storage; getOrCreate 16 alnum, setPassword min 8).
- [x] `BackupHelper.kt` -> `lib/backup/backup_helper.dart`: backupNow (WAL checkpoint), backupIfDue(30 min), listBackups, share, safe restore (temp -> SQLite header -> schema check -> replace; ghalat password par live DB nahi chhuti), purana CBC / plain .db restore. Farq: restore se pehle safety backup; public Downloads copy nahi (Share se).
- [x] `BackupScheduler.kt` -> `lib/backup/backup_scheduler.dart`: 12 PM / 9 PM checkpoint + app-close, `main()` mein `BackupScheduler.instance.register()`. Farq: WorkManager nahi — sirf app zinda hone par (Timer + resume/paused).
- [x] `BackupExportActivity.kt` -> `lib/screens/backup_export_screen.dart` + `lib/backup/backup_export.dart`: Full / date-range CSV + PDF (Open / Print / Share). Dashboard Backup tile ab chalta hai. Encrypted Backup Now / Password / Restore sirf admin.
- pubspec: `cryptography`, `flutter_secure_storage`, `share_plus`, `file_picker`, `pdf`, `printing`, `open_filex`. `tools/android_fix.sh` ab minSdk 23 karta hai.
- PDF mein Urdu naam: `assets/fonts/NotoNastaliqUrdu-Regular.ttf` pubspec mein declare karein (warna Helvetica).
- Note: compile/test nahi hua (Flutter SDK nahi) — `flutter pub get && flutter analyze && flutter test test/backup_test.dart`.
- [ ] Baaki: WorkManager background backup, Settings mein Backup row, Android Room DB ka Flutter mein import (schema alag).

## Flutter side (2026-09-29) — Purchase mukammal: saved purchase edit + Delete + supplier comparison (Phase 2)
- [x] `PurchaseActivity.kt` / `RoomPurchaseRepository.savePurchase`: `PurchaseScreen(editBillNo:)` — History card tap, Day Book purchase row aur Party Dashboard purchase row (teeno sirf admin) saved bill ko edit mode mein kholte hain. Returned bill edit nahi hota.
- [x] DB v12: `purchases.supplierInvoiceNo`; `purchase_items.conversionFactor / itemName / retailRate / wholesaleRate` (purani rows 0 / '' = "captured nahi"). `PurchaseItem.conversionFactor` khareed ke waqt freeze hota hai, is liye baad mein ladder badle to bhi edit / return / delete / party-transaction item edit wahi qty nikalte hain (`purchaseItemSmallestQty`, `partialSmallestQty`, `editPurchaseItem` — factor > 0 pehle, warna maujuda ladder).
- [x] `purchaseEditDiff` (`lib/utils/stock_touch_policy.dart`, Kotlin `StockTouchPolicy.purchaseEditDiff`): edit par SIRF badli / nayi lines ka stock + weighted cost touch hota hai; jo line waisi hi rahi uska frozen factor carry aur na reverse na dobara add. Reverse hone wali line ka stock baad ki sale se kam ho chuka ho to poora edit rok diya jata hai.
- [x] Edit save: purana bill utarna (supplier ka baaqi, payments, cash rows), phir naya; bill se linked payments (`billReference`) ki cash dobara nahi ginti (`planPurchaseCash` + `subtractLinkedPaid`); audit `purchase_edit`.
- [x] Naya bill: supplier ka invoice no. + duplicate invoice alert + same supplier/total/din warning, pichla purchase rate auto-fill, Retail/Wholesale rate, margin/loss warning, naya product mid-purchase, Split Payment (Cash + Bank), Hold / Recall (`PHOLD...`), draft autosave, supplier ka live balance, bill preview.
- [x] Edit screen par **Delete** button (confirm -> `PurchaseHistoryRepository.deletePurchase`: stock + cost, supplier balance, payments, cash sab wapas) aur item chun kar **Compare suppliers** popup (`RateComparisonRepository.compare`, sasta pehle; admin + manager).
- [x] `PurchaseHistoryRepository.linesForBill` ab line par jama shuda naam dikhata hai; `lib/AH-Developer-Purchase-Screen-Update.zip` repo se hata di gayi.
- Test: `test/purchase_screen_test.dart` (margin, duplicate rule, validation, cash plan, hold/recall, `purchaseEditDiff`, frozen factor, models).
- Note: compile/test nahi hua (Flutter SDK nahi) — `flutter analyze && flutter test test/purchase_screen_test.dart test/purchase_history_test.dart test/party_transaction_test.dart`.

## Flutter side (2026-09-29) — Phase 3 (Sale) ke baqi kaam: bill se linked payments
- [x] `RoomSaleRepository.saveSale` (`linkedToSkip`): saved sale edit karte waqt `paid` mein wo payments pehle se shamil hain jo \"Receive Payment > link to bill\" se aayi thin aur jinki apni cash row hai. Pehle Flutter poora `paid` dobara cash-in kar deta tha (cash book mein double). Ab `SaleRepository._linkedPaidForBill()` (`billReference == bill AND reference != bill`) + pure `subtractLinkedPaid(rows, linkedPaid)` (`lib/db/sale_repository.dart`) — pehli rows se linked raqam kaat kar baqi cash-in banta hai, zero rows chhod di jati hain.
- [x] `deleteSale`: `_voidLinkedPayments(txn, invoice, now)` — linked payment rows + unki cash rows hatti hain (aur sync_queue mein delete), pehle wo orphan \"standalone\" payments ban kar Fix Balances / Payments report / cash book bigaadti thin.
- [x] `returnSale`: `_reverseCash(...)` (`return:<invoice>` dated OUT) + `_voidLinkedPayments(..., refundType: 'OUT', refundLabel: 'Sale Return')` — har linked payment ki cash row ka alag dated refund, phir payment row drop. Party balance ko haath nahi lagate (bill ka apna reversal `total - paid` se pehle hi theek hai, aur `paid` mein linked payments shamil hain).
- Test: `test/sale_linked_payments_test.dart` (`subtractLinkedPaid`: koi linked nahi / ek row / agli row mein spill / poori dropped / total cash-in + linked == paid).
- Phase 3 ab mukammal: `SaleActivity.kt` mein sirf Bluetooth/WhatsApp share baaki hai jo Phase 12 ka hissa hai. (`SaleCart` ka \"Billed Items\" popup Phase 5 mein tracked hai.)
- Note: compile/test nahi hua (Flutter SDK nahi) — `flutter analyze && flutter test test/sale_linked_payments_test.dart test/split_payment_test.dart test/sale_edit_and_draft_test.dart`.

## Flutter side (2026-09-29) — Inventory Insights: Reorder / Damage / Margin / Movers (Phase 9, aakhri screen)
- [x] `InventoryInsightsActivity.kt`: `lib/screens/inventory_insights_screen.dart` (`InventoryInsightsScreen(initialMode: InsightsMode.reorder | damage | profit | movers)`) + `lib/db/inventory_insights_repository.dart` (pure `reorderCandidates`, `suggestedReorderQty`, `damageLossValue`, `totalDamageLoss`, `marginPercent`, `averageMargin`, `sortByMarginAsc`, `buildMovementRows`, `fastMovers`, `slowMovers`, `mergeItemHistory`; test `test/inventory_insights_test.dart`). Reports hub ki 4 rows (Reorder Suggestions, Damage / Loss Report, Profit Margin per Item, Fast / Slow Movers) ab chalti hain; \"Coming soon\" ka `_soon` hata diya. Admin/Manager only.
- **Reorder:** `stock <= reorderLevel` aur `reorderLevel > 0`; tajweez = level ka DOUBLE tak wapas bharna (kam az kam level tak), smallest unit mein.
- **Damage:** `stock_movements` type `DAMAGE` (period filter), Total loss value + Entries; value = `|qty| * cost / smallestUnitFactor` (Kotlin FIX barqarar; product delete ho to raw cost).
- **Margin:** `(sale - cost) / sale * 100`, sirf salePrice > 0; sabse kam margin pehle; rang < 10% red, < 25% amber, warna teal; row tap = us item ki har sale + purchase (naya pehle) dialog.
- **Movers:** period ke andar (returned sales bahar) barcode ke hisaab se qty/amount; Fast = top 15 (qty > 0), Slow = 15 sab se kam (zero-sale pehle). Qty Kotlin jaisi hi — jis unit mein bechi gayi, unit-normalize nahi (isliye carton aur pcs ek hi total mein jur sakte hain).
- Farq (Kotlin se): hafta Monday se (`reportRangeFor`); role repository mein bhi check; barabar values par stable order.
- `StockTouchPolicy.kt` pehle hi `lib/utils/stock_touch_policy.dart` mein port ho chuki thi — sirf `port_map.json` ka status purana tha, ab `done`.
- Note: compile/test nahi hua (Flutter SDK nahi) — `flutter analyze && flutter test test/inventory_insights_test.dart`.
- [ ] Phase 9 mukammal. Agla: Phase 10 (Cloud sync) ya Phase 4 ke baqi (Dashboard/Settings ko MenuRow/ThemeManager par lana).

## Flutter side (2026-09-29) — Stock Taking (Phase 9)
- [x] `StockTakingActivity.kt`: `lib/screens/stock_taking_screen.dart` + `lib/db/stock_taking_repository.dart` (pure `buildVariances`, `stockTakeValueImpact`, `firstInvalidCount`, `filterStockTakeProducts`, `stockTakeSessionId`, `stockTakeSummaryText`; test `test/stock_taking_test.dart`). Reports hub ki \"Stock Taking\" row ab chalti hai. Admin/Manager only.
- Poori catalog list (naam/searchTag/category/barcode search), har item par System stock + \"Counted\" field (custom `NumericKeypadField`). Gintee product ki SMALLEST unit mein (row par unit ka naam likha). **Khali field = gina hi nahi** (0 nahi) — sirf likhi hui ginti wale products chuute hain; search se list filter hone par ginti gum nahi hoti.
- \"Review & Save\": taaza product se variance (|farq| > 0.0001), confirm dialog mein pehli 15 lines + \"… +N more\" + Estimated value impact (`delta * cost / smallestUnitFactor`, Kotlin FIX barqarar).
- Confirm = har line ka `products.stock` update + `STOCK_TAKE` ledger row (reference = `ST<yyMMddHHmmss>`, note `system=.. counted=.. — <note>`) + product `sync_queue`, sab ek transaction mein; phir ek `stock_take` audit entry. Stock History mein rows khud dikhti hain.
- Farq (Kotlin se): negative gintee rad; piece-based item mein fraction rad (`isValidSmallestQty`); role Admin/Manager (Kotlin mein check nahi tha); role repository mein bhi check.
- Note: compile/test nahi hua (Flutter SDK nahi) — `flutter analyze && flutter test test/stock_taking_test.dart`.
- [ ] Baaki: Inventory Insights (Reorder / Damage-Loss / Profit Margin / Movers), StockTouchPolicy.

## Flutter side (2026-09-29) — Stock Adjustment (Phase 9)
- [x] `StockAdjustmentActivity.kt`: `lib/screens/stock_adjustment_screen.dart` + `lib/db/stock_adjustment_repository.dart` (pure `adjustmentDelta`, `adjustmentType`, `validateAdjustment`, `searchProductsForAdjustment`; test `test/stock_adjustment_test.dart`). Reports hub ki "Stock Adjustment" row ab chalti hai. Admin/Manager only.
- Item search (khali search kuch nahi dikhata, Kotlin jaisa) -> dialog: **Damage / Loss** (hamesha stock ghatata hai, ledger type `DAMAGE`) ya **Correction** (+ Add / − Remove, type `ADJUSTMENT`), qty smallest unit mein + optional note.
- Save = `products.stock` update + ledger row (cost = us waqt ka product.cost) + product `sync_queue`, ek transaction mein. Kam karte waqt SQL guard (`stock + delta >= 0`).
- Farq (Kotlin se): piece-based item mein fraction reject (`isValidSmallestQty`); galti par dialog khula rehta hai aur wajah dikhata hai; role repository mein bhi check.
- `DAMAGE` rows ab ban rahi hain — inhi par **Damage / Loss Report** (Inventory Insights) chalegi.
- Note: compile/test nahi hua (Flutter SDK nahi) — `flutter analyze && flutter test test/stock_adjustment_test.dart`.
- [ ] Baaki: Stock Taking, Inventory Insights.

## Flutter side (2026-09-29) — Stock Audit (Phase 9)
- [x] `StockAuditActivity.kt`: `lib/screens/stock_audit_screen.dart` + `lib/db/stock_audit_repository.dart` (pure `buildAuditRows`, `filterAuditRows`; test `test/stock_audit_test.dart`). Reports hub ki "Stock Audit" row ab chalti hai. Admin/Manager only.
- Har product ka `stock` vs `SUM(stock_movements.qty)`; |farq| > 0.01 wale mismatch, bara farq pehle. Card: System stock / Ledger says / Difference + "Isko fix karo"; upar "Sab mismatches fix karo" (confirm dialog).
- Fix = `AUDIT_RECONCILE` ledger row (`StockLedger.logAuditReconciliation`); live `products.stock` KABHI nahi badalta. Fix-all ek transaction mein (ya sab, ya koi nahi) + sync_queue.
- Farq (Kotlin se): card tap us product ki Stock History kholta hai (`StockMovementScreen(initialBarcode:)`; Kotlin generic list kholta tha); negative farq ka breakdown abs value + sign se (Kotlin mein floor() ulta deta tha).
- Note: DB v11 ke backfill ki wajah se purane products pehli baar clean dikhenge; mismatch sirf naye drift par aayega.
- Note: compile/test nahi hua (Flutter SDK nahi) — `flutter analyze && flutter test test/stock_audit_test.dart`.
- [ ] Baaki: Stock Taking, Stock Adjustment, Inventory Insights.

## Flutter side (2026-09-29) — Stock Movement / Stock History + Cost History (Phase 9)
- [x] `StockMovementActivity.kt`: `lib/screens/stock_movement_screen.dart` (`StockMovementScreen(mode: stock | cost)`) + `lib/db/stock_ledger.dart` + `lib/models/stock_movement.dart`. Reports hub ki "Stock History" aur "Cost History" rows ab chalti hain. Admin/Manager only.
- **Asal masla:** Flutter mein `stock_movements` table thi hi nahi, is liye koi movement kabhi record nahi hoti thi. Ab **DB v11**: table + index + purane products ka maujooda stock ek `OPENING_STOCK` row ke taur par (taake ledger sum == product.stock shuru se sahi ho, Stock Audit fazool drift na dikhaye).
- `StockLedger.log(txn, ...)` (Kotlin `logMovement`) har stock badalne wale write ke SAME transaction mein + `sync_queue` (`stock_movement`, id `stock_movement:<id>`): 
  - Sale: `SALE` (naya), `SALE_EDIT` + `SALE_EDIT_REVERSAL` (edit), `SALE_REVERSAL` (delete/return), quick sale `SALE`.
  - Purchase: `PURCHASE` (naya, unitCost = naya weighted cost), `PURCHASE_RETURN` (partial return), `PURCHASE_REVERSAL` (poori delete).
  - Party Transaction: sale item qty edit `SALE_EDIT`, sale item delete `SALE_ITEM_DELETE`, purchase item edit `PURCHASE_EDIT` (rate-only edit bhi, qty 0 ke saath — Cost History mein dikhne ke liye), purchase item delete `PURCHASE_ITEM_DELETE`.
  - Naya product: `OPENING_STOCK` (`ProductRepository.upsert(isNew: true)`).
- `StockLedger.logAuditReconciliation()` tayyar hai (Stock Audit ke liye); `DAMAGE` / `ADJUSTMENT` / `STOCK_TAKE` types screen mein label ke saath maujood hain — likhne wali screens abhi baaki.
- Kotlin FIX barqarar: `PURCHASE_RETURN` ka apna label; Cost History sirf `PURCHASE*` + `OPENING_STOCK`.
- **Bug fix:** `ProductRepository.upsert` ab `ConflictAlgorithm.replace` use karta hai (Kotlin `OnConflictStrategy.REPLACE`); pehle existing product edit karne par PRIMARY KEY conflict aa sakta tha.
- Test: `test/stock_movement_test.dart` (map round-trip, cost-affecting types, qty format, ledgerSum, product filter).
- Note: compile/test nahi hua (Flutter SDK nahi) — `flutter analyze && flutter test test/stock_movement_test.dart`. Purane Flutter DB par pehli baar khulne par v10 -> v11 migration chalegi.
- [ ] Baaki (ledger ab tayyar hai): Stock Audit, Stock Taking, Stock Adjustment, Inventory Insights.

## Flutter side (2026-09-29) — Stock Report (Phase 9)
- [x] `StockReportActivity.kt`: `lib/screens/stock_report_screen.dart` + `lib/db/stock_report_repository.dart` (pure `costPerSmallestUnit`, `salePerSmallestUnit`, `isLowStock`, `summarizeStock`, `filterStock`; test `test/stock_report_test.dart`).
- Dashboard "Low Stock" tile ab `StockReportScreen(lowStockOnly: true)` kholta hai (Kotlin `EXTRA_LOW_STOCK_ONLY`); Reports hub ki "Stock Report" row bhi.
- Summary: Total Products / Low Stock / Stock Value (Cost) / Stock Value (Sale); search naam+searchTag, category, barcode; LOW STOCK ONLY toggle; card par LOW badge + stock breakdown + cost value.
- Kotlin FIX barqarar: value = stock * (rate / smallestUnitFactor) (stock smallest unit mein, rate primary par).
- Role: sab roles (Low Stock tile sab ko dikhta hai). Cashier ko cost data nahi: repository `cost` zero karta hai, "Stock Value (Cost)" card aur row values chhup jate hain.
- [ ] Reports hub ki "Coming soon" rows ab baqi: Stock History, Cost History, Stock Audit, Stock Adjustment, Stock Taking, Reorder, Damage/Loss, Profit Margin, Movers.
- Note: compile/test nahi hua (Flutter SDK nahi) — `flutter analyze && flutter test test/stock_report_test.dart`.

## Flutter side (2026-09-29) — Monthly Sale vs Purchase (Phase 9)
- [x] `MonthlySalesPurchaseActivity.kt`: `lib/screens/monthly_screen.dart` + `lib/db/monthly_repository.dart` (pure `selectEntries`, `groupPeriods`, `suggestParties`, `suggestProducts`; test `test/monthly_test.dart`). Reports hub ki "Sale vs Purchase" row ab isi ko kholti hai.
- Monthly / Yearly, Party (customer/supplier) + Item filter, Total Sale / Total Purchase cards, har period ka Sale / Purchase / Net (naya pehle). Customer chuna => purchase side n/a, supplier => sale side n/a (Kotlin jaisa).
- Farq: party *id* se match (Kotlin naam se); item lines se returned bills bahar (Kotlin ke item queries status nahi dekhte the); item suggestions `matchesQuery` (name + searchTag); header `palette.teal`. Role admin/manager (Kotlin mein check nahi tha, Reports ke andar hai).
- Note: compile/test nahi hua (Flutter SDK nahi) — `flutter analyze && flutter test test/monthly_test.dart`.

## Flutter side (2026-09-29) — Reports (Phase 9, pehli screen)
- [x] `ReportsActivity.kt`: `lib/screens/reports_screen.dart` + `lib/db/reports_repository.dart` (pure `reportRangeFor`, `buildProfitLoss`; test `test/reports_test.dart`). Dashboard tile "Reports" (admin/manager).
- Hub rows chalte hain: Sale/Purchase History (`HistoryScreen(mode:)`), Party Reports, Payments, Due Reminders, Balance Sheet, Zakat.
- Period filter (Today / Week / Month / All Time) -> Total Sales / Profit / Purchases / Expenses / Sale Returns / Purchase Returns / Number of Sales, P&L (Revenue - COGS = Gross - Expenses = Net), Top 5 Products, Daily Sales. SQL Kotlin DAO jaisi (returned bills bahar; profit = sale.total - bill COGS).
- [ ] Rows jo abhi "Coming soon" dikhati hain (baqi Phase 9 screens banne par `_soon` ki jagah `_open(...)`): Stock History, Cost History, Stock Audit, Stock Adjustment, Stock Taking, Reorder, Damage/Loss, Profit Margin, Fast/Slow Movers.
- Farq: Today ka end agla midnight (DST-safe); hafta Monday se (Kotlin mein locale ka firstDayOfWeek); Purchase History row manager ko dikhti hai magar screen admin-only hai.
- Note: compile/test nahi hua (Flutter SDK nahi) — `flutter analyze && flutter test test/reports_test.dart`.

## Flutter side (2026-09-29) — HistoryActivity (Phase 7, aakhri screen)
- [x] `HistoryActivity.kt`: `lib/screens/history_screen.dart` — `HistoryScreen(mode: HistoryMode.sales | purchases | null)`.
  Kotlin mein ye combined screen hai; dono lists Flutter mein pehle se `SaleHistoryScreen` / `PurchaseHistoryScreen` hain
  (Return/Delete/profit admin-only, atomic transactions wahin), isliye ye sirf router hai — logic dobara nahi likhi.
  `mode` di ho to seedha wahi list (koi tab nahi); `mode` null ho to SALES / PURCHASES pills (Purchases sirf admin, warna sirf Sales).
- Kahin se abhi `HistoryScreen` khulti nahi (Dashboard par alag Sale/Purchase History tiles hain) — Phase 9 Reports ke tiles `HistoryScreen(mode: ...)` use karenge.
- Tools: `port_map.json` mein Zakat + Shell Ledger `done` kiye (screens/tests/dashboard tiles pehle se maujood thay, status purana tha).
- Note: compile/test nahi hua (Flutter SDK nahi) — `flutter analyze`.

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
- [x] Items ka "Translate" button: BulkTranslateScreen se jur gaya (Phase 13).
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
- [x] Sale ke baqi chhote items: Split Payment dialog, naye sale par Cash/Bank picker, duplicate-bill warning, inline 'add customer' popup (sab ho chuke — dekhein PORT_STATUS).
- [x] Bill se linked payments (`voidLinkedPayments` / `linkedPaidForBill`) — Sale side ab done (upar 2026-09-29 Phase 3 entry).
- [ ] `BulkDefaultUnitActivity.kt` / `BulkMissingRatesActivity.kt` (Phase 5) — default unit ab column mein hai, screen baaki.
- Note: yeh code is session mein compile/test nahi hua (Flutter SDK maujood nahi tha) — `flutter analyze && flutter test` chalayein.

---
## Flutter side (2026-09-29) — Dashboard (Phase 4)
- [x] `MainActivity.kt`: `lib/screens/dashboard_screen.dart` + `lib/db/dashboard_repository.dart` (pure functions: `dashboardColumns`, `dashboardAmount`, `dashboardSearch`, `todayRange`, `dashboardProfit`, `syncPendingMessage`, `showsProfitCard`, `showsLogoutTile`, `switchableUsers`, `roleColorValue`, `checkSwitchPassword`; tests `test/dashboard_test.dart`).
- Header: Settings gear, dark/light toggle (`ThemeManager`), Quick Switch user. Quick Switch = fingerprint pehle (`Biometric`), cancel/fail par us user ka password; purani plain-text password theek nikle to hash mein badal jata hai. Switch ke baad dashboard naye role ke saath dobara banta hai (Kotlin `recreate()`).
- Live search: naam + searchTag, pehle 6 nateeje, tap => `ItemSearchScreen(preselectBarcode:)`.
- Today's sale (sab roles) / Today's profit (sirf admin, cost data data-layer par bhi band). Kotlin FIX barqarar: profit = discount ke baad sale - COGS. Card tap = amount chhupao (`Rs ••••••`).
- Quick Actions Kotlin ki tarteeb mein, 2 / 3 / 4 column (phone / tablet portrait / bara tablet). Naye hooks: `SaleScreen(openQuickSale: true)` (Quick Sale tile) aur `PartyDashboardScreen(quickPayment: true)` (Payments tile — Received/Made chooser, phir searchable party picker). Logout tile sirf manager/cashier ko (admin Settings se).
- DUES SUMMARY: You'll get / You'll give live-ledger closings se (`partyTotals`), Party Dashboard jaisa hi; tap => Party Dashboard. Sync pending label (`sync_queue.syncedAt IS NULL`) tap => Settings.
- Farq: Reports/Products/Zakat/Balance Sheet/... Kotlin mein Settings/Reports ke andar hain, Flutter Settings mein unke links abhi nahi, is liye "MORE SCREENS" (collapsed) mein hain — links aane par woh section hata dein. Items tile abhi sirf admin (Kotlin sab ko).
- [ ] Backup tile (Phase 11) abhi "Coming soon". Crash dialog + `SyncWorker.schedulePeriodic` (Phase 10/13). Dashboard tiles ko `MenuRow` par lana zaroori nahi tha (Kotlin bhi apna quick-action card use karta hai).
- Note: yeh code compile/test nahi hua (Flutter SDK nahi tha) — `flutter analyze && flutter test` chalayein.
