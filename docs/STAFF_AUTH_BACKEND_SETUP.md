# Staff authentication backend — staged foundation

## Critical status
This is a backend foundation, not a completed app migration. The Flutter login still validates local SQLite credentials and `SyncApi.firestoreFor()` still uses anonymous Firebase Auth. **Do not deploy `firebase/firestore.staff-claims.rules` to the live project**: it will deny current anonymous sync and will deny all cashier writes.

## Included
- Callable `staffLogin` with Firebase App Check enforcement and per-account/IP rate limits.
- Custom Firebase token with server-issued `staffId`, `branchId`, `role`, `active` claims.
- PBKDF2-HMAC-SHA256 verification compatible with `lib/utils/password_hasher.dart` (120,000 rounds, 16-byte salt, 32-byte output).
- `getMyStaffContext` token self-check.
- Claims-based branch rules; cashier direct writes deliberately denied.

## Staff account provisioning
A trusted Admin SDK process must create `staff_accounts/{normalizedUsername}` with:
`staffId` (immutable ID), `branchId`, `role` (`admin|manager|cashier`), `active` (boolean), and `passwordHash` (`pbkdf2$<32-hex-salt>$<64-hex-hash>`).
Never make this collection client-readable/writable. Never accept plaintext legacy passwords. Do not put service-account keys in the app.

## Deploy to staging only
1. Install Node.js 20 and Firebase CLI; in `functions/` run `npm install` and `npm run build`.
2. Configure Firebase App Check for the actual app; use debug providers only in local development.
3. Deploy Functions to a separate staging Firebase project.
4. Provision a test staff account using a trusted Admin SDK tool.
5. Call `staffLogin`, exchange its token using `FirebaseAuth.signInWithCustomToken`, then call `getMyStaffContext`.
6. Verify wrong password, inactive user, unknown user, malformed hash, throttling, and App Check rejection.
7. Test rules in Firebase Emulator Suite before any production cutover.

## App wiring (added, OPT-IN, default OFF)
- `lib/services/staff_auth.dart`: password login -> `staffLogin` -> `signInWithCustomToken` -> claims verified from the ID token.
- Settings > "Secure Cloud Login (staff)" switch (default OFF). OFF = unchanged behaviour (local login + anonymous sync).
- ON: sync never uses anonymous sign-in; without a verified staff session sync reports "not signed in". Local login still works offline.
- Needs `cloud_functions` + `firebase_app_check` (added to pubspec). Configure App Check (Play Integrity / DeviceCheck) first. Windows desktop is not supported by these plugins: leave the switch OFF there.
- NOT done yet: OTP / biometric-only / no-password logins do not call `staffLogin` (they have no password); first-admin setup; password-change sync to `staff_accounts`; cashier server-side sale. Do not deploy claims rules until those exist.
- Not compiled or run here: run `flutter pub get`, `flutter analyze`, `flutter test`, then test on staging.

## Remaining app migration
- Add `cloud_functions`; call `staffLogin` from password login and sign in with returned custom token.
- Do not trust the callable response for authorization; trust verified token claims.
- Remove anonymous sign-in from `SyncApi.firestoreFor()` only after custom-token login is wired.
- Keep local SQLite roles as offline UI cache only; offline users must not write to cloud.
- Explicitly migrate first-admin setup, OTP, biometric, no-password, password reset, user switching, and account deactivation. Do not silently fall back to anonymous cloud access.

## Cashier sales
A secure sale callable is intentionally not fabricated. It must be implemented against the actual sale schema and include sale header/lines, stock movements, customer balance, payment/cash entries, edits/reversals, returns, idempotency, and offline queue semantics. Until that is complete, the rules deny cashier direct writes. Map and test the full sale path before enabling cashier cloud writes.

## Rollback
Keep live rules unchanged. Back up Firestore and local databases. Use a separate staging project and a tested rollback plan.
