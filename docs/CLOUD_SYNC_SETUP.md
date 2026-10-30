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

## Production test (sab devices par)
- [ ] Device A par sale/purchase banayein → Device B par aa jaye (aur ulta)
- [ ] Dono devices par stock ka number ek jaisa
- [ ] Naya device jis ka `branch_members` document nahi — sync mein permission-denied aaye (ye sahi hai)
- [ ] Access rules (Manage Users → Access) badlen → dusre device par sync ke baad nazar aayen
