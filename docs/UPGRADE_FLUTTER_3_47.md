# Upgrade: Flutter 3.24 → 3.47 + Android targetSdk 36 (2026-11-10)

Kyun: Google Play 31 Aug 2026 se naye apps / updates ke liye **targetSdk 36 (Android 16)** maangta hai.
Flutter 3.24 ka template targetSdk 34 deta tha, is liye APK Play Store par upload nahi ho sakti thi.

## Kya badla

| File | Tabdeeli |
|------|----------|
| `pubspec.yaml` | `workmanager` ^0.5.2 → **^0.9.1** (0.5.x purane Flutter embedding par tha, Flutter 3.29+ par compile nahi hota). Baaki plugins apni maujooda range (^) mein naye patch/minor le lenge |
| `lib/backup/backup_background.dart` | workmanager 0.9 API: `initialize()` se `isInDebugMode` hata, `ExistingWorkPolicy.keep` → `ExistingPeriodicWorkPolicy.keep` |
| `tools/android_fix.sh` | Naya Flutter **Kotlin-DSL** (`build.gradle.kts`) template banata hai — script ab dono (KTS + purana Groovy) sambhalta hai. targetSdk **36**, compileSdk ≥ 36, minSdk ≥ 23, signing + proguard + desugaring KTS mein |
| `.github/workflows/build.yml` | `FLUTTER_VERSION` = **3.47.x**; naya input `accept_new_lockfile`; `pubspec-lock` artifact ab fail par bhi upload; iOS: Swift Package Manager band (CocoaPods raasta), deployment target 15.5 kisi bhi template se; purana "Bump Kotlin plugin" step hata (script karta hai); iOS privacy strings (pichla audit) |
| `.github/workflows/migration-tests.yml` | Flutter 3.47.x |

## ⚠️ Workflow files haath se lagani hongi
`Import zip` workflow `.github/` folder **import nahi karta** (bot ka token workflows nahi badal sakta). Is liye:
1. GitHub par repo kholein → `.github/workflows/build.yml` → ✏️ Edit → is zip wali `build.yml` ka poora text paste → Commit.
2. Yahi `migration-tests.yml` ke saath.
3. Phir zip import karein (baaki code).

## Pehla CI run (nayi pubspec.lock)
`pubspec.yaml` badla hai, is liye purani `pubspec.lock` match nahi karegi. Yahan Flutter nahi tha, lock CI hi banayegi:
1. Actions → **Build** → Run workflow → `accept_new_lockfile` ✅ tick → Run.
2. Run khatam hone par artifact **pubspec-lock** download → us ki `pubspec.lock` repo ke root mein commit (zip mein ya GitHub par upload).
3. Agla run normal (bina tick) — lock check phir se sakht.

Agar "Analyze + Test" fail ho to log ka error bhejein — naye Flutter ke deprecation zyada tar sirf *info* hain (CI unhein fail nahi karta).

## Device par zaroor check karein (Android 15/16 ke naye rules)
- **Edge-to-edge**: target 35+ par app status bar / neeche ki gesture bar ke peechay tak jati hai. Har screen ka neeche wala button (Save, Total bar) chhupa to nahi?
- **Tablet / bari screen** (Android 16): orientation lock aur "resize nahi" tablets par nazar-andaz hote hain — landscape mein Sale / Purchase screen theek dikhe.
- **Background sync** (`SyncKeepAlive`, dataSync foreground service): target 35+ par din mein ~6 ghante ki hadd. Lambe din ke baad bhi sync chale aur app crash na ho.
- **Back gesture** (predictive back): dialogs / unsaved bill par back dabane se data na jaye.
- **Backup worker** (workmanager 0.9): 12 PM / 9 PM checkpoint band app par bhi bane (Settings > Backup mein waqt).
- Bluetooth printer, Bill Scan (camera), contact picker, fingerprint login.

## Abhi jaan boojh kar nahi badla
- `flutter_contacts` 2.x, `share_plus` 11+, `local_auth` 3.x, `flutter_local_notifications` 18+: in ke naye major versions mein API badli hai; maujooda versions naye Flutter par chalne chahiyein. CI ya device par masla aaye to agla qadam.
- **applicationId `com.example...`** abhi bhi hai — Play Store ke liye badalna zaroori (dekhein `COMMERCIAL_AUDIT_2026-11-10.md` A1; id badalne se purani install update nahi hoti, backup/restore se data le jayein).
- Flutter 3.50 (November 2026) aane par Material ke purane imports deprecate honge — tab dobara dekhein.


## Fix: Device A ki payment sync nahi hui, edit karne par hui (2026-11-10)
**Wajah:** doosra device sirf wo docs pull karta hai jin ka `updatedAt` us ke checkpoint (−10 min) se naya ho. `updatedAt`
Device A ki clock se aur payment save hone ke waqt ka hota hai. A der se push kare (net nahi / app band) ya A ki clock
peeche ho, to doc "purana" lagta tha aur kabhi nahi aata. Iska bachao `pushedAt` wali doosri query hai — lekin wo
Firestore **index** maangti hai, aur index na ho to error **chupke se** nigal liya jata tha. Edit naya `updatedAt`
deta hai, isliye tab aa jati thi.

**Code fix:** payments / cash / sales / purchases / expenses ka pull overlap 10 min → 1 ghanta; `pushedAt` query fail ho
to Sync Now ke natije mein `warning: pushedAt index missing ...` dikhta hai.

**Aap ko karna hai:** `firebase deploy --only firestore:indexes` (repo ki `firebase/firestore.indexes.json`) — ya Console >
Firestore > Indexes mein har collection ke liye (`branchId` ↑, `pushedAt` ↑). Pehle se chhooti entries ke liye
Device B par Settings > Sync > **Resync from a date/time (pull)** — payment wale din se pehle ki tareekh.
