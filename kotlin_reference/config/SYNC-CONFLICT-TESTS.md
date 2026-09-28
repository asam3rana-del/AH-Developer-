# Multi-device sync test script (manual QA)

Ye P4 ka detailed, step-by-step version hai — pehle wala 9-line matrix ab har
scenario ke liye exact steps, expected result, aur edge cases ke sath expand
kiya gaya hai. Isay khud ya kisi tester ko seedha follow karke run kiya ja
sakta hai. Automated nahi hai (real/emulator devices + live Firebase project
chahiye — dekho TESTS-README.md ke "Agla step" section, P9 ka androidTest
half is se alag cheez hai).

## Prerequisites (ek dafa setup)

1. Do devices (A aur B) — do real phones ya ek real + ek emulator, dono par
   app install.
2. Dono par **same Firebase project** (Settings > Cloud Sync Setup mein same
   `google-services.json` / custom project) aur **same Branch Code** save
   karo. Dono device IDs (`SyncApi.currentUid`) Firebase console ke
   `branch_members/{uid}` mein add hone chahiye (warna sab kuch
   `PERMISSION_DENIED` dega — scenario 0 dekho).
3. Har scenario se pehle: Settings > Sync History khali/samajh mein aane
   wali state par hai, dono devices ka clock sahi hai (system time — Firestore
   ke `updatedAt` comparisons ise use karte hain, ghalat clock false
   conflict/false winner de sakta hai).
4. "Sync" = Settings ya jahan bhi manual "Sync Now" button hai wahan tap
   karna, ya 15 min tak periodic WorkManager run ka intezar (manual tap se
   test tez hota hai).

## Scenario 0 — Sanity: dono devices online, permission check

1. A aur B dono online hain, dono Branch Code save kiya hua hai.
2. A par koi bhi chhota edit karo (e.g. ek expense add karo) aur Sync Now tap
   karo.
3. B par Sync Now tap karo.
4. **Expected:** B ka Settings > Sync History mein koi `sync_push_failed`
   ya "permission denied" wala Audit entry nahi hai. Expense B par dikh raha
   hai.
5. Agar `PERMISSION_DENIED` aaye: rukiye, pehle Firebase console mein dono
   `branch_members/{uid}` docs check karo — baqi sab scenarios isi par
   depend karte hain.

## Scenario 1 — Product create, online, dono taraf

1. A par: Products > Add Product. Naya barcode, naam, category, sale price,
   wholesale price, aur teeno units (Carton/Box/Pcs jaisi 3-tier ladder,
   ya jitne tiers set ho) bharo. Save karo.
2. A online hai — Sync khud trigger hoga (`enqueueProduct` context ke sath
   call hota hai). Confirm karne ke liye A par Sync Now bhi tap karo.
3. B par Sync Now tap karo.
4. **Expected on B:** Product list mein wahi barcode dikhta hai, name/
   category/salePrice/wholesalePrice match karte hain, aur teeno unit
   fields (unit, unitSize, unitNote, secondaryUnit/Qty, tertiaryUnit/Qty)
   bilkul same hain jaise A par set kiye the.
5. **Not expected:** Stock field is step mein kuch bhi nahi hona chahiye —
   agar opening stock diya tha, wo scenario 3 ki tarah delta se aayega, is
   liye stock 0 dikhna is step ke liye normal hai jab tak koi purchase/
   opening-stock entry na ho.

## Scenario 2 — Stock: dono offline, dono ek hi product bechte/khareedte hain

1. A aur B dono ko is product ka sync ho chuka ho (scenario 1 se), stock
   maan lo abhi 10 hai (dono par).
2. **Dono devices ko Airplane Mode / WiFi off karo** (asal offline, sirf
   "sync na dabana" nahi).
3. A par: is product ki 2 units bechdo (Sale banao, save karo).
4. B par: isi product ki 5 units khareedo (Purchase banao, save karo).
5. Dono devices ka local stock is waqt alag-alag dikhna chahiye: A par 8,
   B par 15 (dono apne khud ke offline change ke sath).
6. **Dono ko wapas online karo**, phir dono par baari-baari Sync Now tap
   karo (pehle A, phir B, phir A dobara taake dono taraf ka data mil jaye).
7. **Expected:** Dono devices par final stock = 10 - 2 + 5 = **13**.
8. Yahi is fix ki wajah hai ke `increment_stock` Firestore
   `FieldValue.increment()` use karta hai (snapshot nahi) — agar kabhi
   stock 8 ya 15 par atak jaye (kisi ek device ka change lost ho jaye), ye
   regression hai.
9. **Edge case — retry/backoff:** Step 6 mein A ko sync karte waqt beech
   mein WiFi wapas off kar do (partial network drop simulate karne ke
   liye). `SyncWorker` ka agla scheduled run (ya agla manual Sync Now)
   isi queued `increment_stock` row ko dobara push karega — WorkManager
   khud retry/backoff handle karta hai, `sync_queue` row tab tak nahi
   hatai jati jab tak push successful na ho. Verify: is row ko do dafa
   apply hone se stock double na ho (ek hi entry ek hi baar apply hoti hai,
   chahe push mein kitni bhi der lage).

## Scenario 3 — Customer balance: dono offline, dono ek hi customer ka balance badalte hain

1. Ek customer chuno jiska balance dono devices par sync ho chuka hai
   (maan lo 1000).
2. Dono devices offline karo.
3. A par: is customer ko ek credit sale do (jaise 300 ka udhaar sale) —
   balance A par locally 1300 ho jayega.
4. B par: isi customer se ek payment receive karo (jaise 200 wapas liya) —
   balance B par locally 800 ho jayega.
5. Dono online karo, dono par baari-baari Sync Now.
6. **Expected:** Dono devices par final balance = 1000 + 300 - 200 =
   **1100**. Na 1300 rehna chahiye na 800 — dono deltas preserve hone
   chahiye, koi bhi snapshot dusre ko overwrite na kare
   (`customerJson()` mein `balance` field hi shamil nahi hai, is liye ye
   guaranteed hai jab tak koi purana/reverted build na chal raha ho).
7. Settings > Sync History mein `sync_conflict` entry **nahi** aani
   chahiye is scenario ke liye (balance conflict nahi hai, do independent
   deltas hain) — `sync_conflict` sirf name/phone jaisi full-snapshot
   field ke liye aata hai (scenario 7 dekho).

## Scenario 4 — Expense create → sync → delete → sync

1. A par ek expense add karo. A online, Sync Now.
2. B par Sync Now — expense B par dikhna chahiye.
3. A par wahi expense delete karo. A par Sync Now.
4. B par Sync Now dobara.
5. **Expected:** Expense B se gayab ho jata hai.
6. Ye tombstone (`_deleted: true` + `updatedAt`) ke zariye hota hai, hard
   delete nahi — is liye step 3 aur 4 ke beech B ka pull agar beech mein
   ho jaye (delete se pehle), phir dobara pull karne par bhi delete
   correctly apply hoga (kyunke tombstone doc `updatedAt` ke sath rehta
   hai, khtm nahi hota).

## Scenario 5 — Sale/Purchase delete → tombstone → items bhi gayab

1. A par ek sale banao (2-3 items ke sath), Sync Now, B par Sync Now —
   confirm karo sale + uske items B par (SaleHistory/Reports mein) sahi
   dikh rahe hain.
2. A par wahi sale delete karo (History se "Delete/Void"). A par Sync Now.
3. B par Sync Now.
4. **Expected on B:** Sale record khud aur uske sab sale_items dono gayab
   ho jate hain (`applyServerChanges` ka sales loop `_deleted` par pehle
   `saleDao.deleteItems(invoice)` phir `saleDao.deleteSale(invoice)` call
   karta hai — agar sirf sale gayab ho par orphan items reh jayein, ye bug
   hai). Purchase ke liye same check billNo ke sath.
5. **Edge case:** Agar delete se pehle B ne stock already apne taraf se
   is sale ki wajah se decrement kiya tha (increment_stock queue se), wo
   stock change is delete se automatically wapas nahi aata — sale delete
   sirf record hata deta hai, koi reverse `increment_stock` khud nahi
   bhejta. (Ye current design hai — agar app "delete sale = restore
   stock" karta hai to wo alag se ek forward-compensating
   `increaseProductStock()` call ke zariye hota hoga; check karo ke wo
   call bhi dono devices tak sync hua ya sirf A par local reh gaya.)

## Scenario 6 — Timestamp-winner: dono offline, same product ka price A aur B dono par badalte hain

1. Product X ka sale price dono devices par sync state mein same hai
   (maan lo 100).
2. Dono offline karo.
3. A par price 120 kar do (thoda ruk kar — is se A ka `updatedAt`
   timestamp thoda pehle lock hota hai).
4. Kuch second baad B par price 150 kar do (B ka `updatedAt` A se baad ka
   hai).
5. Dono online karo. Pehle **A ko sync** karo, phir **B ko sync** karo.
6. **Expected:** Final price sab jagah **150** hai (jis device ka
   `updatedAt` sabse baad ka tha, wahi winner) — ek endless ping-pong
   nahi (A ka push B ke naye value ko wapas 120 par nahi le jata).
7. Settings > Sync History mein ek **`sync_conflict`** Audit entry dikhni
   chahiye us device par jiska push reject hua (jis timestamp jyada
   purana tha) — details mein dono values (local vs cloud) mention honi
   chahiyein.
8. **Retry order variation:** Wahi test dobara karo lekin ulta order mein
   sync karo (pehle B, phir A) — result same rehna chahiye: **150 hi jeete
   ga**, kyunke winner push-order par nahi, `updatedAt` value par depend
   karta hai (Firestore transaction `incomingUpdatedAt >= serverUpdatedAt`
   check karta hai, chahe push kisi bhi order mein aaye).
9. **Edge case — clock skew:** Agar B ka device clock A se peeche hai
   (galat system time), B ka "baad mein kiya gaya" edit bhi purana
   timestamp carry kar sakta hai aur galat tarah se haar sakta hai — is
   liye Prerequisites mein clock check zaroori hai. Ye ek known limitation
   hai (last-write-wins purely `updatedAt` field par based hai), bug
   nahi.

## Scenario 7 — Name/phone conflict par sync_conflict Audit log

1. Customer Y dono devices par sync hai.
2. Dono offline. A par customer ka naam change karo ("Ali" → "Ali Khan").
3. Pehle A ko online karke Sync Now karo (naya naam cloud par chala jata
   hai).
4. Is dauran B abhi bhi offline hai — B par isi customer ka **koi alag
   phone number** edit karo (offline), taake B ka local row `dirty=true`
   ho jaye is customer ke liye.
5. B ko online karke Sync Now karo.
6. **Expected:** B ka local `dirty` flag set tha aur naam/phone A ke
   pulled snapshot se mismatch tha, is liye Settings > Sync History mein
   ek `sync_conflict` Audit row aati hai jisme B ka purana (overwritten)
   naam/phone aur naya cloud wala naam/phone dono likhe hote hain
   (`applyServerChanges`'s customer loop). Final data wahi hota hai jo
   server se aya (cloud snapshot hamesha overwrite karta hai jab bhi B
   pull karta hai — is field ke liye delta-merge nahi, balance jaisa nahi
   hai) — matlab B ka apna phone-number edit bhi is overwrite mein kho
   jata hai.
7. Same test supplier ke liye aur product ke name/salePrice ke liye bhi
   dohrao (dono ka apna `sync_conflict` audit path hai).

## Scenario 8 — Password reset A par, B par asar nahi

1. A par User Management se kisi user ka password reset karo.
2. A par Sync Now.
3. B par Sync Now.
4. **Expected:** B par us user ka login password **badla hua nahi** hai —
   naya password sirf A par kaam karta hai. Firebase console mein
   `users/{serverId}` document kholo — `passwordHash` field ka wahan naam
   tak nahi hona chahiye (`userJson()` deliberately isay exclude karta
   hai).
5. Yahi wajah hai ke `applyServerChanges`'s users loop mein naye user ke
   liye ek random UUID se hash generate hota hai jab wo pehli baar kisi
   dusre device par pull hota hai — us random hash se koi bhi login nahi
   kar sakta jab tak wahi device khud apna password set/reset na kare.

## Scenario 9 — OTP phone linking: password bhi mangna chahiye

1. Sirf ek hi active user ho app mein (ya test ke liye ek fresh install
   par sirf default admin).
2. Login screen par "OTP" method chuno, apna phone number daal kar
   "SEND OTP" karo, code aane par verify karo.
3. Agar ye phone number kisi existing user se pehle se link nahi hai
   (aur app mein sirf ek hi active user hai): **Expected** — app seedha
   login complete nahi karta. Ek dialog aata hai jo us (sole) user ka
   **current account password** manga ta hai, tabhi phone us user se
   link hota hai aur login complete hota hai.
4. Ghalat password dalne par: link nahi hota, login fail hota hai.
5. Sahi password dalne par: phone ab is user se linked hai — agli baar
   seedha OTP se login ho jata hai, password dobara nahi manga jata
   (`db.userDao().findByPhone(phone)` ab match kar jata hai).
6. **Not acceptable (security regression agar aisa ho):** Sirf OTP verify
   hote hi, bina password maange, koi bhi arbitrary naya phone number
   sole admin account se automatically link ho jaye — ye wahi bug hai jo
   pehle fix kiya gaya tha (dekho `LoginActivity.verifyAndLogin`'s
   "SECURITY FIX" comment); agar test isay reproduce kare to ye regression
   hai.

## Har scenario ke baad check karne ki cheezein (checklist)

- [ ] Settings > Sync History mein koi unexpected `sync_push_failed` nahi.
- [ ] Dono devices ka final data (stock/balance/name/price) ek dusre se
      match karta hai.
- [ ] Jahan `sync_conflict` expected tha, wahan Audit entry maujood hai
      aur uski details sahi (dono values) dikha rahi hain.
- [ ] Firebase console mein jaake concerned document manually dekho —
      `stock`/`balance` field wahan Number hai (Increment ke baad kabhi
      `NaN`/missing nahi hona chahiye).
- [ ] Koi bhi passwordHash Firestore documents mein kahin nahi dikhta.
