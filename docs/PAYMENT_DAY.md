# Customer ka "payment ka din" (DB v37) — 2026-11-12

**Kyun:** Autopilot har 1–3 din yaad dilata tha, chahe customer ke paas paisa ho ya na ho. Tankhwah wala 1 tareekh
ko deta hai, dihari wala Juma ko — usi din yaad-dahani sab se zyada kaam karti hai.

**Kaise:** Customers & Suppliers → customer → Edit → **Payment day (when they have money)** (admin / manager):
"Every Friday", "Every month on the 1" … (Not set = pehle jaisa).

**Asar:** us din, agar us customer ka koi bhi baqi hai (late na bhi ho), Wasooli Autopilot use aaj ki list
(TODO) mein laata hai — tarteeb: toota wada → aaj ka wada → **payment din** → follow-up → late → aaj due.
Label: "Payment day today" / ticker "AAJ PAYMENT DIN". Aaj baat ho chuki ho to DONE. Baqi din pehle jaisa.

**Data:** `customers.paySchedule` TEXT: '' | `w:1..7` (Mon..Sun) | `m:1..31` (chhote mahine mein aakhri din).
DB v36 → v37 migration (`ALTER TABLE customers ADD COLUMN paySchedule`), sync payload mein, purana doc
(field nahi) local value nahi mitata. Firestore rules mein badlav nahi chahiye (cashier ke customer update mein ye
field mana nahi; app mein cashier badal nahi sakta).

Files: `lib/models/pay_schedule.dart` (naya), `lib/db/app_database.dart`, `lib/models/party.dart`,
`lib/db/party_repository.dart`, `lib/sync/sync_queue_helper.dart`, `lib/sync/sync_apply.dart`,
`lib/models/collection_autopilot.dart`, `lib/db/collection_autopilot_repository.dart`,
`lib/screens/party_screen.dart`, `lib/screens/wasooli_queue_screen.dart`, `lib/screens/collection_ticker_screen.dart`.
Tests: `test/pay_schedule_test.dart` (naya), migration tests (test/ + test_migration/) v37 par.

## Phone par check
- [ ] Update ke baad app khule, purana data sahi (migration)
- [ ] Customer → Edit → Payment day = aaj ka din → Collection / Wasooli mein "Payment day today"
- [ ] WhatsApp bhejein → DONE mein chala jaye
- [ ] Doosre phone par Sync → wahan bhi wahi payment day
- [ ] "Not set" karke save → wapas normal
