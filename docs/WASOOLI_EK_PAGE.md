# Wasooli ek page ("Aaj kis se lena hai")

Dashboard ka Collection ab EK page kholta hai. Purani screens (Autopilot list, Sab bills, Kab se / Aging)
upar ke ⋮ menu mein hain.

## Usool: ek party = ek tareekh = ek button
- Har party par sirf EK tareekh, 3 rang: **Late** (laal), **Aaj** (narangi), **Aage** (hara).
- Tareekh kaunsi (pehli jo laagu ho): jhagra → **wada** → qist → bill due date / payment din / agla rabta.
- Wada bill ki due date se zyada ahem: naya wada aage ka ho to party "Aage" (wade par), chahe bill late ho.
- Purana chuka hua qarz: us ke wade naye bill par laagu nahi.

## Page
- Upar: Aaj wasool (Rs, party), Late (Rs, party), aaj kitna mila.
- Filter: Sab | Late | Aaj | Is hafta, aur naam / phone search.
- Card: naam, baqi, tareekh chip, "2 dafa toota", "aaj baat hui", aur Call / WhatsApp / Paisa mila.
- Call ke baad foran sawal: **Paisa mila / Wada kiya / Nahi mila**.
  - Wada kiya: Kal / 3 din / 1 hafta / Mahine ke aakhir / koi aur tareekh, raqam (khali = poora baqi).
  - Nahi mila: kal phir list mein.
- Party par tap: sab se upar **ABHI KA WADA** (ya WADA TOOTA / AGLI TAREEKH) bari dabbi; neeche purane wade kati
  hui line mein, payments aur bills.

## Payment ke baad "Baqi kab dega?"
Collection ke kisi bhi "Paisa mila" se payment ke baad baqi reh jaye to app poochhti hai
"Baqi Rs X kab dega?" — tareekh chuno = naya wada (purana "toota" hat jata hai); "Abhi tareekh nahi" = sirf payment.
(Dashboard ke normal Payment Received screen par ye sawal abhi nahi aata.)

## Test (phone par)
- [ ] Dashboard > Collection: ek page, upar 2 dabbe, filters.
- [ ] Late party > Call > "Wada kiya" > 3 din > Save: party "Aage · (3 din)" mein, hari.
- [ ] Toota wada wali party > party kholo: "WADA TOOTA" laal dabbi; naya wada lo > "ABHI KA WADA" neeli, purana kata hua.
- [ ] Paisa mila (thora) > "Baqi kab dega?" > Kal: party "Aage · kal".
- [ ] Poora paisa: party list se nikal jaye.
- [ ] ⋮ menu se purani screens khulti hain.

## Payment term (har customer ki apni udhaar muddat)
- Collection > party kholo > "Payment term" > kitne din baad pay karta hai chuno (10/15 din, 1/1.5/2/3 month, ya koi mudat nahi).
- Naye udhaar bill par due date khud = bill date + yehi din. (Sale screen par us bill ke liye date badal bhi sakte hain.)
- Jin purane bills par date nahi, Wasooli un par bhi ab 7 din ki jagah is customer ki muddat lagati hai — is liye jo 2 month baad deta hai wo 2 month tak "Late" nahi dikhega.
- Yehi muddat Settings mein shop ka default bhi hai (jab customer ki alag na ho).

### Test
- [ ] Party kholo > Payment term > 2 months > naya credit bill banao > due date ~60 din baad.
- [ ] 2-month wala customer Collection mein 60 din tak "Aage" (hara), "Late" nahi.
