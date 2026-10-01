# PORTING_PLAN — IBTISAAM Kiryana Store (Kotlin) → AH Developer (Flutter)

> **AI assistant (Claude) ke liye — pehle yeh parhein.** Jab user is repo ka zip de:
> 1. Yeh file, `PORT_STATUS.md` aur `ANDROID_CHANGELOG.md` parhein.
> 2. `python3 tools/port_status.py` chalayein (NEW / CHANGED files dekhne ke liye).
> 3. `ANDROID_CHANGELOG.md` ke unchecked items, phir agla incomplete phase port karein.
> 4. Har file port karte waqt `kotlin_reference/main/<File>.kt` ko asal source maanein.
> 5. Kaam ke baad: `tools/port_map.json` ka status, `ANDROID_CHANGELOG.md` ka checkbox,
>    aur `--accept` update karein; is file ka "Kaam ki tarteeb" agar badle to yahan bhi.
> User ko bar bar features batane ki zaroorat nahi honi chahiye.

## 1. Rules jo har screen par lagte hain
- **Units:** `stock` hamesha *smallest unit* mein. `salePrice`, `wholesalePrice`, `cost` **primary unit** ke rate.
  Conversion sirf `product.dart` ke helpers se (`toSmallestUnits`, `toPrimaryUnitRate`, `fromPrimaryUnitRate`,
  `unitLadder`, `formatStockBreakdown`). Kabhi khud ka math na likhein.
- **Transactions:** stock/balance/cash badalne wali har cheez ek DB transaction mein (jaise `sale_repository.dart`).
- **Roles** (session se): `admin`, `manager`, `cashier`. UI hide karna kaafi nahi — screen ke andar bhi check
  aur data layer par bhi (cashier ke liye cost data load hi na ho). Ek `RoleGuard` helper (Phase 4) banayein.
  - admin only: Products, Purchase (+edit), Sale edit/delete/return, History edit/delete, profit, User Management, Setup.
  - admin + manager: Reports, Balance Sheet, Payments Report, Zakat, Audit log, **purchase/cost rates**.
  - sab roles: New Sale, Day Book, Stock, Parties, Cash, Expenses, sale rates.
  - Ghalat role par message: "Sirf Admin is screen ko access kar sakta hai" / "Sirf Admin/Manager ...".
- **Zabaan:** har text `Loc.t(en, ur)` se (English/Urdu). Urdu font: NotoNastaliqUrdu (`kotlin_reference` ke saath assets se lein).
- **Search:** product search hamesha `matchesQuery` (name + searchTag, har lafz).
- **Sync:** Firestore schema Android jaisa hi (dono apps ek backend). Deletes tombstone se, stock/balance atomic increment.
- **Naming:** `XyzActivity.kt` → `screens/xyz_screen.dart`, DAO/Repository → `db/xyz_repository.dart`.
  ViewModel/Factory ki zaroorat nahi (skip).
- **Tests:** `kotlin_reference/test` ke tests Dart `test/` mein convert karein (unit conversion, discount, sale/purchase).

## 2. Phases (tarteeb)  — live status `PORT_STATUS.md` mein
| Phase | Kya | Nota |
|---|---|---|
| 0-3 | Models/DB, Products, Purchase, Sale | ✅ Mukammal. Sale mukammal (linked payments samet). Purchase mukammal (edit-saved-purchase, Delete, supplier comparison samet). Bluetooth/WhatsApp share = Phase 12 (done) |
| 4 | Login, roles (`RoleGuard`), Loc, Theme, Settings, Dashboard | ✅ Mukammal (device par nazar-e-saani baaki). Pehle sabse zaroori tha — baaki sab screens role/zabaan par depend karti hain |
| 5 | Item Rate Search, Rate Comparison, Items, Bulk rates/units, SaleCart, Quick Sale, Hold/Recall | ✅ Mukammal — Spec: `docs/specs/item_rate_search.md` (device par nazar-e-saani baaki) |
| 6 | Parties (list, dashboard, transactions, reports), Due Reminders | ✅ Mukammal |
| 7 | Sale/Purchase History (edit/return/delete admin-only) | ✅ Mukammal (device par nazar-e-saani baaki) |
| 8 | Cash, Cash Register, Expense, Day Book, Payments, Balance Sheet, Zakat, Shell Ledger | ✅ Mukammal (device par nazar-e-saani baaki) |
| 9 | Reports, Monthly, Stock Report/Audit/Taking/Adjustment/Movement, Inventory Insights | ✅ Mukammal (device par nazar-e-saani baaki) |
| 10 | Cloud sync (SyncApi/Queue/Worker/Repository/Settings, Branch, DeviceTag) | ✅ Mukammal (Phone OTP samet). Device par Firebase setup + 2-device test baaki |
| 11 | Backup/Export/Crypto/Scheduler | ✅ Mukammal — Format Android se compatible (device par nazar-e-saani baaki) |
| 12 | Bluetooth print, Bill Preview, Bill Scan (OCR) | ✅ Mukammal — iPad par printer alag plugin (device par nazar-e-saani baaki) |
| 13 | Bulk Translate, Merge Duplicates, Duplicate Unit Fix | ✅ Mukammal (Merge par preview + backup) |

**CI status (2026-10-01): Build #114 — Analyze + Test, iOS (unsigned), Android APK, Windows (exe) sab green. `flutter test` sab pass (pehle 630/20 fail se theek kiye).**

Har phase ke baad: `flutter analyze`, `flutter test`, aur Android app ke saath ek sample bill/purchase ka number mila kar dekhein.

## 3. Android update ka tareeqa (aap ko bas 3 kaam)
1. Android mein badlav ho → badli hui `.kt` file `kotlin_reference/main/` mein replace karein
   (aur agar web mein bhi badla to `kotlin_reference/config/` — root par `config/` copy hata di gayi).
2. `ANDROID_CHANGELOG.md` mein ek chhota entry sabse upar: kya badla (2-3 lines).
3. `python3 tools/port_status.py` — 🔁 wali files batati hain kaunsi Flutter screen update chahiye.
Phir zip Claude ko dein: "PORTING_PLAN.md ke mutabiq aage barho".

## 4. Pehle se ki gayi Android tabdeeliyan (Flutter mein lani hain)
Dekhein `ANDROID_CHANGELOG.md`. Filhal: Item Rate Search (3 sale rates, wholesale, cost sirf admin/manager).
Yeh bhi yaad rahe (Android ke comments se): Purchase editing sirf admin (manager hata diya gaya);
Sale edit/delete sirf admin; History mein profit sirf admin; naye sale mein due ho to customer zaroori.

## 5. Suggestions
1. Phase 4 (login + roles) sabse pehle — warna Flutter ke saare screens sab ko khule honge.
2. iPad par sab se pehle Phase 5 + Sale kaafi hai counter par kaam chalane ke liye; sync baad mein.
3. ~~`lib/AH-Developer-Purchase-Screen-Update.zip` repo se hata dein~~ — hata di gayi (2026-10-01 audit mein asal mein hati).
4. `pubspec.yaml` mein aage chahiye: `local_auth` (app lock), `shared_preferences` (session/language),
   `crypto`+`cryptography` (password/backup), `flutter_blue_plus` ya `print_bluetooth_thermal` (printer),
   `google_mlkit_text_recognition` (bill scan), `workmanager` (background sync/backup).
5. Android + Web dono mein badlav ho to changelog mein "Web" alag likhein (web ka apna code alag hai).
6. Har phase par ek chhota Dart test likhein jo Kotlin test ke barabar ho — Android aur Flutter ke numbers mel khayenge.
