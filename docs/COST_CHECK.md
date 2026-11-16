# Cost Check (sale par ghalat loss)

**Masla:** Item ka rate aakhri khareed se upar hai (jaise Sufi Ghee 590/kg, khareed 585.63/kg), phir bhi
sale par "Cost shak wali hai" aur loss dikhta hai (cost Rs 3456 for 3 kg = 1152/kg).

**Wajah:** Product ki cost *weighted average* hai. Kharab purchases (August) delete/edit hone par,
khaas kar jab stock thora bacha ho, average bigad jata hai. Rate Search "Last Cost" aakhri purchase dikhata hai,
magar sale bill product ki average cost lagata hai.

**Hal:**
1. Sale par "Cost shak wali hai" dialog mein (Admin/Manager) naya button **Cost theek karo**:
   item ki cost aakhri purchase rate par ho jati hai, bill ki line ki cost dobara nikalti hai, aur bill save hota hai.
2. **Items > Cost Check**: sab items jin ki average cost aakhri purchase se 1.5x zyada ya kam hai — list,
   sab chune hue, Apply. Phir "Fix Bill Cost" se purani bills ki ghalat cost bhi theek karen.

Product ki cost sync hoti hai (dono devices). Har change `audit` mein `cost_check_fix` ke naam se likha jata hai.

## Test (phone par)
- [ ] Sufi Ghee 3 kg x 590 sale > dialog mein "Cost theek karo" > bill save, profit plus (~Rs 13).
- [ ] Items > Cost Check > list dekhen > Apply > dusre phone par product cost wahi.
- [ ] Phir Fix Bill Cost > purani bills ka loss theek.
