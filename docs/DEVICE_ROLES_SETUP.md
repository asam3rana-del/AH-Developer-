# Device roles — bina Cloud Functions / bina card ke

Cloud Functions ke liye Firebase **Blaze** plan (card) chahiye. Ye raasta sirf **Firestore rules** use karta hai, jo free Spark plan par chalte hain.

## Idea
Har device ka `branch_members/{uid}` document pehle se hai (branch ke liye). Us mein ek **optional `role`** field (`admin`, `manager`, `cashier`) Firebase Console se likhein. `firebase/firestore.device-roles.rules` us role ko server par force karta hai.

- `role` **na ho** (ya `admin` / `manager`) = bilkul aaj jaisa, poori access. Isliye rollout mein koi purana device nahi tootta.
- `role = cashier`:
  - sirf till ki collections **padh** sakta hai (customers, products, sales, payments, expenses, cash, units, categories, returns, stock movements, settings, shell, due follow-ups). `users` (password hashes), suppliers, purchases, payroll, rent, utility bills, zakat **nahi**.
  - sale / payment / expense / cash / return / stock movement / customer / cash register / follow-up **bana aur badal** sakta hai.
  - product par sirf `stock` (+ `updatedAt`, `appliedOps`) badal sakta hai (sale ka stock kam hona); rate / cost / naam nahi. Customer ki `creditLimit`, `openingBalance`, `stuckBalance` nahi.
  - **kuch delete nahi** kar sakta: ye app delete ko `_deleted: true` likh kar karti hai, rules wo bhi cashier ke liye band karte hain.
- Role **device** ka hai (uska anonymous UID), insaan ka nahi: counter ka tablet = cashier, malik ka phone = admin.

## Setup (card ki zaroorat nahi)
1. Cashier device par app: **Settings > Cloud Sync Setup** mein **Device ID** dekhein (wahi `branch_members` ka document ID hai).
2. Firebase Console > Firestore > `branch_members` > us Device ID ka document > **Add field**: `role` (string) = `cashier`. Save.
3. Test (abhi purane rules hi live hain, kuch nahi badla): CI mein **Firebase rules test** chalayein, `device_roles.test.js` pass hona chahiye.
4. Pehle apne **purane live rules ki copy** (`firebase/firestore.rules`) alag save karein (rollback).
5. Firebase Console > Firestore > **Rules** > `firebase/firestore.device-roles.rules` ka poora text paste > Publish.
6. Cashier device par sale, payment, customer, stock check karein. Admin device par sab kuch pehle jaisa chalna chahiye. Sync History mein "permission denied" aaye to wo entry cashier ke liye band hai (neeche dekhein).
7. Masla aaye to rollback: purane rules wapas paste karke Publish.

## Hadood (sach)
- Ye **per-person login** nahi, per-device role hai. Agar cashier malik ke phone par login kare to us phone ka role chalega.
- Rules sale ke amounts, prices ya balance ke sahi hone ki jaanch nahi kar sakte: chhedkhani kiya hua cashier app apni branch mein ghalat amount likh sakta hai. Doosri branch, delete, rates, settings, users ye sab band hain.
- Cashier products ka `cost` padh sakta hai (document mein hota hai).
- Cashier ki product upsert (rate / naam badalna) aur naya product banana band hai; agar app kabhi aisi entry bheje to wo Sync History mein "permission denied" ban kar atak jati hai. Agar customer ki creditLimit kisi doosre device par badli ho aur cashier ka purana copy usay wapas likhne ki koshish kare, wo entry bhi rok di jati hai (yehi chahiye).
- Cashier device ka pull `users` / suppliers / purchases / payroll ko permission-denied ke bajaye khali samajh kar aage badh jata hai (app apna `branch_members/{uid}.role` 10 minute mein ek baar padhti hai). Manager / admin / bina role wale device par permission-denied pehle jaisa saaf ghalti rehta hai.
- Naye cashier device par `users` pull nahi hote (denied), is liye pehle ek baar admin / manager wahan login karein.
- Agar chahein ke role na likha ho to bhi cashier samjha jaye (zyada strict), `myRole()` mein `'admin'` ko `'cashier'` karein (phir malik ke devices par `role = admin` likhna zaroori).
- Staff login (password se cloud sign-in) wala raasta, jo Cloud Functions chahta hai, ab bhi alag option hai; jab card ho tab.
