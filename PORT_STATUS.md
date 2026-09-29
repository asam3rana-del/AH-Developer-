# PORT_STATUS (auto-generated — edit mat karein)

`python3 tools/port_status.py` chala kar dobara banayein.

**Overall (lines of Kotlin ke hisaab se): 44%**  (21628/49102)

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

## Phase 2: Purchase — 64%

| | Kotlin | LOC | Flutter | Note |
|---|---|---|---|---|
| 🟡 | PurchaseActivity.kt | 2325 | lib/screens/purchase_screen.dart | Sirf naya purchase; edit-saved-purchase baaki. Admin-only. |
| ✅ | PurchaseRepository.kt | 141 | lib/db/purchase_repository.dart |  |
| ✅ | RoomPurchaseRepository.kt | 597 | lib/db/purchase_repository.dart |  |
| ✅ | PurchaseUseCases.kt | 169 | lib/db/purchase_repository.dart |  |
| ➖ | PurchaseViewModel.kt | 180 | — | Flutter mein State/setState — alag ViewModel zaroori nahi. |

## Phase 3: Sale — 68%

| | Kotlin | LOC | Flutter | Note |
|---|---|---|---|---|
| 🟡 | SaleActivity.kt | 1869 | lib/screens/sale_screen.dart | Done: naya sale, quick sale, hold/recall, default unit, reprice, margin warning, credit-limit confirm, saved sale edit/return/delete (admin only), draft autosave, customer ka apna rate, Rs(amount) mode, inline line edit, Print, Split Payment dialog, Cash/Bank picker (naye sale par), duplicate-bill warning, inline 'add customer' popup. Baaki: Bluetooth/WhatsApp share (Phase 12). |
| ✅ | SaleRepository.kt | 136 | lib/db/sale_repository.dart | Edit/delete/return + audit + frozen conversionFactor (DB v4) bhi done; linked-payment void Phase 6/8 mein. |
| ✅ | RoomSaleRepository.kt | 563 | lib/db/sale_repository.dart |  |
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
| 🟡 | MainActivity.kt | 1085 | lib/screens/dashboard_screen.dart | Role-based dashboard maujood; live search / baaki tiles check baaki. |
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

## Phase 6: Parties (customer/supplier) — 27%

| | Kotlin | LOC | Flutter | Note |
|---|---|---|---|---|
| 🟡 | PartyActivity.kt | 1359 | lib/screens/party_screen.dart | Done: tabs, add form, search, Dues only, edit/delete (live balance), history dialog, Call, Fix Balances, Merge, Cleanup Payments/Orphaned, stuck balance (admin/manager). Baaki: contact picker (flutter_contacts + permissions), row tap se Party Dashboard/Transaction. |
| 🟡 | PartyDashboardActivity.kt | 1522 | lib/screens/party_dashboard_screen.dart + lib/db/party_dashboard_repository.dart | Sab roles. Done: You'll Get/Give cards (tap = filter), Parties/Transactions/Items tabs, search, filter dialog, live-ledger balances, Daily/Stuck line, item detail + Edit Rates (admin only, sync_queue ke saath), main menu, '+' quick add, Add Sale/Purchase bar. Cashier ko cost/purchase data nahi. Baaki: party row tap -> PartyTransaction, Overdue/Due Today badge (sales mein dueDate nahi), Purchase row edit (Phase 7), Payment Received/Made party picker (PartyQuickAddMenu). Test: test/party_dashboard_test.dart. |
| ⬜ | PartyTransactionActivity.kt | 2219 | lib/screens/party_transaction_screen.dart | Edit/delete items admin-only. |
| ⬜ | PartyReportsActivity.kt | 1034 | lib/screens/party_reports_screen.dart |  |
| ✅ | PartyRepository.kt | 444 | lib/db/party_repository.dart | lib/db/party_repository.dart: CRUD + live balances + recalc(dryRun) + merge + cleanup, sab ek transaction mein. PartyLedger/trueBalance/countBalanceDrift yahin (Balance Sheet bhi yahi istemal karta hai). Test: test/party_test.dart. |
| ✅ | PartyUseCases.kt | 196 | lib/db/party_repository.dart | Validation (naam zaroori) PartyRepository.addCustomer/editCustomer/... mein. |
| ⬜ | PartyQuickAddMenu.kt | 291 | lib/widgets/party_quick_add_menu.dart |  |
| ⬜ | DueRemindersActivity.kt | 494 | lib/screens/due_reminders_screen.dart |  |
| ➖ | PartyViewModel.kt | 271 | — |  |
| ➖ | PartyViewModelFactory.kt | 58 | — |  |

## Phase 7: History — 0%

| | Kotlin | LOC | Flutter | Note |
|---|---|---|---|---|
| ⬜ | HistoryActivity.kt | 1063 | lib/screens/history_screen.dart | Return/Delete/profit admin-only. |
| ⬜ | SaleHistoryActivity.kt | 621 | lib/screens/sale_history_screen.dart | Profit sirf admin. |
| ⬜ | PurchaseHistoryActivity.kt | 860 | lib/screens/purchase_history_screen.dart | Admin-only. |

## Phase 8: Cash, expense, accounts — 63%

| | Kotlin | LOC | Flutter | Note |
|---|---|---|---|---|
| ✅ | CashActivity.kt | 483 | lib/screens/cash_screen.dart + lib/db/cash_repository.dart | Sab roles. Cash Out + category => Expense + linked cash row (ek transaction). DB v6: expenses.method. Test: test/cash_test.dart. |
| ✅ | CashRegisterActivity.kt | 580 | lib/screens/cash_register_screen.dart + lib/db/cash_register_repository.dart | Sab roles. Open (check+insert ek transaction, create_if_absent) / edit opening / close (fresh expected confirm) / reopen + history. Test: test/cash_register_test.dart. Dashboard par "Cash Register" tile. |
| ✅ | ExpenseActivity.kt | 504 | lib/screens/expense_screen.dart + lib/db/expense_repository.dart | Sab roles. Save/Delete = Expense + linked cash OUT row ek transaction. CashRepository.save ab isi ExpenseRepository.insertExpenseWithCash ko use karta hai. Test: test/expense_test.dart. Dashboard par "Expenses" tile. |
| ✅ | DayBookActivity.kt | 476 | lib/screens/day_book_screen.dart + lib/db/day_book_repository.dart | Sab roles. Sale row tap = admin only (SaleScreen editInvoice). Purchase row tap Phase 7 (edit saved purchase) ke saath. Double-count fixes test/day_book_test.dart mein. |
| ✅ | PaymentsReportActivity.kt | 428 | lib/screens/payments_screen.dart (History tab) | History tab admin/manager only; edit/delete admin only. Record tab (Receive/Make Payment) for all roles. |
| ✅ | BalanceSheetActivity.kt | 289 | lib/screens/balance_sheet_screen.dart + lib/db/balance_sheet_repository.dart | Admin/Manager only (RoleGuard + role check in repository). Fix Balances dry-run warning: ledger logic ab PartyRepository (party_repository.dart) se aata hai. Tile abhi Dashboard par; Phase 9 mein Reports ke andar le jayen. Test: test/balance_sheet_test.dart. |
| ⬜ | ZakatActivity.kt | 983 | lib/screens/zakat_screen.dart | admin/manager only. |
| ⬜ | ShellLedgerActivity.kt | 607 | lib/screens/shell_ledger_screen.dart |  |

## Phase 9: Reports & stock — 0%

| | Kotlin | LOC | Flutter | Note |
|---|---|---|---|---|
| ⬜ | ReportsActivity.kt | 808 | lib/screens/reports_screen.dart | admin/manager only. |
| ⬜ | MonthlySalesPurchaseActivity.kt | 561 | lib/screens/monthly_sales_purchase_screen.dart |  |
| ⬜ | StockReportActivity.kt | 327 | lib/screens/stock_report_screen.dart |  |
| ⬜ | StockAuditActivity.kt | 345 | lib/screens/stock_audit_screen.dart |  |
| ⬜ | StockTakingActivity.kt | 335 | lib/screens/stock_taking_screen.dart |  |
| ⬜ | StockAdjustmentActivity.kt | 328 | lib/screens/stock_adjustment_screen.dart |  |
| ⬜ | StockMovementActivity.kt | 361 | lib/screens/stock_movement_screen.dart |  |
| ⬜ | InventoryInsightsActivity.kt | 529 | lib/screens/inventory_insights_screen.dart |  |
| ⬜ | StockTouchPolicy.kt | 163 | lib/utils/stock_touch_policy.dart |  |

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

## Phase 11: Backup — 0%

| | Kotlin | LOC | Flutter | Note |
|---|---|---|---|---|
| ⬜ | BackupHelper.kt | 406 | lib/backup/backup_helper.dart | Backup format Android se compatible rakhna. |
| ⬜ | BackupExportActivity.kt | 778 | lib/screens/backup_export_screen.dart | Backup format Android se compatible rakhna. |
| ⬜ | BackupCrypto.kt | 123 | lib/backup/backup_crypto.dart | Backup format Android se compatible rakhna. |
| ⬜ | BackupPasswordStore.kt | 90 | lib/backup/backup_password_store.dart | Backup format Android se compatible rakhna. |
| ⬜ | BackupScheduler.kt | 147 | lib/backup/backup_scheduler.dart | Backup format Android se compatible rakhna. |

## Phase 12: Print & scan — 0%

| | Kotlin | LOC | Flutter | Note |
|---|---|---|---|---|
| ⬜ | PrinterHelper.kt | 1661 | lib/services/printer_helper.dart | Bluetooth ESC/POS. |
| ⬜ | BillPreviewActivity.kt | 840 | lib/screens/bill_preview_screen.dart |  |
| ⬜ | BillScanActivity.kt | 493 | lib/screens/bill_scan_screen.dart | OCR (ML Kit). |

## Phase 13: Maintenance tools — 0%

| | Kotlin | LOC | Flutter | Note |
|---|---|---|---|---|
| ⬜ | BulkTranslateActivity.kt | 620 | lib/screens/bulk_translate_screen.dart |  |
| ⬜ | MergeDuplicateProductsFix.kt | 187 | lib/utils/merge_duplicate_products.dart |  |
| ⬜ | DuplicateUnitFix.kt | 124 | lib/utils/duplicate_unit_fix.dart |  |

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
