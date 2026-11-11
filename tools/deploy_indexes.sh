#!/data/data/com.termux/files/usr/bin/env bash
# Repo ki firebase/firestore.indexes.json (sab collections ke branchId+updatedAt aur branchId+pushedAt indexes)
# LIVE project par deploy. Chalayein (Termux, repo folder se):   bash tools/deploy_indexes.sh
# Doosra project:                                               bash tools/deploy_indexes.sh <project-id>
# Sirf indexes banata hai — rules / data ko nahi chhoota. Pehle se bane extra indexes delete NAHI hote.
set -e
PROJECT="${1:-my-grocery-pos-8a444}"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${TMPDIR:-/tmp}/ah_indexes_deploy"
rm -rf "$WORK" && mkdir -p "$WORK"
cp "$HERE/../firebase/firestore.indexes.json" "$WORK/firestore.indexes.json"
printf '{\n  "firestore": { "indexes": "firestore.indexes.json" }\n}\n' > "$WORK/firebase.json"
cd "$WORK"
echo "Deploying Firestore indexes to: $PROJECT"
firebase deploy --only firestore:indexes --project "$PROJECT"
echo
echo "Ho gaya. Indexes ban'ne mein 5-15 minute lagte hain (Console > Firestore > Indexes: 'Building' -> 'Enabled')."
echo "Phir app mein Sync Now — 'pushedAt index missing' warning khatam honi chahiye."
