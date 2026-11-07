# AH Developer — Wasooli (Collection) Update

Tareekh: 2026-11-06
Maqsad: jin se paisa lena hai un ka reminder khud bane (malik busy ho tab bhi), late / pending / toote wade aaj ki list mein saaf dikhen, aur aaj ki wasooli behtar ho.

---

## 1. Naya: Collection Autopilot (is patch mein)

### Masla
- Late / pending party ko reminder tab tak nahi jata tha jab tak malik khud yaad rakh kar na bheje.
- Reminder bhejne ke baad bhi party list mein barabar "late" dikhti rehti thi — pata nahi chalta kis ko aaj ho chuka.

### Autopilot ke qaide (`lib/models/collection_autopilot.dart`, PURE — DB / UI nahi)
| Halat | Nateeja |
|---|---|
| Late / due / toota wada, kabhi baat nahi hui | **TODO** (foran) |
| Aakhri baat ke baad gap poora ho gaya | **TODO** |
| Aaj WhatsApp / call / nateeja ho chuka | **DONE** (list se neeche, ginti mein) |
| Gap abhi poora nahi | **WAITING** (kitne din baad phir) |
| Dispute | **WAITING** (roz nahi satata) |

- Gap: toota wada **1 din**, 30+ din purana baqi **2 din**, baaqi **3 din** (`touchGapDays`).
- Malik ka tay kiya follow-up / "wada aaj" gap ko override karta hai (sirf aaj ho chuka ho to DONE).
- "Koshish" = WhatsApp / call / visit / sms, ya koi nateeja (paid, promised ...). Sirf note koshish nahi ginta (`isTouch`).
- Tarteeb: toota wada → aaj ka wada → follow-up din → late → aaj due; phir bari raqam pehle.

### Files
| File | Kaam |
|---|---|
| `lib/models/collection_autopilot.dart` | Naya. `buildAutopilot`, `AutopilotQueue`, `AutopilotItem`, `autopilotNotificationBody` |
| `lib/db/collection_autopilot_repository.dart` | Naya. `CollectionAutopilotRepository.today()` = queue + aaj customers se mili raqam (`payments`, `partyType='customer'`) |
| `lib/screens/wasooli_queue_screen.dart` | Naya. Progress card, bara "Agla bhejo" (WhatsApp) button, har row par WhatsApp / Call / "Paisa mila", DONE aur WAITING sections |
| `lib/screens/dashboard_screen.dart` | "Collection Autopilot" tile + badge (aaj kitne baqi) |
| `lib/services/due_alert_service.dart` | Notification ab autopilot queue se; tap par seedha Wasooli Queue screen (`queuePayload = 'wasooli_queue'`) |
| `test/collection_autopilot_test.dart` | Naya, 9 tests |

### Notification
- Subah 10 baje ke baad, shaam 6 baje ke baad dobara — sirf tab jab TODO baqi ho.
- Jo party aaj ho chuki wo dobara nahi aati.
- Matn misaal: "5 parties ko yaad dilana baqi (Rs ...) • 2 ka wada toota • aaj wasool: Rs ...".
- Foreground aur Android WorkManager dono wahi `checkAndNotify` chalate hain (pehle jaisa).
- `DueAlertService.bodyFor` purane test ke liye barqarar rakha gaya.

### Hadd
- WhatsApp message khud nahi jata (Android bina tap ke nahi bhejne deta). Malik "Agla bhejo" dabata hai, har tap par agli party; 20 parties ~2-3 minute.

---

### Ek screen (CollectionHubScreen)
- `lib/screens/collection_hub_screen.dart` (naya): ek screen, 2 tabs — **Aaj (Autopilot)** aur **Tamam bqaya** (purani Due Reminders list, filters + search).
- Dashboard par ab ek hi tile "Collection" (badge = aaj baqi reminders). Collect today / Late / Promise broken tiles hub ka tab 2 filter ke sath kholte hain.
- Notification tap -> hub tab 1 (Autopilot).
- `WasooliQueueScreen` aur `DueRemindersScreen` mein `embedded` flag: tab ke andar apni AppBar nahi. Purani report-screen se `DueRemindersScreen()` abhi bhi akeli khulti hai.

### Partial payment par due date renew
- Customer ki payment save hone par (`PaymentRepository.save` / `saveAllocated`), agar us ke bills abhi baqi hain, un bills ki due date aage ho jati hai (`_renewDueDates`, `lib/models/due_renewal.dart`).
- Nayi date = aaj + muddat. Muddat: customer ki default `dueDays` (agar set) -> warna bill ki apni purani muddat (3..30 din) -> warna 7 din.
- Sirf wo bills jin par date set thi; date kabhi peeche nahi jati; poora ada bill open nahi hota isliye nahi chhua jata.
- Sync: har badle hue bill ka `sale update` queue mein jata hai. Test: `test/due_renewal_test.dart`.
- Nateeja: partial payment dene wali party "late" list se hat jati hai, nayi date guzarne par wapas aati hai.

## 2. Pehle ka collection patch (`ah-collection-plan-patch.zip`)

Is mein ye files thin (project mein shamil / merge ho chuki):
- `lib/models/collection_plan.dart` — payment ki raqam sab se **purane bill se (FIFO)** lagti hai, phir "Previous balance", baqi advance (`planCollection`, `openBillsForCollection`). Kai bills wale customer ke liye har bill ki alag line wala reminder (`itemizedReminderMessage`).
- `lib/db/due_followup_repository.dart`, `lib/db/due_reminders_repository.dart`, `lib/db/payment_repository.dart`
- `lib/screens/due_reminders_screen.dart`
- `test/due_followup_test.dart`

## 3. Sale screen
- Udhaar sale par sirf due date picker ("Set date" chip). Quick day-chips (Tomorrow/1/3/7/15/30) aur ✕ hata diye. Date na chuni ho to pehle jaisa auto date (customer / dukaan ki default muddat) lagti hai.

---

## 4. Test / Deploy
- [ ] Is environment mein Flutter SDK nahi tha — **kuch compile / run nahi hua**. Pehle chalayein:
  `flutter pub get && flutter analyze && flutter test test/collection_autopilot_test.dart test/due_followup_test.dart test/due_alert_body_test.dart`
- [ ] Device par: Android 13+ par notification permission; Oppo / Xiaomi par background notification.
- [ ] DB / Firestore mein koi tabdeeli nahi (follow-up sync pehle jaisa).
- [ ] Permission: `due_reminders` wale users hi ye screen / tile dekhte hain.

## 5. ANDROID_CHANGELOG.md mein paste karne ke liye

```
## Flutter side (2026-11-06) — Wasooli Autopilot
- [x] Naya `lib/models/collection_autopilot.dart` + `lib/db/collection_autopilot_repository.dart` + `lib/screens/wasooli_queue_screen.dart`: late / pending / toote wade ki aaj ki list khud banti hai (TODO / DONE / WAITING), gap: toota wada 1 din, 30+ din 2 din, baaqi 3 din; dispute roz nahi.
- [x] "Agla bhejo" button: har tap par agli party ka WhatsApp + follow-up entry khud; row par WhatsApp / Call / Paisa mila.
- [x] Dashboard tile "Collection Autopilot" (badge = aaj baqi). `DueAlertService` ab autopilot queue se notification banati hai, tap par Wasooli Queue; jo aaj ho chuka wo dobara nahi.
- [x] Test: `test/collection_autopilot_test.dart` (9).
- [ ] Bina `flutter analyze` / `flutter test` ke likha gaya (Flutter SDK nahi) — CI par `Analyze + Test` dekhein.
```
