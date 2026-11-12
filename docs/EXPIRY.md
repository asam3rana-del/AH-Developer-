# Expiry date + Expiry Report (2026-11-12)

`products.expiry` schema aur sync mein pehle se tha, lekin item form par na likhne ki jagah thi na koi report.
Ulta: item **edit karke save** karne par purani expiry (agar Kotlin import se aayi ho) mit jati thi — ye bhi theek.

- **Items → item kholein → Expiry date** (Reorder Level ke neeche): tap = calendar, ✕ = hatao. `yyyy-MM-dd` mein
  save; purane `dd/MM/yyyy`, `MM/yyyy` bhi parhe jate hain.
- **Reports → Stock reports → Expiry Report**: jis maal ka stock hai aur jo expire ho chuka ya 30 din mein hoga,
  sab se pehle wala upar. Upar do dibbe: Expired / 30 din ke andar (admin/manager ko cost par qeemat bhi).
- Ek item ki ek expiry (agli expire hone wali batch ki date likhein) — batch-wise nahi.

Files: `lib/utils/expiry.dart` (naya, pure), `lib/screens/expiry_report_screen.dart` (naya),
`lib/screens/product_screen.dart`, `lib/screens/reports_screen.dart`. Test: `test/expiry_test.dart`.

## Phone par check
- [ ] Doodh par aaj se 10 din baad ki expiry → Expiry Report mein "10 day(s) left"
- [ ] Ghee par guzri tareekh → laal "Expired"
- [ ] Item edit kar ke sirf rate badlein, save → expiry wahi rahe
- [ ] Doosre phone par Sync → wahan bhi report mein
