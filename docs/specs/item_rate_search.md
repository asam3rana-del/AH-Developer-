# Spec: Item Rate Search  (Android: ItemSearchActivity.kt · Web: rateComparison.js)

Flutter target: `lib/screens/item_search_screen.dart`  (Phase 5)
Android ref: `kotlin_reference/main/ItemSearchActivity.kt` (latest, 2026-09-28)

## Maqsad
Customer ko rate jaldi batana. Rate dekhne ke liye item kholna na pade.

## Rates kaise nikalte hain
- `Product.salePrice` aur `Product.wholesalePrice` **primary unit** (jaise Carton) ke rate hain.
- Har tier ka rate = `fromPrimaryUnitRate(rate, tier.unit)` (Flutter: product.dart mein already hai).
- Tiers ki tarteeb: bara unit pehle → `product.unitLadder().reversed`.
  1 ya 2 tier wale item par sirf utni hi tiers dikhein (jaise sirf Pcs).
- Rate agar poora number ho to bina decimal ("Rs 2880"), warna 2 decimal.

## Screen
1. Search box. Match: `name` + `searchTag`, har typed lafz dono mein kahin hona chahiye (`matchesQuery`).
2. Har result card: naam + "Stock: <formatStockBreakdown>" ek line mein, neeche ek line
   `Ctn Rs 2880 • Dzn Rs 720 • Pcs Rs 60` (teal, bold). Sale price 0 ho to "Sale rate set nahi".
3. Item kholne par (sabse upar → neeche):
   1. **Sale Rate card** — Carton/Dozen/Pcs alag alag bade font (~22sp) mein; neeche
      chhota "Wholesale: ..." (orange) sirf agar `wholesalePrice > 0`.
   2. **Quick Summary** — Current Stock, "Last Sold At" (aakhri sale rate). Cost wali lines neeche.
   3. **Sale Rate History** — newest first, pehli 3 rows, baaki "Show N more".
   4. **[Show cost ▾] button** — sirf admin/manager. Tap par khulta hai:
      Compare Suppliers (best rate badge, trend arrow, stale warning ≥30 din) +
      Purchase Rate History. Default band.

## Roles (zaroori)
| Cheez | admin | manager | cashier |
|---|---|---|---|
| Sale rates (3 tier) + wholesale | ✅ | ✅ | ✅ |
| Sale history | ✅ | ✅ | ✅ |
| Show cost button, Best Purchase Rate, Profit Margin, Compare Suppliers, Purchase History | ✅ | ✅ | ❌ (dikhna hi nahi, DB query bhi nahi) |

Cashier ke liye purchase data load hi na karein (sirf UI hide karna kaafi nahi).

## Web
`rateComparison.js` (screen ka naam ab "Rate Search") mein bhi yahi behaviour.
