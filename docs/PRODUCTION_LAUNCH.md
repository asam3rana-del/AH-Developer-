# Production launch guide (Play Store) — 2026-11-10

Code mein jo ho sakta tha wo ho chuka hai (dekhein `COMMERCIAL_AUDIT_2026-11-10.md`, `UPGRADE_FLUTTER_3_47.md`).
Ye file un kaamon ki hai jo **aap** (Play Console / Firebase / dukaan) karenge, tarteeb se.

## 1. Keystore — sab se pehle
- `ahkey` wala keystore (`KEYSTORE_BASE64` secret ki asal file) aur dono passwords **do alag jagah** rakhein
  (e.g. Google Drive ka private folder + USB). Ye kho gaya to maujooda installs ko kabhi update nahi kar sakenge.
- Play Console par **Play App Signing** on rahne dein (default). Phir CI wali key sirf "upload key" hai; kho jaye
  to Google se reset ho sakti hai.

## 2. App ID — ✅ faisla: `com.hannasolutions.pos` (2026-11-10)
Pehle: `com.example.ah_developer_kiryana_store`. Ab CI har build mein Android `applicationId` aur iOS bundle id
`com.hannasolutions.pos` rakhta hai (`tools/android_fix.sh` ka `APP_ID`, `build.yml` ka iOS step). Ise **kabhi na badlein**.
(Code ka andar wala package / `namespace` wahi purana hai — us se users ko koi farq nahi.)

⚠️ Ye **nayi app** hai: purani "com.example" app ke upar update nahi hogi, phone par dono alag dikhengi. Har dukaan par:
1. **Purani** app: Sync Now → **Backup Now** → backup file phone se bahar bhi copy (WhatsApp / Drive).
2. **Nayi** app install → pehli dafa khulne par Settings → Backup / Restore → wo backup **restore** (password wahi).
3. Data check: customer balances, aaj ki sales, cash register, stock.
4. Nayi app mein Settings → Cloud Sync Setup dobara (google-services.json paste + branch code) → Sync Now.
   Firestore `branch_members/{uid}`: nayi app ka anonymous UID naya hoga — Firebase Console mein us UID ka
   `branch_members` doc banayein (purane device ki tarah), warna sync par permission-denied.
5. Sab theek ho to **purani app uninstall**.

**Firebase:** Console → Project settings → Add app → Android → package `com.hannasolutions.pos` + SHA-1 / SHA-256
(Play Console → App integrity → App signing aur Upload key dono). Phone OTP login, App Check isi ke baad chalenge.

## 3. Play Console
- Upload: CI artifact **android-aab** (`app-release.aab`) — APK nahi.
- **Privacy policy URL** (neeche ka draft kisi public page par: GitHub Pages / apni website).
- **Data safety** form (neeche jawab).
- **Permissions declaration**: Foreground service (dataSync) — wajah: "offline POS data ko cloud se sync rakhna
  jab app minimize ho"; short video maang sakte hain.
- Content rating questionnaire, target audience (18+ / business), app category: Business.
- Pehle **Internal testing** track → 2-3 din dukaan par → phir Production.

## 4. Data safety — jawab (draft, apne hisaab se check karein)
| Sawal | Jawab |
|-------|-------|
| Data collect / share? | Collect: haan (sirf app ke kaam ke liye). Share with third parties: **nahi** |
| Encrypted in transit | Haan (Firebase HTTPS) |
| User data delete karwa sakta hai | Haan (dukaan malik se rabta / app mein record delete) |
| Personal info | Naam, phone number (customers/suppliers/staff) — App functionality |
| Financial info | Sales, payments, balances (dukaan ka hisaab) — App functionality |
| Contacts | Sirf jab user contact chunta hai, sirf wo naam/number party mein save — App functionality |
| Photos | Bill scan: tasveer device par hi OCR hoti hai, upload nahi; party photo device par — App functionality |
| Ads / analytics | Koi nahi |

## 5. Privacy policy — draft
> **[Business ka naam] — Privacy Policy** (Hanna Solutions POS app)
> Aakhri tabdeeli: [tareekh]
>
> Ye app dukaan ka hisaab (sales, purchases, payments, stock, customers, staff) rakhne ke liye hai.
>
> **Kya data:** aap jo khud darj karte hain — customers / suppliers / staff ke naam aur phone numbers, bills,
> payments, stock, kharche. Staff login ke liye username aur password (password sirf hash shakl mein).
>
> **Kahan rehta hai:** sab se pehle aap ke device par. Agar dukaan malik cloud sync on kare to dukaan ke apne
> Google Firebase project mein (Google Cloud, encrypted connection). Backup files password se encrypted (AES-256).
>
> **Permissions:** Camera (bill scan — tasveer device par hi parhi jati hai), Contacts (sirf jab aap number
> chunein), Bluetooth / network (bill printer), Notifications (wasooli / bill reminders), fingerprint (login).
>
> **Share:** hum data kisi ko bechte ya share nahi karte. Koi ads ya tracking nahi.
>
> **Delete:** record app mein delete kar sakte hain; poora data hatwane ke liye: [email / phone].
>
> **Rabta:** [email], [phone], [address].

## 6. Launch se pehle aakhri checklist
- [ ] CI Build: Analyze + Test, Android (APK + AAB), Windows green; iOS (Xcode 26) green ya iPad abhi nahi
- [ ] Dukaan ke phone par nayi APK purani ke upar: data salamat, sale/payment/sync theek
- [ ] Firestore indexes deploy (`firebase deploy --only firestore:indexes`) — payment sync fix ke liye zaroori
- [ ] Opening cash/bank aur customer/supplier opening balances asli
- [ ] Stock audit (ginti) ek dafa
- [ ] 1-2 hafte purane system ke saath parallel hisaab
- [ ] Keystore backup (upar #1)
