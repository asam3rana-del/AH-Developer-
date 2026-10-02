#!/usr/bin/env bash
# Zip se sirf zaroori files repo mein paste karta hai. Baqi sab ignore (skip).
# Usage: bash tools/import_zip.sh <zip-file>
set -e
Z="$1"
rm -rf /tmp/x && mkdir /tmp/x
unzip -q "$Z" -d /tmp/x
SRC=$(find /tmp/x -mindepth 1 -maxdepth 1 -type d | head -1)
[ -n "$SRC" ] || SRC=/tmp/x

# Poore folders (zaroori)
for d in lib tools docs assets kotlin_reference; do
  [ -d "$SRC/$d" ] && { mkdir -p "$d"; cp -a "$SRC/$d"/. "$d"/; echo "PASTE: $d/"; }
done
# test/: sirf Dart tests (.kt nahi)
if [ -d "$SRC/test" ]; then
  mkdir -p test
  (cd "$SRC/test" && find . -type f ! -name '*.kt' -print0) | while IFS= read -r -d '' f; do
    mkdir -p "test/$(dirname "$f")"; cp -a "$SRC/test/$f" "test/$f"
  done
  echo "PASTE: test/ (sirf non-.kt)"
fi
# Zaroori root files (README.md aur .github jaan boojh kar skip)
for f in pubspec.yaml pubspec.lock analysis_options.yaml PORTING_PLAN.md PORT_STATUS.md ANDROID_CHANGELOG.md; do
  [ -f "$SRC/$f" ] && { cp -a "$SRC/$f" "$f"; echo "PASTE: $f"; }
done
# Purane layout wali Kotlin folders -> sirf kotlin_reference/ mein jayen, root par nahi
for d in main config androidTest; do
  [ -d "$SRC/$d" ] && { mkdir -p "kotlin_reference/$d"; cp -a "$SRC/$d"/. "kotlin_reference/$d"/; echo "MERGE: $d/ -> kotlin_reference/$d/"; }
done
# Jo kuch paste nahi hua woh skip
for e in $(ls -A "$SRC"); do
  case "$e" in lib|tools|docs|assets|kotlin_reference|test|main|config|androidTest|pubspec.yaml|pubspec.lock|analysis_options.yaml|PORTING_PLAN.md|PORT_STATUS.md|ANDROID_CHANGELOG.md) ;; *) echo "SKIP: $e";; esac
done
# Pehle se maujood stray copies saaf (kabhi fail nahi karta)
[ -f tools/check_root.sh ] && bash tools/check_root.sh --fix || true
exit 0
