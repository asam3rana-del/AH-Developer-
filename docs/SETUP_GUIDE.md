# Nayi dukaan ka Setup Guide (2026-11-12)

Settings → Shop Information → **SHOP SETUP GUIDE (new shop)** (sirf admin). 5 qadam, sab maujooda screens /
data istemal karte hain (koi naya table nahi):

1. **Dukaan ki maloomat** — naam, malik, phone, reminders ki payment details (Settings wali hi fields).
2. **Ibtidai raqam** — galle ka cash + bank. Ek dafa Cash In → *Owner Capital* (note "Opening cash / bank") ban
   kar Balance Sheet mein "Owner Capital added" mein aata hai. Dobara karne par warning (raqam dugni na ho).
   Flag: `app_settings.setup_opening_money_done` (device ka, sync nahi).
3. **Customers & suppliers** — Party screen kholta hai; har party ka Opening Balance.
4. **Items & stock** — Items kholta hai; Opening Stock, sahi Cost, Expiry. Pehle 20–30 zyada bikne wale.
5. **Balance Sheet** — 4 lines haqeeqat se milayein.

File: `lib/screens/setup_guide_screen.dart` (naya), `lib/screens/settings_screen.dart`.

## Phone par check (Demo dukaan mein karein)
- [ ] Settings → Open Demo shop → Setup guide → naam save
- [ ] Ibtidai raqam: cash 50,000, bank 20,000 → Balance Sheet: Owner Capital added 70,000
- [ ] Guide dobara kholein, phir raqam → "pehle darj ho chuki" warning
- [ ] Qadam 3/4 ke buttons sahi screens kholen
