# PORT_STATUS (auto-generated — edit mat karein)

`python3 tools/port_status.py` chala kar dobara banayein.

**Overall (lines of Kotlin ke hisaab se): 78%**  (38677/49102)

## Phase 0: Foundation (models, DB, colors, widgets) — 100%

| | Kotlin | LOC | Flutter | Note |
|---|---|---|---|---|
| ✅ | Database.kt | 2280 | lib/models/*.dart + lib/db/app_database.dart | Entities + 3-tier unit ladder. Room migrations skip (fresh DB v1). |
| ✅ | DiscountCalculator.kt | 37 | lib/utils/discount_calculator.dart |  |
| ✅ | AppColors.kt | 28 | lib/theme/app_colors.dart |  |
| ✅ | PremiumHeader.kt | 160 | lib/widgets/premium_header.dart |  |
| ✅ | UiHelpers.kt | 175 | lib/widgets/premium_widgets.dart |  |

## Phase 1: Products — 100%

| | Kotlin | LOC | Flutter | Note |
|---|---|---|---|---|
| ✅ | ProductUnitDialog.kt | 625 | lib/widgets/unit_dialog.dart | 3-tier + "Default Unit for Sale / Quick Sale" chips (lib/widgets/unit_dialog.dart). |
| ✅ | ProductActivity.kt | 2112 | lib/screens/product_screen.dart | Admin-only (role guard baad mein Phase 4 se). |

## Phase 2: Purchase — 100%

| | Kotlin | LOC | Flutter | Note |
|---|---|---|---|---|
| ✅ | PurchaseActivity.kt | 2325 | lib/screens/purchase_screen.dart | lib/screens/purchase_screen.dart + lib/utils/purchase_calc.dart + lib/services/purchase_hold_recall.dart. Naya purchase + saved purchase edit (PurchaseScreen(editBillNo:), admin-only; sirf badli lines ka stock/cost), supplier invoice no. + duplicate alerts, qty/unit/rate + pichla rate auto-fill, Retail/Wholesale rate, margin warning, Split Payment, Hold/Recall (PHOLD) + draft autosave, Delete button (edit mode) aur supplier rate-comparison popup. Scan Bill + Bill Preview/Print (Phase 12) done. Test: test/purchase_screen_test.dart. |
| ✅ | PurchaseRepository.kt | 141 | lib/db/purchase_repository.dart |  |
| ✅ | RoomPurchaseRepository.kt | 597 | lib/db/purchase_repository.dart |  |
| ✅ | PurchaseUseCases.kt | 169 | lib/db/purchase_repository.dart |  |
| ➖ | PurchaseViewModel.kt | 180 | — | Flutter mein State/setState — alag ViewModel zaroori nahi. |

## Phase 3: Sale — 68%

| | Kotlin | LOC | Flutter | Note |
|---|---|---|---|---|
| 🟡 | SaleActivity.kt | 1869 | lib/screens/sale_screen.dart | Done: naya sale, quick sale, hold/recall, default unit, reprice, margin warning, credit-limit confirm, saved sale edit/return/delete (admin only), draft autosave, customer ka apna rate, Rs(amount) mode, inline line edit, Print, Split Payment dialog, Cash/Bank picker (naye sale par), duplicate-bill warning, inline 'add customer' popup. Bill Preview: Bluetooth print + WhatsApp (Phase 12) done. |
| ✅ | SaleRepository.kt | 136 | lib/db/sale_repository.dart | Edit/delete/return + audit + frozen conversionFactor (DB v4) done. Bill-linked payments bhi: edit par linkedPaidForBill cash-in mein dobara nahi ginta (subtractLinkedPaid), delete par linked payments + unki cash rows hatti hain, return par unka dated 'return:<ref>' refund + payment row hat'ta hai (voidLinkedPayments). Test: test/sale_linked_payments_test.dart. |
| ✅ | RoomSaleRepository.kt | 563 | lib/db/sale_repository.dart | linkedToSkip (edit) + voidLinkedPayments (delete) sale_repository.dart mein. |
| ✅ | SaleUseCases.kt | 400 | lib/db/sale_repository.dart |  |
| ➖ | SaleViewModel.kt | 193 | — |  |

## Phase 4: Login, roles, settings, dashboard — 57%

| | Kotlin | LOC | Flutter | Note |
|---|---|---|---|---|
| 🟡 | LoginActivity.kt | 866 | lib/screens/login_screen.dart | Password / none / fingerprint / both done. OTP + phone link Phase 10 mein. |
| ✅ | PasswordHasher.kt | 61 | lib/utils/password_hasher.dart |  |
| 🟡 | UserManagementActivity.kt | 753 | lib/screens/user_management_screen.dart | Fingerprint lock done. Sync queue Phase 10 mein. |
| ✅ | AppLock.kt | 157 | lib/services/app_lock.dart | WidgetsBindingObserver + navigatorKey; pending re-lock prefs mein. |
| ✅ | Loc.kt | 43 | lib/utils/loc.dart |  |
| 🟡 | ThemeManager.kt | 125 | lib/theme/theme_manager.dart | Palette + dark toggle done. Purani screens abhi static AppColors par — migrate baaki. |
| 🟡 | SettingsActivity.kt | 1320 | lib/screens/settings_screen.dart | Shop info, login method (password/fingerprint/both/none), dark mode, language, users. Printer/Backup/Sync/OTP baad ke phases. |
| 🟡 | MainActivity.kt | 1085 | lib/screens/dashboard_screen.dart | Header (Settings gear, dark toggle, Quick Switch: fingerprint -> password fallback + plain-text migration), live item-rate search (top 6, tap = Item Rate Search), Today sale/profit (tap = hide; profit sirf admin, discount ke baad), 2/3/4-column Quick Actions (Kotlin tarteeb), Quick Sale + Payments tiles (SaleScreen.openQuickSale / PartyDashboardScreen.quickPayment), DUES SUMMARY (live-ledger You'll get/give), sync-pending label. Backup tile (BackupExportScreen) done. Baaki: crash dialog + SyncWorker.schedulePeriodic (Phase 10/13), Items tile Kotlin mein sab roles ko (Flutter mein admin), MORE SCREENS section Settings/Reports mein links aane par hata dein. Test: test/dashboard_test.dart. |
| ✅ | InputValidation.kt | 58 | lib/utils/input_validation.dart |  |
| ✅ | Numerickeypad.kt | 214 | lib/widgets/numeric_keypad.dart | NumericKeypad.show + NumericKeypadField. Kotlin mein sirf StockTakingActivity istemal karti hai — Sale/Purchase ko keypad par lana ZAROORI NAHI. |
| ✅ | MenuRow.kt | 196 | lib/widgets/menu_row.dart | MenuRow / ExpandableMenuRow / IconBadge. Dashboard/Settings ko isi par lana baaki. |

## Phase 5: Item search, rates, items, sale extras — 92%

| | Kotlin | LOC | Flutter | Note |
|---|---|---|---|---|
| ✅ | ItemSearchActivity.kt | 842 | lib/screens/item_search_screen.dart | Spec item_rate_search.md ke mutabiq (3 sale rates, wholesale, cost gate). |
| ✅ | RateComparisonActivity.kt | 537 | lib/screens/rate_comparison_screen.dart | Admin/manager only (RoleGuard + repository cashier ko khali deta hai). Rates primary unit par normalize. lib/db/rate_comparison_repository.dart (pure buildSupplierRateRows) + test/rate_comparison_test.dart. Dashboard tile. |
| ✅ | ItemsActivity.kt | 1300 | lib/screens/items_screen.dart | Admin-only (RoleGuard). Products/Categories/Units tabs, category drill-down + rename/delete, Change Category, Delete, Edit -> ProductScreen(editBarcode). lib/db/items_repository.dart. Baaki: Import (Rate List CSV, file picker chahiye) aur Translate (Phase 13). Test: test/items_test.dart. |
| ✅ | BulkMissingRatesActivity.kt | 525 | lib/screens/bulk_missing_rates_screen.dart | Admin-only (Items se RoleGuard). Dono rate + unit chips (primary par convert), save + sync_queue ek transaction (ProductRepository.setRates). |
| ✅ | BulkDefaultUnitActivity.kt | 318 | lib/screens/bulk_default_unit_screen.dart | Admin-only (Items se RoleGuard). Auto pehle se highlight; Auto par save = koi write nahi (ProductRepository.setDefaultUnitIndex). |
| 🟡 | SaleCart.kt | 685 | lib/utils/sale_cart.dart | Done: default unit, reprice on sale type, margin check, Rs-amount mode, inline line edit, customer-rate suggest. Baaki: sirf 'Billed Items' popup (Flutter mein list seedhi screen par hai). |
| ✅ | SaleQuickSale.kt | 404 | lib/screens/sale_quick_sale.dart | Dialog + saveQuickSale + credit-limit confirm + top-30-day items pehle. System keyboard (Kotlin bhi yahi). |
| ✅ | SaleHoldRecall.kt | 199 | lib/services/sale_hold_recall.dart + lib/widgets/held_bills_dialog.dart | encode/decode + Held Bills dialog. Sale holds sirf HOLD% (PHOLD% purchase ke liye). |

## Phase 6: Parties (customer/supplier) — 80%

| | Kotlin | LOC | Flutter | Note |
|---|---|---|---|---|
| 🟡 | PartyActivity.kt | 1359 | lib/screens/party_screen.dart | Done: tabs, add form, search, Dues only, edit/delete (live balance), history dialog, Call, Fix Balances, Merge, Cleanup Payments/Orphaned, stuck balance (admin/manager). Baaki: contact picker (flutter_contacts + permissions), row tap se Party Dashboard/Transaction. |
| 🟡 | PartyDashboardActivity.kt | 1522 | lib/screens/party_dashboard_screen.dart + lib/db/party_dashboard_repository.dart | Sab roles. Done: You'll Get/Give cards (tap = filter), Parties/Transactions/Items tabs, search, filter dialog, live-ledger balances, Daily/Stuck line, item detail + Edit Rates (admin only, sync_queue ke saath), main menu, '+' quick add, Add Sale/Purchase bar. Cashier ko cost/purchase data nahi. Party row tap -> PartyTransactionScreen done. Overdue/Due Today badge (customers) done (DB v10). Payment Received/Made party picker done (party_quick_add_menu.dart). Purchase row tap = PurchaseScreen(editBillNo:) (admin only). Test: test/party_dashboard_test.dart. |
| ✅ | PartyTransactionActivity.kt | 2219 | lib/screens/party_transaction_screen.dart + lib/db/party_transaction_repository.dart | Balance/Stuck/stat cards (live ledger), All/Bills/Payments + search, Billed Items dialog (item edit/delete admin-only, ek transaction: stock+cost+bill+balance+cash+sync_queue), Receive/Make Payment (showPaymentDialog) + payment Edit/Delete (admin) + Share (clipboard), Edit Name, openPayment. Farq: Share = clipboard, Overdue asli (bill dueDate, DB v10), supplier screen sirf admin/manager. Test: test/party_transaction_test.dart. |
| ✅ | PartyReportsActivity.kt | 1034 | lib/screens/party_reports_screen.dart + lib/db/party_reports_repository.dart | 6 reports (Item, Ledger, Payment History, Statement, Sale/Purchase by Party, P&L / Purchase Summary) — returned bills bahar, general payments Ledger/Statement mein, stuck split. Admin/Manager only (RoleGuard). Farq: Material icons; purchase item naam live product se. Test: test/party_reports_test.dart. |
| ✅ | PartyRepository.kt | 444 | lib/db/party_repository.dart | lib/db/party_repository.dart: CRUD + live balances + recalc(dryRun) + merge + cleanup, sab ek transaction mein. PartyLedger/trueBalance/countBalanceDrift yahin (Balance Sheet bhi yahi istemal karta hai). Test: test/party_test.dart. |
| ✅ | PartyUseCases.kt | 196 | lib/db/party_repository.dart | Validation (naam zaroori) PartyRepository.addCustomer/editCustomer/... mein. |
| ✅ | PartyQuickAddMenu.kt | 291 | lib/widgets/party_quick_add_menu.dart | showPartyMenuSheet (Kotlin showPremiumMenuSheet) + PartyMenuItem + showPartyPickerForPayment (searchable, naam/phone) -> PartyTransactionScreen(openPayment: true). Dashboard '+' menu ab isi se. Payment Made cashier ko nahi (supplier screen band). Pure `pickerCandidates` test: test/party_quick_add_test.dart. |
| ✅ | DueRemindersActivity.kt | 494 | lib/screens/due_reminders_screen.dart + lib/db/due_reminders_repository.dart | Sales/Purchases tabs, Overdue + Total outstanding cards, badge (OVERDUE/DUE TODAY/DUE SOON/UPCOMING/No date), card tap = date picker (dirty + updatedAt + sync_queue), WhatsApp (wa.me, 0->92) + Call. DB v10: sales.dueDate + purchases.dueDate; sale edit dueDate carry karti hai. Admin/Manager only (Kotlin mein Reports ke andar). Test: test/due_reminders_test.dart. |
| ➖ | PartyViewModel.kt | 271 | — |  |
| ➖ | PartyViewModelFactory.kt | 58 | — |  |

## Phase 7: History — 100%

| | Kotlin | LOC | Flutter | Note |
|---|---|---|---|---|
| ✅ | HistoryActivity.kt | 1063 | lib/screens/history_screen.dart | lib/screens/history_screen.dart — router: HistoryMode.sales/purchases => SaleHistoryScreen/PurchaseHistoryScreen; mode null => SALES/PURCHASES pills (Purchases sirf admin). Business logic dedicated screens mein (admin-only Return/Delete/profit). |
| ✅ | SaleHistoryActivity.kt | 621 | lib/screens/sale_history_screen.dart | lib/db/sale_history_repository.dart (pure groupSalesByCustomer/summarizeSales/filterGroups). Sab roles dekh sakte hain; profit + Edit/Return/Delete sirf admin. Print = text Bill Preview. Test: test/sale_history_test.dart. Dashboard tile. |
| ✅ | PurchaseHistoryActivity.kt | 860 | lib/screens/purchase_history_screen.dart | lib/screens/purchase_history_screen.dart + lib/db/purchase_history_repository.dart (pure summarizePurchases/filterPurchaseRows/parseReturnRequest/returnedLineAmount). Admin-only. Partial return + delete ek transaction mein. Card tap = PurchaseScreen(editBillNo:) (returned bill par detail dialog). Print = text preview, Share = clipboard. Test: test/purchase_history_test.dart. |

## Phase 8: Cash, expense, accounts — 100%

| | Kotlin | LOC | Flutter | Note |
|---|---|---|---|---|
| ✅ | CashActivity.kt | 483 | lib/screens/cash_screen.dart + lib/db/cash_repository.dart | Sab roles. Cash Out + category => Expense + linked cash row (ek transaction). DB v6: expenses.method. Test: test/cash_test.dart. |
| ✅ | CashRegisterActivity.kt | 580 | lib/screens/cash_register_screen.dart + lib/db/cash_register_repository.dart | Sab roles. Open (check+insert ek transaction, create_if_absent) / edit opening / close (fresh expected confirm) / reopen + history. Test: test/cash_register_test.dart. Dashboard par "Cash Register" tile. |
| ✅ | ExpenseActivity.kt | 504 | lib/screens/expense_screen.dart + lib/db/expense_repository.dart | Sab roles. Save/Delete = Expense + linked cash OUT row ek transaction. CashRepository.save ab isi ExpenseRepository.insertExpenseWithCash ko use karta hai. Test: test/expense_test.dart. Dashboard par "Expenses" tile. |
| ✅ | DayBookActivity.kt | 476 | lib/screens/day_book_screen.dart + lib/db/day_book_repository.dart | Sab roles. Sale row tap = admin only (SaleScreen editInvoice). Purchase row tap = PurchaseScreen(editBillNo:) (admin only). Double-count fixes test/day_book_test.dart mein. |
| ✅ | PaymentsReportActivity.kt | 428 | lib/screens/payments_screen.dart (History tab) | History tab admin/manager only; edit/delete admin only. Record tab (Receive/Make Payment) for all roles. |
| ✅ | BalanceSheetActivity.kt | 289 | lib/screens/balance_sheet_screen.dart + lib/db/balance_sheet_repository.dart | Admin/Manager only (RoleGuard + role check in repository). Fix Balances dry-run warning: ledger logic ab PartyRepository (party_repository.dart) se aata hai. Tile abhi Dashboard par; Phase 9 mein Reports ke andar le jayen. Test: test/balance_sheet_test.dart. |
| ✅ | ZakatActivity.kt | 983 | lib/screens/zakat_screen.dart | lib/screens/zakat_screen.dart. admin/manager only (RoleGuard). Test: test/zakat_test.dart. Dashboard tile. |
| ✅ | ShellLedgerActivity.kt | 607 | lib/screens/shell_ledger_screen.dart | lib/screens/shell_ledger_screen.dart. Test: test/shell_test.dart. Dashboard tile. |

## Phase 9: Reports & stock — 89%

| | Kotlin | LOC | Flutter | Note |
|---|---|---|---|---|
| 🟡 | ReportsActivity.kt | 808 | lib/screens/reports_screen.dart | lib/screens/reports_screen.dart + lib/db/reports_repository.dart. Admin/Manager only. Done: hub rows (Monthly, Stock Report, History, Party Reports, Payments, Due Reminders, Balance Sheet, Zakat), period filter, 7 summary cards, P&L, Top Products, Daily Sales. Baaki: Stock*/Insights rows abhi "Coming soon" — un screens ke saath jorna. Test: test/reports_test.dart. Dashboard tile. |
| ✅ | MonthlySalesPurchaseActivity.kt | 561 | lib/screens/monthly_sales_purchase_screen.dart | lib/screens/monthly_screen.dart + lib/db/monthly_repository.dart (pure selectEntries/groupPeriods). Admin/Manager only. Party id se match, item lines mein returned bills bahar. Test: test/monthly_test.dart. Reports hub row. |
| ✅ | StockReportActivity.kt | 327 | lib/screens/stock_report_screen.dart | lib/screens/stock_report_screen.dart + lib/db/stock_report_repository.dart (pure costPerSmallestUnit/summarizeStock/filterStock). Sab roles (dashboard Low Stock tile, StockReportScreen(lowStockOnly: true)); cashier ko cost data nahi. Test: test/stock_report_test.dart. Reports hub row. |
| ✅ | StockAuditActivity.kt | 345 | lib/screens/stock_audit_screen.dart | lib/screens/stock_audit_screen.dart + lib/db/stock_audit_repository.dart (pure buildAuditRows/filterAuditRows, reconcile = AUDIT_RECONCILE ledger rows ek transaction mein, live stock nahi chhoota). Admin/Manager only. Card tap = us product ki Stock History (StockMovementScreen(initialBarcode)). Test: test/stock_audit_test.dart. Reports hub row. |
| ✅ | StockTakingActivity.kt | 335 | lib/screens/stock_taking_screen.dart + lib/db/stock_taking_repository.dart | Admin/Manager only (RoleGuard + repository check). Poori list + search, gintee smallest unit mein, khali = nahi gina, Review dialog (15 lines + value impact), Confirm = STOCK_TAKE ledger + stock + sync_queue ek transaction mein + audit. Farq: negative/fraction gintee rad. Test: test/stock_taking_test.dart. |
| ✅ | StockAdjustmentActivity.kt | 328 | lib/screens/stock_adjustment_screen.dart | lib/screens/stock_adjustment_screen.dart + lib/db/stock_adjustment_repository.dart (pure adjustmentDelta/validateAdjustment/searchProductsForAdjustment). Damage/Loss (DAMAGE) + Correction +/- (ADJUSTMENT); stock + ledger + sync_queue ek transaction mein, SQL guard se negative stock nahi. Admin/Manager only. Test: test/stock_adjustment_test.dart. Reports hub row. |
| ✅ | StockMovementActivity.kt | 361 | lib/screens/stock_movement_screen.dart | lib/screens/stock_movement_screen.dart + lib/db/stock_ledger.dart + lib/models/stock_movement.dart. Stock History + Cost History (StockMovementMode). DB v11: stock_movements table + purane stock ka OPENING_STOCK backfill. StockLedger.log() har stock write ke transaction mein (sale/edit/delete/return/quick sale, purchase/edit/delete/return, party_transaction item edit/delete, naya product opening stock). Admin/Manager only. Test: test/stock_movement_test.dart. Reports hub rows. |
| ✅ | InventoryInsightsActivity.kt | 529 | lib/screens/inventory_insights_screen.dart + lib/db/inventory_insights_repository.dart | Admin/Manager only (RoleGuard + repository check). 4 tabs: Reorder / Damage / Margin / Movers (Reports hub ki 4 rows initialMode se). Pure: reorderCandidates, suggestedReorderQty, damageLossValue (cost/smallestUnitFactor FIX), marginPercent, fast/slowMovers, mergeItemHistory. Margin row tap = sale+purchase history dialog. Test: test/inventory_insights_test.dart. |
| ✅ | StockTouchPolicy.kt | 163 | lib/utils/stock_touch_policy.dart | Pehle se maujood (Sale edit ke saath port hui, test/sale_edit_and_draft_test.dart); port_map status purana tha. |

## Phase 10: Cloud sync (Firestore) — 0%

| | Kotlin | LOC | Flutter | Note |
|---|---|---|---|---|
| ⬜ | SyncApi.kt | 1472 | lib/sync/sync_api.dart | Firestore schema Android jaisa hi rakhna (dono apps ek backend). |
| ⬜ | SyncQueueHelper.kt | 1289 | lib/sync/sync_queue_helper.dart | Firestore schema Android jaisa hi rakhna (dono apps ek backend). |
| ⬜ | SyncRepository.kt | 144 | lib/sync/sync_repository.dart | Firestore schema Android jaisa hi rakhna (dono apps ek backend). |
| ⬜ | SyncWorker.kt | 207 | lib/sync/sync_worker.dart | Firestore schema Android jaisa hi rakhna (dono apps ek backend). |
| ⬜ | SettingsSync.kt | 709 | lib/sync/settings_sync.dart | Firestore schema Android jaisa hi rakhna (dono apps ek backend). |
| ⬜ | CloudConfigStore.kt | 126 | lib/sync/cloud_config_store.dart | Firestore schema Android jaisa hi rakhna (dono apps ek backend). |
| ⬜ | BranchConfigStore.kt | 74 | lib/sync/branch_config_store.dart | Firestore schema Android jaisa hi rakhna (dono apps ek backend). |
| ⬜ | DeviceTag.kt | 45 | lib/sync/device_tag.dart | Firestore schema Android jaisa hi rakhna (dono apps ek backend). |
| ⬜ | NetworkMonitor.kt | 52 | lib/sync/network_monitor.dart | Firestore schema Android jaisa hi rakhna (dono apps ek backend). |

## Phase 11: Backup — 82%

| | Kotlin | LOC | Flutter | Note |
|---|---|---|---|---|
| 🟡 | BackupHelper.kt | 406 | lib/backup/backup_helper.dart | backupNow/backupIfDue(30 min)/listBackups/restore/restoreFromPath + safe restore (temp -> header -> schema check -> replace) + purana CBC/plain .db restore + share. Farq: public Downloads ki MediaStore copy nahi (Share se); restore se pehle safety backup; restore par schema check. Baaki: Android Room DB ko Flutter mein restore karna schema-compatible nahi (fresh DB v12) — tables check se reject hota hai. |
| ✅ | BackupExportActivity.kt | 778 | lib/screens/backup_export_screen.dart | lib/screens/backup_export_screen.dart + lib/backup/backup_export.dart: Full / Date-range CSV + PDF (Open/Print/Share), plus encrypted Backup Now / Password / Restore (admin only). Farq: date range ek picker se, CSV mein UTF-8 BOM, PDF mein Urdu ke liye assets/fonts/NotoNastaliqUrdu-Regular.ttf declare karna hoga. Test: test/backup_test.dart. |
| ✅ | BackupCrypto.kt | 123 | lib/backup/backup_crypto.dart | IBB1 AES-256-GCM (magic + salt16 + iv12 + ct+tag16, PBKDF2-SHA256 120k) + purana IBAKV001 CBC decrypt. Java JCE se bane fixtures ke saath test/backup_test.dart. Farq: poori file memory mein, PBKDF2 alag isolate mein. |
| ✅ | BackupPasswordStore.kt | 90 | lib/backup/backup_password_store.dart | flutter_secure_storage (Keystore/Keychain); getOrCreate (16 alnum) + setPassword (min 8). |
| 🟡 | BackupScheduler.kt | 147 | lib/backup/backup_scheduler.dart | 12 PM / 9 PM checkpoint (din mein ek baar) + app-close backupIfDue(30 min) app zinda hone par (Timer 15 min + resume/paused). Baaki: band app ke liye WorkManager (workmanager plugin). |

## Phase 12: Print & scan — 72%

| | Kotlin | LOC | Flutter | Note |
|---|---|---|---|---|
| 🟡 | PrinterHelper.kt | 1661 | lib/services/printer_service.dart + lib/services/receipt_renderer.dart + lib/utils/escpos.dart + lib/utils/receipt_lines.dart | Bluetooth 58/80mm ESC/POS raster (GS v 0 strips, Kotlin FIX 5 pacing), paged slips, test print, print width. Urdu TextPainter (RTL/shaping). Farq: USB printing nahi (plugin chahiye); text-only printText nahi. Test: test/print_scan_test.dart. |
| ✅ | BillPreviewActivity.kt | 840 | lib/screens/bill_preview_screen.dart + lib/utils/bill_doc.dart | Receipt preview, PRINT, WhatsApp (wa.me text, number popup), Copy, DONE, + NAYA BILL, Prev/Net Balance. Sale/Purchase (save ke baad) aur dono History Print isi par. Farq: WhatsApp par bill TEXT jata hai (Kotlin image bhejta hai). |
| ✅ | BillScanActivity.kt | 493 | lib/screens/bill_scan_screen.dart + lib/utils/bill_scan_parser.dart | Camera/Gallery -> ML Kit OCR -> review/edit rows -> Purchase screen "Scan Bill" (naam se product match, warna naya product). Test: test/print_scan_test.dart. |

## Phase 13: Maintenance tools — 100%

| | Kotlin | LOC | Flutter | Note |
|---|---|---|---|---|
| ✅ | BulkTranslateActivity.kt | 620 | lib/screens/bulk_translate_screen.dart + lib/db/bulk_translate_repository.dart | Admin-only (Items 'Translate' pill, RoleGuard). Categories/Units batch rename (master + products + sync_queue, ek transaction) + Items search-tag stepper (Save & Next, comma se kayi English naam). Yahin par 'Fix Duplicate Unit Names' aur 'Merge Duplicate Products' cards. Test: test/maintenance_test.dart. |
| ✅ | MergeDuplicateProductsFix.kt | 187 | lib/utils/merge_duplicate_products.dart | planProductMerge (pure) + preview() + run() ek transaction (plan transaction ke andar dobara). Farq: pehle preview dialog + backup, khali naam merge nahi, stock_movements dirty=1, audit row. Test: test/maintenance_test.dart. |
| ✅ | DuplicateUnitFix.kt | 124 | lib/utils/duplicate_unit_fix.dart | dedupedUnitName (pure) + run() ek transaction + sync_queue. Farq: units master list ki 'Box\nBox' rows bhi saaf. Test: test/maintenance_test.dart. |

## Phase 99: Android-only (skip)

| | Kotlin | LOC | Flutter | Note |
|---|---|---|---|---|
| ➖ | CrashHandler.kt | 74 | — | Android-specific ya test/stub; Flutter mein zaroorat nahi. |
| ➖ | EarlyCrashInitProvider.kt | 44 | — | Android-specific ya test/stub; Flutter mein zaroorat nahi. |
| ➖ | PosApplication.kt | 72 | — | Android-specific ya test/stub; Flutter mein zaroorat nahi. |
| ➖ | KeyboardInsets.kt | 39 | — | Android-specific ya test/stub; Flutter mein zaroorat nahi. |
| ➖ | ThemedActivity.kt | 49 | — | Android-specific ya test/stub; Flutter mein zaroorat nahi. |
| ➖ | FakeSaleRepository.kt | 169 | — | Android-specific ya test/stub; Flutter mein zaroorat nahi. |
| ➖ | ReportsScreens.kt | 1 | — | Android-specific ya test/stub; Flutter mein zaroorat nahi. |
| ➖ | PurchaseScreens.kt | 1 | — | Android-specific ya test/stub; Flutter mein zaroorat nahi. |
| ➖ | PurchaseViewModelFactory.kt | 57 | — | Android-specific ya test/stub; Flutter mein zaroorat nahi. |
| ➖ | SaleViewModelFactory.kt | 49 | — | Android-specific ya test/stub; Flutter mein zaroorat nahi. |
