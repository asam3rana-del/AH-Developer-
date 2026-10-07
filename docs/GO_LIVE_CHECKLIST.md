# Go-live checklist — jo ho chuka hai

Aakhri update: 2026-10-07. "User" = dukaan wale ki apni device-testing; CI = GitHub Actions.

## 1. Build aur tests
| Item | Natija | Saboot |
|------|--------|--------|
| Flutter SDK se clean build | ✅ Pass | CI Build #213 (main, `fb5c296`) |
| `flutter analyze` | ✅ Pass | CI Build #213, job "Analyze + Test" |
| `flutter test` (sab tests) | ✅ Pass | CI Build #213, job "Analyze + Test" |
| Android release APK | ✅ Build hua | CI Build #213 |
| iOS (unsigned) aur Windows (exe) | ✅ Build hue | CI Build #213 |

## 2. Device par test (user)
| Item | Natija |
|------|--------|
| Multi-device sync (2 devices) | ✅ Sab kuch theek sync ho raha hai |
| Printer physical testing | ✅ Theek chal raha hai |
| Urdu print | ✅ Theek |
| PDF reports (Urdu) | ✅ Theek |

## 3. Features jo main mein shamil hain
| Feature | Halat |
|---------|-------|
| Month Close / Reopen (`period_closes`) | ✅ Code shamil. Sync `app_settings` key `month_close:<yyyy-MM>` se hota hai (nayi Firestore collection / rules nahi). Test: `test/month_close_sync_test.dart` |
| Default Sale + Quick Sale Unit screen | ✅ Code shamil. "Review" (ek ek) aur "All Products" (category chips, search, "Apply to shown"); sab badlav sync queue mein |

## Note
- CI Build #213 manually chala tha; is ke baad ke changes (Month Close, Unit screen) ke liye naya CI run chalana hoga.
- CI ki sirf "Node.js 20 is deprecated" warnings hain (workflow actions ki), app ki nahi.
