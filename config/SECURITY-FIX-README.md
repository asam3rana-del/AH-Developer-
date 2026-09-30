# Security Fix — Keystore Removal (kya kiya gaya aur ab kya karna hai)

## Maine kya kiya
1. `.gitignore` add ki — ab keystores, `local.properties`, `build/` folders waghera
   kabhi bhi accidentally commit nahi honge.
2. `release.keystore` aur `keystore_b64.txt` is copy se **delete** kar diye —
   ye dono mein aapki asli release-signing private key thi.

## Aapko ab ye 3 kaam karne hain (zaroori)

### 1. Naya keystore banayein
Purani keystore ko compromised samjhein (agar kabhi GitHub par gayi thi). Nayi
banayein:
```
keytool -genkey -v -keystore release.keystore -alias ibtisaam \
  -keyalg RSA -keysize 2048 -validity 10000
```
`release-signing-setup.md` mein diye gaye steps follow karein (already sahi
likhe hain — GitHub Secrets mein `RELEASE_KEYSTORE_BASE64`,
`RELEASE_STORE_PASSWORD`, `RELEASE_KEY_ALIAS`, `RELEASE_KEY_PASSWORD` set
karein).

### 2. Firebase mein naya SHA-1/SHA-256 fingerprint add karein
Naya keystore = naya fingerprint. Purana fingerprint Firebase console se
**remove** kar dein (Project Settings → Your app → SHA fingerprints), warna
purani (compromised) keystore se signed koi bhi fake APK bhi OTP login use kar
paayega.

### 3. Agar ye repo pehle se GitHub par push ho chuki hai — history saaf karein
Sirf naye commit mein file delete karna kaafi nahi (purani commit history mein
keystore ab bhi milegi). Apne local machine par (jahan asli `.git` folder hai)
ye chalayein:
```
# git-filter-repo (recommended) — ya BFG Repo-Cleaner
pip install git-filter-repo
git filter-repo --path release.keystore --path keystore_b64.txt --invert-paths
git push origin --force --all
```
Phir Firebase mein wahi step-2 wala fingerprint update zaroor karein.

**Note:** `google-services.json` ko maine delete nahi kiya (app build ke liye
chahiye, aur Google isko public rakhna generally safe manta hai kyunke asli
security Firestore rules + API key restrictions se aati hai — jo aapki
`firestore.rules` mein already sahi lagi). Phir bhi behtar hai isko repo se
gitignore rakhein aur CI secret se inject karein — filhal maine sirf
`.gitignore` mein add kar diya hai taake future commits mein na jaye.
