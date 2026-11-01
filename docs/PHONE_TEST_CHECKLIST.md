# Phone test checklist (asli device par)

Ye tests CI nahi kar sakti — inhe aap apne phone par karein. Har test ke baad ✅ / ❌ likh dein; ❌ ho to screenshot bhej dein.
**Shuru karne se pehle:** asli dukaan ka backup (Backup tile → Backup now) kisi alag jagah (Drive / computer) save kar lein.

## 1. Update test (purani app ke upar nayi app)
1. Purani app mein note karein: Customers ki list ka ek balance, ek supplier balance, ek item ka stock, aaj ki sale ka total.
2. Nayi APK **uninstall kiye bina** install karein (purani app ke upar).
3. App kholein (login hona chahiye, data wahi).
4. Check: wahi balances, stock aur aaj ki sale ka total. Koi item / bill gayab na ho.
5. Ek chhoti sale karein aur print / share karein.

✅ = sab number wahi aur sale ho gayi.

## 2. Backup / restore (doosra phone ya test installation)
1. Phone A: Backup tile → Backup now. File + password (Backup screen par dikhta hai) note karein.
2. Phone B (ya naya install): app kholein → Restore → file chunein → password dein.
3. Check phone B par: Dashboard ka Today sale, Dues Summary, Items ki ginti, Balance Sheet ke totals — phone A se barabar.
4. Ghalat password dalein → restore fail hona chahiye, phone B ka data na badle.

✅ = totals barabar, ghalat password par safe refuse.

## 3. Do phone par ek saath sale
1. Dono phones par internet ON, ek hi branch/shop code, ek hi item ka stock note karein (maslan 10).
2. Phone A par 2 sale, phone B par 3 sale — ek hi item, ek hi waqt.
3. Dono par Sync Now.
4. Check dono phones par: item ka stock = 10 − 5 = 5, customer balance dono par ek jaisa, bills ki ginti barabar.

✅ = dono phones par stock aur balance bilkul ek jaise.

## 4. Offline sale aur reconnect
1. Phone A ka internet band (airplane mode). 2 sale karein (ek udhaar customer ko).
2. Dashboard par "not yet synced" ka warning aana chahiye.
3. Internet ON → Sync Now. Warning chali jaye; phone B par bills aa jayen.
4. Settings → Sync History: koi "stuck" entry na ho. Ho to Retry Now dabayein aur error ka screenshot bhejein.

## 5. Sale → return → hisaab
1. Ek item 2 qty udhaar bechein. Phir 1 qty return karein.
2. Check: customer balance sirf 1 qty ka, stock +1, cash / ledger mein return ka asar.
3. Reports → Profit & Loss: is bill ka profit = (1 qty ka sale rate − cost).

## 6. Purchase → supplier payment
1. Ek purchase 10 qty, kuch paise abhi, baqi udhaar.
2. Supplier balance = baqi rakam, item stock +10, cost (Rate Search → Last Cost) sahi.
3. Supplier ko payment dein → balance kam, cash kam.

## 7. Rent aur Workers (naye hisse)
1. Shop Rent: ek shop ka rent dein, ek advance dein; agle mahine rent advance mein se kate (Rent screen ka baqi advance sahi ghate).
2. Workers: attendance lagayein, advance dein, salary dein — salary = hazri − advance, aur Recycle Bin se delete kiya hua worker wapas aaye.

## 8. Bill cost (purane bill)
1. Reports → koi purana bill jis par loss tha: Bill Cost Repair se check karein ke cost theek hai.
2. Naye bill mein unit badal kar (carton ↔ piece) sale karein: cost per piece = carton cost ÷ piece-per-carton, bill par profit munasib.

## Natija
| Test | Phone | Natija | Note |
|------|-------|--------|------|
| 1 Update | | | |
| 2 Backup / restore | | | |
| 3 Do phone sale | | | |
| 4 Offline / sync | | | |
| 5 Return | | | |
| 6 Purchase | | | |
| 7 Rent / Workers | | | |
| 8 Bill cost | | | |
