# Asli phone par test sheet (release se pehle)

Maqsad: GO_LIVE_CHECKLIST ke ⬜ items asli device par parkhna. Har test ke aage jo hona chahiye woh likha hai; fark aaye to
screenshot + kya kiya likh kar bhej dein. **Shuru karne se pehle:** Backup lo (Dashboard > Backup) aur file kisi dusri jagah rakho.
Test asli dukaan ke data par na karein: alag test installation ya test customer/item banayein ("TEST Ali", "TEST Rice").

**Natija (2026-11-01):** ✅ = OK (test ho gaya) · ⬜ = abhi baaki. Jahan sirf hissa test hua wahan likha hai kya baaki hai.

## A. Hisaab (ek hi phone)
1. ✅ **Sale + return** — OK: cash bill par partial aur poori return (stock, Returns Report, Day Book milte hain).
   ⬜ Baaki: TEST Ali ko Rs 500 ka **udhaar** bill, Rs 100 return, customer balance **400**.
2. ⬜ **Purchase + payment** — TEST Supplier se Rs 1000 ki purchase, Rs 400 payment. Hona chahiye: supplier payable **600**, item stock purchase qty se barha.
3. ⬜ **Expense** — Rs 200 expense (cash). Hona chahiye: cash in hand **200 kam**, Day book mein entry.
4. ✅ **Unit** — OK: box ki sale + return chali, Rate Search mein bade aur chhote (box) dono unit ki cost aur margin dikhte hain.
5. 🟡 **Credit limit** — ✅ "Credit Limit Exceeded" dialog aata hai (Hafiz Pan Shop par dekha).
   ⬜ Baaki: admin se Settings > "Credit limit override" ON, phir cashier se: dialog mein sirf OK (Save Anyway nahi); admin/manager se Save Anyway chalta hai.
6. ⬜ **Reports milan** — aaj ka Profit & Loss aur Balance Sheet apne haath ke hisaab se milao.
7. ✅ **Discount wali bill ka partial return** — OK: Rs 200 bill, discount 50 (total 150), 1 box return => Rs 75 wapas; stock, bill, Returns Report aur Total Sales/Returned sab milte hain.
8. ✅ **Day Book** — OK (partial/poori return ke baad Cash In/Out/Net sahi, doosri chat mein pass).
9. ⬜ **Purchase partial return** — stock, cost, supplier balance sirf wapas hui miqdaar se badle; Day Book Cash In ka asar.

## B. Do devices (sync)
10. ✅ Dono par ek hi customer/item; ek saath sale — OK (sync ke baad stock/balance ek jaise).
11. ✅ Aeroplane mode mein sale, phir net on — OK (dusre phone par wahi bill, koi double nahi).
12. ✅ Sync status — OK (aap ke mutabiq sync sab theek chal raha hai).

## C. Safety
13. 🟡 **Roles** — ✅ cashier: Sale History mein Return/Edit/Delete aur profit nahi, Reports/cost nahi khulte, "Credit limit override" ka switch band.
    ⬜ Baaki: Cash & Bank cashier ko nahi dikhna chahiye (naya build); admin Manage Users > Access se ek item de, cashier ko khule (dusre device par bhi).
14. ⬜ **Backup/restore** — Backup lo, dusri test installation par restore. Hona chahiye: customers, stock, cash totals wahi.
15. ✅ **Update** — OK: purani app ke upar nayi APK install hui, purana data salamat.

## D. Release
16. ✅ Android APK install aur chal rahi hai. ⬜ iOS/Windows jab zaroorat ho.

Natija likhne ka tareeqa: `5 ✅`, `9 ❌ stock galat`, ... bhej dein.
