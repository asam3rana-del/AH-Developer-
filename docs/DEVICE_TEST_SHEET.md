# Asli phone par test sheet (release se pehle)

Maqsad: GO_LIVE_CHECKLIST ke ⬜ items asli device par parkhna. Har test ke aage jo hona chahiye woh likha hai; fark aaye to
screenshot + kya kiya likh kar bhej dein. **Shuru karne se pehle:** Backup lo (Dashboard > Backup) aur file kisi dusri jagah rakho.
Test asli dukaan ke data par na karein: alag test installation ya test customer/item banayein ("TEST Ali", "TEST Rice").

## A. Hisaab (ek hi phone)
1. **Sale + return** — TEST Ali (balance 0) ko TEST Rice ka Rs 500 ka udhaar bill. Phir Rs 100 ka return.
   Hona chahiye: customer balance **400**, stock return wale qty se wapas barha, History mein dono entries.
2. **Purchase + payment** — TEST Supplier se Rs 1000 ki purchase, Rs 400 payment.
   Hona chahiye: supplier payable **600**, item stock purchase qty se barha.
3. **Expense** — Rs 200 expense (cash). Hona chahiye: cash in hand **200 kam**, Day book mein entry.
4. **Unit** — bade/chhote unit wale item ki 1 chhoti unit (jaise 1 box) ki sale. Hona chahiye: stock bade unit ka 1/factor kam;
   Rate Search mein Last Cost / Profit Margin bade aur chhote dono unit mein dikhe (naya).
5. **Credit limit** — TEST Ali ki limit 1000, balance 800: Rs 300 ka udhaar bill. Hona chahiye: "Credit Limit Exceeded" dialog.
   Settings > "Credit limit override" ON karo, cashier se login: dialog mein sirf OK (Save Anyway nahi). Admin/manager se Save Anyway chalta hai.
6. **Reports milan** — aaj ka Profit & Loss aur Balance Sheet apne haath ke hisaab se milao (upar ke test numbers se).

## B. Do devices (sync)
7. Dono par ek hi customer/item; dono se **lagbhag ek saath** sale. Hona chahiye: sync ke baad dono par stock aur balance **ek jaise**.
8. Ek phone **aeroplane mode** mein sale kare, phir net on. Hona chahiye: sync ke baad dusre phone par wahi bill, koi double nahi.
9. Settings mein sync status: pending / failed entries ka number dekho (failed 0 hona chahiye).

## C. Safety
10. **Roles** — cashier login: reports/cost nahi khulte. Admin Manage Users > Access se ek item do: cashier ko khulta hai (dusre device par bhi).
11. **Backup/restore** — Backup lo, dusri test installation par restore. Hona chahiye: customers, stock, cash totals wahi.
12. **Update** — purani app ke **upar** nayi APK install (uninstall nahi). Hona chahiye: purana data salamat, app khule.

## D. Release
13. Naye Build ki APK install; Android par sab sahi. (iOS/Windows jab zaroorat ho.)

Natija likhne ka tareeqa: `1 ✅`, `5 ❌ dialog nahi aaya`, ... bhej dein.
