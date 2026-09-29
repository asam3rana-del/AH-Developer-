# --- Versions: Kotlin 2.1.0 + AGP 8.7.3 + Gradle 8.9 (Firebase 23.x libs need Kotlin 2.1 metadata; AGP 8.3's R8 can't read it) ---
sed -i -E 's/(org.jetbrains.kotlin.android" version )"[0-9.]+"/\1"2.1.0"/' android/settings.gradle
sed -i -E 's/(com.android.application" version )"[0-9.]+"/\1"8.7.3"/' android/settings.gradle
sed -i -E 's/gradle-[0-9.]+-(all|bin)/gradle-8.9-all/' android/gradle/wrapper/gradle-wrapper.properties
echo "=== settings.gradle (verify versions) ==="
cat android/settings.gradle
grep -q '"org.jetbrains.kotlin.android" version "2.1.0"' android/settings.gradle || { echo "ERROR: Kotlin 2.1.0 not applied"; exit 1; }
grep -q '"com.android.application" version "8.7.3"' android/settings.gradle || { echo "ERROR: AGP 8.7.3 not applied"; exit 1; }
cat android/gradle/wrapper/gradle-wrapper.properties

# Firebase/sqflite/url_launcher/... plugins need NDK 25.1.8937393 (Flutter 3.24 template pins 23.1.7779620)
# and some need compileSdk 35. Handles both Groovy forms: `ndkVersion = x` and `ndkVersion x`.
GRADLE=android/app/build.gradle
[ -f android/app/build.gradle.kts ] && GRADLE=android/app/build.gradle.kts
sed -i -E 's/ndkVersion[[:space:]]*=?[[:space:]]*flutter\.ndkVersion/ndkVersion = "25.1.8937393"/' "$GRADLE"
sed -i -E 's/compileSdk(Version)?[[:space:]]*=?[[:space:]]*flutter\.compileSdkVersion/compileSdk = 35/' "$GRADLE"
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

# --- R8 rules: google_mlkit_text_recognition refers to Chinese/Japanese/Korean/Devanagari option classes
# that we don't bundle (Latin only). Tell R8 to ignore them, otherwise release build fails with "Missing class". ---
cat > android/app/proguard-rules.pro <<'EOF'
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
EOF
# Release buildType mein proguard file jodo (`signingConfig signingConfigs.debug` ke baad).
sed -i -E "s/^([[:space:]]*)signingConfig[[:space:]]*=?[[:space:]]*signingConfigs\.debug/&\n\1proguardFiles getDefaultProguardFile('proguard-android.txt'), 'proguard-rules.pro'/" "$GRADLE"
echo "=== app build.gradle (verify proguard) ==="
grep -n "proguard\|signingConfig" "$GRADLE"
grep -q "proguard-rules.pro" "$GRADLE" || { echo "ERROR: proguard rules not wired into build.gradle"; exit 1; }
