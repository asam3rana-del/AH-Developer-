# Hanna POS — khud use se pehle device sign-off (2026-11-11)

Code side: CI Build #692 — Analyze + Test ✅, Android APK/AAB ✅, Windows ✅ (iOS alag). Money flows (sale, purchase,
payment edit/delete, returns, cash) aur sync code review ho chuka. Ye sheet sirf woh cheezein hain jo **phone par**
hi pakki ho sakti hain. Har line ✅ / ❌ — ❌ ka screenshot.

Do phone chahiye: **A** (pehle migrate) aur **B** (purani app abhi chalti rahe). Test data par karein ya pehle Backup.

## 0. Migration (sirf phone A)
- [ ] Purani app: Sync Now → Backup Now → backup file WhatsApp/Drive par
- [ ] Nayi **Hanna POS** install (icon par "Hanna POS"); purani app abhi delete nahi
- [ ] Restore backup → customers ke balance, aaj ki sales, cash register, stock **purani app jaise**
- [ ] Cloud Sync Setup (nayi google-services.json + `dusri-branch`) → `branch_members` mein naya Device ID → Sync Now: "Received / Sent", koi warning nahi
- [ ] App band karke dobara kholein: login ya seedha andar — dobara login nahi maangna chahiye (session check)

## 1. Billing (A)
- [ ] Cash sale → print / PDF share (Urdu theek dikhe)
- [ ] Udhaar sale **naye naam** ke customer par → customer bana, balance barha
- [ ] Poora paid sale **naye naam** par → B par Sync ke baad wo customer bhi B par ho (fix B4)
- [ ] Wahi bill edit (qty / rate badlein) → stock aur balance sahi
- [ ] Bill return → stock wapas, balance kam

## 2. Parties
- [ ] Naya customer "Ali" → dobara "Ali" banane par roka jaye, message "Ali (Mohalla)" (fix B3)
- [ ] Credit limit field khali karke save → limit hat jaye (0)
- [ ] Payment receive (bill se link) → bill ka baqi aur customer balance dono kam
- [ ] Wahi payment **edit** (amount badlein) aur phir **delete** → balance wapas sahi; Recycle Bin mein aaye

## 3. Purchase & stock
- [ ] Purchase naye supplier ke saath → stock barha, cost / rate update
- [ ] Purchase edit (qty kam) → stock / cost sahi; agar beech mein sale ho chuki ho to saaf message
- [ ] Low stock, stock audit screen khulein

## 4. Do phone sync (A ↔ B)
- [ ] A par sale + payment → B par 1 minute mein (ya Sync Now) aaye
- [ ] A ka net band → 2 entries → net on → B par aayein (late push / indexes)
- [ ] Sync chalte waqt A par naya bill → 5–10 s baad khud chala jaye (fix S2)
- [ ] Dono par same customer ka balance **barabar**

## 5. Security / login
- [ ] 5 ghalat password → lockout; app band-khol karne par bhi lockout baqi (barhta hua waqt)
- [ ] Admin ne cashier deactivate kiya → cashier ke phone par app restart → login screen (session revalidate)
- [ ] OTP login (agar use karte hain) → login ke baad Sync Now theek, `permission-denied` nahi (fix B1)
- [ ] Fingerprint / app lock

## 6. Backup
- [ ] Backup Now → file bani; password ke saath
- [ ] Doosre / test phone par restore → data poora
- [ ] App band → 12 PM / 9 PM ka background backup bana (Settings > Backup mein waqt) — workmanager naya naam

## 7. Android 15 / 16 (naya targetSdk 36)
- [ ] Har screen ka neeche wala button (Save, Total, Print) gesture bar ke peechay chhupa **nahi**
- [ ] Back gesture: bill bharte waqt back → data na jaye / poochhe
- [ ] Tablet landscape (agar tablet hai): Sale / Purchase screen theek
- [ ] Bluetooth printer connect + test print; USB printer (agar hai)
- [ ] Bill scan (camera), contact se phone number chunna
- [ ] Notifications (wasooli reminder) aayein
- [ ] Din bhar chalne ke baad sync / app crash nahi

## 8. About
- [ ] Settings → About & Privacy → privacy link khule, WhatsApp / call buttons chalein

## Sign-off
Sab ✅ + **1 hafta** asli dukaan par (purani app B par parallel) → hisaab barabar → B ko bhi migrate → purani app delete.
Iske baad commercial ke liye sirf Play Console protocols (`PRODUCTION_LAUNCH.md`, `STORE_LISTING.md`).

---

## Natija — 2026-11-11 (phone par test, Asam Hameed)

**Server / cloud (live project `my-grocery-pos-8a444`)**
- ✅ 64 Firestore indexes deploy + Enabled → "pushedAt index missing" warning khatam, payment sync theek
- ✅ Privacy site live: https://my-grocery-pos-8a444.web.app/privacy.html
- ✅ Firebase rules test #11 green → **device-roles rules live** (`tools/deploy_rules_live.sh`); rollback: `bash deploy_rules_live.sh rollback`
- ✅ Android app `com.hannasolutions.pos` Firebase mein + SHA-1/SHA-256

**Do phone sync (nayi rules ke saath)**
- ✅ Dono phone Sync Now → "Received", koi error nahi
- ✅ Naya customer A → B
- ✅ Payment banana → edit (10 → 20) → delete, teenon A ↔ B sahi, balance wapas barabar

**Hisaab**
- ✅ Sale 15,700 / cost 15,300 / munafa 400 — P&L sahi
- ✅ Balance Sheet: cash 50,400 + bank 20,000 = 70,400 = capital 70,000 + munafa 400; asal cash / stock se mila
- ✅ Sale return (sugar 6,800): cash 43,600, stock 6,500, munafa 100
- ✅ Purchase return (sugar 6,500, Asim): cash 50,100, stock 0, munafa 100
- ✅ Daily bill WhatsApp share: return ke baad bill 8,900, paid 8,900, baqi 0

**Backup / login**
- ✅ Backup Now → test purchase 1,300 → restore → test purchase hat gayi, "Please sign in again"
- ✅ 5 ghalat password → "Too many wrong attempts. Try again in 28 s"; sahi password se khula
- ✅ Forgot password → phone PIN / fingerprint → naya password

**Is test ke dauran mili cheezein**
- 🔧 FIXED (Build #693): Android 15+ par neeche ki system bar Settings ka **Logout** (aur doosri lambi screens ka aakhri button) chhupa deti thi → `main.dart` mein `_BottomSystemBarGuard` (poori app). Phone par dobara check: ⬜
- ℹ️ Rate Search: jo purchase line **poori wapas** ho jaye wo bill se hat jaati hai, is liye "Purchase Rate History" khali dikhti hai. Hisaab theek; return ka record Returns Report mein. (Baad mein "Returned" line dikhana — optional)
- ℹ️ Restore "undo" nahi: synced phone par restore ke baad Sync Now cloud ka data (maslan hatayi hui test entry) wapas le aata hai — jaan boojh kar (doosre phone ka data na mite). Ghalat entry ko **delete** karein.
- ℹ️ Test phone par alag install ki hui app cloud se nahi judi ("Not set up", 39 pending) — jaan boojh kar; test data asal cloud mein na jaye.
- ⚠️ Forgot password phone ke screen-lock PIN par chalta hai → counter phone ka PIN cashier ko na dein.

**Baqi**
- ⬜ Build #693 APK install → Logout poora nazar aaye, Sale screen keyboard ke saath theek
- ⬜ Asal (cloud wali) app mein test data saaf + opening cash / bank / party baqi / stock count
- ⬜ Cashier phone aaye to `branch_members/{DeviceID}` mein `role = "cashier"`
- ⬜ 1 hafta asli dukaan par → phir commercial ke liye Play Console ($25 account — abhi ruka hua)
