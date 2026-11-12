# Phone se bahar backup — roz 1-tap (2026-11-12)

**Masla:** backup roz phone par banta tha (12 PM / 9 PM), lekin phone gum / kharab / chori ho to backup bhi saath
jata. Google Drive / Firebase Storage ka auto upload naya package + OAuth / card maangta — is liye 1-tap tareeqa.

- **Raat 9 baje ke baad** (din mein ek dafa) notification: "Backup phone se bahar bhejein" — sirf agar pichle ~20
  ghante mein bahar nahi bheja. Background (WorkManager) aur app khulne par, dono.
- **Tap** → sab se naye backup ki share sheet → WhatsApp (apna number / "Message yourself") ya Google Drive.
- Backup screen par naya card: "Aaj bahar bheja ✓ / N din pehle / kabhi nahi" + **SEND NEWEST BACKUP OUTSIDE**.
- Kisi bhi raste se backup share ho (purana share button bhi) to ginti ho jati hai; share sheet band (dismiss)
  karne par nahi.
- ⚠️ Backup encrypted hai — **Backup Password** likh kar ghar par rakhein, warna naye phone par restore nahi hoga.

Files: `lib/backup/offsite_backup.dart` (naya), `lib/backup/backup_helper.dart`, `lib/backup/backup_background.dart`,
`lib/services/due_alert_service.dart`, `lib/main.dart`, `lib/screens/backup_export_screen.dart`.
Test: `test/offsite_backup_test.dart`.

## Phone par check
- [ ] Backup screen: card laal "kabhi nahi" → SEND → WhatsApp par apne aap ko → card hara "aaj ✓"
- [ ] Agle din raat 9 ke baad notification aaye (agar us din share nahi kiya) → tap → share sheet
- [ ] Backup Password dekh kar kaghaz par likh lein
