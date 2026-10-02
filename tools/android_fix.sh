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

# App ka naam (phone par icon ke neeche): Hanna Solutions.
sed -i -E 's/android:label="[^"]*"/android:label="Hanna Solutions"/' "$MANIFEST"
grep -q 'android:label="Hanna Solutions"' "$MANIFEST" || { echo "ERROR: app label not set"; exit 1; }
if ! grep -q "BLUETOOTH_CONNECT" "$MANIFEST"; then
  sed -i '0,/<manifest[^>]*>/s//&\n    <uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30" \/>\n    <uses-permission android:name="android.permission.BLUETOOTH_ADMIN" android:maxSdkVersion="30" \/>\n    <uses-permission android:name="android.permission.BLUETOOTH_CONNECT" \/>\n    <uses-permission android:name="android.permission.BLUETOOTH_SCAN" android:usesPermissionFlags="neverForLocation" \/>\n    <uses-permission android:name="android.permission.CAMERA" \/>/' "$MANIFEST"
fi

# Phase 6 (Parties): contact picker (flutter_contacts) — READ_CONTACTS, sirf tab jodo jab pehle se na ho.
if ! grep -q "READ_CONTACTS" "$MANIFEST"; then
  sed -i '0,/<manifest[^>]*>/s//&\n    <uses-permission android:name="android.permission.READ_CONTACTS" \/>/' "$MANIFEST"
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
  [ -n "$KEYSTORE_PASSWORD" ] || { echo "ERROR: KEYSTORE_PASSWORD secret set nahi (GitHub repo secret banayein)"; exit 1; }
  echo "$KEYSTORE_BASE64" | base64 -d > android/app/upload.jks
  sed -i -E "s/^([[:space:]]*)buildTypes[[:space:]]*\{/\1signingConfigs {\n\1    release {\n\1        storeFile file('upload.jks')\n\1        storePassword System.getenv('KEYSTORE_PASSWORD')\n\1        keyAlias 'ahkey'\n\1        keyPassword System.getenv('KEY_PASSWORD') ?: System.getenv('KEYSTORE_PASSWORD')\n\1    }\n\1}\n\1buildTypes {/" "$GRADLE"
  sed -i -E 's/signingConfigs\.debug/signingConfigs.release/' "$GRADLE"
  echo "=== app build.gradle (verify signing) ==="
  grep -n "signingConfig\|upload.jks" "$GRADLE"
  grep -q "signingConfigs.release" "$GRADLE" || { echo "ERROR: release signing not applied"; exit 1; }
else
  echo "WARNING: KEYSTORE_BASE64 secret nahi mila, debug key use hogi (update install nahi hoga)"
fi

# --- Security: Android auto-backup band (DeviceTag/sync prefs doosre phone par copy na hon). ---
if ! grep -q 'android:allowBackup' "$MANIFEST"; then
  sed -i '0,/<application/s//<application android:allowBackup="false"/' "$MANIFEST"
else
  sed -i -E 's/android:allowBackup="true"/android:allowBackup="false"/' "$MANIFEST"
fi
grep -q 'android:allowBackup="false"' "$MANIFEST" || { echo "ERROR: allowBackup=false not applied"; exit 1; }

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

# --- Background sync (SyncKeepAlive / flutter_foreground_task): app minimize hone par bhi sync chale. ---
for perm in FOREGROUND_SERVICE FOREGROUND_SERVICE_DATA_SYNC POST_NOTIFICATIONS WAKE_LOCK; do
  if ! grep -q "android.permission.$perm\"" "$MANIFEST"; then
    sed -i "0,/<manifest[^>]*>/s//&\n    <uses-permission android:name=\"android.permission.$perm\" \/>/" "$MANIFEST"
  fi
done
if ! grep -q "flutter_foreground_task.service.ForegroundService" "$MANIFEST"; then
  sed -i 's#</application>#    <service android:name="com.pravera.flutter_foreground_task.service.ForegroundService" android:foregroundServiceType="dataSync" android:exported="false" \/>\n    </application>#' "$MANIFEST"
fi
grep -n "FOREGROUND_SERVICE\|ForegroundService" "$MANIFEST" || { echo "ERROR: foreground service not added to manifest"; exit 1; }

# --- Backup ki public Downloads copy (Kotlin BackupHelper.copyToDownloads): MediaStore MethodChannel ---
# lib/backup/downloads_copy.dart isi channel ("ah_developer/downloads") ko bulata hai. Android 10+ par
# permission nahi chahiye; 9 aur us se purane par WRITE_EXTERNAL_STORAGE (maxSdk 28) chahiye.
if ! grep -q 'android.permission.WRITE_EXTERNAL_STORAGE' "$MANIFEST"; then
  sed -i '0,/<manifest[^>]*>/s//&\n    <uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" android:maxSdkVersion="28" \/>/' "$MANIFEST"
fi
case "$MAIN" in
  *.kt)
    PKG=$(grep -m1 '^package ' "$MAIN" | sed -E 's/^package[[:space:]]+//; s/[[:space:]]*;?[[:space:]]*$//')
    [ -n "$PKG" ] || { echo "ERROR: MainActivity package nahi mila"; exit 1; }
    cat > "$MAIN" <<KT
package $PKG

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream

// FlutterFragmentActivity: local_auth (fingerprint). Channel: backup ki Downloads copy.
class MainActivity : FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ah_developer/downloads")
            .setMethodCallHandler { call, result ->
                if (call.method != "copyToDownloads") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val path = call.argument<String>("path")
                val fileName = call.argument<String>("fileName")
                val folder = call.argument<String>("folder")
                if (path == null || fileName == null || folder == null) {
                    result.error("bad_args", "path/fileName/folder chahiye", null)
                    return@setMethodCallHandler
                }
                Thread {
                    val ok = try {
                        copyToDownloads(File(path), fileName, folder)
                    } catch (e: Exception) {
                        e.printStackTrace()
                        false
                    }
                    runOnUiThread { result.success(ok) }
                }.start()
            }
        setupUsbChannel(flutterEngine)
    }

    // ---- USB thermal printer (Kotlin PrinterHelper USB hissa: host mode, bulk OUT endpoint). Plugin nahi. ----
    // Channel "ah_developer/usb": list / permission / open / write / close. Delays Dart mein (Bluetooth jaisa).
    private var usbConn: UsbDeviceConnection? = null
    private var usbIface: UsbInterface? = null
    private var usbEp: UsbEndpoint? = null
    private val usbPermAction = "com.ahdeveloper.USB_PERMISSION"

    private fun usbMgr(): UsbManager? = getSystemService(Context.USB_SERVICE) as? UsbManager

    private fun findBulkOut(d: UsbDevice): Pair<UsbInterface, UsbEndpoint>? {
        for (i in 0 until d.interfaceCount) {
            val itf = d.getInterface(i)
            for (e in 0 until itf.endpointCount) {
                val ep = itf.getEndpoint(e)
                if (ep.type == UsbConstants.USB_ENDPOINT_XFER_BULK && ep.direction == UsbConstants.USB_DIR_OUT) return itf to ep
            }
        }
        return null
    }

    private fun findUsb(vid: Int, pid: Int): UsbDevice? =
        usbMgr()?.deviceList?.values?.firstOrNull { it.vendorId == vid && it.productId == pid }

    private fun usbClose() {
        try { val c = usbConn; val i = usbIface; if (c != null && i != null) c.releaseInterface(i) } catch (_: Exception) {}
        try { usbConn?.close() } catch (_: Exception) {}
        usbConn = null; usbIface = null; usbEp = null
    }

    @Suppress("UnspecifiedRegisterReceiverFlag")
    private fun usbAskPermission(d: UsbDevice, cb: (Boolean) -> Unit) {
        val m = usbMgr()
        if (m == null) { cb(false); return }
        if (m.hasPermission(d)) { cb(true); return }
        val flags = if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0
        val pi = PendingIntent.getBroadcast(this, 0, Intent(usbPermAction).setPackage(packageName), flags)
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context, intent: Intent) {
                if (intent.action == usbPermAction) {
                    try { unregisterReceiver(this) } catch (_: Exception) {}
                    cb(intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false))
                }
            }
        }
        val filter = IntentFilter(usbPermAction)
        if (Build.VERSION.SDK_INT >= 33) registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        else registerReceiver(receiver, filter)
        m.requestPermission(d, pi)
    }

    private fun setupUsbChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ah_developer/usb")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "list" -> {
                        val out = ArrayList<Map<String, Any>>()
                        for (d in (usbMgr()?.deviceList?.values ?: emptyList<UsbDevice>())) {
                            if (findBulkOut(d) == null) continue
                            var label = ""
                            try { label = d.productName ?: "" } catch (_: Exception) {}
                            if (label.isEmpty()) label = "USB printer " + d.vendorId + ":" + d.productId
                            out.add(mapOf("vid" to d.vendorId, "pid" to d.productId, "name" to label))
                        }
                        result.success(out)
                    }
                    "permission" -> {
                        val d = findUsb(call.argument<Int>("vid") ?: -1, call.argument<Int>("pid") ?: -1)
                        if (d == null) result.success(false) else usbAskPermission(d) { ok -> result.success(ok) }
                    }
                    "open" -> {
                        usbClose()
                        val d = findUsb(call.argument<Int>("vid") ?: -1, call.argument<Int>("pid") ?: -1)
                        val m = usbMgr()
                        val fe = if (d != null) findBulkOut(d) else null
                        if (d == null || m == null || fe == null || !m.hasPermission(d)) {
                            result.success(false)
                        } else {
                            try {
                                val c = m.openDevice(d)
                                if (c == null) { result.success(false) }
                                else {
                                    c.claimInterface(fe.first, true)
                                    usbConn = c; usbIface = fe.first; usbEp = fe.second
                                    result.success(true)
                                }
                            } catch (e: Exception) { e.printStackTrace(); usbClose(); result.success(false) }
                        }
                    }
                    "write" -> {
                        val bytes = call.argument<ByteArray>("bytes")
                        val c = usbConn
                        val ep = usbEp
                        if (bytes == null || c == null || ep == null) { result.success(false) }
                        else Thread {
                            var ok = true
                            try {
                                var off = 0
                                while (off < bytes.size) {
                                    val len = minOf(4096, bytes.size - off)
                                    val slice = bytes.copyOfRange(off, off + len)
                                    if (c.bulkTransfer(ep, slice, slice.size, 5000) < 0) { ok = false; break }
                                    off += len
                                }
                            } catch (e: Exception) { e.printStackTrace(); ok = false }
                            runOnUiThread { result.success(ok) }
                        }.start()
                    }
                    "close" -> { usbClose(); result.success(true) }
                    else -> result.notImplemented()
                }
            }
    }

    private fun copyToDownloads(source: File, fileName: String, folder: String): Boolean {
        if (!source.exists()) return false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
                put(MediaStore.MediaColumns.MIME_TYPE, "application/octet-stream")
                put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/" + folder)
            }
            val uri = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values) ?: return false
            val out = contentResolver.openOutputStream(uri) ?: return false
            out.use { o -> FileInputStream(source).use { it.copyTo(o) } }
            return true
        }
        @Suppress("DEPRECATION")
        val dir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), folder)
        if (!dir.exists() && !dir.mkdirs()) return false
        source.copyTo(File(dir, fileName), overwrite = true)
        return true
    }
}
KT
    echo "=== MainActivity (Downloads channel) ==="; cat "$MAIN"
    grep -q 'ah_developer/downloads' "$MAIN" || { echo "ERROR: Downloads channel not written"; exit 1; }
    grep -q 'ah_developer/usb' "$MAIN" || { echo "ERROR: USB channel not written"; exit 1; }
    # USB host: required=false (USB na ho to bhi app install ho; Play Store filter na lage)
    if ! grep -q 'android.hardware.usb.host' "$MANIFEST"; then
      sed -i '0,/<manifest[^>]*>/s//&\n    <uses-feature android:name="android.hardware.usb.host" android:required="false" \/>/' "$MANIFEST"
    fi
    ;;
  *) echo "WARNING: MainActivity Kotlin nahi hai — Downloads copy channel skip (Share se backup chalta rahega)";;
esac
