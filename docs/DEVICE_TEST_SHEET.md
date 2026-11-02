# Asli phone par test sheet (release se pehle)

Maqsad: GO_LIVE_CHECKLIST ke ⬜ items asli device par parkhna. Har test ke aage jo hona chahiye woh likha hai; fark aaye to
screenshot + kya kiya likh kar bhej dein. **Shuru karne se pehle:** Backup lo (Dashboard > Backup) aur file kisi dusri jagah rakho.
Test asli dukaan ke data par na karein: alag test installation ya test customer/item banayein ("TEST Ali", "TEST Rice").

**Natija (2026-11-02):** ✅ = OK (test ho gaya) · ⬜ = abhi baaki. Jahan sirf hissa test hua wahan likha hai kya baaki hai.

## A. Hisaab (ek hi phone)
1. ✅ **Sale + return** — OK: cash bill par partial aur poori return (stock, Returns Report, Day Book milte hain).
   ✅ Udhaar bill par partial return: 5 Kg ka bill, 2 Kg return => 3 Kg × Rs 260, Total 780, Returned 520, Due 780 (sahi).
   ✅ asim ka ledger: opening 0, is bill ka debit 780, closing balance Rs 780 (1300 nahi) — tablet par dekha. (Doosre phone ka ledger screenshot mein nahi dekha.)
   ✅ Poori bill partial returns ke baad: 5 Kg ki cheeni bill, 2 + 1 + 2 Kg return => status Returned, stock +5, Day Book mein teen Sale Return Cash Out (280, 140, 280), Cash In 700 ek hi dafa (Net 0).
2. ✅ **Purchase + payment** — OK: Rs 1000 purchase, Rs 400 payment (CASH), supplier payable **Rs 600** (Party Details), purchase total 1000.
3. ✅ **Expense** — OK: Rs 200 cash expense, Today Cash Out 400 se 600, Recent Transactions mein "Expense: Miscellaneous − Rs 200"; P&L mein Operating Expenses 200.
4. ✅ **Unit** — OK: box ki sale + return chali, Rate Search mein bade aur chhote (box) dono unit ki cost aur margin dikhte hain.
5. ✅ **Credit limit** — OK: "Credit Limit Exceeded" dialog aata hai. Override ON par cashier ko sirf OK aata hai; admin/manager ko "Save Anyway" ka button aata hai.
   Save Anyway ke baad bill save hua (Hafiz Pan Shop: purana balance 290646 + 7260 = 297906, dialog ke number se milta hai).
6. ✅ **Reports milan** — OK (2026-11-02): P&L aaj: Sales 780, COGS 701, Gross 79, Expenses 200, Net −121; Sale Returns 660 = 520 (dal chana) + 140 (cheeni) Returns Report se mili. Balance Sheet: Total Assets, Payable (1006208) aur Receivable (2110504) milte hain.
   ⚠️ Cash in Hand / Bank ab bhi bohat minus: test data mein opening cash/bank entry nahi. Asli dukaan par pehle ek dafa Cash In se opening daalein aur Fix Balances (backup ke baad) chalayen.
7. ✅ **Discount wali bill ka partial return** — OK: Rs 200 bill, discount 50 (total 150), 1 box return => Rs 75 wapas; stock, bill, Returns Report aur Total Sales/Returned sab milte hain.
8. ✅ **Day Book** — OK (partial/poori return ke baad Cash In/Out/Net sahi, doosri chat mein pass).
9. ✅ **Purchase partial return** — OK: (a) udhaar bill 10 Jar × 100, paid 400, 3 Jar return => Total 700, Paid 400, supplier payable 300, stock −180 pcs (3 Jar), Returns Report Rs 300; (b) poori paid bill 1000, 3 Jar return => Total 700, Paid 700, Day Book mein Purchase Return Cash In 300, Cash Out 1000 kam nahi hua.

## B. Do devices (sync)
10. ✅ Dono par ek hi customer/item; ek saath sale — OK (sync ke baad stock/balance ek jaise).
11. ✅ Aeroplane mode mein sale, phir net on — OK (dusre phone par wahi bill, koi double nahi).
12. ✅ Sync status — OK (aap ke mutabiq sync sab theek chal raha hai).

## C. Safety
13. ✅ **Roles** — OK: cashier: Sale History mein Return/Edit/Delete aur profit nahi, Reports/cost nahi khulte, Cash & Bank nahi dikhta,
    "Secure Cloud Login", "Credit limit override" aur "Server credit-limit check" ke switch band.
    ✅ Admin ne cashier ko **Daily Bills** ka Access diya: cashier ko Settings > Reports mein sirf Daily Bills dikha, aur sync ke baad **dusre device par bhi** aa gaya.
    Expense aur Shell Ledger cashier ko Settings mein dikhte hain (jaan-boojh kar khule; admin chahe to Access se band kar sakta hai).
14. ✅ **Backup/restore** — OK: Backup Now se bani encrypted backup file dusre phone par Restore from file se kholi, data har lihaaz se theek aaya (aap ke mutabiq).
15. ✅ **Update** — OK: purani app ke upar nayi APK install hui, purana data salamat.

## D. Release
16. ✅ Android APK install aur chal rahi hai. ⬜ iOS/Windows jab zaroorat ho.

Natija likhne ka tareeqa: `5 ✅`, `9 ❌ stock galat`, ... bhej dein.
