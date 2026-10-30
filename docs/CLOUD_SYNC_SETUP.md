# Cloud sync — har device ko branch access dena (production)

Firebase rules (`firebase/firestore.rules`) har device ko sirf us ki apni branch ka data dene dete hain. Iske liye har device ki
signed-in UID ka ek document `branch_members/{uid}` hona zaroori hai. Ye document app se nahi bante (rules clients ko likhne nahi
dete) — Firebase console se banane hain. Agar ye na ho to sync "permission-denied" deta hai.

## Har naye device ke liye (ek martaba)
1. Us device par app mein **Settings → Cloud Sync Setup** kholen, Firebase ki values aur **Branch Code** daal kar **Save** karein.
2. Dialog mein **Device ID** dikhegi (ye Firebase UID hai; pehli sync koshish ke baad aati hai). Isko copy karein.
3. Firebase console → **Firestore Database** → collection `branch_members` → **Add document**:
   - Document ID = copy ki hui Device ID (UID)
   - Field `branchId` (string) = wahi Branch Code jo device mein likha hai (jaise `main`)
4. Device par dobara sync chalayen. Dono (ya sab) devices ka **Branch Code bilkul ek jaisa** hona chahiye, warna data alag branch mein jayega.

## Rules deploy karna
- `firebase/firestore.rules` ko Firebase console (Firestore → Rules) mein publish karein, ya `firebase deploy --only firestore:rules`.
- Rules deploy karne se **pehle** sab devices ke `branch_members/{uid}` documents bana lein, warna sab devices ki sync ruk jayegi.

## Hamara setup (single branch, 3 devices)
- **Branch Code:** `dusri-branch` (sirf ek hi branch hai). Teeno devices par **bilkul yahi** likha ho: chhote harf, hyphen ke saath,
  koi space nahi. Zara sa farq hua to us device ka data alag branch mein jayega.
- **Teeno devices** ka `branch_members/{uid}` document Firebase console mein bana hua hai
  (ID = us device ki Device ID / Firebase UID, field `branchId` = `dusri-branch`).
- **Rules:** repo wali `firebase/firestore.rules` hi live honi chahiye. Ye `branch_members/{uid}` se branch check karti hai.
  `isMyBranch()` mein branch ka naam hardcode (jaise `branchId == "dusri-branch"`) **nahi** karna: app anonymous sign-in
  use karti hai, to hardcoded rules mein API key wala koi bhi bahar wala data parh/likh sakta hai.
- **Sync ka rasta (teeno cheezein ek saath zaroori):**
  1. Device ki Firebase anonymous UID (`signInAnonymously`)
  2. `branch_members/{uid}.branchId` == device ka Branch Code
  3. Rules (`isMyBranch`) ka `branch_members` se match
  Inmein se koi ek toote to sync `permission-denied` deta hai.
- **Kya sync hota hai:** sales, purchases, payments, customers/suppliers ke balances, products aur stock, expenses,
  cash transactions, returns, stock movements, workers, rents, utility bills, zakat, users aur settings
  (poori list rules ke `isSyncedCollection()` mein hai). Stock aur balance **delta** (increment) ke tor par jate hain,
  is liye do devices ek hi cheez badlen to koi entry khoti nahi.

## Dhyan rakhein (kab dobara document banana parta hai)
- App uninstall, "Clear data", ya naya phone: **naya anonymous UID** banta hai. Naye UID ka `branch_members` document
  dobara banayein, warna us device ki sync `permission-denied` degi.
- Naya (4th) device: upar wale "Har naye device ke liye" steps, Branch Code `dusri-branch`.
- Purane Firestore docs jin mein `branchId` field nahi, woh rules ke tahat update/delete nahi ho sakte.
- Rules badalne se pehle purane rules kahin copy kar ke rakhein, taake zaroorat par wapas paste ho sakein.

## Production test (sab devices par)
- [ ] Device A par sale/purchase banayein → Device B par aa jaye (aur ulta)
- [ ] Dono devices par stock ka number ek jaisa
- [ ] Naya device jis ka `branch_members` document nahi — sync mein permission-denied aaye (ye sahi hai)
- [ ] Access rules (Manage Users → Access) badlen → dusre device par sync ke baad nazar aayen
