# Qist (installment) plan — 2026-11-12

Bara / purana baqi qiston mein: Customers & Suppliers → customer card → **Qist**.

**Banana (admin / manager):** raqam (default = maujooda baqi), kitni qisten (2–12), har kitne din (hafta / 15 din /
mahina), pehli qist ki tareekh → preview ("4× Rs 2,500 • aakhri 31 May") → SAVE PLAN.

**Chalana:** kuch alag nahi — paisa pehle jaisa **Payment Received** se. Plan banne ke baad ki payments tarteeb se
qiston par lagti hain (adhoori pehle poori). Qist sheet mein har qist: Paid / Late (part paid) / Due today /
Upcoming, upar "Late amount".

**Wasooli Autopilot:** qist ki tareekh wale din, ya koi guzri qist adhoori ho, customer TODO mein
("Installment due" / ticker "QIST DUE") — tarteeb: toota wada → aaj ka wada → **qist** → payment din → …

**Data:** `customers.qistPlan` (JSON: total, count, firstDate, everyDays, createdAt) — DB v37 mein hi (payment din ke
saath; v37 abhi kisi phone par nahi gaya tha). Customer ke saath sync. Har qist ka alag record nahi, is liye payment
edit / delete khud sahi asar karta hai. Plan hatane se payments nahi badaltin.

**Hadd:** sirf `payments` table ki wasooli ginti hai (bill par counter pe diya cash nahi); plan raqam aur asal baqi
alag ho sakte hain (plan sirf schedule hai, khata wohi).

Files: `lib/models/qist_plan.dart`, `lib/db/qist_repository.dart`, `lib/screens/qist_sheet.dart` (naye);
`lib/models/party.dart`, `lib/db/app_database.dart`, `lib/sync/sync_queue_helper.dart`, `lib/sync/sync_apply.dart`,
`lib/models/collection_autopilot.dart`, `lib/db/collection_autopilot_repository.dart`, `lib/screens/party_screen.dart`,
`lib/screens/wasooli_queue_screen.dart`, `lib/screens/collection_ticker_screen.dart`. Test: `test/qist_plan_test.dart`.

## Phone par check (test phone / Demo)
- [ ] Customer jis par Rs 10,000 baqi → Qist → 4, mahana, pehli aaj → SAVE → 4 qisten nazar aayen
- [ ] Wasooli list mein "Installment due"
- [ ] Payment Received Rs 2,500 → Qist sheet: pehli "Paid"
- [ ] Doosre phone par Sync → wahan bhi plan
- [ ] REMOVE PLAN → payments wahi rahein
