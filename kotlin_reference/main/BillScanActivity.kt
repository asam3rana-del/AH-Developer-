package com.grocerypos.v11.ui

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Bundle
import android.text.Editable
import android.text.InputType
import android.text.TextWatcher
import android.view.Gravity
import android.view.View
import android.widget.*
import androidx.activity.result.IntentSenderRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.documentscanner.GmsDocumentScannerOptions
import com.google.mlkit.vision.documentscanner.GmsDocumentScanning
import com.google.mlkit.vision.documentscanner.GmsDocumentScanningResult
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import org.json.JSONArray
import org.json.JSONObject
import com.grocerypos.v11.R
import com.grocerypos.v11.ui.components.*

/** One OCR-detected (or manually added) row on the review screen, before it becomes
 *  a real PurchaseLine back in PurchaseActivity. Everything here is editable — OCR
 *  is never trusted blindly. */
data class ScannedLine(
    var name: String,
    var qty: String,
    var rate: String,
    var include: Boolean = true
)

/** Lets the user scan (or pick from gallery) a supplier's purchase bill, runs
 *  on-device ML Kit text recognition on it, does a best-effort parse into
 *  item/qty/rate rows, and shows a review/edit screen. Nothing is added to the
 *  Purchase form until the user taps "Confirm & Add" — the result is returned to
 *  PurchaseActivity as a JSON array via RESULT_ITEMS_JSON, and PurchaseActivity
 *  matches each name against existing Products before creating lines.
 *
 *  ---- Accuracy upgrade: ML Kit Document Scanner ----
 *  "Scan Document" now goes through Google's ML Kit Document Scanner
 *  (GmsDocumentScanning) instead of a plain camera photo. It auto-detects the bill's
 *  edges, corrects perspective/skew, and removes shadows/glare before handing back a
 *  clean, cropped image — the OCR step below then runs on that clean image instead
 *  of a raw, possibly tilted/shadowed photo, which meaningfully improves item/qty/rate
 *  read accuracy. It also has its own built-in camera, so the CAMERA permission
 *  dance that used to be here is no longer needed. "Gallery" stays as a fallback for
 *  an already-taken photo and skips the auto-crop/enhance step. */
class BillScanActivity : ThemedActivity() {

    companion object {
        const val RESULT_ITEMS_JSON = "scanned_items_json"
    }

    // Same palette as PurchaseActivity, kept consistent
    // Pulled from ThemeManager so this screen respects dark mode.
    private var bg = "#F4F6F8"
    private var cardWhite = "#FFFFFF"
    private var navy = "#0F9B8E"
    private var teal = "#0B2545"
    private var textDark = "#0B2545"
    private var textMuted = "#7C8798"
    private var border = "#E3E8EE"
    private var red = "#E5484D"

    private fun loadThemeColors() {
        val p = com.grocerypos.v11.util.ThemeManager.palette(this)
        bg = p.bg
        cardWhite = p.cardWhite
        navy = p.teal
        teal = p.navy
        textDark = p.textDark
        textMuted = p.textMuted
        border = p.border
        red = p.red
    }

    private lateinit var statusText: TextView
    private lateinit var imagePreview: ImageView
    private lateinit var reviewHeader: TextView
    private lateinit var reviewContainer: LinearLayout
    private lateinit var addRowManual: TextView
    private lateinit var confirmButton: Button
    private lateinit var progressBar: ProgressBar

    private var photoUri: Uri? = null
    private val scannedLines = mutableListOf<ScannedLine>()

    // ---- ML Kit Document Scanner client. SCANNER_MODE_FULL gives the user the full
    // edit flow (crop handles, filters, shadow/stain removal) before the image comes
    // back to us — this is what actually drives the accuracy improvement, since a
    // clean, well-lit, perspective-corrected image is what on-device OCR needs most. ----
    private val documentScanner by lazy {
        val options = GmsDocumentScannerOptions.Builder()
            .setGalleryImportAllowed(false)
            .setPageLimit(1)
            .setResultFormats(GmsDocumentScannerOptions.RESULT_FORMAT_JPEG)
            .setScannerMode(GmsDocumentScannerOptions.SCANNER_MODE_FULL)
            .build()
        GmsDocumentScanning.getClient(options)
    }

    private val documentScannerLauncher = registerForActivityResult(ActivityResultContracts.StartIntentSenderForResult()) { result ->
        if (result.resultCode == Activity.RESULT_OK) {
            val scanResult = GmsDocumentScanningResult.fromActivityResultIntent(result.data)
            val pageUri = scanResult?.pages?.firstOrNull()?.imageUri
            if (pageUri != null) {
                photoUri = pageUri
                processImage(pageUri)
            } else {
                statusText.text = "Scan mil nahi saka. Dobara koshish karein."
            }
        }
    }

    private val galleryLauncher = registerForActivityResult(ActivityResultContracts.GetContent()) { uri ->
        if (uri != null) { photoUri = uri; processImage(uri) }
    }

    override fun onCreate(b: Bundle?) {
        super.onCreate(b)
        loadThemeColors()

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.parseColor(bg))
        }

        // ---------------- Header ----------------
        val header = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(26, 30, 22, 22)
            background = roundedBg(navy)
        }
        header.addView(TextView(this).apply {
            text = "\u2190"
            textSize = 18f
            setTextColor(Color.WHITE)
            setPadding(6, 0, 24, 0)
            setOnClickListener { finish() }
        })
        header.addView(TextView(this).apply {
            text = "Scan Bill"
            textSize = 18f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            setTextColor(Color.WHITE)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        })
        root.addView(header)

        val scroll = ScrollView(this).apply {
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f)
        }
        val body = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(24, 20, 24, 20)
        }
        scroll.addView(body)
        root.addView(scroll)

        // ---------------- Scan Document / Gallery buttons ----------------
        val scanButtonsRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        scanButtonsRow.addView(
            actionButton("Scan Document", R.drawable.ic_document) { launchDocumentScanner() },
            LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { setMargins(0, 0, 8, 0) }
        )
        scanButtonsRow.addView(
            actionButton("Gallery", R.drawable.ic_image) { galleryLauncher.launch("image/*") },
            LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { setMargins(8, 0, 0, 0) }
        )
        body.addView(scanButtonsRow)
        body.addView(spacer(8))
        body.addView(TextView(this).apply {
            text = "Scan Document = auto crop + clean-up (zyada accurate). Gallery = pehle se li hui photo (bina crop/enhance)."
            textSize = 11f
            setTextColor(Color.parseColor(textMuted))
            setPadding(4, 0, 4, 0)
        })
        body.addView(spacer(16))

        imagePreview = ImageView(this).apply {
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, (180 * resources.displayMetrics.density).toInt())
            scaleType = ImageView.ScaleType.CENTER_CROP
            background = strokedBg(border, cardWhite)
            visibility = View.GONE
        }
        body.addView(imagePreview)
        body.addView(spacer(10))

        progressBar = ProgressBar(this).apply {
            visibility = View.GONE
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
                gravity = Gravity.CENTER
            }
        }
        val progressRow = LinearLayout(this).apply { gravity = Gravity.CENTER; addView(progressBar) }
        body.addView(progressRow)

        statusText = TextView(this).apply {
            text = "Bill scan karein ya gallery se select karein — items neeche detect ho kar dikhenge."
            textSize = 13f
            setTextColor(Color.parseColor(textMuted))
            setPadding(4, 8, 4, 16)
        }
        body.addView(statusText)

        reviewHeader = TextView(this).apply {
            text = "Detected Items — Review & Edit"
            textSize = 13f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            setTextColor(Color.parseColor(teal))
            setPadding(0, 4, 0, 10)
            visibility = View.GONE
        }
        body.addView(reviewHeader)

        reviewContainer = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        body.addView(reviewContainer)

        addRowManual = TextView(this).apply {
            text = "\u2795  Add row manually"
            textSize = 13f
            setTextColor(Color.parseColor(teal))
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            setPadding(4, 12, 4, 40)
            visibility = View.GONE
            setOnClickListener {
                scannedLines.add(ScannedLine("", "", ""))
                renderReviewRows()
            }
        }
        body.addView(addRowManual)

        // ---------------- Footer: Confirm button ----------------
        confirmButton = Button(this).apply {
            text = "CONFIRM & ADD TO PURCHASE"
            setTextColor(Color.WHITE)
            textSize = 14f
            isAllCaps = false
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            background = roundedBg(navy)
            setPadding(0, 26, 0, 26)
            visibility = View.GONE
            setOnClickListener { confirmAndReturn() }
        }
        val footer = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(24, 14, 24, 18)
            setBackgroundColor(Color.parseColor(cardWhite))
            addView(confirmButton)
        }
        root.addView(footer)

        setContentView(root)
    }

    // ---------------- Capture (ML Kit Document Scanner) ----------------
    /** Launches the ML Kit Document Scanner flow. Its own built-in camera means no
     *  runtime CAMERA permission is needed here. Falls back to a plain Toast if Play
     *  Services isn't available/up to date on the device — Gallery still works either way. */
    private fun launchDocumentScanner() {
        val availability = GoogleApiAvailability.getInstance()
        val playServicesStatus = availability.isGooglePlayServicesAvailable(this)
        if (playServicesStatus != ConnectionResult.SUCCESS) {
            Toast.makeText(this, "Google Play Services update chahiye — Gallery se try karein.", Toast.LENGTH_LONG).show()
            return
        }
        documentScanner.getStartScanIntent(this)
            .addOnSuccessListener { intentSender ->
                documentScannerLauncher.launch(IntentSenderRequest.Builder(intentSender).build())
            }
            .addOnFailureListener {
                Toast.makeText(this, "Scanner shuru nahi ho saka: ${it.message}", Toast.LENGTH_LONG).show()
            }
    }

    // ---------------- OCR ----------------
    private fun processImage(uri: Uri) {
        imagePreview.visibility = View.VISIBLE
        imagePreview.setImageURI(uri)
        progressBar.visibility = View.VISIBLE
        statusText.text = "Reading bill…"
        reviewContainer.removeAllViews()
        scannedLines.clear()
        confirmButton.visibility = View.GONE
        reviewHeader.visibility = View.GONE
        addRowManual.visibility = View.GONE

        try {
            val image = InputImage.fromFilePath(this, uri)
            val recognizer = TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
            recognizer.process(image)
                .addOnSuccessListener { visionText ->
                    progressBar.visibility = View.GONE
                    val parsed = parseReceiptText(visionText.text)
                    scannedLines.clear()
                    scannedLines.addAll(parsed)
                    statusText.text = if (parsed.isEmpty())
                        "Koi item detect nahi hua. Neeche manually add karein ya dobara scan karein."
                    else
                        "${parsed.size} lines detect hui — qty/rate check kar ke confirm karein."
                    reviewHeader.visibility = if (parsed.isEmpty()) View.GONE else View.VISIBLE
                    addRowManual.visibility = View.VISIBLE
                    confirmButton.visibility = View.VISIBLE
                    renderReviewRows()
                }
                .addOnFailureListener { e ->
                    progressBar.visibility = View.GONE
                    statusText.text = "OCR fail hui: ${e.message}. Dobara koshish karein."
                    addRowManual.visibility = View.VISIBLE
                    confirmButton.visibility = View.VISIBLE
                }
        } catch (e: Exception) {
            progressBar.visibility = View.GONE
            statusText.text = "Image load nahi hui: ${e.message}"
        }
    }

    /** Best-effort receipt parser. Receipts vary wildly in layout, so this uses simple
     *  heuristics (skip header/footer keywords, pull numbers off each line, treat the
     *  remaining text as the item name) and always leaves the result editable before
     *  it's added to the Purchase form — nothing here is trusted blindly. */
    private fun parseReceiptText(raw: String): List<ScannedLine> {
        val results = mutableListOf<ScannedLine>()
        val numberRegex = Regex("""\d+[.,]?\d*""")
        val skipWords = listOf(
            "total", "subtotal", "cash", "change", "tax", "gst", "invoice", "receipt",
            "bill no", "date", "thank", "cashier", "balance", "discount", "signature"
        )

        raw.lines().forEach { rawLine ->
            val line = rawLine.trim()
            if (line.length < 3) return@forEach
            val lower = line.lowercase()
            if (skipWords.any { lower.contains(it) }) return@forEach

            val numbers = numberRegex.findAll(line).map { it.value.replace(",", "") }.toList()
            if (numbers.isEmpty()) return@forEach

            var namePart = line
            numbers.forEach { namePart = namePart.replaceFirst(it, "") }
            namePart = namePart.replace(Regex("""[xX*×@=]"""), " ")
                .replace(Regex("""\s+"""), " ")
                .trim(' ', '-', '.', ':', ',')

            if (namePart.length < 2) return@forEach

            val qty = if (numbers.size >= 2) numbers[0] else ""
            val rate = if (numbers.size >= 2) numbers[1] else numbers[0]

            results.add(ScannedLine(name = namePart, qty = qty, rate = rate))
        }
        return results
    }

    // ---------------- Review rows ----------------
    private fun renderReviewRows() {
        reviewContainer.removeAllViews()
        scannedLines.forEachIndexed { index, line ->
            val row = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(18, 14, 18, 14)
                background = strokedBg(border, cardWhite)
                layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
                    setMargins(0, 0, 0, 10)
                }
            }

            val topRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
            val includeBox = CheckBox(this).apply { isChecked = line.include }
            includeBox.setOnCheckedChangeListener { _, checked -> line.include = checked }
            topRow.addView(includeBox)

            val nameField = EditText(this).apply {
                setText(line.name)
                hint = "Item name"
                setTextColor(Color.parseColor(textDark))
                textSize = 14f
                background = null
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            }
            nameField.addTextChangedListener(object : TextWatcher {
                override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
                override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
                override fun afterTextChanged(s: Editable?) { line.name = s.toString() }
            })
            topRow.addView(nameField)

            topRow.addView(TextView(this).apply {
                text = "\u2715"
                textSize = 14f
                setTextColor(Color.parseColor(red))
                setPadding(12, 0, 4, 0)
                setOnClickListener {
                    scannedLines.removeAt(index)
                    renderReviewRows()
                }
            })
            row.addView(topRow)

            val numRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; setPadding(0, 8, 0, 0) }
            val qtyField = EditText(this).apply {
                setText(line.qty)
                hint = "Qty"
                inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL
                setTextColor(Color.parseColor(textDark))
                textSize = 13f
                background = strokedBg(border, "#FAFBFC")
                setPadding(14, 10, 14, 10)
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { setMargins(0, 0, 6, 0) }
            }
            qtyField.addTextChangedListener(object : TextWatcher {
                override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
                override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
                override fun afterTextChanged(s: Editable?) { line.qty = s.toString() }
            })
            val rateField = EditText(this).apply {
                setText(line.rate)
                hint = "Rate"
                inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL
                setTextColor(Color.parseColor(textDark))
                textSize = 13f
                background = strokedBg(border, "#FAFBFC")
                setPadding(14, 10, 14, 10)
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { setMargins(6, 0, 0, 0) }
            }
            rateField.addTextChangedListener(object : TextWatcher {
                override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
                override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
                override fun afterTextChanged(s: Editable?) { line.rate = s.toString() }
            })
            numRow.addView(qtyField)
            numRow.addView(rateField)
            row.addView(numRow)

            reviewContainer.addView(row)
        }
    }

    private fun confirmAndReturn() {
        val included = scannedLines.filter { it.include && it.name.isNotBlank() }
        if (included.isEmpty()) {
            Toast.makeText(this, "Kam az kam ek item select karein", Toast.LENGTH_SHORT).show()
            return
        }
        val arr = JSONArray()
        included.forEach { line ->
            arr.put(JSONObject().apply {
                put("name", line.name.trim())
                put("qty", line.qty.toDoubleOrNull() ?: 1.0)
                put("rate", line.rate.toDoubleOrNull() ?: 0.0)
            })
        }
        setResult(Activity.RESULT_OK, Intent().putExtra(RESULT_ITEMS_JSON, arr.toString()))
        finish()
    }

    // ---------------- UI helpers ----------------
    private fun tintedDrawable(iconRes: Int, tintHex: String, sizeDp: Int = 16): android.graphics.drawable.Drawable? {
        val d = androidx.core.content.ContextCompat.getDrawable(this, iconRes)?.mutate() ?: return null
        d.setTint(Color.parseColor(tintHex))
        val size = (sizeDp * resources.displayMetrics.density).toInt()
        d.setBounds(0, 0, size, size)
        return d
    }

    private fun actionButton(label: String, iconRes: Int? = null, onClick: () -> Unit) = Button(this).apply {
        text = label
        setTextColor(Color.WHITE)
        textSize = 13.5f
        isAllCaps = false
        setTypeface(typeface, android.graphics.Typeface.BOLD)
        background = roundedBg(teal)
        setPadding(0, 22, 0, 22)
        if (iconRes != null) {
            setCompoundDrawablesRelative(tintedDrawable(iconRes, "#FFFFFF", 17), null, null, null)
            compoundDrawablePadding = (8 * resources.displayMetrics.density).toInt()
        }
        setOnClickListener { onClick() }
    }

    // spacer() now comes from the shared UiHelpers.kt (item #24 dedup) — was a
    // byte-identical private copy here before.
}
