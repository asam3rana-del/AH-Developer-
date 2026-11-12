# Crash reports developer tak (2026-11-12)

**Crashlytics kyun nahi:** Crashlytics ko Android build mein Gradle plugin + build mein bandha google-services.json
chahiye. Ye app har dukaan ka Firebase project runtime par leti hai (Cloud Sync Setup), aur build ID ke baghair
Crashlytics app start par hi crash kar sakta hai — yani crash pakarne wala khud crash ki wajah. Is liye maujooda
CrashHandler (har crash ka stack trace phone par) ko do raste diye:

1. **Khud cloud par:** Cloud Sync juda ho to crash ke baad agli dafa app khulte hi text Firestore
   **`crash_reports`** mein (device, branch, waqt, app). Dekhne ke liye: Firebase Console → Firestore → crash_reports.
   Rules: sirf banana; branch_members wala device; apna uid; text ≤ 8000; app se koi parh / badal / mita nahi
   sakta. Ek crash ek hi dafa. Demo mode mein nahi.
2. **WhatsApp:** "App crashed last time" dialog mein naya **Send to developer** → support number (app_info) par.

**Rules deploy zaroori:** `bash /sdcard/Download/deploy_rules_live.sh` (nayi file — crash_reports block dono rules
mein, roles + rollback). Pehle GitHub → Firebase rules test chalayein (naya test bhi hai).

Files: `lib/services/crash_reporter.dart` (naya), `lib/screens/dashboard_screen.dart`,
`firebase/firestore.device-roles.rules`, `firebase/firestore.rules`, `firebase/rules-tests/device_roles.test.js`,
`tools/deploy_rules_live.sh`. Test: `test/crash_reporter_test.dart`.
