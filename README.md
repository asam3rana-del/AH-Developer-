# kotlin_reference — Android (Kotlin) source, read-only reference

Yeh IBTISAAM Kiryana Store Android app ka source hai, sirf Flutter mein convert
karne ke liye rakha gaya hai. **Isay edit mat karein** — jab Android mein kuch
badle to nayi `.kt` file yahan replace karein (dekhein `../PORTING_PLAN.md`,
section "Android update ka tareeqa").

- `main/`        — app ki saari Kotlin files (Activity, DAO/Database, ViewModel...)
- `test/`, `androidTest/` — unit / instrumented tests. Inhe Dart tests
  (`test/`) mein convert karna, khaas taur par unit-conversion, discount,
  sale/purchase use-cases.
- `config/`      — AndroidManifest (kaunsi screen kya hai), strings, Firestore rules,
  aur design/security notes.

Dhyan: kuch files ka `package` naam folder se match nahi karta (jaise
`ItemSearchActivity.kt` mein `package ...v11.ui`). Porting ke waqt package
naam ko ignore karein, sirf logic dekhein.
