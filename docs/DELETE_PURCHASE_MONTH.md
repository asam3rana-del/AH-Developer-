# Poore mahine ki purchases ek saath delete (2026-11-16)

**Kyun:** August mein app ke bugs ki wajah se purchases ka data ghalat bana; ek ek bill delete karna mushkil.

**Kahan:** Purchase History → upar 🗑️ (delete_sweep) — **sirf admin**.
1. Mahina chunein (har mahine ke saath bills ki ginti aur kul raqam).
2. Tasdeeq: kitne bill, kitni raqam, kya asar hoga → `DELETE` likhein.
3. Progress "Deleting 12 / 37…" → aakhir mein kitne hue / kaun se nahi hue (wajah ke saath).

**Har bill par wohi purana single delete (force):** stock wapas (0 se neeche nahi), cost wapas, supplier khata
aur cash se hat'ta hai, Recycle Bin mein jata hai (wapas laya ja sakta hai), doosre phone par sync.

**Baad mein zaroor:** shelf gin kar **Stock Audit** se stock theek karein, phir Balance Sheet dekhein — kyun ke
August ka ghalat maal hatne ke baad bhi baad ki sales / ghalat entries ka asar stock par reh sakta hai.

**Pehle:** Backup Now (aur bahar bhej dein) — agar kuch ulta ho to wapas aa sake.

Files: `lib/utils/purchase_month.dart` (naya), `lib/screens/purchase_history_screen.dart`.
Test: `test/purchase_month_test.dart`.
