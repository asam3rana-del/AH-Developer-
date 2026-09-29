sed -i -E 's/(com.android.application" version )"[0-9.]+"/\1"8.3.2"/' android/settings.gradle
sed -i -E 's/gradle-[0-9.]+-(all|bin)/gradle-8.6-all/' android/gradle/wrapper/gradle-wrapper.properties
grep -n "version" android/settings.gradle
cat android/gradle/wrapper/gradle-wrapper.properties

# Firebase/sqflite/url_launcher/... plugins need NDK 25.1.8937393 (Flutter 3.24 template pins 23.1.7779620)
# and some need compileSdk 35. Handles both Groovy forms: `ndkVersion = x` and `ndkVersion x`.
GRADLE=android/app/build.gradle
[ -f android/app/build.gradle.kts ] && GRADLE=android/app/build.gradle.kts
sed -i -E 's/ndkVersion[[:space:]]*=?[[:space:]]*flutter\.ndkVersion/ndkVersion = "25.1.8937393"/' "$GRADLE"
sed -i -E 's/compileSdk(Version)?[[:space:]]*=?[[:space:]]*flutter\.compileSdkVersion/compileSdk = 35/' "$GRADLE"
# AGP 8.3.2 only knows up to compileSdk 34 — silence its "unsupported" warning.
echo "android.suppressUnsupportedCompileSdk=35" >> android/gradle.properties
grep -n "ndkVersion\|compileSdk" "$GRADLE"
