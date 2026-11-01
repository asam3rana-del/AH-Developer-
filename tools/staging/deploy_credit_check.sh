#!/data/data/com.termux/files/usr/bin/env bash
# Deploys ONLY the reserveCredit function + the Firestore indexes to the STAGING project (id fixed below).
# Needs the Blaze plan on staging (Cloud Functions). Set a budget alert first. Never run this against live.
set -e
PROJECT=ah-staging-a1b2c
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
[ -e firebase.json ] && { echo "Refusing: $ROOT/firebase.json already exists."; exit 1; }
trap 'rm -f "$ROOT/firebase.json"' EXIT
echo "Building functions..."
(cd functions && npm install --no-audit --no-fund && npm run build)
# Temporary config (removed on exit): only the pieces this deploy needs.
cat > firebase.json <<JSON
{ "functions": { "source": "functions" }, "firestore": { "indexes": "firebase/firestore.indexes.json" } }
JSON
echo "Deploying reserveCredit + indexes to $PROJECT ..."
echo "(If it asks to DELETE indexes that are not in the file, answer N.)"
firebase deploy --only functions:reserveCredit,firestore:indexes --project "$PROJECT"
echo "Done. Wait until the credit_reservations index shows 'Enabled' (Firebase console > Firestore > Indexes), then run:"
echo "  node test_credit_check.mjs --api-key <staging web API key>"
