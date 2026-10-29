#!/usr/bin/env bash
# Manual tool (CI ko nahi rokta). Root par stray Kotlin copies check/saaf karta hai.
#   bash tools/check_root.sh        -> sirf check
#   bash tools/check_root.sh --fix  -> stray Kotlin copies seedha hata deta hai
set -u
cd "$(dirname "$0")/.."
FIX=0; [ "${1:-}" = "--fix" ] && FIX=1
BAD=0

# Root par sirf yeh allowed hain (Flutter ke generated folders bhi).
ALLOWED=".git .github .gitignore .gitattributes .metadata .dart_tool .idea build \
android ios windows assets analysis_options.yaml pubspec.yaml pubspec.lock \
ANDROID_CHANGELOG.md PORTING_PLAN.md PORT_STATUS.md README.md LICENSE \
docs firebase lib test tools"

for d in main config androidTest db screens models sync services widgets utils theme backup; do
  if [ -d "$d" ]; then
    if [ $FIX -eq 1 ]; then
      rm -rf "$d"; echo "FIXED: root '$d/' hata diya"
    else
      echo "STRAY: root par '$d/' hai (Kotlin/purani ya lib/ ke bahar paste hui copy)"; BAD=1
    fi
  fi
done

while IFS= read -r f; do
  [ -z "$f" ] && continue
  if [ $FIX -eq 1 ]; then rm -f "$f"; echo "FIXED: $f hata di"
  else echo "STRAY: $f (Flutter test/ mein .kt nahi hoti)"; BAD=1; fi
done < <(find test -name '*.kt' 2>/dev/null)

for f in *.kt; do
  [ -e "$f" ] || continue
  echo "STRAY: root par $f (Kotlin file repo mein nahi honi chahiye)"; BAD=1
done

for e in $(ls -A); do
  case " $ALLOWED " in *" $e "*) ;; *) echo "UNKNOWN: root par '$e' allowed list mein nahi"; BAD=1;; esac
done

[ $BAD -eq 0 ] && echo "Root clean hai." || echo "Root mein masla hai (upar dekhein)."
exit $BAD
