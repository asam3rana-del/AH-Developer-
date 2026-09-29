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

# flutter_secure_storage (backup password) needs minSdk 23; Flutter 3.24 template default is 21.
sed -i -E 's/minSdk(Version)?[[:space:]]*=?[[:space:]]*flutter\.minSdkVersion/minSdk = 23/' "$GRADLE"
grep -n "minSdk" "$GRADLE"

# Phase 12 (Print & Scan): Bluetooth printer + camera permissions. `flutter create` manifest mein
# yeh nahi hoti; sirf tab jodo jab pehle se na hon.
MANIFEST=android/app/src/main/AndroidManifest.xml
if ! grep -q "BLUETOOTH_CONNECT" "$MANIFEST"; then
  sed -i '0,/<manifest[^>]*>/s//&\n    <uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30" \/>\n    <uses-permission android:name="android.permission.BLUETOOTH_ADMIN" android:maxSdkVersion="30" \/>\n    <uses-permission android:name="android.permission.BLUETOOTH_CONNECT" \/>\n    <uses-permission android:name="android.permission.BLUETOOTH_SCAN" android:usesPermissionFlags="neverForLocation" \/>\n    <uses-permission android:name="android.permission.CAMERA" \/>/' "$MANIFEST"
fi
grep -n "uses-permission" "$MANIFEST"
