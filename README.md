# AH Developer — Kiryana Store (Flutter, cross-platform)

Flutter port of the **IBTISAAM Kiryana Store** Kotlin/Android app, aimed at
running the same POS on iPad/iPhone as well as Android from one codebase.

## What's in this drop (Phase 0-9 — foundation, Product, Purchase, Sale, Parties, History, Cash, Reports & Stock)

- `lib/models/` — every entity from the Kotlin `Database.kt` (Product,
  Category, UnitType, Customer, Supplier, Sale, SaleItem, Purchase,
  PurchaseItem, Payment, ReturnLine, User, Expense, CashTransaction,
  CashRegister, AppSetting, SyncQueueEntry), including the 3-tier unit-ladder
  conversion logic (`toSmallestUnits`, `formatStockBreakdown`,
  `toPrimaryUnitRate`/`fromPrimaryUnitRate` for per-unit price conversion)
- `lib/db/app_database.dart` — SQLite schema, one table per entity, matching
  the Room schema column-for-column
- `lib/db/product_repository.dart`, `category_unit_repository.dart`,
  `supplier_repository.dart`, `purchase_repository.dart`,
  `customer_repository.dart`, `sale_repository.dart` — Dart ports of
  `ProductDao`/`CategoryDao`/`UnitDao`/`SupplierDao`/`CustomerDao` and the
  `PurchaseActivity.savePurchase()` / `SaleActivity.saveSale()` transactions
- `lib/utils/discount_calculator.dart` — Dart port of `DiscountCalculator.kt`
- `lib/widgets/` — reusable "premium" UI pieces (cards, gradient badges,
  gradient buttons, header) matching the Android app's visual style
- `lib/screens/product_screen.dart` — full Add/Edit Product screen: name +
  multi-tier unit picker, category (with autocomplete + add-new), pricing
  (purchase/wholesale/retail), opening stock with unit dropdown, reorder
  level, Save, **Delete (while editing)**, Cancel Edit, and a searchable
  product list with per-card Edit/Delete
- `lib/screens/purchase_screen.dart` — New Purchase screen: supplier
  autocomplete (auto-creates new suppliers), date picker, item entry
  (product autocomplete, unit-aware quantity, rate), running bill list with
  per-line remove, subtotal, paid amount with **credit-purchase
  confirmation** when nothing is paid, Save (updates stock, recalculates
  weighted-average cost, updates supplier balance, records payment/cash
  entry — all in one transaction)
- `lib/screens/sale_screen.dart` — New Sale screen: Retail/Wholesale toggle
  (auto-fills the matching price per unit when you pick a product or change
  unit), customer autocomplete (auto-creates new customers), item entry with
  live stock-availability check against what's already in the cart, running
  bill list, discount, paid amount with **due-requires-customer
  validation**, Save (checks stock again inside the transaction, decreases
  stock, updates customer balance, records payment/cash entry)
- `lib/main.dart` — bottom navigation between Products, Purchase, and Sale
- `.github/workflows/build.yml` — CI that builds an **unsigned iOS app** on
  a macOS cloud runner (since iOS builds require a Mac) and an Android APK

## Porting plan (Kotlin → Flutter)

Poora plan, phases aur rules: **`PORTING_PLAN.md`** · live progress: **`PORT_STATUS.md`** ·
Android ki nayi tabdeeliyan: **`ANDROID_CHANGELOG.md`** · Kotlin source: **`kotlin_reference/`**.

## Setup (you're building this yourself, so here's the full path)

### 1. Install Flutter
Follow https://docs.flutter.dev/get-started/install for your OS. Run
`flutter doctor` afterward and fix anything it flags.

### 2. Get dependencies
```
flutter pub get
```

### 3. Run it
- Android device/emulator: `flutter run`
- iPad simulator (needs a Mac + Xcode installed): `flutter run -d ios`

### 4. Firebase (for cloud sync — optional until you port that phase)
```
dart pub global activate flutterfire_cli
flutterfire configure
```
This generates `lib/firebase_options.dart`. Then uncomment the two Firebase
lines in `lib/main.dart`.

### 5. Building for a real iPad
You need:
- A Mac with Xcode installed
- An Apple Developer account ($99/yr) — required even for installing on
  your own device outside TestFlight/App Store
- Open `ios/Runner.xcworkspace` in Xcode, sign in with your Apple ID under
  **Signing & Capabilities**, pick your Team, then either:
  - Plug in the iPad and hit Run, or
  - **Product > Archive** to create a distributable build for TestFlight

### 6. CI builds (no Mac needed just to verify it compiles)
Push to `main` and check the **Actions** tab on GitHub — the workflow here
builds an unsigned iOS `.app` and an Android `.apk` automatically. The iOS
one still needs to be signed locally in Xcode before it'll install on a
real device (Apple requires code signing; GitHub Actions can't do that part
without your Apple certificates).

## Notes on data

This starts as a **fresh** SQLite database (version 1) — it does not read
the existing Android app's `.db` file directly, since you'll likely want
both apps pointed at the same Firestore backend for sync rather than a
one-time file copy. If you want your existing product/customer data
carried over, say so and we can add a one-time import routine (e.g. reading
the exported Android backup format your app already produces).


## Windows build

Windows PC par: Flutter SDK + Visual Studio 2022 ("Desktop development with C++" aur "C++ ATL" components), phir:

```
flutter config --enable-windows-desktop
flutter create --platforms=windows --project-name ah_developer_kiryana_store .
flutter pub get
flutter build windows --release
```

Output: `build\windows\x64\runner\Release\` — poora folder copy karein. Ya GitHub Actions ka `build-windows` job (artifact `windows-build`).

Windows par: database `%APPDATA%` mein (`lib/db/desktop_db_init.dart`), backups `Documents\IBTISAAM POS Backups` mein.
Printer (Windows): Settings > Printer Setup > SELECT PRINTER — installed Windows printer (driver ke zariye, 58/80mm roll PDF) ya Network printer (IP, raw ESC/POS, port 9100). 58mm ke liye PRINT WIDTH 384, 80mm ke liye 576.
Firebase sync: Settings > Cloud Sync Setup (Windows par firebase_core/auth/firestore chalte hain; pehla build C++ SDK download karta hai, is liye lamba ho sakta hai).
Nahi chalte (Android/iOS-only): Bill Scan OCR, Bluetooth printer, fingerprint login aur Phone OTP login (password se login hota hai).
Layout: desktop window mein screens 900 px chauri column mein beech mein dikhti hain.
