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

# --- Fixed signing key: har build par wahi key, taake APK purani app ke upar update ho sake. ---
# Secret KEYSTORE_BASE64 (GitHub repo secret) se keystore banti hai. Na ho to debug key (update nahi hoga).
if [ -n "$KEYSTORE_BASE64" ]; then
  echo "$KEYSTORE_BASE64" | base64 -d > android/app/upload.jks
  sed -i -E "s/^([[:space:]]*)buildTypes[[:space:]]*\{/\1signingConfigs {\n\1    release {\n\1        storeFile file('upload.jks')\n\1        storePassword 'AhKiryana2026x'\n\1        keyAlias 'ahkey'\n\1        keyPassword 'AhKiryana2026x'\n\1    }\n\1}\n\1buildTypes {/" "$GRADLE"
  sed -i -E 's/signingConfigs\.debug/signingConfigs.release/' "$GRADLE"
  echo "=== app build.gradle (verify signing) ==="
  grep -n "signingConfig\|upload.jks" "$GRADLE"
  grep -q "signingConfigs.release" "$GRADLE" || { echo "ERROR: release signing not applied"; exit 1; }
else
  echo "WARNING: KEYSTORE_BASE64 secret nahi mila, debug key use hogi (update install nahi hoga)"
fi

# --- Fingerprint (local_auth) Android requirements. Inke bina BiometricPrompt khulta hi nahi aur
# authenticate() PlatformException (no_fragment_activity) deta hai => hamesha "Fingerprint not verified". ---
# 1) USE_BIOMETRIC permission
if ! grep -q "USE_BIOMETRIC" "$MANIFEST"; then
  sed -i '0,/<manifest[^>]*>/s//&\n    <uses-permission android:name="android.permission.USE_BIOMETRIC" \/>/' "$MANIFEST"
fi
grep -n "USE_BIOMETRIC" "$MANIFEST" || { echo "ERROR: USE_BIOMETRIC not added"; exit 1; }

# 2) MainActivity must extend FlutterFragmentActivity
MAIN=$(find android/app/src/main -name "MainActivity.kt" -o -name "MainActivity.java" | head -1)
echo "MainActivity: $MAIN"
sed -i 's/io\.flutter\.embedding\.android\.FlutterActivity\b/io.flutter.embedding.android.FlutterFragmentActivity/; s/: FlutterActivity()/: FlutterFragmentActivity()/; s/extends FlutterActivity/extends FlutterFragmentActivity/' "$MAIN"
cat "$MAIN"
grep -q "FlutterFragmentActivity" "$MAIN" || { echo "ERROR: MainActivity not switched to FlutterFragmentActivity"; exit 1; }

# 3) Themes must be AppCompat based (BiometricPrompt requirement)
for f in android/app/src/main/res/values/styles.xml android/app/src/main/res/values-night/styles.xml; do
  [ -f "$f" ] || continue
  sed -i 's#@android:style/Theme.Light.NoTitleBar#Theme.AppCompat.Light.NoActionBar#g; s#@android:style/Theme.Black.NoTitleBar#Theme.AppCompat.DayNight.NoActionBar#g' "$f"
  echo "=== $f ==="; cat "$f"
done
