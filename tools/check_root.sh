#!/usr/bin/env bash
# Manual tool (CI ko nahi rokta). Root par stray Kotlin copies check/saaf karta hai.
#   bash tools/check_root.sh        -> sirf check
#   bash tools/check_root.sh --fix  -> stray ko kotlin_reference/ mein merge karke hata deta hai
set -u
cd "$(dirname "$0")/.."
FIX=0; [ "${1:-}" = "--fix" ] && FIX=1
BAD=0

# Root par sirf yeh allowed hain (Flutter ke generated folders bhi).
ALLOWED=".git .github .gitignore .gitattributes .metadata .dart_tool .idea build \
android ios windows assets analysis_options.yaml pubspec.yaml pubspec.lock \
ANDROID_CHANGELOG.md PORTING_PLAN.md PORT_STATUS.md README.md LICENSE \
docs kotlin_reference lib test tools"

for d in main config androidTest; do
  if [ -d "$d" ]; then
    if [ $FIX -eq 1 ]; then
      mkdir -p "kotlin_reference/$d"
      cp -a "$d"/. "kotlin_reference/$d"/ && rm -rf "$d"
      echo "FIXED: root '$d/' kotlin_reference/$d/ mein merge hua aur hata diya"
    else
      echo "STRAY: root par '$d/' hai (kotlin_reference/$d/ ki copy)"; BAD=1
    fi
  fi
done

while IFS= read -r f; do
  [ -z "$f" ] && continue
  if [ $FIX -eq 1 ]; then
    rel="${f#test/}"; mkdir -p "kotlin_reference/test/$(dirname "$rel")"
    mv "$f" "kotlin_reference/test/$rel"
    echo "FIXED: $f -> kotlin_reference/test/$rel"
  else
    echo "STRAY: $f (Flutter test/ mein .kt nahi hoti)"; BAD=1
  fi
done < <(find test -name '*.kt' 2>/dev/null)

for f in *.kt; do
  [ -e "$f" ] || continue
  echo "STRAY: root par $f (Kotlin file sirf kotlin_reference/main/ mein)"; BAD=1
done

if [ -f README.md ] && cmp -s README.md kotlin_reference/README.md; then
  echo "STRAY: root README.md asal project README nahi, kotlin_reference/README.md ki copy hai"; BAD=1
fi

for e in $(ls -A); do
  case " $ALLOWED " in *" $e "*) ;; *) echo "UNKNOWN: root par '$e' allowed list mein nahi"; BAD=1;; esac
done

[ $BAD -eq 0 ] && echo "Root clean hai." || echo "Root mein masla hai (upar dekhein)."
exit $BAD
