# Hanna POS — customers ko update (app ke andar)

Hanna Installment wala hi tareeqa (`lib/services/app_update.dart`). App har 6 ghante mein ek dafa (internet ho to)
public file dekhti hai: `https://raw.githubusercontent.com/asam3rana-del/hanna-updates/main/hanna-pos.json`
(`AppInfo.updateUrl`). Hanna Installment ki `update.json` **alag** file hai — dono ek hi `hanna-updates` repo mein.

Naya build ho to Dashboard par "Naya update aa gaya hai":
- **Mobile:** APK app ke andar download (progress + notification), phir Android ka "Update" parda. Purani app ke upar
  install = data aur license wahi. Download ke dauran back dabane se app band nahi hoti, sirf peeche jati hai.
- **PC (Windows):** `Hanna-POS-Setup.exe` khud download, SHA-256 milati hai, chup chaap install
  (purani app band, nayi lag kar khud khulti hai). Data (AppData) aur license wahi.
- Haath se: Settings › About card › **Check for update**.

## Ek dafa (setup)
1. `hanna-updates` public repo pehle se hai (Hanna Installment wala). Is mein sirf JSON aur APK/Setup — koi code / key nahi.
2. GitHub > Settings (profile) > Developer settings > Personal access tokens > **Fine-grained tokens** > Generate new token.
   Repository access: **Only select repositories > hanna-updates**. Permissions > Repository > **Contents: Read and write**.
   (Installment ke liye jo token banaya tha wahi bhi chal jata hai.)
3. AH-Developer repo > Settings > Secrets and variables > Actions > New repository secret: `UPDATES_TOKEN` = token.

## Har update
Actions > **Build** > Run workflow > **publish_update** tick + **update_notes** (kya naya hai) > Run.
Android + Windows green hone par:
- `hanna-updates` mein release **`pos-build-<run>`** (`app-release.apk` + `Hanna-POS-Setup.exe`)
- `hanna-pos.json` mein naya build, links, sha256, notes — 6 ghante ke andar sab apps ko dialog.

Pehle naya build apne phone / PC par test karein, phir tick wala run chalayein.

## Zaroori update
`hanna-pos.json` mein `"min_build": 31` — 31 se purani app par dialog band nahi hota. Aam taur par 0.

## Hifazat
- Sirf `https://` link. PC Setup ka SHA-256 na mile to install nahi hota.
- Android sirf usi keystore wali APK ko update maanta hai (secrets `KEYSTORE_*` hamesha wahi rakhein).
- `build` = CI ka run number (`--dart-define=APP_BUILD`, build.yml). Local build (0) par auto check band.

---

# PC (Windows) par Cloud Sync — REST (Hanna Installment wala fix)

Windows par Firebase ka C++ (Firestore) SDK sync ke dauran app gira deta tha (crash `0xe06d7363`, KERNELBASE.dll).
Ab PC par wo SDK bilkul shuru nahi hota; sync **REST** se hoti hai (`lib/sync/firestore_rest.dart`,
`lib/sync/sync_api_rest.dart`) — mobile jaisa hi data / faisle (last-write-wins, tombstone, stock increments).

PC ko jorne ke liye:
1. PC par Settings › Cloud Sync Setup: wahi Firebase project + Branch Code jo mobile par hai. Save.
2. Firebase Console › Authentication › Sign-in method › **Anonymous** ON hona chahiye.
3. Wahan PC ki **Device ID** nazar aayegi — Firestore › `branch_members` mein us ID se document (mobile jaisa, `branchId`, `role`).
4. Sync Now.

Aur:
- Sync se pehle ghadi check (`lib/sync/clock_check.dart`): device ki tareekh/waqt 1 ghante se zyada ghalat ho to sync rukti hai
  aur saaf paigham aata hai (ghalat waqt wale records doosre devices ka hisaab kharab karte the).
- Heartbeat (`branch_sync/{branchId}`): kuch naya na ho to poori pull nahi — Firestore ki daily reads bachti hain.
  `firebase/firestore.rules` (aur device-roles rules) dobara publish karein; na karein to bhi sync chalti hai (poori pull).
- PC par "Staff cloud login" (secure staff mode) nahi — OFF rakhein.
