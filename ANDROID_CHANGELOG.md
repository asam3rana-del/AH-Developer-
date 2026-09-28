# ANDROID_CHANGELOG — Android/Web mein jo badla, Flutter mein port hona baaki

Har Android tabdeeli yahan sabse upar likhein (naya pehle). Flutter mein port ho jaye to
`[ ]` ko `[x]` karein aur `python3 tools/port_status.py --accept <File>.kt` chalayein.

## 2026-09-28 — Item Rate Search: sale rates pehle, cost chhupa
- [ ] `ItemSearchActivity.kt`: search list mein har item ke neeche Ctn/Dzn/Pcs sale rates;
  item kholne par bara Sale Rate card + wholesale; purchase/supplier/profit-margin sirf
  admin/manager ko "Show cost" button ke peeche. Spec: `docs/specs/item_rate_search.md`
- [ ] Web `rateComparison.js`: same badlav; screen ka naam "Rate Search".
- Flutter dependency: role/session (Phase 4) pehle chahiye, warna cost gate nahi lag sakta.
- Note: purani web Rate Comparison screen cashier ko bhi supplier rates dikhati thi — Flutter mein yeh galti na dohrayein.
