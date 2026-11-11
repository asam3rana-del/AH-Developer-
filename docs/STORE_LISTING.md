# Google Play store listing — Hanna POS (draft, 2026-11-11)

Play Console → Grow → Store presence → Main store listing. Limits: naam 30, short 80, full 4000 characters.
Default language: **English (United States)**; Translations → **Urdu (ur)** add karke neeche wala Urdu text.

## Basic
| Field | Value |
|-------|-------|
| App name (30) | `Hanna POS: Billing & Khata` |
| Package | `com.hannasolutions.pos` |
| Category | Business |
| Tags | Point of sale, Accounting, Inventory |
| Developer name | Asam Hameed (Hanna Solutions) |
| Contact email | asam9rana@gmail.com |
| Phone | +92 300 6296815 |
| Website | https://my-grocery-pos-8a444.web.app |
| Privacy policy | https://my-grocery-pos-8a444.web.app/privacy.html |
| Price | Free (abhi) |
| Ads | No |

## English
**Short description (80):**
`Offline shop billing, udhaar khata, stock & cash book — syncs across phones.`

**Full description:**
```
Hanna POS is a complete billing and bookkeeping app for kiryana, grocery and general stores — made in Pakistan by Asam Hameed (Hanna Solutions).

Works without internet. Your shop's data stays on your phone, and syncs between your shop's phones when internet is available.

BILLING
• Fast sale bills with item search, rates and discounts
• Cash, bank and udhaar (credit) bills
• Print receipts on Bluetooth, USB or network thermal printers
• Share bills as PDF on WhatsApp (Urdu supported)

UDHAAR KHATA & COLLECTION
• Customer and supplier ledgers with opening balances
• Credit limit per customer
• Receivables by age — who owes, for how long
• Collection list and WhatsApp payment reminders

STOCK
• Purchases, supplier bills, returns
• Low stock alerts, stock audit and adjustments
• Units and categories, bulk rate tools
• Scan supplier bills with the camera

CASH & ACCOUNTS
• Daily cash register and day book
• Expenses, shop rent, utility bills, workers' salary and advances
• Reports: sales, profit, balance sheet, party reports
• Zakat calculator

SAFE & MULTI-USER
• Owner, manager and cashier roles with permissions
• Encrypted backup and restore
• Recycle bin for deleted bills and entries
• Sync across your shop's phones (optional)

English and Urdu.

Support: WhatsApp 0300-6296815 · asam9rana@gmail.com
```

## اردو (Urdu translation)
**Short description:**
`انٹرنیٹ کے بغیر بِل، اُدھار کھاتہ، اسٹاک اور کیش بُک — آپ کے سب فونز میں سنک`

**Full description:**
```
Hanna POS کریانہ، جنرل اسٹور اور دکانوں کے لیے مکمل بِلنگ اور حساب کتاب ایپ ہے — Hanna Solutions، پاکستان۔

انٹرنیٹ کے بغیر چلتی ہے۔ دکان کا ڈیٹا آپ کے فون میں رہتا ہے، اور انٹرنیٹ ہو تو دکان کے فونز آپس میں سنک ہوتے ہیں۔

بِلنگ
• تیز سیل بِل، آئٹم سرچ، ریٹ اور ڈسکاؤنٹ
• کیش، بینک اور اُدھار بِل
• بلوٹوتھ / USB / نیٹ ورک پرنٹر پر رسید
• بِل PDF میں واٹس ایپ پر (اردو کے ساتھ)

اُدھار کھاتہ اور وصولی
• گاہک اور سپلائر کھاتے
• ہر گاہک کی کریڈٹ حد
• کس نے کتنا اور کب سے دینا ہے
• وصولی لسٹ اور واٹس ایپ یاد دہانی

اسٹاک
• خریداری، سپلائر بِل، واپسی
• کم اسٹاک الرٹ، اسٹاک آڈٹ
• کیمرے سے سپلائر بِل اسکین

کیش اور حساب
• روزانہ کیش رجسٹر اور ڈے بُک
• خرچے، دکان کا کرایہ، بجلی گیس بِل، ملازمین کی تنخواہ
• رپورٹس: سیل، منافع، بیلنس شیٹ
• زکوٰۃ کیلکولیٹر

محفوظ
• مالک، مینیجر، کیشیئر — الگ اختیارات
• انکرپٹڈ بیک اپ اور ریسٹور
• حذف شدہ بِل کے لیے ری سائیکل بِن

سپورٹ: واٹس ایپ 0300-6296815
```

## Graphics checklist
| Asset | Size | Note |
|-------|------|------|
| App icon | 512 × 512 PNG, 32-bit, ≤ 1 MB | Same as launcher icon |
| Feature graphic | 1024 × 500 JPG/PNG (no transparency) | Naam + 1 line + phone mockup |
| Phone screenshots | 2–8, 16:9 or 9:16, min side ≥ 320 px, max ≤ 3840 px | Dashboard, Sale bill, Receipt print/PDF, Udhaar khata, Receivables, Stock, Reports, Urdu screen |
| 7" / 10" tablet screenshots | optional (recommended — app tablet par bhi chalti hai) | Same screens on tablet |

Screenshots se pehle: **demo data** use karein (asli customers ke naam / phone numbers nahi).

## App content (Policy → App content)
- **Privacy policy:** upar wala URL
- **Ads:** No ads
- **App access:** "All or some functionality is restricted" → review ke liye ek demo admin login (username / password) dein
- **Content rating:** questionnaire → Utility / Productivity; koi violence / gambling nahi → Everyone
- **Target audience:** 18+
- **Data safety:** `PRODUCTION_LAUNCH.md` section 4; data deletion URL = privacy page (section 5)
- **Foreground service (dataSync):** wajah: "Keeps the shop's offline sales data in sync with the shop's other devices while the app is minimised." Short screen recording maang sakte hain
- **Government / financial features:** No (ye bank / lending app nahi)
