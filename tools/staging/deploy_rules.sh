#!/data/data/com.termux/files/usr/bin/env bash
# Deploys the staff-claims rules to the STAGING project only (project id is fixed below).
set -e
cd "$(dirname "$0")"
cp ../../firebase/firestore.staff-claims.rules ./firestore.rules
firebase deploy --only firestore:rules --project ah-staging-a1b2c
