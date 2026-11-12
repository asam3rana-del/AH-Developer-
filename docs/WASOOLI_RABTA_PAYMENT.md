# Wasooli behtari — Rabta, Payment info, Udhaar se pehle warning (2026-11-12)

## 1. Rabta history (customers)
- Customers & Suppliers → customer card par **Call**: dialer khulte hi "call" ki entry ban jati hai aur nateeja
  likhne ki sheet khulti hai (call se wapas aate hi samne): baat hui / nahi uthaya / wada (raqam + tareekh) / agla
  follow-up / note. Sheet band karein to entry "sent" rehti hai.
- Naya button **Rabta**: us customer ki poori history (call, WhatsApp, wade, nateeje), naya pehle; wahin se add /
  edit / delete. Yahi entries Collection / Wasooli list aur "wada toota" mein istemal hoti hain, aur sync hoti hain.
- Suppliers: abhi sirf call (log nahi) — follow-up table sirf customers ke liye bani hai.

Files: `lib/screens/party_screen.dart` (followup_sheets / due_followup_repository wahi purane).

## 2. Payment details har reminder ke neeche
- Settings → Shop Information → **Payment details for reminders** (Raast ID / JazzCash / Easypaisa / bank IBAN).
- Har WhatsApp wasooli reminder (Collection, Due Reminders, aaj ki collection card) ke neeche khud:
  "Payment yahan bhej sakte hain / ادائیگی یہاں بھیج سکتے ہیں: …". Khali chhorein to kuch nahi jurta.
- `payment_info` sync hoti hai — ek phone par likhein, sab phones par.

Files: `lib/services/payment_info.dart` (naya), `lib/services/collection_actions.dart`,
`lib/widgets/todays_collection_card.dart`, `lib/screens/due_reminders_screen.dart`,
`lib/screens/settings_screen.dart`, `lib/sync/sync_queue_helper.dart`. Test: `test/payment_info_test.dart`.

## 3. Udhaar dene se pehle warning
Naya udhaar bill (baqi > 0) save karte waqt, agar is customer ka:
- baqi **late** hai (due date guzar gayi; date na ho to bill 30 din se purana), ya
- **pichla wada toota** hai,

to dialog: "Rs X late hai (sab se purana N din) / wada toota — phir bhi udhaar dein?".
Settings ki "Only admin/manager can Save Anyway" ON ho to cashier ke liye sirf OK (rok); admin / manager de sakte
hain. Bill edit, poora paid bill, naya customer: koi warning nahi. Ghalti ho to warning chhor di jati hai (sale nahi
rukti). Credit limit wala check pehle jaisa alag chalta hai.

Files: `lib/services/credit_risk.dart` (naya), `lib/screens/sale_screen.dart`. Test: `test/credit_risk_test.dart`.

## Phone par check
- [ ] Settings mein payment details likh kar save → Collection se WhatsApp reminder → neeche payment wali lines
- [ ] Doosre phone par Sync → wahan bhi reminder mein wahi lines
- [ ] Customer card → Call → wapas app → nateeja sheet → "wada, kal tak Rs 500" save → **Rabta** mein nazar aaye
- [ ] Rabta mein wada kal ki tareekh ka → parson us customer ko udhaar bill → "wada toota" warning
- [ ] Customer jis ka bill due date se guzar chuka → naya udhaar bill → warning; poora paid bill → koi warning nahi
- [ ] Cashier login + "Only admin/manager" ON → warning mein sirf OK, bill save na ho
