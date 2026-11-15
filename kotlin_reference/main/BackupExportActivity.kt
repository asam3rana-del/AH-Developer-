package com.grocerypos.v11.ui

import android.app.DatePickerDialog
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.drawable.GradientDrawable
import android.graphics.pdf.PdfDocument
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import android.print.PageRange
import android.print.PrintAttributes
import android.print.PrintDocumentAdapter
import android.print.PrintDocumentInfo
import android.print.PrintManager
import android.provider.MediaStore
import android.view.Gravity
import android.view.View
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.FileProvider
import androidx.lifecycle.lifecycleScope
import com.grocerypos.v11.CashTransaction
import com.grocerypos.v11.Customer
import com.grocerypos.v11.DayBookPurchase
import com.grocerypos.v11.DayBookSale
import com.grocerypos.v11.Expense
import com.grocerypos.v11.PosDatabase
import com.grocerypos.v11.Product
import com.grocerypos.v11.Purchase
import com.grocerypos.v11.Sale
import com.grocerypos.v11.smallestUnitFactor
import com.grocerypos.v11.Supplier
import com.grocerypos.v11.formatStockBreakdown
import com.grocerypos.v11.util.Loc
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

/**
 * One-button business backup: pulls Sales, Purchases, Day Book, Customers (+ their
 * ledgers), Suppliers (+ their ledgers), Products/Stock, Expenses, and Cash/Bank
 * transactions into a SINGLE combined CSV (opens in Excel) and a SINGLE combined,
 * printable PDF — either for all-time data or a custom date range.
 *
 * Launch from anywhere with:
 *   startActivity(Intent(this, BackupExportActivity::class.java))
 *
 * Manifest requirements (add once, alongside whatever FileProvider the app may
 * already declare for printing receipts — just merge the cache-path entry in):
 *
 *   <activity android:name=".ui.BackupExportActivity" android:exported="false" />
 *
 *   <provider
 *       android:name="androidx.core.content.FileProvider"
 *       android:authorities="${applicationId}.fileprovider"
 *       android:exported="false"
 *       android:grantUriPermissions="true">
 *       <meta-data
 *           android:name="android.support.FILE_PROVIDER_PATHS"
 *           android:resource="@xml/file_paths" />
 *   </provider>
 *
 * res/xml/file_paths.xml (create if it doesn't exist, else add the cache-path line):
 *   <paths>
 *       <cache-path name="backups" path="backups/" />
 *   </paths>
 *
 * No storage permission is needed: files are written to the app's own cache dir
 * (always allowed) for Open/Share/Print, and on Android 10+ a second copy is
 * best-effort saved into the public Downloads/GroceryPOS_Backups folder via
 * MediaStore so the user can find it later from the Files app. On Android 9 and
 * below that public copy is skipped — the cache-dir copy is still fully usable
 * via the Open/Share/Print buttons.
 */
class BackupExportActivity : AppCompatActivity() {

    // ---- Pulled from ThemeManager so the on-screen UI respects dark mode. The PDF export
    // itself (PdfExporter's Paint colors further below) is intentionally left FIXED — it's a
    // printed document, always white-bg/dark-text regardless of the app's current theme. ----
    private var bg = "#F3F4F9"
    private var cardWhite = "#FFFFFF"
    private var cardBorder = "#EEF0F7"
    private var textDark = "#2E3242"
    private var labelGray = "#9AA0B4"
    private var teal = "#0F9B8E"
    private var blue = "#5B6EE8"
    private var green = "#4CAF50"

    private fun loadThemeColors() {
        val p = com.grocerypos.v11.util.ThemeManager.palette(this)
        bg = p.bg
        cardWhite = p.cardWhite
        cardBorder = p.border
        textDark = p.textDark
        labelGray = p.textMuted
        teal = p.flatTealFg
        blue = p.flatBlueFg
        green = p.flatTealFg
    }

    private lateinit var statusText: TextView
    private lateinit var actionsRow: LinearLayout
    private lateinit var fullBackupBtn: TextView
    private lateinit var rangeBackupBtn: TextView

    private var lastPdfFile: File? = null
    private var lastCsvFile: File? = null

    override fun onCreate(b: Bundle?) {
        super.onCreate(b)
        loadThemeColors()

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(24, 40, 24, 32)
            setBackgroundColor(Color.parseColor(bg))
        }

        val headerRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        headerRow.addView(TextView(this).apply {
            text = "\u2190"
            textSize = 18f
            setTextColor(Color.parseColor(textDark))
            setPadding(0, 0, 16, 0)
            setOnClickListener { finish() }
        })
        headerRow.addView(TextView(this).apply {
            text = Loc.t(this@BackupExportActivity, "Backup & Reports", "\u0628\u06CC\u06A9 \u0627\u067E \u0627\u0648\u0631 \u0631\u067E\u0648\u0631\u0679\u0633")
            textSize = 19f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            setTextColor(Color.parseColor(textDark))
        })
        root.addView(headerRow)

        root.addView(TextView(this).apply {
            text = Loc.t(
                this@BackupExportActivity,
                "Exports Sales, Purchases, Day Book, Customer & Supplier ledgers, Stock, Expenses and Cash into one CSV + one printable PDF.",
                "\u0633\u06CC\u0644\u060C \u062E\u0631\u06CC\u062F\u0627\u0631\u06CC\u060C \u0688\u06D2 \u0628\u06A9\u060C \u06A9\u0633\u0679\u0645\u0631 \u0627\u0648\u0631 \u0633\u067E\u0644\u0627\u0626\u0631 \u0644\u062C\u0631\u060C \u0627\u0633\u0679\u0627\u06A9\u060C \u0627\u062E\u0631\u0627\u062C\u0627\u062A \u0627\u0648\u0631 \u06A9\u06CC\u0634 \u06A9\u0648 \u0627\u06CC\u06A9 CSV + \u0627\u06CC\u06A9 \u067E\u0631\u0646\u0679 \u0627\u06D8\u0644 PDF \u0645\u06CC\u06BA \u062C\u0645\u0639 \u06A9\u0631\u062A\u0627 \u06C1\u06D2\u06D4"
            )
            textSize = 12.5f
            setTextColor(Color.parseColor(labelGray))
            setPadding(28, 8, 0, 24)
        })

        fullBackupBtn = actionButton(
            Loc.t(this, "\uD83D\uDCE6 Full Backup (All Data)", "\uD83D\uDCE6 \u0645\u06A9\u0645\u0644 \u0628\u06CC\u06A9 \u0627\u067E (\u062A\u0645\u0627\u0645 \u0688\u06CC\u0679\u0627)"),
            blue
        ) { startFullBackup() }
        root.addView(fullBackupBtn)
        root.addView(View(this).apply { layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 16) })

        rangeBackupBtn = actionButton(
            Loc.t(this, "\uD83D\uDCC5 Custom Date Range Backup", "\uD83D\uDCC5 \u062F\u0631\u062C \u062F\u0648\u0631\u0627\u0646\u06CC\u06C1 \u0628\u06CC\u06A9 \u0627\u067E"),
            teal
        ) { startCustomRangeBackup() }
        root.addView(rangeBackupBtn)

        statusText = TextView(this).apply {
            textSize = 12.5f
            setTextColor(Color.parseColor(labelGray))
            setPadding(4, 20, 4, 8)
        }
        root.addView(statusText)

        actionsRow = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            visibility = View.GONE
        }
        root.addView(actionsRow)

        setContentView(ScrollView(this).apply {
            setBackgroundColor(Color.parseColor(bg))
            addView(root)
        })
    }

    private fun actionButton(label: String, color: String, onClick: () -> Unit): TextView {
        return TextView(this).apply {
            text = label
            textSize = 14.5f
            setTextColor(Color.WHITE)
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            gravity = Gravity.CENTER
            background = GradientDrawable().apply {
                setColor(Color.parseColor(color))
                cornerRadius = 18f
            }
            setPadding(24, 30, 24, 30)
            isClickable = true
            setOnClickListener { onClick() }
        }
    }

    // ---------------- Trigger flows ----------------

    private fun startFullBackup() {
        runBackup(0L, Long.MAX_VALUE, Loc.t(this, "Full", "\u0645\u06A9\u0645\u0644"), "Full")
    }

    private fun startCustomRangeBackup() {
        val cal = Calendar.getInstance()
        DatePickerDialog(this, { _, y, m, d ->
            val startCal = Calendar.getInstance().apply {
                set(y, m, d, 0, 0, 0); set(Calendar.MILLISECOND, 0)
            }
            DatePickerDialog(this, { _, y2, m2, d2 ->
                val endCal = Calendar.getInstance().apply {
                    set(y2, m2, d2, 23, 59, 59); set(Calendar.MILLISECOND, 999)
                }
                if (endCal.timeInMillis < startCal.timeInMillis) {
                    Toast.makeText(this, Loc.t(this, "End date must be after start date", "\u0627\u062E\u062A\u062A\u0627\u0645\u06CC \u062A\u0627\u0631\u06CC\u062E \u0634\u0631\u0648\u0639 \u06A9\u06CC \u062A\u0627\u0631\u06CC\u062E \u0633\u06D2 \u0628\u0639\u062F \u06C1\u0648\u0646\u06CC \u0686\u0627\u06C1\u06CC\u06D2"), Toast.LENGTH_SHORT).show()
                    return@DatePickerDialog
                }
                runBackup(startCal.timeInMillis, endCal.timeInMillis, Loc.t(this, "Range", "\u062F\u0648\u0631\u0627\u0646\u06CC\u06C1"), "Range")
            }, cal.get(Calendar.YEAR), cal.get(Calendar.MONTH), cal.get(Calendar.DAY_OF_MONTH)).apply {
                setTitle(Loc.t(this@BackupExportActivity, "Select End Date", "\u0627\u062E\u062A\u062A\u0627\u0645\u06CC \u062A\u0627\u0631\u06CC\u062E \u0645\u0646\u062A\u062E\u0628 \u06A9\u0631\u06CC\u06BA"))
                datePicker.calendarViewShown = true; datePicker.spinnersShown = false
            }.show()
        }, cal.get(Calendar.YEAR), cal.get(Calendar.MONTH), cal.get(Calendar.DAY_OF_MONTH)).apply {
            setTitle(Loc.t(this@BackupExportActivity, "Select Start Date", "\u0627\u0628\u062A\u062F\u0627\u0626\u06CC \u062A\u0627\u0631\u06CC\u062E \u0645\u0646\u062A\u062E\u0628 \u06A9\u0631\u06CC\u06BA"))
            datePicker.calendarViewShown = true; datePicker.spinnersShown = false
        }.show()
    }

    private fun runBackup(start: Long, end: Long, labelForFile: String, statusTag: String) {
        setBusy(true)
        actionsRow.visibility = View.GONE
        lifecycleScope.launch {
            try {
                val db = PosDatabase.get(this@BackupExportActivity)
                val data = collectBackupData(db, start, end)
                val stamp = SimpleDateFormat("yyyy-MM-dd_HHmm", Locale.getDefault()).format(Date())
                val baseName = "GroceryPOS_Backup_${labelForFile}_$stamp"

                val pdfFile = writePdf(data, start, end, baseName)
                val csvFile = writeCsv(data, start, end, baseName)
                lastPdfFile = pdfFile
                lastCsvFile = csvFile

                tryCopyToDownloads(pdfFile, "application/pdf")
                tryCopyToDownloads(csvFile, "text/csv")

                showResult(pdfFile, csvFile)
            } catch (e: Exception) {
                Toast.makeText(this@BackupExportActivity, "Backup failed: ${e.message ?: "unknown error"}", Toast.LENGTH_LONG).show()
            } finally {
                setBusy(false)
            }
        }
    }

    private fun setBusy(busy: Boolean) {
        fullBackupBtn.isEnabled = !busy
        rangeBackupBtn.isEnabled = !busy
        fullBackupBtn.alpha = if (busy) 0.5f else 1f
        rangeBackupBtn.alpha = if (busy) 0.5f else 1f
        statusText.text = if (busy) Loc.t(this, "Generating backup\u2026", "\u0628\u06CC\u06A9 \u0627\u067E \u062A\u06CC\u0627\u0631 \u06C1\u0648 \u0631\u06C1\u0627 \u06C1\u06D2\u2026") else statusText.text
    }

    // ---------------- Data collection ----------------

    private data class DayBookRow(val date: Long, val type: String, val ref: String, val party: String, val total: Double, val paid: Double, val status: String)
    private data class Totals(val totalSales: Double, val totalPurchases: Double, val totalExpenses: Double, val receivables: Double, val payables: Double, val stockValue: Double)
    private data class BackupData(
        val dayBook: List<DayBookRow>,
        val sales: List<DayBookSale>,
        val purchases: List<DayBookPurchase>,
        val customers: List<Customer>,
        val customerLedgers: Map<Long, List<Sale>>,
        val suppliers: List<Supplier>,
        val supplierLedgers: Map<Long, List<Purchase>>,
        val products: List<Product>,
        val expenses: List<Expense>,
        val cashTx: List<CashTransaction>,
        val totals: Totals
    )

    private suspend fun collectBackupData(db: PosDatabase, start: Long, end: Long): BackupData {
        val sales = db.saleDao().salesBetween(start, end)
        val purchases = db.purchaseDao().purchasesBetween(start, end)
        val dayBook = (
            sales.map { DayBookRow(it.createdAt, "Sale", it.invoice, it.customerName, it.total, it.paid, it.status) } +
            purchases.map { DayBookRow(it.createdAt, "Purchase", it.billNo, it.supplierName, it.total, it.paid, it.status) }
        ).sortedBy { it.date }

        val allCustomers = db.customerDao().all().first()
        val customerLedgers = mutableMapOf<Long, List<Sale>>()
        allCustomers.forEach { c ->
            val ledger = db.saleDao().salesByCustomer(c.id).filter { it.createdAt in start..end }
            if (ledger.isNotEmpty()) customerLedgers[c.id] = ledger
        }

        val allSuppliers = db.supplierDao().all().first()
        val supplierLedgers = mutableMapOf<Long, List<Purchase>>()
        allSuppliers.forEach { s ->
            val ledger = db.purchaseDao().purchasesBySupplier(s.id).filter { it.createdAt in start..end }
            if (ledger.isNotEmpty()) supplierLedgers[s.id] = ledger
        }

        val products = db.productDao().all().first()
        val expenses = db.expenseDao().between(start, end)
        val cashTx = db.cashTransactionDao().between(start, end)

        // FIX: was db.productDao().stockValueTotal() — raw SQL SUM(stock*cost), which
        // overstates value by the unit-conversion factor because `stock` is stored in
        // the product's SMALLEST unit while `cost` is per PRIMARY unit. Same bug already
        // fixed in BalanceSheetActivity/StockReportActivity; computed here the same way.
        val stockValue = products.sumOf { p ->
            val factor = p.smallestUnitFactor()
            val costPerSmallestUnit = if (factor > 0) p.cost / factor else p.cost
            p.stock * costPerSmallestUnit
        }

        val totals = Totals(
            totalSales = db.saleDao().totalSalesBetween(start, end),
            totalPurchases = db.purchaseDao().totalBetween(start, end),
            totalExpenses = db.expenseDao().totalBetween(start, end),
            receivables = db.customerDao().receivablesTotal(),
            payables = db.supplierDao().payablesTotal(),
            stockValue = stockValue
        )

        return BackupData(dayBook, sales, purchases, allCustomers, customerLedgers, allSuppliers, supplierLedgers, products, expenses, cashTx, totals)
    }

    // ---------------- PDF generation ----------------

    /** Minimal paginated PDF table builder — tracks current Y position and starts a
     *  new page automatically when content would overflow the bottom margin. */
    private class PdfReportBuilder {
        private val doc = PdfDocument()
        private var pageNumber = 0
        private var page: PdfDocument.Page? = null
        private var canvas: Canvas? = null
        private var y = 0f

        private val pageWidth = 595
        private val pageHeight = 842
        private val marginX = 36f
        private val marginTop = 40f
        private val marginBottom = 40f
        private val contentWidth = pageWidth - 2 * marginX

        private val titlePaint = Paint().apply { textSize = 16f; isFakeBoldText = true; color = Color.parseColor("#2E3242"); isAntiAlias = true }
        private val subPaint = Paint().apply { textSize = 9f; color = Color.parseColor("#9AA0B4"); isAntiAlias = true }
        private val sectionPaint = Paint().apply { textSize = 13f; isFakeBoldText = true; color = Color.parseColor("#0F9B8E"); isAntiAlias = true }
        private val headerTextPaint = Paint().apply { textSize = 8.5f; isFakeBoldText = true; color = Color.WHITE; isAntiAlias = true }
        private val headerBgPaint = Paint().apply { color = Color.parseColor("#5B6EE8") }
        private val cellPaint = Paint().apply { textSize = 8.3f; color = Color.parseColor("#2E3242"); isAntiAlias = true }
        private val linePaint = Paint().apply { color = Color.parseColor("#EEF0F7"); strokeWidth = 0.6f }
        private val footerPaint = Paint().apply { textSize = 7.5f; color = Color.parseColor("#9AA0B4"); isAntiAlias = true }

        private fun newPage() {
            finishPageIfOpen()
            pageNumber++
            page = doc.startPage(PdfDocument.PageInfo.Builder(pageWidth, pageHeight, pageNumber).create())
            canvas = page!!.canvas
            y = marginTop
        }

        private fun finishPageIfOpen() {
            page?.let {
                canvas?.drawText("Page $pageNumber", pageWidth - marginX - 40f, pageHeight - 20f, footerPaint)
                doc.finishPage(it)
            }
        }

        private fun ensureSpace(height: Float) {
            if (canvas == null) { newPage(); return }
            if (y + height > pageHeight - marginBottom) newPage()
        }

        fun addTitle(text: String) {
            ensureSpace(30f)
            canvas!!.drawText(text, marginX, y + 16f, titlePaint)
            y += 28f
        }

        fun addSubtitle(text: String) {
            ensureSpace(18f)
            canvas!!.drawText(text, marginX, y + 10f, subPaint)
            y += 22f
        }

        fun addSectionHeading(text: String) {
            ensureSpace(26f)
            canvas!!.drawText(text, marginX, y + 14f, sectionPaint)
            y += 20f
        }

        fun addSpacer(h: Float = 10f) { y += h }

        fun addEmptyNote(text: String) {
            ensureSpace(16f)
            canvas!!.drawText(text, marginX, y + 11f, subPaint)
            y += 18f
        }

        fun addTable(columns: List<String>, weights: List<Float>, rows: List<List<String>>) {
            if (rows.isEmpty()) {
                addEmptyNote("\u2014 no records \u2014")
                return
            }
            val totalWeight = weights.sum()
            val colWidths = weights.map { it / totalWeight * contentWidth }

            fun drawHeader() {
                ensureSpace(20f)
                canvas!!.drawRect(marginX, y, marginX + contentWidth, y + 18f, headerBgPaint)
                var x = marginX
                columns.forEachIndexed { i, h ->
                    canvas!!.drawText(truncate(h, colWidths[i], headerTextPaint), x + 4f, y + 13f, headerTextPaint)
                    x += colWidths[i]
                }
                y += 18f
            }

            drawHeader()
            rows.forEach { row ->
                if (y + 15f > pageHeight - marginBottom) {
                    newPage()
                    drawHeader()
                }
                var x = marginX
                row.forEachIndexed { i, cell ->
                    val w = colWidths.getOrElse(i) { 40f }
                    canvas!!.drawText(truncate(cell, w, cellPaint), x + 4f, y + 11f, cellPaint)
                    x += w
                }
                canvas!!.drawLine(marginX, y + 14f, marginX + contentWidth, y + 14f, linePaint)
                y += 15f
            }
            y += 10f
        }

        private fun truncate(text: String, maxWidth: Float, paint: Paint): String {
            if (paint.measureText(text) <= maxWidth - 6) return text
            var t = text
            while (t.isNotEmpty() && paint.measureText("$t\u2026") > maxWidth - 6) t = t.dropLast(1)
            return if (t.isEmpty()) "" else "$t\u2026"
        }

        fun build(): PdfDocument {
            finishPageIfOpen()
            page = null
            return doc
        }
    }

    private fun writePdf(data: BackupData, start: Long, end: Long, baseName: String): File {
        val fmtDt = SimpleDateFormat("dd MMM yyyy hh:mm a", Locale.getDefault())
        val fmtD = SimpleDateFormat("dd MMM yyyy", Locale.getDefault())
        val rangeText = if (start <= 0L) "All Time" else "${fmtD.format(Date(start))}  \u2014  ${fmtD.format(Date(end))}"

        val builder = PdfReportBuilder()
        builder.addTitle("Grocery POS \u2014 Business Backup Report")
        builder.addSubtitle("Period: $rangeText     |     Generated: ${fmtDt.format(Date())}")
        builder.addSpacer(4f)

        builder.addSectionHeading("Business Summary")
        builder.addTable(
            listOf("Metric", "Value"), listOf(2f, 1f),
            listOf(
                listOf("Total Sales (period)", "Rs %.2f".format(data.totals.totalSales)),
                listOf("Total Purchases (period)", "Rs %.2f".format(data.totals.totalPurchases)),
                listOf("Total Expenses (period)", "Rs %.2f".format(data.totals.totalExpenses)),
                listOf("Receivables \u2014 You'll Get (current)", "Rs %.2f".format(data.totals.receivables)),
                listOf("Payables \u2014 You'll Give (current)", "Rs %.2f".format(data.totals.payables)),
                listOf("Current Stock Value (current)", "Rs %.2f".format(data.totals.stockValue))
            )
        )

        builder.addSectionHeading("Day Book (Roznamcha)")
        builder.addTable(
            listOf("Date", "Type", "Ref#", "Party", "Total", "Paid", "Status"),
            listOf(1.6f, 0.8f, 1f, 1.6f, 1f, 1f, 0.9f),
            data.dayBook.map { listOf(fmtDt.format(Date(it.date)), it.type, it.ref, it.party, "Rs %.2f".format(it.total), "Rs %.2f".format(it.paid), it.status) }
        )

        builder.addSectionHeading("Sales")
        builder.addTable(
            listOf("Date", "Invoice", "Customer", "Total", "Paid", "Status"),
            listOf(1.5f, 1.2f, 1.6f, 1f, 1f, 0.9f),
            data.sales.map { listOf(fmtDt.format(Date(it.createdAt)), it.invoice, it.customerName, "Rs %.2f".format(it.total), "Rs %.2f".format(it.paid), it.status) }
        )

        builder.addSectionHeading("Purchases")
        builder.addTable(
            listOf("Date", "Bill#", "Supplier", "Total", "Paid", "Status"),
            listOf(1.5f, 1.2f, 1.6f, 1f, 1f, 0.9f),
            data.purchases.map { listOf(fmtDt.format(Date(it.createdAt)), it.billNo, it.supplierName, "Rs %.2f".format(it.total), "Rs %.2f".format(it.paid), it.status) }
        )

        builder.addSectionHeading("Customers")
        builder.addTable(
            // NEW (Stuck Balance): extra column — 0.00 for every customer without a stuck amount.
            listOf("Name", "Phone", "Opening Bal", "Current Bal", "Stuck Bal"),
            listOf(1.5f, 1.1f, 1f, 1f, 1f),
            data.customers.map { listOf(it.name, it.phone, "Rs %.2f".format(it.openingBalance), "Rs %.2f".format(it.balance), "Rs %.2f".format(it.stuckBalance)) }
        )
        data.customers.forEach { c ->
            val ledger = data.customerLedgers[c.id] ?: return@forEach
            builder.addSpacer(2f)
            builder.addSectionHeading("Ledger: ${c.name}")
            builder.addTable(
                listOf("Date", "Invoice", "Total", "Paid", "Status"),
                listOf(1.6f, 1.2f, 1f, 1f, 0.9f),
                ledger.map { listOf(fmtDt.format(Date(it.createdAt)), it.invoice, "Rs %.2f".format(it.total), "Rs %.2f".format(it.paid), it.status) }
            )
        }

        builder.addSectionHeading("Suppliers")
        builder.addTable(
            listOf("Name", "Phone", "Opening Bal", "Current Bal"),
            listOf(1.6f, 1.2f, 1f, 1f),
            data.suppliers.map { listOf(it.name, it.phone, "Rs %.2f".format(it.openingBalance), "Rs %.2f".format(it.balance)) }
        )
        data.suppliers.forEach { s ->
            val ledger = data.supplierLedgers[s.id] ?: return@forEach
            builder.addSpacer(2f)
            builder.addSectionHeading("Ledger: ${s.name}")
            builder.addTable(
                listOf("Date", "Bill#", "Total", "Paid"),
                listOf(1.6f, 1.2f, 1f, 1f),
                ledger.map { listOf(fmtDt.format(Date(it.createdAt)), it.billNo, "Rs %.2f".format(it.total), "Rs %.2f".format(it.paid)) }
            )
        }

        builder.addSectionHeading("Products & Stock")
        builder.addTable(
            listOf("Barcode", "Name", "Category", "Stock", "Sale Price", "Cost"),
            listOf(1f, 1.6f, 1f, 1.2f, 0.9f, 0.9f),
            data.products.map { listOf(it.barcode, it.name, it.category, it.formatStockBreakdown(), "Rs %.2f".format(it.salePrice), "Rs %.2f".format(it.cost)) }
        )

        builder.addSectionHeading("Expenses")
        builder.addTable(
            listOf("Date", "Category", "Description", "Amount"),
            listOf(1.4f, 1f, 1.8f, 0.9f),
            data.expenses.map { listOf(fmtDt.format(Date(it.createdAt)), it.category, it.description, "Rs %.2f".format(it.amount)) }
        )

        builder.addSectionHeading("Cash / Bank Transactions")
        builder.addTable(
            listOf("Date", "Type", "Method", "Amount", "Reason"),
            listOf(1.4f, 0.8f, 0.9f, 0.9f, 1.6f),
            data.cashTx.map { listOf(fmtDt.format(Date(it.createdAt)), it.type, it.method, "Rs %.2f".format(it.amount), it.reason) }
        )

        val doc = builder.build()
        val dir = File(cacheDir, "backups").apply { mkdirs() }
        val file = File(dir, "$baseName.pdf")
        FileOutputStream(file).use { doc.writeTo(it) }
        doc.close()
        return file
    }

    // ---------------- CSV generation ----------------

    private fun writeCsv(data: BackupData, start: Long, end: Long, baseName: String): File {
        val fmtDt = SimpleDateFormat("dd MMM yyyy hh:mm a", Locale.getDefault())
        val sb = StringBuilder()

        fun section(title: String) { sb.append("\n=== $title ===\n") }
        fun row(vararg cells: String) { sb.append(cells.joinToString(",") { csvEscape(it) }).append("\n") }

        section("BUSINESS SUMMARY")
        row("Metric", "Value")
        row("Total Sales (period)", "%.2f".format(data.totals.totalSales))
        row("Total Purchases (period)", "%.2f".format(data.totals.totalPurchases))
        row("Total Expenses (period)", "%.2f".format(data.totals.totalExpenses))
        row("Receivables (current)", "%.2f".format(data.totals.receivables))
        row("Payables (current)", "%.2f".format(data.totals.payables))
        row("Stock Value (current)", "%.2f".format(data.totals.stockValue))

        section("DAY BOOK")
        row("Date", "Type", "Ref", "Party", "Total", "Paid", "Status")
        data.dayBook.forEach { row(fmtDt.format(Date(it.date)), it.type, it.ref, it.party, "%.2f".format(it.total), "%.2f".format(it.paid), it.status) }

        section("SALES")
        row("Date", "Invoice", "Customer", "Total", "Paid", "Status")
        data.sales.forEach { row(fmtDt.format(Date(it.createdAt)), it.invoice, it.customerName, "%.2f".format(it.total), "%.2f".format(it.paid), it.status) }

        section("PURCHASES")
        row("Date", "Bill No", "Supplier", "Total", "Paid", "Status")
        data.purchases.forEach { row(fmtDt.format(Date(it.createdAt)), it.billNo, it.supplierName, "%.2f".format(it.total), "%.2f".format(it.paid), it.status) }

        section("CUSTOMERS")
        row("Name", "Phone", "Opening Balance", "Current Balance", "Stuck Balance")
        data.customers.forEach { row(it.name, it.phone, "%.2f".format(it.openingBalance), "%.2f".format(it.balance), "%.2f".format(it.stuckBalance)) }

        section("CUSTOMER LEDGERS")
        data.customers.forEach { c ->
            val ledger = data.customerLedgers[c.id] ?: return@forEach
            row("Customer:", c.name)
            row("Date", "Invoice", "Total", "Paid", "Status")
            ledger.forEach { row(fmtDt.format(Date(it.createdAt)), it.invoice, "%.2f".format(it.total), "%.2f".format(it.paid), it.status) }
            sb.append("\n")
        }

        section("SUPPLIERS")
        row("Name", "Phone", "Opening Balance", "Current Balance")
        data.suppliers.forEach { row(it.name, it.phone, "%.2f".format(it.openingBalance), "%.2f".format(it.balance)) }

        section("SUPPLIER LEDGERS")
        data.suppliers.forEach { s ->
            val ledger = data.supplierLedgers[s.id] ?: return@forEach
            row("Supplier:", s.name)
            row("Date", "Bill No", "Total", "Paid")
            ledger.forEach { row(fmtDt.format(Date(it.createdAt)), it.billNo, "%.2f".format(it.total), "%.2f".format(it.paid)) }
            sb.append("\n")
        }

        section("PRODUCTS & STOCK")
        row("Barcode", "Name", "Category", "Stock", "Sale Price", "Cost")
        data.products.forEach { row(it.barcode, it.name, it.category, it.formatStockBreakdown(), "%.2f".format(it.salePrice), "%.2f".format(it.cost)) }

        section("EXPENSES")
        row("Date", "Category", "Description", "Amount")
        data.expenses.forEach { row(fmtDt.format(Date(it.createdAt)), it.category, it.description, "%.2f".format(it.amount)) }

        section("CASH / BANK TRANSACTIONS")
        row("Date", "Type", "Method", "Amount", "Reason")
        data.cashTx.forEach { row(fmtDt.format(Date(it.createdAt)), it.type, it.method, "%.2f".format(it.amount), it.reason) }

        val dir = File(cacheDir, "backups").apply { mkdirs() }
        val file = File(dir, "$baseName.csv")
        file.writeText(sb.toString())
        return file
    }

    private fun csvEscape(s: String): String {
        val needsQuote = s.contains(",") || s.contains("\"") || s.contains("\n")
        val esc = s.replace("\"", "\"\"")
        return if (needsQuote) "\"$esc\"" else esc
    }

    // ---------------- Save a visible copy to Downloads (best effort, API 29+) ----------------

    private fun tryCopyToDownloads(file: File, mime: String) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        try {
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, file.name)
                put(MediaStore.Downloads.MIME_TYPE, mime)
                put(MediaStore.Downloads.RELATIVE_PATH, "Download/GroceryPOS_Backups")
            }
            val uri = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values) ?: return
            contentResolver.openOutputStream(uri)?.use { out -> file.inputStream().use { it.copyTo(out) } }
        } catch (_: Exception) {
            // Best effort only — the cache-dir copy (used by Open/Share/Print) always exists.
        }
    }

    // ---------------- Result UI: Open / Share / Print ----------------

    private fun showResult(pdfFile: File, csvFile: File) {
        statusText.text = Loc.t(this, "Backup ready", "\u0628\u06CC\u06A9 \u0627\u067E \u062A\u06CC\u0627\u0631 \u06C1\u06D2") + ": ${pdfFile.name}"

        actionsRow.removeAllViews()
        actionsRow.addView(resultButton(Loc.t(this, "\uD83D\uDCC4 Open PDF", "\uD83D\uDCC4 PDF \u06A9\u06BE\u0648\u0644\u06CC\u06BA")) { openFile(pdfFile, "application/pdf") })
        actionsRow.addView(spacerView())
        actionsRow.addView(resultButton(Loc.t(this, "\uD83D\uDDA8\uFE0F Print PDF", "\uD83D\uDDA8\uFE0F PDF \u067E\u0631\u0646\u0679 \u06A9\u0631\u06CC\u06BA")) { printPdf(pdfFile) })
        actionsRow.addView(spacerView())
        actionsRow.addView(resultButton(Loc.t(this, "\uD83D\uDCCA Open CSV (Excel)", "\uD83D\uDCCA CSV \u06A9\u06BE\u0648\u0644\u06CC\u06BA (Excel)")) { openFile(csvFile, "text/csv") })
        actionsRow.addView(spacerView())
        actionsRow.addView(resultButton(Loc.t(this, "\uD83D\uDD17 Share Both", "\uD83D\uDD17 \u062F\u0648\u0646\u0648\u06BA \u0634\u06CC\u0626\u0631 \u06A9\u0631\u06CC\u06BA")) { shareFiles(listOf(pdfFile, csvFile)) })
        actionsRow.visibility = View.VISIBLE
    }

    private fun spacerView() = View(this).apply { layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 12) }

    private fun resultButton(label: String, onClick: () -> Unit): TextView {
        return TextView(this).apply {
            text = label
            textSize = 13.5f
            setTextColor(Color.parseColor(textDark))
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            gravity = Gravity.CENTER_VERTICAL
            background = GradientDrawable().apply {
                setColor(Color.parseColor(cardWhite))
                cornerRadius = 14f
                setStroke(1, Color.parseColor(cardBorder))
            }
            setPadding(22, 22, 22, 22)
            isClickable = true
            setOnClickListener { onClick() }
        }
    }

    private fun uriFor(file: File): Uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)

    private fun openFile(file: File, mime: String) {
        val uri = uriFor(file)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, mime)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        try {
            startActivity(intent)
        } catch (e: Exception) {
            Toast.makeText(this, Loc.t(this, "No app found to open this file", "\u0627\u0633 \u0641\u0627\u0626\u0644 \u06A9\u0648 \u06A9\u06BE\u0648\u0644\u0646\u06D2 \u06A9\u06D2 \u0644\u06CC\u06D2 \u06A9\u0648\u0626\u06CC \u0627\u06CC\u067E \u0646\u06C1\u06CC\u06BA \u0645\u0644\u06CC"), Toast.LENGTH_LONG).show()
        }
    }

    private fun shareFiles(files: List<File>) {
        val uris = ArrayList(files.map { uriFor(it) })
        val intent = Intent(Intent.ACTION_SEND_MULTIPLE).apply {
            type = "*/*"
            putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        startActivity(Intent.createChooser(intent, Loc.t(this, "Share Backup", "\u0628\u06CC\u06A9 \u0627\u067E \u0634\u06CC\u0626\u0631 \u06A9\u0631\u06CC\u06BA")))
    }

    private fun printPdf(file: File) {
        val printManager = getSystemService(Context.PRINT_SERVICE) as PrintManager
        val jobName = file.nameWithoutExtension
        printManager.print(jobName, FilePrintAdapter(file, jobName), PrintAttributes.Builder().build())
    }

    /** Feeds an already-generated PDF file straight into Android's Print framework —
     *  works regardless of how the PDF was produced, and lets the user print to a
     *  physical printer or "Save as PDF" through the system print dialog. */
    private class FilePrintAdapter(private val file: File, private val jobName: String) : PrintDocumentAdapter() {
        override fun onLayout(
            oldAttrs: PrintAttributes?,
            newAttrs: PrintAttributes,
            cancellationSignal: CancellationSignal?,
            callback: LayoutResultCallback,
            extras: Bundle?
        ) {
            if (cancellationSignal?.isCanceled == true) {
                callback.onLayoutCancelled()
                return
            }
            val info = PrintDocumentInfo.Builder(jobName)
                .setContentType(PrintDocumentInfo.CONTENT_TYPE_DOCUMENT)
                .build()
            callback.onLayoutFinished(info, true)
        }

        override fun onWrite(
            pages: Array<out PageRange>,
            destination: ParcelFileDescriptor,
            cancellationSignal: CancellationSignal?,
            callback: WriteResultCallback
        ) {
            try {
                FileInputStream(file).use { input ->
                    FileOutputStream(destination.fileDescriptor).use { output ->
                        input.copyTo(output)
                    }
                }
                callback.onWriteFinished(arrayOf(PageRange.ALL_PAGES))
            } catch (e: Exception) {
                callback.onWriteFailed(e.message)
            }
        }
    }
}
