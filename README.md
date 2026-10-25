# Hanna Solutions — Kiryana Store (Flutter)

IBTISAAM Kiryana Store ka POS: Android + iPad/iOS + Windows, sirf Flutter. Kotlin se port poora ho chuka hai (100%); ab Flutter code hi asal source hai.

## Folder structure
- `lib/` — app (screens, db, sync, backup, services, models, utils, widgets, theme)
- `test/` — Dart tests (`*_test.dart`)
- `firebase/` — `firestore.rules` aur `firestore.indexes.json` (Firebase Console se deploy)
- `tools/` — `android_fix.sh` (CI mein Android native hissa: printer/USB channel, Kotlin/AGP/Gradle versions, signing), `import_zip.sh`, `check_root.sh`, `port_status.py`
- `docs/` — `APP_RULES.md` (roles, units, transactions), `GO_LIVE_CHECKLIST.md`, specs
- `.github/workflows/` — `build.yml` (analyze/test + iOS/Android/Windows), `import-zip.yml`

`android/`, `ios/`, `windows/` repo mein nahi hain; CI `flutter create` se banata hai.

## Build (GitHub Actions)
- `Build` workflow har push par chalta hai (sirf `.md` / `docs/` badalne par nahi). Naya push aane par purani chalti run cancel ho jati hai.
- Flutter ka version `build.yml` ke `FLUTTER_VERSION` mein ek hi jagah hai (abhi 3.24.0). Naya version aazmane ke liye Actions > Build > Run workflow mein `flutter_version` likhein (e.g. 3.47.2) — repo mein kuch badalna nahi parta. Naye Flutter par `tools/android_fix.sh` ke Kotlin/AGP/Gradle/compileSdk fixes dobara check karne parte hain.
- Android APK ke liye secrets: `KEYSTORE_BASE64`, `KEYSTORE_PASSWORD`, `KEY_PASSWORD` (fixed signing key, taake update ho sake).
- `pubspec.lock` repo mein nahi, is liye `flutter pub get` har build par `pubspec.yaml` ke caret ranges ke andar sab se naye packages uthata hai.

## Code zip se update karna
Zip mein exactly ek wrapper folder (`AH-Developer--main/`) hona chahiye; repo root par `.zip` daalein to `import-zip.yml` unzip karke files add/overwrite karta hai (delete nahi karta, aur `.github/` ko haath nahi lagata — workflow files GitHub par haath se badalni hongi). Phir `Build` workflow haath se chalayein.

## Checks (local)
`flutter analyze && flutter test`, aur `bash tools/check_root.sh` (root par faltu cheezein pakadta hai).
