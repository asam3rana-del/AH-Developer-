# Staging Firebase project (never test security changes on the live project)

- Project ID: `ah-staging-a1b2c` (Spark plan). The live "My grocery pos" project must not be used for any of the steps below.
- Firestore database `(default)` created in production mode. Rules and indexes deployed from `firebase/firestore.rules` and `firebase/firestore.indexes.json`.
- Cloud Functions (`staffLogin`, `getMyStaffContext`) are NOT deployed: they need the Blaze plan. Enable it on staging only, and set a budget alert first.

## Tools (`tools/staging/`)

- `deploy_rules.sh` deploys `firebase/firestore.staff-claims.rules` to the staging project only (project id is fixed in the script).
- `provision_staff.mjs` creates or updates `staff_accounts/{username}` in staging:
  - dry run by default (`node provision_staff.mjs staff.json`), `--apply` writes;
  - refuses to run unless the service-account key's `project_id` contains `staging`;
  - password is hashed here (`pbkdf2$<salt>$<hash>`, the same format as `password_hasher.dart`); plain passwords are never stored;
  - `staff.json` and any key file are git-ignored; delete `staff.json` after use.

## Running from an Android tablet (Termux)

1. `pkg update -y && pkg upgrade -y`, then `pkg install -y nodejs unzip` (upgrade first, otherwise `node` fails with "CANNOT LINK EXECUTABLE").
2. `npm install -g firebase-tools`, then `firebase login --no-localhost` (answer `n` to the Gemini and usage questions).
3. Unzip `tools/staging` from the project zip into `~`, `cd` into it, `npm install`.
4. Create a service-account key for the staging project only (Firebase console > Project settings > Service accounts), keep it as `~/staging-key.json`, delete the downloaded copy, and `export GOOGLE_APPLICATION_CREDENTIALS=$HOME/staging-key.json`.
5. Usernames: letters, digits, `_`, `.`, `-` only (3 to 40 characters, no spaces); they are stored lower-case.

## Workflow files

The zip importer excludes `.github`, so workflow files (for example `firebase-rules-test.yml`) must be created or edited directly in GitHub. Manual workflows: "Firebase rules test", "Migration tests".
