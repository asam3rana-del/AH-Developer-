# Go-live checklist — jo ho chuka hai

Aakhri update: 2026-10-07 (CI Build #215 tak). "User" = dukaan wale ki apni device-testing; CI = GitHub Actions.

## 1. Build aur tests
| Item | Natija | Saboot |
|------|--------|--------|
| Flutter SDK se clean build | ✅ Pass | CI Build #215 (main, `3f055ed`, manual) — pehle #213 (`fb5c296`) bhi pass |
| `flutter analyze` | ✅ Pass | Build #215, job "Analyze + Test" (2m 1s) |
| `flutter test` (sab tests) | ✅ Pass | Build #215, job "Analyze + Test" |
| Android release APK | ✅ Build hua | Build #215 (7m 45s) |
| iOS (unsigned) aur Windows (exe) | ✅ Build hue | Build #215 (18m 25s / 6m 10s) |
| Upload ke baad auto builds | ✅ Pass | Build #214 aur Import zip #99 (commit `a77542a`) |

## 2. Device par test (user)
| Item | Natija |
|------|--------|
| Multi-device sync (2 devices) | ✅ Sab kuch theek sync ho raha hai |
| Printer physical testing | ✅ Theek chal raha hai |
| Urdu print | ✅ Theek |
| Bill print (Urdu naam, hisaab, totals) | ✅ Theek — 07/10/2026 ki asli slip dekhi gayi |
| Lambi qty ("0.615 Qtr" / "9.091 Gram") | ✅ Fix shamil (qty column chaura, 2 lines tak) — user: print ok |
| PDF reports (Urdu) | ✅ Theek |

## 3. Features jo main mein shamil hain
| Feature | Halat |
|---------|-------|
| Default Sale + Quick Sale Unit screen | ✅ Code shamil. "Review" (ek ek) aur "All Products" (category chips, search, "Apply to shown"); sab badlav sync queue mein |
| Rate Search (cost) saaf kiya | ✅ Code shamil. Cost kholne par sirf Last Cost, Profit Margin (maujooda sale rate par) aur Purchase Rate History; Average Cost aur Supplier Comparison hata diye |

## Note
- Month Close feature app se hata diya gaya hai (user ke kehne par). Unit screen wale changes Build #215 mein hain (pass). Baaki release checks (update test, backup-restore, do devices par ek saath sale) abhi list mein nahi.
- CI ki sirf "Node.js 20 is deprecated" warnings hain (workflow actions ki), app ki nahi.
