# ANDROID_CHANGELOG — Android/Web mein jo badla, Flutter mein port hona baaki

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
