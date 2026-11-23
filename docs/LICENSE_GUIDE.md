# Hanna POS — License guide (Hanna Solutions ke liye)

## Kaise kaam karta hai
- Har phone / PC ka apna **Device ID** hota hai (jaise `ABCD-EFGH-IJKL-MNOP`). Dukandar ko Settings › License (ya band hone par khud) nazar aata hai.
- Aap us Device ID ki **key** banate hain (`HP1-....`). Key sirf usi device par chalti hai, copy kar ke dusre par nahi.
- Key par aap ki private key ka digital signature hota hai — koi khud key nahi bana sakta, aur key mein tareekh badalne se wo bekaar ho jati hai.
- Internet ki zaroorat nahi. Internet mile to app aap ke Firebase se check karti hai (band karna / key bhejna) — optional.

| Halat | App |
|---|---|
| Naya install | **7 din muft trial** (`LicenseConfig.trialDays`) |
| Key active | Sab chalta hai. Aakhri 7 din upar peeli/laal patti |
| Trial / muddat khatam, ya aap ne band kiya | Login ke baad **sirf License screen** (Device ID, key, WhatsApp, admin/manager ke liye Backup, Logout) |
| Device ki tareekh peeche ki | Band — "tareekh theek karein" (muddat lambi karne se bachao) |

Purane (pehle se chal rahe) dukandar: update ke baad pehli dafa khulne se trial shuru hota hai — 7 din mein un ko key de dein.

Phone par Device ID app install se bandha hai: app **uninstall kar ke dobara** lagayein to Device ID badal jata hai — nayi key deni hogi. PC (Windows) par Device ID computer se bandha hai (reinstall par wahi).

## Ek dafa ki setup
1. **Private key** (alag file mein di gayi) ko GitHub repo › Settings › Secrets and variables › Actions › **New repository secret**: naam `HANNA_LICENSE_PRIVATE_KEY`, value = file wali PRIVATE line ki lambi value. Phir file phone/PC se mita dein. **Ye kisi ko na dein** — jis ke paas ye ho wo keys bana sakta hai.
2. `.github/workflows/license-key.yml` repo mein khud upload karein (Import-zip `.github` nahi daalta).
3. (Optional) `lib/license/license_config.dart` › `vendorWhatsApp` mein apna number (`923001234567`) — dukandar ka "WhatsApp par bhejein" seedha aap ko jaye.

## Key banana (phone se)
GitHub › **Actions** › **License key** › **Run workflow**:
- Device ID (dukandar ne bheja), Plan: `yearly` / `monthly` / `lifetime` / `days`, Amount (kitne saal / mahine / din), Gahak ka naam.
- Run khatam ho to us run ko kholein › **Summary** mein key — copy kar ke WhatsApp karein. Dukandar License screen mein paste › **ACTIVATE**.
- Renew: wohi Device ID, naya plan — nayi key purani ki jagah le leti hai. Muddat aaj se ginti hai.

PC se: `pip install cryptography` › `HANNA_LICENSE_PRIVATE_KEY=... python3 tools/license_tool.py issue --device ABCD-EFGH-IJKL-MNOP --plan yearly`
Key check: `python3 tools/license_tool.py show --key HP1-...`

## Online band / key bhejna (optional, aap ka APNA Firebase project)
1. console.firebase.google.com › naya project (jaise `hanna-licenses`) › Firestore Database banayein.
2. Firestore › Rules:
   ```
   rules_version = '2';
   service cloud.firestore {
     match /databases/{db}/documents {
       match /licenses/{id} {
         allow get: if true;          // app sirf apna doc parhti hai
         allow list, write: if false; // likhna sirf aap (Console se)
       }
     }
   }
   ```
3. Project settings › General: **Project ID** aur **Web API Key** — `lib/license/license_config.dart` mein `firebaseProjectId` / `firebaseApiKey` mein daal kar build.
4. Kisi device ko **band** karna: Firestore › collection `licenses` › document ID = Device ID **bina dash** (`ABCDEFGHIJKLMNOP`) › field `blocked` (boolean) = `true`. Dobara chalu: `false` (ya doc mita dein).
5. Key **internet se bhejna**: usi doc mein field `key` (string) = poori key — app internet milte hi khud activate kar leti hai.

App har 6 ghante (aur khulne par) check karti hai jab internet ho. Internet na ho to offline key jaisi hai waisi chalti hai.

## Ahem
- `lib/license/license_config.dart` ki `publicKeyB64` aap ki private key ka jora hai. Private key gum ho jaye ya leak ho: `python3 tools/license_tool.py keygen` se naya jora, public key yahan badlein, naya build — **purani saari keys bekaar**, sab ko nayi deni hongi.
- Trial ke din: `LicenseConfig.trialDays`. Yaad-dihani: `warnDays`.
