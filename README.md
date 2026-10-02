# AH Developer — Kiryana Store (Flutter)

IBTISAAM Kiryana Store Android (Kotlin) app ka Flutter port: Android + iPad/iOS + Windows POS.

## Folder structure
- `lib/` — Flutter app (screens, db, sync, backup, services, models, utils)
- `test/` — Dart tests (`*_test.dart` sirf; `.kt` files yahan nahi)
- `kotlin_reference/` — asal Android Kotlin source, **read-only reference** (Kotlin ka sirf yahi ek ghar hai)
- `tools/` — `port_status.py`, `port_map.json`, `android_fix.sh`, `check_root.sh`
- `docs/` — specs
- `.github/workflows/` — `build.yml` (analyze/test + iOS/Android/Windows builds), `import-zip.yml`
- `PORTING_PLAN.md`, `PORT_STATUS.md`, `ANDROID_CHANGELOG.md` — porting plan, progress, Android tabdeeliyan

`android/`, `ios/`, `windows/` repo mein nahi hain; CI `flutter create` se banata hai.

## Root clean rakhna
Root par `main/`, `config/`, `androidTest/` ya `.kt` files nahi honi chahiye.
Check: `bash tools/check_root.sh` — Fix: `bash tools/check_root.sh --fix`.
Import zip ke waqt yeh khud chalta hai; build ko kabhi nahi rokta.
