# Malik ka capital, galla ginti, Demo dukaan — 2026-11-12

## 1. Owner Capital / Owner Drawings
**Masla:** malik ka dala hua paisa aur ghar le jaya hua paisa alag darj nahi hota tha. Balance Sheet ka
"Capital" sirf balancing figure tha, is liye ghalti hone par bhi sheet barabar hi dikhti thi.

**Ab:** Cash In / Cash Out screen ki category list mein do nayi categories:
| Category | Kab | Asar |
|---|---|---|
| `Owner Capital (malik ne dala)` | sirf **Cash In** | na income na kharcha; reason `Owner: Capital` |
| `Owner Drawings (ghar ke liye)` | sirf **Cash Out** | na kharcha (munafa kam nahi); reason `Owner: Drawings` |

Ulti taraf (Capital par Cash Out, Drawings par Cash In) app rok deti hai. Expense screen ki list mein ye nahi aatin.

**Balance Sheet → CAPITAL / EQUITY** ab hisson mein:
- Owner Capital added
- Less: Owner Drawings
- Opening balances & other (calculated) — opening stock, parties ke opening baqi, Owner Capital ke baghair likha
  opening cash, damage, rounding
- Net Profit (all-time)

Note mein "is mahine ghar ke liye nikala" bhi. Agar drawings > (kul munafa + dala hua capital) to laal warning.
Purana data: koi owner entry nahi => sab "Opening balances & other" mein (pehle jaisa total).

**Mashwara:** naye shuru mein opening cash / bank **Cash In → Owner Capital** se likhein.

Files: `lib/db/cash_repository.dart`, `lib/db/balance_sheet_repository.dart`, `lib/screens/balance_sheet_screen.dart`.
Tests: `test/cash_test.dart`, `test/balance_sheet_test.dart`.

## 2. Galla band karna — blind count
Cash Register (Cash In / Cash Out screen ka register button) pehle se tha: opening, din ka hisaab, ginti, Shortage /
Excess, history. **Kamzori:** "Counted" khane expected raqam se pehle se bhare hote the — bina gine ek tap mein
"Matched".

**Ab:**
- Counted Cash / Bank khali aate hain — gin kar likhna lazmi (Bank khali = 0).
- Cashier (admin / manager nahi) ko khule register par din ka In/Out aur Expected nazar nahi aata; band hone ke baad
  farq history mein sab ko dikhta hai.

File: `lib/screens/cash_register_screen.dart`.

## 3. Demo / Training dukaan
Settings → **Demo / Training shop** (sirf admin kholta hai; demo mein koi bhi band kar sakta hai).

- Alag DB file `ah_developer_demo_shop.db` — asal file ko haath nahi lagta. `AppDatabase.database` har dafa check
  karta hai ke khuli file mode ke mutabiq hai, warna band kar ke sahi kholta hai.
- Cloud sync band (`SyncRepository` foran laut aata hai); Settings ka sync card sirf "Demo mein band" dikhata hai
  (Setup / Disconnect nahi — cloud settings asal dukaan ki hain).
- Backup / restore band (demo backup asal backups mein na mile).
- Har screen par narangi **DEMO** patti; dashboard ki "not yet synced" warning nahi.
- Pehli dafa demo: naya demo admin banana parta hai. Band karne par asal login (asal password).
- Background WorkManager backup / sync flag nahi parhte => hamesha asal DB (demo chalte bhi asal ka backup theek).

Files: `lib/services/demo_mode.dart` (naya), `lib/db/app_database.dart`, `lib/sync/sync_repository.dart`,
`lib/backup/backup_helper.dart`, `lib/widgets/sync_section.dart`, `lib/db/dashboard_repository.dart`,
`lib/screens/settings_screen.dart`, `lib/main.dart`. Test: `test/demo_mode_test.dart`.

## Phone par check
- [ ] Cash In 1,000 → Owner Capital → Balance Sheet "Owner Capital added" 1,000, munafa wahi
- [ ] Cash Out 500 → Owner Drawings → "Less: Owner Drawings" −500, munafa kam **nahi** hua, note mein is mahine 500
- [ ] Cash Out par Owner Capital chunein → roka jaye
- [ ] Cash Register: Counted khali; cashier login par Expected nazar na aaye; ghalat ginti → Shortage
- [ ] Settings → Open Demo shop → DEMO patti, naya admin, sale karein → Exit Demo → asal data waisa hi, demo sale nahi
- [ ] Demo mein Sync Now / Backup → band ka message; doosre phone par demo ki koi entry nahi
