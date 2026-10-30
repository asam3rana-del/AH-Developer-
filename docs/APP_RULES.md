# App Rules — AH Developer (Flutter)

Ye app sirf Flutter mein chalti hai; Android Kotlin app se mukabla ya porting ab nahi hoti.
(Code comments mein jahan `PORTING_PLAN` likha hai, uska matlab yahi rules hain.)

## Rules jo har screen par lagte hain
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
- **Access rules (per user)**: admin "Manage Users" -> Access se kisi bhi user ke liye koi report / tool ON ya OFF kar sakta hai
  (`lib/services/permissions.dart`). Role ke default wahi rehte hain jo pehle thay; sirf badle hue items `users.permissions` (JSON)
  mein save hote hain aur sync se har device par jate hain. Admin hamesha full access, kabhi lock nahi hota.
- **Zabaan:** har text `Loc.t(en, ur)` se (English/Urdu). Urdu font: NotoNastaliqUrdu (assets/ se).
- **Search:** product search hamesha `matchesQuery` (name + searchTag, har lafz).
- **Sync:** Firestore schema wahi rehta hai jo pehle se chal raha hai (`firebase/` mein rules aur indexes). Deletes tombstone se, stock/balance atomic increment.
- **Naming:** screen → `screens/xyz_screen.dart`, data → `db/xyz_repository.dart`.
- **Tests:** Dart tests `test/` mein (unit conversion, discount, sale/purchase); naya logic aaye to test saath likhein.

## Sync: der se push hone wali entries (pushedAt)
- Har push par document par `pushedAt` (cloud par pahunchne ka waqt) lagta hai; `updatedAt` banne ke waqt ka rehta hai (last-write-wins ke liye).
- Pull dono se hota hai: `updatedAt > checkpoint` aur `pushedAt > checkpoint`. Is se offline ke baad der se aane wali transactions dusre devices par kabhi miss nahi hotin.
- `pushedAt` wali query ke liye `firebase/firestore.indexes.json` ke naye indexes deploy karna zaroori hai: `firebase deploy --only firestore:indexes`. Deploy se pehle pull purane tareeqe par chalta hai (kuch toota nahi).
- Jo documents is fix se pehle push hue unmein `pushedAt` nahi hota; unke liye Settings > Sync > "Resync from a date/time (pull)".
