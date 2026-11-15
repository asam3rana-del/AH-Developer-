# AH Developer — Kiryana Store (Flutter)

IBTISAAM Kiryana Store: Android + iPad/iOS + Windows POS app (sirf Flutter).

## Folder structure
- `lib/` — Flutter app (screens, db, sync, backup, services, models, utils)
- `test/` — Dart tests (`*_test.dart`)
- `firebase/` — `firestore.rules` aur `firestore.indexes.json` (Firebase par deploy ke liye)
- `tools/android_fix.sh` — CI build mein Android native hissa (printer/USB channel, versions) lagata hai
- `docs/` — `APP_RULES.md` (roles, units, transactions), specs, go-live checklist
- `.github/workflows/build.yml` — analyze/test + iOS/Android/Windows builds

`android/`, `ios/`, `windows/` repo mein nahi hain; CI `flutter create` se banata hai.
