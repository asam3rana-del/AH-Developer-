# Wasooli ek page par + purane wade ka bug (2026-11-16)

## 1. Collection = ek hi page, 3 tab
Dashboard → **Collection**:
- **Today (Autopilot)** — aaj kis ko yaad dilana hai (pehle jaisa)
- **All dues** — saari parties, filters, search (pehle jaisa)
- **Aging** (naya tab) — kis se kitna, kitne din purana (pehle dashboard ka alag "Receivables" tile tha; wo tile
  hata diya, aaj ki collection card ka "see aging" ab isi tab ko kholta hai)

## 2. Bug: purana baqi chuka kar naya udhaar => "Promise broken" / purana follow-up
**Masla:** wada (promise) sirf follow-up entry "Paid / Refused / Dispute" se khatam hota tha. Customer ne
"Payment Received" se sara baqi ada kiya, phir naya maal udhaar liya — naye bill par bhi purana wada "toota"
aur purana follow-up "due today" dikhta tha.

**Ab:** har party ka "maujooda qarz kab se" = FIFO ke baad bache hue sab se purane bill ki tareekh
(`DueParty.debtSince`). Us se **pehle** ke wade / follow-up / rabte purane (chuka diye gaye) qarz ke maane jate
hain aur laagu nahi hote — Autopilot, All dues, aaj ki card, WhatsApp reminder ki shiddat, aur udhaar ki warning,
sab jagah (`entriesForCurrentDebt`). Purana qarz abhi baqi ho (thora bhi) to purana wada pehle jaisa laagu.
"Previous balance" (bina bill wala opening baqi) ho to shuruaat maloom nahi — sab rabte laagu (pehle jaisa).
Rabta history (timeline) mein purani entries waisi hi nazar aati hain — kuch delete nahi hota.

Files: `lib/db/due_reminders_repository.dart`, `lib/models/due_followup.dart`, `lib/models/collection_autopilot.dart`,
`lib/db/due_followup_repository.dart`, `lib/screens/due_reminders_screen.dart`, `lib/services/credit_risk.dart`,
`lib/screens/collection_hub_screen.dart`, `lib/screens/receivables_screen.dart`, `lib/screens/dashboard_screen.dart`.
Test: `test/current_debt_test.dart`.

## Phone par check
- [ ] Collection kholein → 3 tab; Aging tab mein buckets / parties
- [ ] Jis party ka "Promise broken" tha aur jis ne sab ada karke naya maal liya → ab "Promise broken" nahi
- [ ] Jis ka purana baqi abhi bhi hai → "Promise broken" pehle jaisa
