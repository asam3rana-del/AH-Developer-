# Commercial release audit — 2026-11-10

Source: `AH-Developer--main.zip` (227 Dart files, ~70k lines, 100+ tests).
Note: is review ke dauran Flutter SDK maujood nahi tha, is liye `flutter analyze` / `flutter test` **nahi chale**.
Neeche ke fixes haath se (static review) kiye gaye hain — CI "Analyze + Test" pass hona zaroori hai.

## A. Release BLOCKERS (Play Store / App Store par jaane se pehle)

| # | Masla | Asar | Kya karna hai |
|---|-------|------|---------------|
| A1 | **applicationId = `com.example.ah_developer_kiryana_store`** (`flutter create` ka default; `android_fix.sh` badalta nahi). iOS bundle id bhi `com.example...` | Google Play `com.example` wala package **qubool nahi karta**. App Store bhi nahi | Apna id rakhein (e.g. `com.hannasolutions.pos`). ⚠️ Id badalne se purani install **update nahi hogi** (naya app ban jata hai) — dukaan ke phones par pehle encrypted backup, phir nayi app mein restore |
| A2 | **targetSdk = 34** (Flutter 3.24 template default) | 31 Aug 2026 se Play Store naye apps/updates ke liye **API 36** maangta hai — upload reject | 🟡 **Code mein kiya**: Flutter 3.47.x + targetSdk 36 (`docs/UPGRADE_FLUTTER_3_47.md`). CI run + device test baaki |
| A3 | **iOS privacy strings nahi the** (camera, photos, contacts, Face ID, Bluetooth, local network) | iOS par Bill Scan / contact picker / Face ID / BT printer kholte hi app **crash**; App Store review reject | ✅ **Fix kiya**: `build.yml` mein "Set iOS usage descriptions" step |
| A4 | Android 14+/target 35+: `FOREGROUND_SERVICE_DATA_SYNC` (SyncKeepAlive) | Target 35+ par dataSync service ki 6 ghante/din ki hadd; Play Console mein foreground-service declaration (video/justification) chahiye | Target badhane ke baad `flutter_foreground_task` naya version + timeout handling test karein, ya keep-alive sirf zaroorat par |
| A5 | Privacy policy | Contacts, camera, phone number (OTP) use hote hain — Play "Data safety" form aur privacy policy URL zaroori | Privacy policy page banayein |

## B. Bugs jo fix kiye gaye (code)

### B1 — HIGH: OTP login sync ki pehchan mita deta tha
`lib/services/otp_login.dart`. OTP `signInWithCredential` usi Firebase app par hota tha jis par sync ka anonymous user hai.
Nateeja: device ka UID badal jata → `branch_members/{uid}` nahi milta → **saara sync `permission-denied`**, aur purana anonymous UID hamesha ke liye kho jata (Admin ko dobara provision karna parta).
**Fix:** OTP ab alag (secondary) Firebase app `otp_login` par verify hota hai, phir us ka session sign-out. Sync ka user nahi chhera jata.
**Device test zaroori:** OTP login → phir Settings > Sync History mein push/pull theek.

### B2 — HIGH (security): Session role DB se check nahi hota tha
`lib/main.dart` → `_revalidateSession()`. Role/username SharedPreferences se aate the. Windows par wo plain JSON file hai — cashier `session_role` ko `admin` likh kar admin ban sakta tha. Deactivate kiya hua user / badla hua role restart ke baad bhi purana chalta.
**Fix:** har launch par `users` table se milaya jata hai: user na mile ya inactive ho → logout; role/permissions badle hon → session update.

### B3 — MEDIUM: Ek hi naam ki do parties = galat khata
Sale/Purchase customer ko **naam se** dhoondte hain (`saveSale`: pehla match). Party screen par "Add anyway" se duplicate naam ban jata tha → dusre "Ali" ka har bill pehle "Ali" ke khate mein.
**Fix:** `PartyRepository` (add + rename) aur `party_screen.dart` mein duplicate naam ab **roka** jata hai (`SavePartyResult.duplicateName`), message: naam mein farq likhein, e.g. "Ali (Mohalla)". Purchase screen pehle se rokti thi. Purane duplicates ke liye maujooda "merge duplicates" tool.

### B4 — MEDIUM: Sale mein naya customer cloud par nahi jata tha
`lib/db/sale_repository.dart` (`saveSale` + `saveQuickSale`). Bill par naya naam likhne se customer row banti thi magar sync queue mein nahi jati thi. Udhaar bill par to `increment_balance` ke seed se cloud par ban jata, lekin **poora paid bill** hone par wo customer doosre devices par kabhi nahi pahunchta aur wahan bill "walk-in" dikhta.
**Fix:** insert ke foran baad `SyncQueueHelper.enqueueCustomer(txn, id)`.

## C. Baaki findings (fix nahi kiye — faisla / test chahiye)

| # | Severity | Kahan | Masla | Mashwara |
|---|----------|-------|-------|----------|
| C1 | Medium | `main.dart` | `DeviceTag.init / BranchConfigStore.init / Loc.load / Session.load` mein koi exception (kharab DB / prefs) → `runApp` kabhi nahi chalta, **safed screen** | In ko try/catch mein, aur fail par ek "recovery" screen (backup restore option ke saath) |
| C2 | Low-Med | `login_screen.dart` | Ghalat-password lockout (5 koshish / 30 s) `static` variables mein — app band-khol karne se reset | Fail count + lockUntil `app_settings` mein rakhein, barhta hua waqfa |
| C3 | Low | `login_screen.dart` | Plain-text password (purane users) abhi bhi qubool, pehli login par hash hota hai | Theek hai; release se pehle check karein ke koi user plain-text par na bacha ho |
| C4 | Low | `functions/src/index.ts` `reserveCredit` | Reservation 5 min tak rehti hai, sale ka balance push hone ke baad bhi → us dauran doosre device par wahi raqam do baar ginti, credit limit ke qareeb customer ka bill bewajah ruk sakta hai | Sale push ke baad reservation delete/expire karne ka callable |
| C5 | Low | `party_screen.dart` edit | Credit limit field khali karne se limit **hatt'ti nahi** (`tryParse('') ?? purani`) — 0 likhna parta hai | Khali = 0 |
| C6 | Low | dialogs (`shell_ledger_screen.dart` waghaira) | Dialog ke `TextEditingController` dispose nahi hote (chhota memory leak) | Ahem nahi |
| C7 | Info | 68 jagah `catch (_) {}` | Zyada tar jaan boojh kar (best-effort) — lekin chhupi ghaltiyan log nahi hotin | Kam az kam `debugPrint` / CrashHandler mein darj |

## D. Jo cheezein achhi haalat mein mili
- Sale save: validation (NaN/negative), ek transaction mein stock + ledger + cash, double-tap guard, duplicate invoice guard, credit limit transaction ke andar.
- Password: PBKDF2-SHA256 120k + constant-time compare; backup AES-256-GCM.
- Restore: decrypt → SQLite check → schema check → safety backup → atomic rename.
- Firestore rules: branch isolation, deny-by-default; Cloud Functions claims-based, rate-limited.
- SQL: interpolation sirf andar ke constant table/column naamon ki; user input hamesha `?` se.

## E. Release se pehle checklist
1. CI "Analyze + Test" is source par green.
2. Device par: OTP login ke baad sync; deactivated user restart par logout; duplicate party naam ka message; poora-paid bill naye naam ke saath → doosre device par customer aur bill link.
3. A1 (applicationId) aur A2 (Flutter/targetSdk) ka faisla + data migration plan.
4. Keystore ka mehfooz backup (pehle se pending).
