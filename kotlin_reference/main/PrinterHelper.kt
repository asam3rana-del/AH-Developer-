package com.grocerypos.v11.util

import android.annotation.SuppressLint
import android.app.Activity
import android.app.PendingIntent
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothSocket
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import android.os.Build
import android.text.Layout
import android.text.StaticLayout
import android.text.TextDirectionHeuristics
import android.text.TextPaint
import android.text.TextUtils
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import java.io.OutputStream
import java.util.UUID

/**
 * Handles printing plain-text and Urdu ESC/POS receipts to a 58mm thermal printer,
 * over either Bluetooth (paired device) or USB (host mode).
 *
 * Manifest permissions needed (Bluetooth):
 *   <uses-permission android:name="android.permission.BLUETOOTH" />
 *   <uses-permission android:name="android.permission.BLUETOOTH_ADMIN" />
 *   <uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
 *   <uses-permission android:name="android.permission.BLUETOOTH_SCAN" />
 *
 * USB needs no manifest permission declaration — access is granted per-device
 * at runtime via a system dialog (requestUsbPermission below).
 */
object PrinterHelper {

    enum class PrinterType { BLUETOOTH, USB }

    /**
     * A structured receipt line, used by [printReceiptLines].
     *
     * Why structured instead of one big pre-formatted string: a plain string
     * with manual space-padding (e.g. "Subtotal" + spaces + "Rs 100") only
     * lines up in a *monospace* font. We render with a real (often
     * proportional/Nastaliq) font, so padding-by-character-count never
     * actually aligns on the printed bitmap. Structured lines let us align by
     * *measured pixel width* instead, and pick RTL/LTR per line rather than
     * for the whole receipt at once (which previously scrambled English
     * lines whenever any Urdu text appeared anywhere in the receipt).
     */
    sealed class ReceiptLine {
        /** [tight] = pack this line closer to its neighbours (used for the header block and the totals block). */
        data class Center(val text: String, val bold: Boolean = false, val tight: Boolean = false) : ReceiptLine()
        data class Left(val text: String) : ReceiptLine()
        /** Label/value pair rendered as two columns, each right/left-aligned by measured width.
         *  [bold] renders both sides in bold — used to make the TOTAL line stand out. */
        data class TwoCol(val left: String, val right: String, val bold: Boolean = false, val tight: Boolean = false) : ReceiptLine()
        data class Blank(val heightPx: Int = 10) : ReceiptLine()
        object Divider : ReceiptLine()

        /**
         * A bordered table row — one or more cells laid out in fixed-width
         * columns (proportioned by [weights]), with a vertical divider line drawn
         * between every column and a horizontal divider line drawn under the row.
         *
         * Kept for callers that still want a ruled grid somewhere on the receipt.
         * The item table itself no longer uses this (see [Row3]/[ItemRow] below) —
         * the customer wanted the printed item list to match the on-screen preview
         * card, which has no grid lines at all.
         *
         * [cells] and [weights] must be the same size — weights are relative (they
         * don't need to sum to any particular number; a column with weight 3 is 3x
         * as wide as one with weight 1).
         *
         * [bold] renders the row in bold (used for the header row).
         * [topBorder] additionally draws a line above this row.
         *
         * Cell text that doesn't fit its column width is ellipsized ("…") rather
         * than wrapped, so every row stays exactly one line tall and the grid lines
         * stay perfectly straight.
         */
        data class TableRow(
            val cells: List<String>,
            val weights: List<Float>,
            val bold: Boolean = false,
            val topBorder: Boolean = false
        ) : ReceiptLine()

        /**
         * Plain, borderless 3-column row (col1 left/RTL-aware, col2 centered,
         * col3 right-aligned) — used for the "Item / Qty / Amount" header row
         * so it matches the on-screen preview card, which has no grid.
         */
        data class Row3(
            val col1: String,
            val col2: String,
            val col3: String,
            // Amount widened further (2.2 -> 2.7) per request — Item trimmed to
            // compensate so the row keeps using the same total width.
            val weights: List<Float> = listOf(2.3f, 1.2f, 2.7f),
            val bold: Boolean = false
        ) : ReceiptLine()

        /**
         * FIX (print didn't match preview — "print view ki tarah print ana chahiye"):
         * the on-screen receipt card now has its own RATE column between ITEM and
         * QTY (see BillPreviewActivity's header row: ITEM / RATE / QTY / AMOUNT),
         * but the printed header was still the older 3-column Row3 ("Item / Qty /
         * Amount") with no Rate label at all. Row4 is the 4-column borderless
         * equivalent — col1 left/RTL-aware, col2 & col3 centered, col4
         * right-aligned — used for the printed "Item / Rate / Qty / Amount"
         * header so it lines up with what the customer already sees on screen.
         */
        data class Row4(
            val col1: String,
            val col2: String,
            val col3: String,
            val col4: String,
            val weights: List<Float> = listOf(2f, 1f, 1f, 1f),
            val bold: Boolean = false
        ) : ReceiptLine()

        /**
         * One item row rendered exactly like the on-screen preview card:
         * line 1 is the item name (bold, left/RTL-aware) with qty centered and
         * amount right-aligned in the same row; line 2 is "@ rate" in smaller
         * plain text directly under the name. No borders, no grid — just the
         * two stacked lines per item, same as BillPreviewActivity's `kv`-style
         * item rows on screen.
         */
        /**
         * FIX (item name getting truncated — "item k nechey item name aye"): the item
         * name previously shared one line with qty/amount, squeezed into a narrow
         * column, so longer (especially Urdu) names got ellipsized. Now rendered as:
         *   line 1: <name>                                    (full row width, bold)
         *   line 2: <rate>              <qty>              <amount>   (amount bold)
         * FIX (print didn't match preview): line 2 used to read
         * "<qty> @ <rate> <amount>", which put qty first and buried rate behind an
         * "@" — different order from the on-screen card's ITEM / RATE / QTY / AMOUNT
         * header. Line 2 now shows rate / qty / amount, left-to-right, in the same
         * order as the header (and the preview card), just wrapped onto its own line
         * under the name instead of a plain "@ rate" note.
         * [weights] is kept for source compatibility with existing call sites (the
         * shared header Row4 above still uses it) but is no longer used by ItemRow's
         * own layout, since line 1 now always spans the full row width.
         */
        data class ItemRow(
            val name: String,
            val qty: String,
            val rate: String,
            val amount: String,
            val weights: List<Float> = listOf(2.8f, 1.2f, 2.2f)
        ) : ReceiptLine()

        /**
         * "Gate Pass" wholesaler-slip layout — one item row laid out EXACTLY
         * like the reference wholesaler slip — Amount, Qty and Rate as three
         * plain columns on the LEFT, and the item name (RTL-aware, Urdu/English
         * mixed) filling the remaining width on the RIGHT, all on a single
         * borderless line — instead of ItemRow's two-stacked-lines layout. Used
         * with the matching "Amount / Qty / Rate / Barcode" Row4 header above it
         * so the printed table matches the requested column order/labels.
         * FIX ("Amount. Qty Rate Barcode" — 3rd column relabeled from CTN to
         * Rate): this field used to be [ctn] (qty rounded to a whole number);
         * renamed to [rate] and now carries the per-unit sale/purchase rate
         * instead, to match the requested header.
         */
        data class GateRow(
            val amount: String,
            val qty: String,
            val rate: String,
            val name: String,
            val weights: List<Float> = listOf(1.15f, 0.85f, 0.7f, 2.3f),
            val bold: Boolean = false
        ) : ReceiptLine()

        /**
         * One item row laid out EXACTLY like the on-screen Bill Preview card's item
         * table ("print bhi aesa hi aye" — the print should match the preview card
         * pixel-for-pixel in structure): four columns — ITEM (name, bold,
         * RTL-aware, ellipsized), AMOUNT (bold, centered), QTY (plain, centered,
         * already carries its unit e.g. "4 Shell"), RATE (plain, right-aligned) —
         * using the SAME column proportions as the printed "ITEM / AMOUNT / QTY /
         * RATE" Row4 header above it (default weights 2:1:1:1, matching the
         * on-screen card's LinearLayout weights), unlike the older [ItemRow]/
         * [GateRow] layouts which use different column counts/orders for other
         * receipt styles.
         */
        data class PreviewItemRow(
            val name: String,
            val amount: String,
            val qty: String,
            val rate: String,
            val weights: List<Float> = listOf(2f, 1f, 1f, 1f),
            /** Urdu-bill style: ITEM sits at the RIGHT edge and the columns run right-to-left
             *  (visually AMOUNT | RATE | QTY | ITEM). Weights stay in logical order name/amount/qty/rate. */
            val mirrored: Boolean = false
        ) : ReceiptLine()
    }

    // Urdu/Arabic item names were reported "muskil se parha jata" (barely readable)
    // at the same small size used for numeric cells. Item names are drawn noticeably
    // bigger and slightly bolder than the numeric columns for legibility on thermal
    // print, on top of the wider item column.
    // FIX (overall print size — "print size bht bara ha"): the item name now gets its
    // own full-width line (see ReceiptLine.ItemRow below) instead of sharing a narrow
    // column with qty/amount, so it no longer needs as large a boost to stay legible.
    // Trimmed 1.2 -> 1.1, which combined with the tighter padding below noticeably
    // shortens the printed receipt without making names hard to read.
    private const val ARABIC_ITEM_FONT_BOOST = 1.1f

    private val SPP_UUID: UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")
    private const val ACTION_USB_PERMISSION = "com.grocerypos.v11.USB_PERMISSION"

    // ESC @ - initialize/reset printer
    private val ESC_INIT = byteArrayOf(0x1B, 0x40)

    // REVERTED: an ESC 7 "heating density" command (0x1B 0x37 ...) was tried here as an
    // experimental hardware-level darkness boost. On this printer it was NOT interpreted
    // as a heating command — the firmware read it as something else entirely (looked like
    // a code-page/character-set switch) and the whole receipt printed as corrupted
    // symbol/CJK garbage afterward. Removed completely; do not re-add this command for
    // this printer. Darkness improvements are limited to the bitmap-level changes above
    // (FILL_AND_STROKE synthetic bold + the 195 luminance threshold) — if those aren't
    // enough, the fix has to be a hardware one (printer settings/firmware, or the head
    // itself), not another blind ESC/POS command guess.

    // Feed a few lines then partial cut (GS V 1) - supported by most 58mm printers.
    // NOTE: printers with no cutter hardware (most handheld/mobile 58mm Bluetooth
    // printers) simply ignore an unsupported cut command, so this is safe to always send.
    //
    // FIX (too much blank paper at top/bottom of every receipt — "page upper and
    // bottom bht zaida use ho raha"): this was 3 line-feeds (0x0A x3). On a
    // continuous roll with no cutter (the common case per the note above), that
    // blank feed after receipt N doesn't disappear — it just sits on the paper
    // directly above receipt N+1's first line, so it reads as wasted space at
    // BOTH the bottom of one receipt and the top of the next. Trimmed to 2, which
    // is still enough tear-off/cutter clearance for the last printed line on
    // every printer this was tested against. If your printer has an auto-cutter
    // FIX 2 (still too much blank paper — "top aur bottom ma page zayda use ho
    // raha ha", follow-up round): 2 was still leaving a visible gap. Trimmed to
    // 1 line-feed before the cut command — the GS V 1 cut itself needs no extra
    // feed to be safe on the printers this was tested against, it just cuts
    // where the paper already is. If a printer with an actual auto-cutter ever
    // nicks the last printed line with this value, raise it back to 2.
    private val FEED_AND_CUT = byteArrayOf(0x0A, 0x1D, 0x56, 0x01)

    // Thermal print-head width in dots. A standard 58mm printer's head is 384 dots
    // (48 bytes per raster row @ 203dpi); 80mm printers are 576.
    //
    // FIX (receipt prints as random Chinese/CJK symbols + ";;;;" rows — "print thk kro
    // is tarah a raha ha"): this was hard-coded to 480 (60 bytes/row), a value picked
    // earlier only to shrink the blank strip on the right edge. On a printer whose
    // head is 384 dots, a GS v 0 raster command declaring 60 bytes/row is wider than
    // the printer can accept — the firmware rejects the command and then prints the
    // raw image bytes as if they were TEXT (in its Chinese GBK code page, which is
    // exactly the CJK-looking garbage in the photo). The default is now the safe 384,
    // and the width is a per-device setting (Settings > Printer > PRINT WIDTH,
    // stored as app_setting "printer_dots") so a wider printer can be tuned up
    // without a rebuild.
    const val DEFAULT_DOTS_WIDTH = 384
    private const val MIN_DOTS_WIDTH = 256
    private const val MAX_DOTS_WIDTH = 576

    /** Clamps to a sane range and rounds down to a multiple of 8 (raster rows are whole bytes). */
    fun normalizeDotsWidth(requested: Int?): Int {
        val w = (requested ?: DEFAULT_DOTS_WIDTH).coerceIn(MIN_DOTS_WIDTH, MAX_DOTS_WIDTH)
        return w - (w % 8)
    }

    // FIX (print reliability): a whole multi-item receipt was previously rendered as
    // ONE raster image and sent to the printer in a single GS v 0 command. Long bills
    // (many items) produce a tall bitmap, and a lot of cheap 58mm ESC/POS printers
    // (Bluetooth SPP in particular) have a small internal receive/render buffer — a
    // single oversized raster command either gets truncated, prints garbled/blank, or
    // the printer just stops responding partway through. This is the most common cause
    // of "print theek nahi aata" on longer bills. The fix: split the bitmap into safe
    // horizontal strips and send them as separate GS v 0 commands, with a short pause
    // between each so the printer's buffer has time to actually print/clear before the
    // next chunk arrives.
    //
    // FIX 2 (overlapping / "double exposure" print — receipt lines printing on top of
    // each other, e.g. "Date" merging into the next line, item names showing as
    // garbled/tangled marks): real-world testing on a customer's printer showed this
    // STILL happening with the original 200px/40ms values, and even after the first
    // round of tuning (80px / 3ms-per-row / 60ms floor) some units continued to
    // overlap — most visible on Urdu lines, where two overlapping cursive lines
    // produce meaningless tangled shapes instead of legible letters (this is what
    // looked like "garbled Urdu font" but was actually two strips overlapping on the
    // paper, not a font/shaping problem).
    //
    // Root cause: the printer was still physically feeding/printing strip N when
    // strip N+1 arrived, so strip N+1 started printing before the paper had advanced
    // past strip N. Three changes tighten this further:
    //   1. Smaller strips (48px instead of 80px) — even less data per raster command,
    //      so each one finishes printing/feeding faster and pacing is finer-grained.
    //   2. A larger per-row pause (6ms/row instead of 3ms/row) and a higher minimum
    //      floor (100ms instead of 60ms) — gives slower mechanical feed more margin.
    //   3. A short settle delay right after ESC_INIT (before the first strip) and
    //      right before FEED_AND_CUT (after the last strip) — some printers need a
    //      moment to finish initializing / finish their last print job before the
    //      next command is safe to send.
    // If overlap still happens on your printer, raise MS_PER_STRIP_ROW further (e.g.
    // 6f -> 9f or 12f) and/or MIN_INTER_CHUNK_DELAY_MS (e.g. 100 -> 150) — those are
    // the two knobs to tune per-printer-model. Slower prints are always safer than
    // overlapping ones.
    // SPEED TUNING: fewer, slightly larger strips means fewer separate write+flush
    // round-trips (each one has its own Bluetooth/USB overhead), which is a real
    // speed win — while the *pacing per row* (MS_PER_STRIP_ROW) still guarantees each
    // strip has fully fed through the printer before the next one lands, so the
    // anti-overlap fix from before is preserved. Only raise MAX_STRIP_HEIGHT_PX
    // further if you also see garbled/overlapping print return — smaller strips are
    // always the safer fallback.
    //
    // FIX 3 (item table now matches the on-screen preview): the ruled grid table
    // (TableRow) was replaced for the item list with borderless Row3/ItemRow lines
    // (see below), which also has the side benefit of fewer draw operations per
    // item (no grid strokes), so this doesn't fight the anti-overlap pacing above.
    // FIX 4 ("ye print aya ha" — a SHORT bill, only 1-4 items, still printed as
    // corrupted CJK/symbol garbage starting just 2-3 lines in, right after the shop
    // header, even on this printer after a full power-cycle restart): garbling on a
    // short receipt rules out the earlier "tall bitmap overruns the buffer" cause —
    // there just isn't enough data here for that. This is the printer choking on the
    // faster strip/timing values below (64px / 90ms floor / 5ms-per-row), which were
    // raised for print speed at the cost of the anti-overlap margin from FIX 2. Per
    // this file's own SPEED TUNING note ("smaller strips are always the safer
    // fallback"), reverted below the original safe values (48px/100ms/6ms) to a more
    // conservative setting, since this printer garbles even on short bills.
    // FIX 5 ("print half k bad phr kharab ho gia" — a long, multi-item bill still
    // turned to CJK/symbol garbage partway through, on a printer where FIX 4's
    // values (32px / 150ms floor / 8ms-per-row / 256B pieces / 12ms gap) were not
    // enough margin): every "print reliability" knob in this block only has one
    // safe direction to move — smaller/slower — so all five are tightened together
    // one more notch. This trades a bit of total print time for buffer safety; if
    // garbling STILL happens after this on a given unit, halve MAX_STRIP_HEIGHT_PX
    // again (e.g. 24 -> 16) and/or raise BT_WRITE_PIECE_GAP_MS before touching
    // anything else — those two are the most effective per past rounds.
    private const val MAX_STRIP_HEIGHT_PX = 24
    private const val MIN_INTER_CHUNK_DELAY_MS = 200L
    private const val MS_PER_STRIP_ROW = 10f
    private const val SETTLE_DELAY_MS = 150L
    private const val BT_WRITE_PIECE_BYTES = 128
    private const val BT_WRITE_PIECE_GAP_MS = 20L

    /** How long to pause after sending a strip of [stripHeightPx] dots, before sending
     *  the next one — scaled to strip height with a safe minimum floor. See FIX 2 above. */
    private fun interChunkDelayFor(stripHeightPx: Int): Long =
        maxOf(MIN_INTER_CHUNK_DELAY_MS, (stripHeightPx * MS_PER_STRIP_ROW).toLong())

    // Optional bundled Urdu font for correct Nastaliq/Naskh shaping when printing.
    // Place a font file at app/src/main/assets/fonts/NotoNastaliqUrdu-Regular.ttf
    // (or change this path) to use it; if missing, we fall back to the system
    // default font, which still renders Urdu via Android's own script fallback.
    private const val URDU_FONT_ASSET_PATH = "fonts/NotoNastaliqUrdu-Regular.ttf"

    // ================= BLUETOOTH =================

    fun hasBluetoothPermission(context: Context): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            ContextCompat.checkSelfPermission(
                context, android.Manifest.permission.BLUETOOTH_CONNECT
            ) == PackageManager.PERMISSION_GRANTED
        } else true
    }

    fun requestBluetoothPermission(activity: Activity, requestCode: Int) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            ActivityCompat.requestPermissions(
                activity,
                arrayOf(
                    android.Manifest.permission.BLUETOOTH_CONNECT,
                    android.Manifest.permission.BLUETOOTH_SCAN
                ),
                requestCode
            )
        }
    }

    /** Already-paired Bluetooth devices (pair them from phone Settings first). */
    @SuppressLint("MissingPermission")
    fun pairedDevices(context: Context): List<BluetoothDevice> {
        if (!hasBluetoothPermission(context)) return emptyList()
        val adapter = BluetoothAdapter.getDefaultAdapter() ?: return emptyList()
        return adapter.bondedDevices?.toList() ?: emptyList()
    }

    // FIX ("printer on hai, range mein hai, phir bhi 'print fail ho gaya'"):
    // Android's normal createRfcommSocketToServiceRecord() connect asks the
    // remote device's SDP server which RFCOMM channel its SPP service lives
    // on, then connects to that. Plenty of cheap/clone 58mm Bluetooth
    // printers don't answer SDP queries properly (or answer with a channel
    // that doesn't match reality), so that connect() throws even though the
    // printer is on, paired, and in range — it's a connection-negotiation
    // failure, not a "printer not reachable" problem. The well-known
    // workaround (used by most ESC/POS printer libraries) is to fall back to
    // an "insecure" RFCOMM socket opened directly on channel 1 via reflection
    // (createRfcommSocket is hidden API, so it's not in the public
    // BluetoothDevice interface) — this skips the SDP lookup entirely and is
    // what most of these printers actually expect. We try the normal/secure
    // path first (works fine on printers with proper SDP), and only fall
    // back to the reflection path if that throws.
    @SuppressLint("MissingPermission")
    private fun openBluetoothSocket(device: BluetoothDevice): BluetoothSocket {
        return try {
            val socket = device.createRfcommSocketToServiceRecord(SPP_UUID)
            socket.connect()
            socket
        } catch (e: Exception) {
            val fallback = try {
                val method = device.javaClass.getMethod("createRfcommSocket", Int::class.javaPrimitiveType)
                method.invoke(device, 1) as BluetoothSocket
            } catch (reflectEx: Exception) {
                throw e // reflection itself failed — surface the original error
            }
            fallback.connect()
            fallback
        }
    }

    @SuppressLint("MissingPermission")
    private fun sendBluetoothBytes(context: Context, macAddress: String, payload: ByteArray): Boolean {
        if (!hasBluetoothPermission(context)) return false
        val adapter = BluetoothAdapter.getDefaultAdapter() ?: return false
        var socket: BluetoothSocket? = null
        return try {
            val device = adapter.getRemoteDevice(macAddress)
            adapter.cancelDiscovery()
            socket = openBluetoothSocket(device)
            val out: OutputStream = socket.outputStream
            out.write(payload)
            out.flush()
            true
        } catch (e: Exception) {
            e.printStackTrace()
            false
        } finally {
            try { socket?.close() } catch (_: Exception) {}
        }
    }

    /**
     * Opens one Bluetooth connection and writes ESC_INIT, then each chunk (flushed
     * individually with a pause scaled to that chunk's strip height — see
     * [interChunkDelayFor] — before the next one is sent), then FEED_AND_CUT — all over
     * the same socket. Used instead of [sendBluetoothBytes] for raster-image receipts
     * so long bills don't overrun the printer's buffer or overlap print (see the FIX
     * comments on [MAX_STRIP_HEIGHT_PX]).
     */
    @SuppressLint("MissingPermission")
    private fun sendBluetoothChunks(context: Context, macAddress: String, chunks: List<Pair<ByteArray, Int>>): Boolean {
        if (!hasBluetoothPermission(context)) return false
        val adapter = BluetoothAdapter.getDefaultAdapter() ?: return false
        var socket: BluetoothSocket? = null
        return try {
            val device = adapter.getRemoteDevice(macAddress)
            adapter.cancelDiscovery()
            socket = openBluetoothSocket(device)
            val out: OutputStream = socket.outputStream

            out.write(ESC_INIT)
            out.flush()
            // Settle delay — see FIX 2 above. Let the printer finish initializing
            // before the first raster strip lands on it.
            Thread.sleep(SETTLE_DELAY_MS)

            for ((chunk, stripHeight) in chunks) {
                // FIX (garbage after a few lines): a whole strip used to be pushed in a
                // single write(). Cheap Bluetooth SPP printers have no flow control and a
                // small receive buffer — if it overflows, bytes are silently dropped in
                // the MIDDLE of a raster command, the printer loses its place, and
                // everything after that is printed as text garbage. Feeding each strip in
                // small pieces with a tiny gap keeps the buffer from ever overflowing.
                var offset = 0
                while (offset < chunk.size) {
                    val len = minOf(BT_WRITE_PIECE_BYTES, chunk.size - offset)
                    out.write(chunk, offset, len)
                    out.flush()
                    offset += len
                    if (offset < chunk.size) Thread.sleep(BT_WRITE_PIECE_GAP_MS)
                }
                Thread.sleep(interChunkDelayFor(stripHeight))
            }

            // Settle delay before feed/cut — give the last strip time to fully print.
            Thread.sleep(SETTLE_DELAY_MS)
            out.write(FEED_AND_CUT)
            out.flush()
            true
        } catch (e: Exception) {
            e.printStackTrace()
            false
        } finally {
            try { socket?.close() } catch (_: Exception) {}
        }
    }

    // ================= USB =================

    /** Currently connected USB devices — shown to the user for manual pick. */
    fun usbDevices(context: Context): List<UsbDevice> {
        val manager = context.getSystemService(Context.USB_SERVICE) as? UsbManager ?: return emptyList()
        return manager.deviceList.values.toList()
    }

    fun hasUsbPermission(context: Context, device: UsbDevice): Boolean {
        val manager = context.getSystemService(Context.USB_SERVICE) as? UsbManager ?: return false
        return manager.hasPermission(device)
    }

    /** Shows the system "Allow app to access USB device" dialog. Result arrives via the passed callback. */
    fun requestUsbPermission(context: Context, device: UsbDevice, onResult: (granted: Boolean) -> Unit) {
        val manager = context.getSystemService(Context.USB_SERVICE) as? UsbManager
        if (manager == null) { onResult(false); return }

        if (manager.hasPermission(device)) { onResult(true); return }

        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
            PendingIntent.FLAG_MUTABLE else 0
        val permissionIntent = PendingIntent.getBroadcast(
            context, 0, Intent(ACTION_USB_PERMISSION), flags
        )

        val receiver = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context, intent: Intent) {
                if (intent.action == ACTION_USB_PERMISSION) {
                    val granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
                    try { context.unregisterReceiver(this) } catch (_: Exception) {}
                    onResult(granted)
                }
            }
        }
        val filter = IntentFilter(ACTION_USB_PERMISSION)
        ContextCompat.registerReceiver(context, receiver, filter, ContextCompat.RECEIVER_NOT_EXPORTED)
        manager.requestPermission(device, permissionIntent)
    }

    private fun findPrinterInterfaceAndEndpoint(device: UsbDevice): Pair<UsbInterface, UsbEndpoint>? {
        for (i in 0 until device.interfaceCount) {
            val usbInterface = device.getInterface(i)
            for (e in 0 until usbInterface.endpointCount) {
                val endpoint = usbInterface.getEndpoint(e)
                if (endpoint.type == UsbConstants.USB_ENDPOINT_XFER_BULK &&
                    endpoint.direction == UsbConstants.USB_DIR_OUT
                ) {
                    return usbInterface to endpoint
                }
            }
        }
        return null
    }

    /** Sends raw ESC/POS bytes to a USB printer. Call requestUsbPermission first if needed. */
    private fun sendUsbBytes(context: Context, deviceName: String, payload: ByteArray): Boolean {
        val manager = context.getSystemService(Context.USB_SERVICE) as? UsbManager ?: return false
        val device = manager.deviceList.values.find { it.deviceName == deviceName } ?: return false
        if (!manager.hasPermission(device)) return false

        val (usbInterface, endpoint) = findPrinterInterfaceAndEndpoint(device) ?: return false
        var connection: UsbDeviceConnection? = null
        return try {
            connection = manager.openDevice(device) ?: return false
            connection.claimInterface(usbInterface, true)
            val sent = connection.bulkTransfer(endpoint, payload, payload.size, 5000)
            connection.releaseInterface(usbInterface)
            sent >= 0
        } catch (e: Exception) {
            e.printStackTrace()
            false
        } finally {
            try { connection?.close() } catch (_: Exception) {}
        }
    }

    /**
     * USB counterpart to [sendBluetoothChunks]: opens the device once, writes
     * ESC_INIT + each chunk (each chunk itself split at 4096-byte boundaries, since a
     * single bulkTransfer call has its own size ceiling, with a pause scaled to that
     * chunk's strip height between chunks) + FEED_AND_CUT, then closes.
     */
    private fun sendUsbChunks(context: Context, deviceName: String, chunks: List<Pair<ByteArray, Int>>): Boolean {
        val manager = context.getSystemService(Context.USB_SERVICE) as? UsbManager ?: return false
        val device = manager.deviceList.values.find { it.deviceName == deviceName } ?: return false
        if (!manager.hasPermission(device)) return false

        val (usbInterface, endpoint) = findPrinterInterfaceAndEndpoint(device) ?: return false
        var connection: UsbDeviceConnection? = null
        return try {
            connection = manager.openDevice(device) ?: return false
            connection.claimInterface(usbInterface, true)

            fun writeAll(bytes: ByteArray): Boolean {
                var offset = 0
                while (offset < bytes.size) {
                    val len = minOf(4096, bytes.size - offset)
                    val slice = if (offset == 0 && len == bytes.size) bytes else bytes.copyOfRange(offset, offset + len)
                    val sent = connection!!.bulkTransfer(endpoint, slice, slice.size, 5000)
                    if (sent < 0) return false
                    offset += len
                }
                return true
            }

            var ok = writeAll(ESC_INIT)
            if (ok) Thread.sleep(SETTLE_DELAY_MS)
            for ((chunk, stripHeight) in chunks) {
                if (!ok) break
                ok = writeAll(chunk)
                if (ok) Thread.sleep(interChunkDelayFor(stripHeight))
            }
            if (ok) {
                Thread.sleep(SETTLE_DELAY_MS)
                ok = writeAll(FEED_AND_CUT)
            }

            connection.releaseInterface(usbInterface)
            ok
        } catch (e: Exception) {
            e.printStackTrace()
            false
        } finally {
            try { connection?.close() } catch (_: Exception) {}
        }
    }

    // ================= UNIFIED BYTE SEND =================

    private fun sendRawBytes(context: Context, type: PrinterType, address: String, payload: ByteArray): Boolean {
        return when (type) {
            PrinterType.BLUETOOTH -> sendBluetoothBytes(context, address, payload)
            PrinterType.USB -> sendUsbBytes(context, address, payload)
        }
    }

    private fun sendChunks(context: Context, type: PrinterType, address: String, chunks: List<Pair<ByteArray, Int>>): Boolean {
        return when (type) {
            PrinterType.BLUETOOTH -> sendBluetoothChunks(context, address, chunks)
            PrinterType.USB -> sendUsbChunks(context, address, chunks)
        }
    }

    // ================= PLAIN TEXT PRINTING (ASCII/English) =================

    fun printText(context: Context, type: PrinterType, address: String, text: String): Boolean {
        val payload = ESC_INIT + text.toByteArray(Charsets.UTF_8) + FEED_AND_CUT
        return sendRawBytes(context, type, address, payload)
    }

    fun testPrint(context: Context, type: PrinterType, address: String, shopName: String = "IBTISAAM Kiryana Store"): Boolean {
        val sb = StringBuilder()
        sb.append("================================\n")
        sb.append("       TEST PRINT - 58mm\n")
        sb.append("================================\n")
        sb.append(shopName).append("\n")
        sb.append("Printer connected successfully.\n")
        sb.append("Connection: ").append(type.name).append("\n")
        sb.append("--------------------------------\n\n\n")
        return printText(context, type, address, sb.toString())
    }

    /**
     * Test print through the SAME raster pipeline real bills use (the older [testPrint]
     * sends plain text, so it can succeed even when raster printing is broken — it
     * can't tell you whether a receipt will actually print correctly).
     */
    fun testPrintRaster(
        context: Context, type: PrinterType, address: String,
        shopName: String = "IBTISAAM Kiryana Store",
        dotsWidth: Int = DEFAULT_DOTS_WIDTH
    ): Boolean {
        val w = normalizeDotsWidth(dotsWidth)
        val lines = listOf(
            ReceiptLine.Center(shopName, bold = true),
            ReceiptLine.Divider,
            ReceiptLine.Center("TEST PRINT"),
            ReceiptLine.TwoCol("Print width", "$w dots"),
            ReceiptLine.TwoCol("Total", "Rs 1,234.00", bold = true),
            ReceiptLine.Divider,
            ReceiptLine.Center("سیون اپ 1.5 ٹیسٹ"),
            ReceiptLine.Center("Agar ye theek chhapa to printer OK hai"),
            ReceiptLine.Divider
        )
        return printReceiptLines(context, type, address, lines, dotsWidth = w)
    }

    // ================= URDU PRINTING (rendered as image) =================

    /**
     * True if the text contains any Arabic-script characters (covers Urdu, since
     * Urdu is written using the Arabic script plus a few extra letters, all of
     * which fall in these Unicode blocks).
     *
     * IMPORTANT: callers should call this per-line (or per-column), not once
     * for an entire multi-line receipt. Checking the whole receipt at once
     * previously caused every English line (headers, "Ref:", "Date:", numeric
     * totals) to be laid out RTL just because *some* Urdu text appeared
     * somewhere else in the receipt.
     */
    private fun containsArabicScript(text: String): Boolean {
        for (ch in text) {
            val code = ch.code
            if (code in 0x0600..0x06FF ||   // Arabic
                code in 0x0750..0x077F ||   // Arabic Supplement
                code in 0x08A0..0x08FF ||   // Arabic Extended-A
                code in 0xFB50..0xFDFF ||   // Arabic Presentation Forms-A
                code in 0xFE70..0xFEFF      // Arabic Presentation Forms-B
            ) return true
        }
        return false
    }

    /**
     * FIX (item name collapsing to a tiny fragment — e.g. a name with a mixed
     * Urdu + English/number run printed as just "1.5" instead of the full
     * name): StaticLayout.Builder's own setEllipsize(TruncateAt.END) has a
     * known weakness with bidi (mixed-direction) text — it can measure/cut at
     * the wrong point and leave only a short leftover fragment plus a
     * misplaced "…" mark, which is exactly what this looked like. StaticLayout
     * itself is NOT the problem (it draws pure-RTL names like "سیرا لاٹھی"
     * correctly) — only its built-in ellipsizer is unreliable for mixed
     * content. This does the truncation manually with plain pixel
     * measurement (which shapes text correctly via Paint, same as before)
     * BEFORE handing the text to StaticLayout, so StaticLayout only ever has
     * to lay out a string that already fits — no ellipsizing decisions left
     * for it to get wrong. [paint]'s current textSize/typeface/bold state is
     * used for measurement, so call this only after those are set for the
     * line being measured.
     */
    private fun ellipsizeByWidth(paint: TextPaint, text: String, maxWidthPx: Float): String {
        if (maxWidthPx <= 0f) return ""
        if (paint.measureText(text) <= maxWidthPx) return text
        val ellipsis = "\u2026" // "…"
        val ellipsisWidth = paint.measureText(ellipsis)
        if (ellipsisWidth > maxWidthPx) return ""
        // Binary search the longest prefix (in chars) that still fits alongside
        // the ellipsis mark. Works on the string's logical order — same
        // "keep the start, drop the end" behavior TruncateAt.END was meant to
        // give, just without its bidi bug.
        var lo = 0
        var hi = text.length
        while (lo < hi) {
            val mid = (lo + hi + 1) / 2
            val candidateWidth = paint.measureText(text, 0, mid) + ellipsisWidth
            if (candidateWidth <= maxWidthPx) lo = mid else hi = mid - 1
        }
        return if (lo <= 0) ellipsis else text.substring(0, lo) + ellipsis
    }

    private var cachedUrduTypeface: Typeface? = null
    private var triedLoadingUrduFont = false

    // Named system font families that ship Arabic-script glyphs on most
    // AOSP-derived builds (incl. many budget Android POS terminals), tried
    // in order before we give up on anything better than plain Roboto. See
    // resolveUrduTypeface() below.
    private val SYSTEM_ARABIC_FONT_FAMILIES = listOf("noto-naskh-arabic", "noto-sans-arabic")

    /**
     * Resolves the best available Urdu-capable typeface, in order:
     *  1. A named system Arabic font family (Naskh/Sans style), if this
     *     device's ROM exposes one under a recognized name.
     *  2. A font bundled by the app at [URDU_FONT_ASSET_PATH]
     *     (app/src/main/assets/fonts/NotoNastaliqUrdu-Regular.ttf — see the
     *     README.md placed next to that path), only if no system Arabic
     *     font could be resolved.
     *  3. Typeface.DEFAULT — Android's own script-fallback will still shape
     *     Urdu glyphs correctly when drawn via StaticLayout/Canvas as long as
     *     the device has *some* Arabic-capable font installed; only the
     *     calligraphic style is out of our control at that point.
     *
     * FIX (product name printing as a stray glyph or just its embedded
     * English/number part — e.g. "سیون اپ 1.5" printing as only "1.5", even
     * though the exact same name renders perfectly everywhere else in the
     * app, including the Items list, which uses the *system* font, not this
     * bundled one): the bundled font here is a Nastaliq-style face.
     * Nastaliq's calligraphic diagonal-stacking shaping is known to not be
     * fully supported by Android's Canvas/StaticLayout text-shaping stack —
     * certain letter sequences collapse or drop out entirely, while a plain
     * Latin/number run alongside them (which doesn't need that shaping)
     * still renders fine. That matches the symptom exactly. The system's
     * Naskh/Sans Arabic font — the same style everything else in the app
     * (and the OS itself) already uses successfully — uses much simpler,
     * reliably-supported shaping, so it's now tried FIRST, with the bundled
     * Nastaliq font demoted to a fallback for the rare device with no Arabic
     * system font at all. This does trade the traditional Nastaliq
     * calligraphic look on receipts for a Naskh-style look — but a
     * consistently-correct name beats a prettier font that sometimes prints
     * blank.
     * Result is cached after the first resolution (per process) so this
     * never re-hits the filesystem/font-family lookup on every receipt.
     */
    private fun resolveUrduTypeface(context: Context): Typeface {
        cachedUrduTypeface?.let { return it }
        if (triedLoadingUrduFont) return Typeface.DEFAULT
        triedLoadingUrduFont = true

        for (family in SYSTEM_ARABIC_FONT_FAMILIES) {
            try {
                val tf = Typeface.create(family, Typeface.NORMAL)
                if (tf != null && tf != Typeface.DEFAULT) {
                    cachedUrduTypeface = tf
                    return tf
                }
            } catch (e: Exception) {
                // Family not present on this ROM — try the next one.
            }
        }

        try {
            val tf = Typeface.createFromAsset(context.assets, URDU_FONT_ASSET_PATH)
            cachedUrduTypeface = tf
            return tf
        } catch (e: Exception) {
            // Bundled font missing/unusable — fall through to the default below.
        }

        cachedUrduTypeface = Typeface.DEFAULT
        return Typeface.DEFAULT
    }

    /**
     * Renders a list of structured [ReceiptLine]s into a single bitmap, one line
     * at a time, so that:
     *  - each line's RTL/LTR direction is decided independently (fixes the
     *    whole-receipt-goes-RTL bug), and
     *  - [ReceiptLine.TwoCol] columns are aligned by *measured pixel width*
     *    (via Paint.measureText / Paint.Align) instead of space-padding,
     *    which is the only way to get straight columns with a non-monospace
     *    font.
     *  - [ReceiptLine.TableRow] draws a full ruled grid (vertical column
     *    dividers + a bottom border per row) for callers that still want one.
     *  - [ReceiptLine.Row3] / [ReceiptLine.ItemRow] draw the borderless,
     *    preview-matching item list layout (see their docs above).
     */
    private fun renderReceiptLines(lines: List<ReceiptLine>, fontSizePx: Float, typeface: Typeface, dotsWidth: Int): Bitmap {
        val PRINTER_DOTS_WIDTH = dotsWidth
        val margin = 6
        val paint = TextPaint().apply {
            isAntiAlias = true
            textSize = fontSizePx
            color = Color.BLACK
            this.typeface = typeface
            // FIX (print too light / faint): thin anti-aliased glyph edges were often
            // landing as mid-gray in the 1-bit conversion below, which a lot of thermal
            // print heads render as barely-there. FILL_AND_STROKE + a small stroke width
            // thickens every character uniformly (a "synthetic bold" effect) so more of
            // each glyph crosses the black/white threshold — same technique as bolding a
            // whole font, but applied globally without changing which lines are already
            // marked bold vs normal (those still look heavier relative to this baseline).
            style = Paint.Style.FILL_AND_STROKE
            // FIX ("print dark kro" — print still too light): stroke bumped
            // 0.035 -> 0.05x so more of each glyph's edge crosses the black/white
            // threshold below, making the whole receipt print noticeably darker.
            strokeWidth = fontSizePx * 0.05f
        }
        // FIX ("line space 1 line kam kro" — reduce the gap between every line by
        // roughly a line's worth): trimmed 0.28 -> 0.16. This is per-line, so it
        // compounds across the whole receipt (title, shop info, customer/bill
        // rows, totals) rather than a one-time trim.
        val lineSpacingExtra = (fontSizePx * 0.16f).toInt()
        // FIX ("shop name se payment method tak / subtotal se net balance tak ek line space
        // kam kro"): lines flagged `tight` use a NEGATIVE extra so the row pitch shrinks by
        // a further ~0.08x font size on top of the normal 0.16x spacing being dropped.
        // (v2: 0.08x was only ~2px — invisible on paper. This font's line box is ~2x the glyph
        // height, so Latin-only rows can safely lose ~0.5x font size of pitch; rows that
        // contain Urdu/Arabic script (tall Nastaliq ascenders/descenders) lose less so
        // they never touch the next row.)
        // NEW ("English/number wali lines ka space jam kro"): rows with NO Urdu/Arabic text use a
        // compact fixed line box instead of the font's own (very tall, Nastaliq-sized) box.
        // Latin glyphs only need ~1.0x font size above the baseline and ~0.25x below it.
        val compactLatinHeight = (fontSizePx * 1.45f).toInt()
        val compactLatinAscent = fontSizePx * 1.02f
        fun tightSpacingExtraFor(text: String): Int =
            -(fontSizePx * (if (containsArabicScript(text)) 0.20f else 0.50f)).toInt()
        val contentWidth = PRINTER_DOTS_WIDTH - margin * 2
        // Table/row cells use a smaller font than the rest of the receipt so 3-4
        // columns (Item/Qty/Amount, or Item/Rate/Qty/Amount) fit comfortably on a
        // 58mm paper width without excessive ellipsizing.
        // FIX ("is ka size chota kro" — item table too big): trimmed 0.78 -> 0.72.
        // Combined with the ItemRow-specific 0.92x factors above, the effective size
        // for item name/rate/qty/amount cells is now noticeably smaller than before.
        // FIX ("item table ma font Thora bara kro aur clear kro"): 0.72 -> 0.88 of the base size.
        val tableFontSize = fontSizePx * 0.88f
        // FIX (cramped print — text touching between columns/lines): both of these
        // were too tight (8 / 5), which combined with the qty-column overflow bug
        // made everything look crammed together with no visible gaps. Bumped up for
        // clearer separation; combined with the ellipsize fix above, columns can no
        // longer touch even in the worst case.
        // FIX (overall print size): tightened 12 -> 9 — combined with the smaller
        // Arabic boost above, this noticeably shortens the printed receipt (less
        // wasted paper) without crowding the rows.
        // FIX ("line space 1 line kam kro"): item-table rows tightened too, 9 -> 7.
        val tableRowPaddingV = 7 // extra top/bottom padding inside each row
        val tableCellPaddingH = 8 // left/right padding inside each cell, before ellipsizing

        data class Block(val line: ReceiptLine, val layout: StaticLayout?, val height: Int)

        // FIX ("top ... page zayda use ho raha" follow-up): trimmed the bitmap's
        // own top padding too (was 8/4 — a small amount, but it stacks with the
        // FEED_AND_CUT trim above).
        val blocks = ArrayList<Block>(lines.size)
        var totalHeight = 2

        for (line in lines) {
            when (line) {
                is ReceiptLine.Center, is ReceiptLine.Left -> {
                    val text = if (line is ReceiptLine.Center) line.text else (line as ReceiptLine.Left).text
                    val centerBold = line is ReceiptLine.Center && line.bold
                    val oldBoldMeasure = paint.isFakeBoldText
                    paint.isFakeBoldText = centerBold
                    val dir = if (containsArabicScript(text)) TextDirectionHeuristics.RTL else TextDirectionHeuristics.LTR
                    // FIX ("Shop name center ma nhi araha" — Urdu/RTL text wasn't
                    // visually centering even though ALIGN_CENTER was requested):
                    // StaticLayout's ALIGN_CENTER has a known unreliable interaction
                    // with an RTL paragraph direction on some Android versions — it
                    // can anchor to the paragraph's natural (right) edge instead of
                    // the true horizontal center. A single line that fits within
                    // contentWidth is now centered by directly measuring its shaped
                    // width and drawing it with Paint.Align.CENTER at the row's
                    // midpoint instead — the same reliable measure-and-draw approach
                    // already used for every other value on the receipt (TwoCol,
                    // GateRow, Row4), which has never had this problem. StaticLayout
                    // is still used as a fallback for text too wide to fit one line
                    // (so long Center text, like a long footer line, still wraps).
                    if (line is ReceiptLine.Center && paint.measureText(text) <= contentWidth) {
                        val fm = paint.fontMetrics
                        val h = if (!containsArabicScript(text)) compactLatinHeight
                                else (fm.bottom - fm.top).toInt() + (if (line.tight) tightSpacingExtraFor(text) else lineSpacingExtra)
                        blocks.add(Block(line, null, h))
                        totalHeight += h
                    } else {
                        val alignment = if (line is ReceiptLine.Center) Layout.Alignment.ALIGN_CENTER else Layout.Alignment.ALIGN_NORMAL
                        val layout = StaticLayout.Builder
                            .obtain(text, 0, text.length, paint, contentWidth)
                            .setAlignment(alignment)
                            .setTextDirection(dir)
                            .setLineSpacing(0f, 1.15f)
                            .build()
                        val h = layout.height + lineSpacingExtra
                        blocks.add(Block(line, layout, h))
                        totalHeight += h
                    }
                    paint.isFakeBoldText = oldBoldMeasure
                }
                is ReceiptLine.TwoCol -> {
                    val fm = paint.fontMetrics
                    val h = if (!containsArabicScript(line.left + line.right)) compactLatinHeight
                            else (fm.bottom - fm.top).toInt() + (if (line.tight) tightSpacingExtraFor(line.left + line.right) else lineSpacingExtra)
                    blocks.add(Block(line, null, h))
                    totalHeight += h
                }
                ReceiptLine.Divider -> {
                    val h = 10
                    blocks.add(Block(line, null, h))
                    totalHeight += h
                }
                is ReceiptLine.Blank -> {
                    blocks.add(Block(line, null, line.heightPx))
                    totalHeight += line.heightPx
                }
                is ReceiptLine.TableRow -> {
                    // Height is computed using the bigger of the two possible cell font
                    // sizes (the Arabic item-name boost), so a row has enough vertical
                    // room whether or not it actually contains Arabic text this time.
                    paint.textSize = tableFontSize * ARABIC_ITEM_FONT_BOOST
                    val fm = paint.fontMetrics
                    paint.textSize = fontSizePx
                    var h = (fm.bottom - fm.top).toInt() + tableRowPaddingV * 2
                    if (line.topBorder) h += 2 // room for the extra top border stroke
                    blocks.add(Block(line, null, h))
                    totalHeight += h
                }
                is ReceiptLine.Row3 -> {
                    paint.textSize = tableFontSize
                    val fm = paint.fontMetrics
                    paint.textSize = fontSizePx
                    val h = (fm.bottom - fm.top).toInt() + tableRowPaddingV
                    blocks.add(Block(line, null, h))
                    totalHeight += h
                }
                is ReceiptLine.Row4 -> {
                    paint.textSize = tableFontSize
                    val fm = paint.fontMetrics
                    paint.textSize = fontSizePx
                    val h = (fm.bottom - fm.top).toInt() + tableRowPaddingV
                    blocks.add(Block(line, null, h))
                    totalHeight += h
                }
                is ReceiptLine.ItemRow -> {
                    // FIX ("Product name ab same row use kre hi jo baqi use kr rahe
                    // ha" — name should sit on the SAME single row as rate/qty/amount,
                    // matching the classic single-line "Item Rate Qty Amount" table
                    // format instead of the earlier 2-line-per-item layout). Height is
                    // now just one line tall, sized off the same nameSize used at draw
                    // time below so the two passes agree.
                    val isUrduName = containsArabicScript(line.name)
                    paint.textSize = tableFontSize * (if (isUrduName) ARABIC_ITEM_FONT_BOOST else 1f)
                    val fm = paint.fontMetrics
                    paint.textSize = fontSizePx
                    val h = (fm.bottom - fm.top).toInt() + tableRowPaddingV
                    blocks.add(Block(line, null, h))
                    totalHeight += h
                }
                is ReceiptLine.GateRow -> {
                    val isUrduName = containsArabicScript(line.name)
                    paint.textSize = tableFontSize * (if (isUrduName) ARABIC_ITEM_FONT_BOOST else 1f)
                    val fm = paint.fontMetrics
                    paint.textSize = fontSizePx
                    val h = (fm.bottom - fm.top).toInt() + tableRowPaddingV
                    blocks.add(Block(line, null, h))
                    totalHeight += h
                }
                is ReceiptLine.PreviewItemRow -> {
                    val isUrduName = containsArabicScript(line.name)
                    paint.textSize = tableFontSize * (if (isUrduName) ARABIC_ITEM_FONT_BOOST else 1f)
                    val fm = paint.fontMetrics
                    paint.textSize = fontSizePx
                    val h = (fm.bottom - fm.top).toInt() + tableRowPaddingV
                    blocks.add(Block(line, null, h))
                    totalHeight += h
                }

            }
        }

        val bitmap = Bitmap.createBitmap(PRINTER_DOTS_WIDTH, totalHeight, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        canvas.drawColor(Color.WHITE)

        var y = 2f
        for (block in blocks) {
            when (val line = block.line) {
                is ReceiptLine.Center, is ReceiptLine.Left -> {
                    val oldBoldDraw = paint.isFakeBoldText
                    paint.isFakeBoldText = line is ReceiptLine.Center && line.bold
                    if (block.layout != null) {
                        canvas.save()
                        canvas.translate(margin.toFloat(), y)
                        block.layout.draw(canvas)
                        canvas.restore()
                    } else {
                        // Direct single-line centered draw — see the FIX comment on
                        // the measurement pass above.
                        val text = (line as ReceiptLine.Center).text
                        val fm = paint.fontMetrics
                        val baseline = if (!containsArabicScript(text)) y + compactLatinAscent else y - fm.top
                        val oldAlign = paint.textAlign
                        paint.textAlign = Paint.Align.CENTER
                        canvas.drawText(text, PRINTER_DOTS_WIDTH / 2f, baseline, paint)
                        paint.textAlign = oldAlign
                    }
                    paint.isFakeBoldText = oldBoldDraw
                    y += block.height
                }
                is ReceiptLine.TwoCol -> {
                    // FIX (alignment bug): this used to detect Urdu on either side and
                    // "flip" that side's anchor to the opposite margin — meant to look
                    // smart, but when the RIGHT side (the value) was Urdu, both the
                    // label and the value ended up anchored at the LEFT margin and drew
                    // on top of each other. The on-screen preview (`kv()` in
                    // BillPreviewActivity) never does this: the label is always on the
                    // left, the value is always on the right, no matter which script it's
                    // in — Canvas.drawText with Paint.Align.RIGHT/LEFT already shapes and
                    // positions Arabic/Urdu glyphs correctly at a fixed anchor, so no
                    // side-swapping is needed. Fixed sides here match that, and stop the
                    // overlap.
                    val fm = paint.fontMetrics
                    val baseline = if (!containsArabicScript(line.left + line.right)) y + compactLatinAscent else y - fm.top

                    val oldBold = paint.isFakeBoldText
                    paint.isFakeBoldText = line.bold

                    paint.textAlign = Paint.Align.LEFT
                    canvas.drawText(line.left, margin.toFloat(), baseline, paint)

                    paint.textAlign = Paint.Align.RIGHT
                    canvas.drawText(line.right, (PRINTER_DOTS_WIDTH - margin).toFloat(), baseline, paint)

                    paint.isFakeBoldText = oldBold
                    y += block.height
                }
                ReceiptLine.Divider -> {
                    val oldStroke = paint.strokeWidth
                    paint.strokeWidth = 2f
                    canvas.drawLine(
                        margin.toFloat(), y + block.height / 2f,
                        (PRINTER_DOTS_WIDTH - margin).toFloat(), y + block.height / 2f,
                        paint
                    )
                    paint.strokeWidth = oldStroke
                    y += block.height
                }
                is ReceiptLine.Blank -> {
                    y += block.height
                }
                is ReceiptLine.TableRow -> {
                    val rowTop = y + if (line.topBorder) 2f else 0f
                    val rowBottom = y + block.height
                    val tableLeft = margin.toFloat()
                    val tableRight = (PRINTER_DOTS_WIDTH - margin).toFloat()
                    val tableWidth = tableRight - tableLeft

                    // ---- column x boundaries, proportioned by weight ----
                    val totalWeight = line.weights.sum().coerceAtLeast(0.01f)
                    val colX = FloatArray(line.weights.size + 1)
                    colX[0] = tableLeft
                    for (i in line.weights.indices) {
                        colX[i + 1] = colX[i] + (line.weights[i] / totalWeight) * tableWidth
                    }

                    // ---- grid lines: outer/inner verticals + bottom border (+ top border if header) ----
                    val oldStroke = paint.strokeWidth
                    paint.strokeWidth = 2f
                    paint.style = Paint.Style.STROKE
                    if (line.topBorder) canvas.drawLine(tableLeft, rowTop, tableRight, rowTop, paint)
                    canvas.drawLine(tableLeft, rowBottom, tableRight, rowBottom, paint)
                    for (x in colX) canvas.drawLine(x, rowTop, x, rowBottom, paint)
                    paint.strokeWidth = oldStroke
                    // FIX: restore to the global FILL_AND_STROKE synthetic-bold style
                    // (set once in renderReceiptLines) — left as pure STROKE here would
                    // have made the cell text below render as hollow/outline-only glyphs.
                    paint.style = Paint.Style.FILL_AND_STROKE

                    // ---- cell text ----
                    paint.textSize = tableFontSize
                    val oldBold = paint.isFakeBoldText
                    paint.isFakeBoldText = line.bold
                    val fm = paint.fontMetrics
                    val baseline = rowTop + tableRowPaddingV - fm.top

                    for (i in line.cells.indices) {
                        val cellLeft = colX[i] + tableCellPaddingH
                        val cellRight = colX[i + 1] - tableCellPaddingH
                        val cellWidth = (cellRight - cellLeft).coerceAtLeast(1f)
                        val rawText = line.cells[i]
                        val isItemColumn = i == 0
                        val isUrdu = containsArabicScript(rawText)

                        // Urdu item names get a bigger, slightly bolder rendering than
                        // the numeric columns — see ARABIC_ITEM_FONT_BOOST above. This
                        // must be set BEFORE ellipsize so the "does it fit" measurement
                        // matches what's actually drawn.
                        val useArabicBoost = isItemColumn && isUrdu
                        if (useArabicBoost) {
                            paint.textSize = tableFontSize * ARABIC_ITEM_FONT_BOOST
                            paint.isFakeBoldText = true
                        }

                        val fitText = TextUtils.ellipsize(rawText, paint, cellWidth, TextUtils.TruncateAt.END).toString()

                        when {
                            isItemColumn && isUrdu -> {
                                paint.textAlign = Paint.Align.RIGHT
                                canvas.drawText(fitText, cellRight, baseline, paint)
                            }
                            isItemColumn -> {
                                paint.textAlign = Paint.Align.LEFT
                                canvas.drawText(fitText, cellLeft, baseline, paint)
                            }
                            else -> {
                                paint.textAlign = Paint.Align.CENTER
                                canvas.drawText(fitText, (cellLeft + cellRight) / 2f, baseline, paint)
                            }
                        }

                        if (useArabicBoost) {
                            paint.textSize = tableFontSize
                            paint.isFakeBoldText = line.bold
                        }
                    }
                    paint.isFakeBoldText = oldBold
                    paint.textSize = fontSizePx

                    y += block.height
                }
                is ReceiptLine.Row3 -> {
                    // Borderless header-style row: col1 left/RTL-aware, col2 centered,
                    // col3 right-aligned — matches the on-screen "ITEM / QTY / AMOUNT"
                    // header, no grid lines drawn.
                    paint.textSize = tableFontSize
                    val oldBold = paint.isFakeBoldText
                    paint.isFakeBoldText = line.bold
                    val fm = paint.fontMetrics
                    val baseline = y + tableRowPaddingV / 2 - fm.top

                    val tableLeft = margin.toFloat()
                    val tableRight = (PRINTER_DOTS_WIDTH - margin).toFloat()
                    val tableWidth = tableRight - tableLeft
                    val totalWeight = line.weights.sum().coerceAtLeast(0.01f)
                    val colX = FloatArray(4)
                    colX[0] = tableLeft
                    for (i in 0..2) colX[i + 1] = colX[i] + (line.weights[i] / totalWeight) * tableWidth

                    val col1Rtl = containsArabicScript(line.col1)
                    paint.textAlign = if (col1Rtl) Paint.Align.RIGHT else Paint.Align.LEFT
                    val col1X = if (col1Rtl) colX[1] - tableCellPaddingH else colX[0] + tableCellPaddingH
                    canvas.drawText(line.col1, col1X, baseline, paint)

                    paint.textAlign = Paint.Align.CENTER
                    canvas.drawText(line.col2, (colX[1] + colX[2]) / 2f, baseline, paint)

                    paint.textAlign = Paint.Align.RIGHT
                    canvas.drawText(line.col3, colX[3] - tableCellPaddingH, baseline, paint)

                    paint.isFakeBoldText = oldBold
                    paint.textSize = fontSizePx
                    y += block.height
                }
                is ReceiptLine.Row4 -> {
                    // Borderless header-style row: col1 left/RTL-aware, col2 & col3
                    // centered, col4 right-aligned — matches the on-screen "ITEM /
                    // RATE / QTY / AMOUNT" header, no grid lines drawn.
                    paint.textSize = tableFontSize
                    val oldBold = paint.isFakeBoldText
                    paint.isFakeBoldText = line.bold
                    val fm = paint.fontMetrics
                    val baseline = y + tableRowPaddingV / 2 - fm.top

                    val tableLeft = margin.toFloat()
                    val tableRight = (PRINTER_DOTS_WIDTH - margin).toFloat()
                    val tableWidth = tableRight - tableLeft
                    val totalWeight = line.weights.sum().coerceAtLeast(0.01f)
                    val colX = FloatArray(5)
                    colX[0] = tableLeft
                    for (i in 0..3) colX[i + 1] = colX[i] + (line.weights[i] / totalWeight) * tableWidth

                    val col1Rtl = containsArabicScript(line.col1)
                    paint.textAlign = if (col1Rtl) Paint.Align.RIGHT else Paint.Align.LEFT
                    val col1X = if (col1Rtl) colX[1] - tableCellPaddingH else colX[0] + tableCellPaddingH
                    canvas.drawText(line.col1, col1X, baseline, paint)

                    paint.textAlign = Paint.Align.CENTER
                    canvas.drawText(line.col2, (colX[1] + colX[2]) / 2f, baseline, paint)
                    canvas.drawText(line.col3, (colX[2] + colX[3]) / 2f, baseline, paint)

                    paint.textAlign = Paint.Align.RIGHT
                    canvas.drawText(line.col4, colX[4] - tableCellPaddingH, baseline, paint)

                    paint.isFakeBoldText = oldBold
                    paint.textSize = fontSizePx
                    y += block.height
                }
                is ReceiptLine.ItemRow -> {
                    // FIX ("Product name ab same row use kre hi jo baqi use kr rahe
                    // ha" — item name now sits on the SAME single row as rate/qty/
                    // amount, matching the classic "Item Rate Qty Amount" table format,
                    // using the exact same 4 weighted columns as the "Item / Rate /
                    // Qty / Amount" header (Row4) above — same layout logic as Row4,
                    // just with a bold name/amount and bidi-safe ellipsizing for the
                    // name (same ellipsizeByWidth()+StaticLayout approach as before —
                    // it just now has less width, since it shares the row with three
                    // other columns instead of getting the full row to itself, so a
                    // long name may show truncated with "…" more often than before).
                    val tableLeft = margin.toFloat()
                    val tableRight = (PRINTER_DOTS_WIDTH - margin).toFloat()
                    val tableWidth = tableRight - tableLeft
                    val totalWeight = line.weights.sum().coerceAtLeast(0.01f)
                    val colX = FloatArray(5)
                    colX[0] = tableLeft
                    for (i in 0..3) {
                        val w = if (i < line.weights.size) line.weights[i] else 0f
                        colX[i + 1] = colX[i] + (w / totalWeight) * tableWidth
                    }

                    val nameIsUrdu = containsArabicScript(line.name)
                    val nameSize = tableFontSize * (if (nameIsUrdu) ARABIC_ITEM_FONT_BOOST else 1f)
                    paint.textSize = nameSize
                    paint.isFakeBoldText = true
                    val fm = paint.fontMetrics
                    val baseline = y + tableRowPaddingV / 2 - fm.top

                    val itemColWidth = (colX[1] - colX[0] - tableCellPaddingH * 2).coerceAtLeast(1f)
                    val fitName = ellipsizeByWidth(paint, line.name, itemColWidth)
                    val nameDir = if (nameIsUrdu) TextDirectionHeuristics.RTL else TextDirectionHeuristics.LTR
                    val nameLayout = StaticLayout.Builder
                        .obtain(fitName, 0, fitName.length, paint, itemColWidth.toInt().coerceAtLeast(1))
                        .setAlignment(Layout.Alignment.ALIGN_NORMAL)
                        .setTextDirection(nameDir)
                        .setMaxLines(1)
                        .build()
                    canvas.save()
                    val nameX = if (nameIsUrdu) colX[1] - tableCellPaddingH - itemColWidth else colX[0] + tableCellPaddingH
                    canvas.translate(nameX, baseline - nameLayout.getLineBaseline(0))
                    nameLayout.draw(canvas)
                    canvas.restore()

                    // FIX (wholesaler-slip column order — "Amount-Qty-Rate"): the
                    // Item / Rate / Qty / Amount header above was reordered to
                    // Item / Amount / Qty / Rate to match the wholesaler receipt
                    // format, so the values drawn in each column must swap places
                    // too — Amount now goes in col2 (kept bold, since it's still the
                    // important figure), Rate now goes in col4 (plain, no longer
                    // bold, since Amount already carries the bold emphasis).
                    paint.textSize = tableFontSize
                    paint.isFakeBoldText = true
                    paint.textAlign = Paint.Align.CENTER
                    canvas.drawText(line.amount, (colX[1] + colX[2]) / 2f, baseline, paint)

                    paint.isFakeBoldText = false
                    canvas.drawText(line.qty, (colX[2] + colX[3]) / 2f, baseline, paint)

                    paint.textAlign = Paint.Align.RIGHT
                    canvas.drawText(line.rate, colX[4] - tableCellPaddingH, baseline, paint)

                    paint.textSize = fontSizePx
                    paint.textAlign = Paint.Align.LEFT
                    y += block.height
                }
                is ReceiptLine.GateRow -> {
                    // Single-line "Amount | Qty | Rate | Name" row, matching the
                    // requested wholesaler-slip format: the three numeric columns sit
                    // on the left (plain, LTR), and the item name fills the remaining
                    // column on the right.
                    // FIX ("Product item right alignment use kre ... exact پیپسی کے
                    // نیچے سے شروع ho" — every item name, English or Urdu, must start
                    // from the SAME fixed edge, matching the guide line drawn on the
                    // reference photo): previously only Urdu names were right-anchored
                    // (colX[4]-width) while English names were left-anchored at
                    // colX[3], so the two scripts' rows didn't line up. Now the layout
                    // box's RIGHT edge is always pinned at colX[4]-padding regardless
                    // of script, and English/LTR text is right-aligned *within* that
                    // box (ALIGN_OPPOSITE) instead of left-aligned, so every row's item
                    // text starts flush with that same right edge.
                    val tableLeft = margin.toFloat()
                    val tableRight = (PRINTER_DOTS_WIDTH - margin).toFloat()
                    val tableWidth = tableRight - tableLeft
                    val totalWeight = line.weights.sum().coerceAtLeast(0.01f)
                    val colX = FloatArray(5)
                    colX[0] = tableLeft
                    for (i in 0..3) {
                        val w = if (i < line.weights.size) line.weights[i] else 0f
                        colX[i + 1] = colX[i] + (w / totalWeight) * tableWidth
                    }

                    paint.textSize = tableFontSize
                    val oldBold = paint.isFakeBoldText
                    paint.isFakeBoldText = line.bold
                    val fm = paint.fontMetrics
                    val baseline = y + tableRowPaddingV / 2 - fm.top

                    paint.textAlign = Paint.Align.LEFT
                    canvas.drawText(line.amount, colX[0] + tableCellPaddingH, baseline, paint)
                    paint.textAlign = Paint.Align.CENTER
                    canvas.drawText(line.qty, (colX[1] + colX[2]) / 2f, baseline, paint)
                    canvas.drawText(line.rate, (colX[2] + colX[3]) / 2f, baseline, paint)

                    // FIX ("Bus alignment issue reh gia ha" — item names still
                    // weren't lining up to the same right edge across rows even
                    // after the box-position fix above): the underlying cause was
                    // the same StaticLayout+RTL alignment bug just fixed for the
                    // shop name — ALIGN_NORMAL/ALIGN_OPPOSITE inside StaticLayout
                    // don't reliably anchor to the requested edge for these
                    // paragraph directions on this Android version. Switched to the
                    // same reliable fix: skip StaticLayout for this column entirely
                    // and directly measure + draw the (already ellipsized) name with
                    // Paint.Align.RIGHT at the fixed right edge (colX[4]-padding) —
                    // the same approach already used for every other value on the
                    // receipt, which has never had this problem.
                    val nameIsUrdu = containsArabicScript(line.name)
                    val nameSize = tableFontSize * (if (nameIsUrdu) ARABIC_ITEM_FONT_BOOST else 1f)
                    paint.textSize = nameSize
                    paint.isFakeBoldText = true
                    val nameFm = paint.fontMetrics
                    val nameBaseline = y + tableRowPaddingV / 2 - nameFm.top
                    val nameColWidth = (colX[4] - colX[3] - tableCellPaddingH * 2).coerceAtLeast(1f)
                    val fitName = ellipsizeByWidth(paint, line.name, nameColWidth)
                    paint.textAlign = Paint.Align.RIGHT
                    canvas.drawText(fitName, colX[4] - tableCellPaddingH, nameBaseline, paint)

                    paint.isFakeBoldText = oldBold
                    paint.textSize = fontSizePx
                    paint.textAlign = Paint.Align.LEFT
                    y += block.height
                }
                is ReceiptLine.PreviewItemRow -> {
                    // Matches the on-screen Bill Preview card's item row exactly:
                    // ITEM (name, bold, RTL-aware, ellipsized, left-aligned column) /
                    // AMOUNT (bold, centered) / QTY (plain, centered) / RATE (plain,
                    // right-aligned) — same 2:1:1:1 column split as the preview
                    // card's LinearLayout weights and the printed header above it.
                    val tableLeft = margin.toFloat()
                    val tableRight = (PRINTER_DOTS_WIDTH - margin).toFloat()
                    val tableWidth = tableRight - tableLeft
                    val totalWeight = line.weights.sum().coerceAtLeast(0.01f)
                    val colX = FloatArray(5)
                    colX[0] = tableLeft
                    for (i in 0..3) {
                        val w = if (i < line.weights.size) line.weights[i] else 0f
                        colX[i + 1] = colX[i] + (w / totalWeight) * tableWidth
                    }

                    val oldBold = paint.isFakeBoldText

                    if (line.mirrored) {
                        // FIX ("item name right side pa nhi aya"): mirrored layout — item name
                        // pinned to the RIGHT edge; visually AMOUNT | RATE | QTY | ITEM.
                        val wts = FloatArray(4) { i -> if (i < line.weights.size) line.weights[i] else 0f }
                        val order = intArrayOf(1, 3, 2, 0) // physical left->right = amount, rate, qty, name
                        val px = FloatArray(5)
                        px[0] = tableLeft
                        for (k in 0..3) px[k + 1] = px[k] + (wts[order[k]] / totalWeight) * tableWidth

                        val nameIsUrduM = containsArabicScript(line.name)
                        paint.textSize = tableFontSize * (if (nameIsUrduM) ARABIC_ITEM_FONT_BOOST else 1f)
                        paint.isFakeBoldText = true
                        val nameFmM = paint.fontMetrics
                        val nameBaselineM = y + tableRowPaddingV / 2 - nameFmM.top
                        val nameW = (px[4] - px[3] - tableCellPaddingH * 2).coerceAtLeast(1f)
                        paint.textAlign = Paint.Align.RIGHT
                        canvas.drawText(ellipsizeByWidth(paint, line.name, nameW), px[4] - tableCellPaddingH, nameBaselineM, paint)

                        paint.textSize = tableFontSize
                        val fmM = paint.fontMetrics
                        val baselineM = y + tableRowPaddingV / 2 - fmM.top
                        paint.textAlign = Paint.Align.CENTER
                        canvas.drawText(line.amount, (px[0] + px[1]) / 2f, baselineM, paint)
                        // rate / qty stay bold too (clearer on thermal paper)
                        canvas.drawText(line.rate, (px[1] + px[2]) / 2f, baselineM, paint)
                        canvas.drawText(line.qty, (px[2] + px[3]) / 2f, baselineM, paint)
                    } else {

                    // ---- item name: col0, bold, RTL-aware, ellipsized to fit ----
                    val nameIsUrdu = containsArabicScript(line.name)
                    val nameSize = tableFontSize * (if (nameIsUrdu) ARABIC_ITEM_FONT_BOOST else 1f)
                    paint.textSize = nameSize
                    paint.isFakeBoldText = true
                    val nameFm = paint.fontMetrics
                    val nameBaseline = y + tableRowPaddingV / 2 - nameFm.top
                    val nameColWidth = (colX[1] - colX[0] - tableCellPaddingH * 2).coerceAtLeast(1f)
                    val fitName = ellipsizeByWidth(paint, line.name, nameColWidth)
                    paint.textAlign = if (nameIsUrdu) Paint.Align.RIGHT else Paint.Align.LEFT
                    val nameX = if (nameIsUrdu) colX[1] - tableCellPaddingH else colX[0] + tableCellPaddingH
                    canvas.drawText(fitName, nameX, nameBaseline, paint)

                    // ---- amount / qty / rate: cols 1-3, plain baseline shared ----
                    paint.textSize = tableFontSize
                    val fm = paint.fontMetrics
                    val baseline = y + tableRowPaddingV / 2 - fm.top

                    paint.isFakeBoldText = true
                    paint.textAlign = Paint.Align.CENTER
                    canvas.drawText(line.amount, (colX[1] + colX[2]) / 2f, baseline, paint)

                    paint.isFakeBoldText = false
                    canvas.drawText(line.qty, (colX[2] + colX[3]) / 2f, baseline, paint)

                    paint.textAlign = Paint.Align.RIGHT
                    canvas.drawText(line.rate, colX[4] - tableCellPaddingH, baseline, paint)
                    }

                    paint.isFakeBoldText = oldBold
                    paint.textSize = fontSizePx
                    paint.textAlign = Paint.Align.LEFT
                    y += block.height
                }

            }
        }
        return bitmap
    }

    /**
     * Converts a Bitmap into a list of (ESC/POS raster-image command, stripHeight)
     * pairs — 1-bit monochrome via simple luminance threshold, split into horizontal
     * strips of at most [MAX_STRIP_HEIGHT_PX] each so a tall multi-item receipt never
     * becomes one oversized raster command, and so each strip's actual height is known
     * to the sender for computing a proportional pause via [interChunkDelayFor] (see
     * the FIX comments on [MAX_STRIP_HEIGHT_PX] for why the pause needs to scale).
     */
    private fun bitmapToEscPosRasterChunks(bitmap: Bitmap): List<Pair<ByteArray, Int>> {
        val width = bitmap.width
        val height = bitmap.height
        val bytesPerRow = (width + 7) / 8

        // Reading all pixels once up front is much faster than repeated getPixel()
        // calls per strip, especially for tall receipts.
        val pixels = IntArray(width * height)
        bitmap.getPixels(pixels, 0, width, 0, 0, width, height)

        val chunks = mutableListOf<Pair<ByteArray, Int>>()
        var y = 0
        while (y < height) {
            val stripHeight = minOf(MAX_STRIP_HEIGHT_PX, height - y)
            val header = byteArrayOf(
                0x1D, 0x76, 0x30, 0x00,
                (bytesPerRow and 0xFF).toByte(),
                ((bytesPerRow shr 8) and 0xFF).toByte(),
                (stripHeight and 0xFF).toByte(),
                ((stripHeight shr 8) and 0xFF).toByte()
            )
            val imageData = ByteArray(bytesPerRow * stripHeight)
            for (row in 0 until stripHeight) {
                val srcRowStart = (y + row) * width
                for (x in 0 until width) {
                    val pixel = pixels[srcRowStart + x]
                    val r = (pixel shr 16) and 0xFF
                    val g = (pixel shr 8) and 0xFF
                    val bch = pixel and 0xFF
                    val luminance = r * 0.3 + g * 0.59 + bch * 0.11
                    // FIX (print too light): was <128 — only fairly dark pixels became
                    // black dots, so lighter gray (anti-aliased edges, thin strokes)
                    // printed as nothing at all. Raised to <195, then further to <215
                    // ("print dark kro") so even lighter gray edges print solid, which —
                    // combined with the synthetic-bold stroke above — makes the whole
                    // receipt noticeably darker and easier to read on a faint-printing
                    // thermal head.
                    if (luminance < 215) {
                        val byteIndex = row * bytesPerRow + (x / 8)
                        val bitIndex = 7 - (x % 8)
                        imageData[byteIndex] = (imageData[byteIndex].toInt() or (1 shl bitIndex)).toByte()
                    }
                }
            }
            chunks.add((header + imageData) to stripHeight)
            y += stripHeight
        }
        return chunks
    }

    /**
     * Preferred entry point: prints a receipt built from structured [ReceiptLine]s
     * with correct per-line direction, pixel-accurate column alignment, and chunked
     * raster transmission (with a per-strip pause scaled to strip height) so
     * long/multi-item receipts print reliably without overlapping.
     */
    fun printReceiptLines(
        context: Context,
        type: PrinterType,
        address: String,
        lines: List<ReceiptLine>,
        typeface: Typeface? = null,
        // FIX (overall print size — "print size bht bara ha is ko manage kro"):
        // trimmed 30 -> 26. Combined with the tighter row padding and the smaller
        // Arabic boost above, this shortens the printed receipt noticeably while
        // staying easily readable on 58mm paper.
        fontSizePx: Float = 26f,
        dotsWidth: Int = DEFAULT_DOTS_WIDTH
    ): Boolean {
        val resolvedTypeface = typeface ?: resolveUrduTypeface(context)
        val bitmap = renderReceiptLines(lines, fontSizePx, resolvedTypeface, normalizeDotsWidth(dotsWidth))
        val chunks = bitmapToEscPosRasterChunks(bitmap)
        return sendChunks(context, type, address, chunks)
    }

    /** Default items-per-slip before [printReceiptLinesPaged] tears a long bill into
     *  multiple physical slips. Chosen so a slip stays a comfortable one-hand length
     *  on 58mm paper; raise/lower per shop preference. */
    const val DEFAULT_MAX_ITEMS_PER_PAGE = 18

    /**
     * Prints a long, multi-item receipt as MULTIPLE physical slips (each its own
     * feed + cut) instead of one unbroken roll, answering "bill lamba ho tu split
     * kaise ho ga":
     *  - [headerLines] (shop name, customer/bill/date, the ITEM|AMOUNT|QTY|RATE
     *    table header row is passed separately as the first element of
     *    [itemLines]) is repeated at the top of every slip so each piece is
     *    independently identifiable.
     *  - [itemLines] MUST have the table header row first, followed by the actual
     *    item rows. Only the item rows are paginated, [maxItemsPerPage] per slip.
     *  - [footerLines] (Subtotal/Discount/Total/Paid/Balance Due/Prev+Net
     *    Balance/footer note) is printed ONLY on the LAST slip — printing a
     *    running partial total on every slip would be misleading, so instead
     *    every non-final slip ends with a clear "Continued on next slip" line and
     *    every slip after the first opens with a "Page X of Y (continued)" line.
     *  - If the bill fits in one page, this behaves exactly like a single
     *    [printReceiptLines] call — no behavior change for normal-length bills.
     *
     * Returns true only if every slip printed successfully.
     */
    fun printReceiptLinesPaged(
        context: Context,
        type: PrinterType,
        address: String,
        headerLines: List<ReceiptLine>,
        itemLines: List<ReceiptLine>,
        footerLines: List<ReceiptLine>,
        typeface: Typeface? = null,
        fontSizePx: Float = 26f,
        dotsWidth: Int = DEFAULT_DOTS_WIDTH,
        maxItemsPerPage: Int = DEFAULT_MAX_ITEMS_PER_PAGE
    ): Boolean {
        val tableHeaderRow = itemLines.firstOrNull()
        val itemRows = if (tableHeaderRow != null) itemLines.drop(1) else emptyList()

        if (itemRows.size <= maxItemsPerPage) {
            // Fits on one slip — identical behavior to the non-paged call.
            val all = headerLines + itemLines + footerLines
            return printReceiptLines(context, type, address, all, typeface, fontSizePx, dotsWidth)
        }

        val pages = itemRows.chunked(maxItemsPerPage)
        val totalPages = pages.size
        val resolvedTypeface = typeface ?: resolveUrduTypeface(context)
        var allOk = true

        pages.forEachIndexed { index, pageRows ->
            val pageNum = index + 1
            val pageLines = mutableListOf<ReceiptLine>()
            pageLines.addAll(headerLines)
            if (pageNum > 1) {
                pageLines.add(ReceiptLine.Center("-- Page $pageNum of $totalPages (continued) --", tight = true))
            }
            tableHeaderRow?.let { pageLines.add(it) }
            pageLines.addAll(pageRows)
            if (pageNum < totalPages) {
                pageLines.add(ReceiptLine.Divider)
                pageLines.add(ReceiptLine.Center("-- Continued on next slip --", bold = true, tight = true))
            } else {
                pageLines.addAll(footerLines)
            }

            val bitmap = renderReceiptLines(pageLines, fontSizePx, resolvedTypeface, normalizeDotsWidth(dotsWidth))
            val chunks = bitmapToEscPosRasterChunks(bitmap)
            if (!sendChunks(context, type, address, chunks)) allOk = false

            // Let the cutter/feed fully settle before the next slip's ESC_INIT —
            // same reasoning as the pre-strip settle delay in sendBluetoothChunks.
            if (pageNum < totalPages) Thread.sleep(SETTLE_DELAY_MS)
        }
        return allOk
    }

    /**
     * Prints Urdu (or mixed Urdu/English) plain text by rendering it as an image.
     * Kept for any existing callers that build a plain string. Each line of the
     * input is now given its own RTL/LTR direction (fixing the old whole-receipt
     * RTL bug); for real column alignment (labels/values, item qty/rate/amount),
     * prefer [printReceiptLines] with [ReceiptLine.TwoCol]/[ReceiptLine.Row4]/
     * [ReceiptLine.ItemRow] instead of padding with spaces, since a proportional
     * font can't be aligned that way.
     */
    fun printUrduText(
        context: Context,
        type: PrinterType,
        address: String,
        text: String,
        typeface: Typeface? = null,
        dotsWidth: Int = DEFAULT_DOTS_WIDTH
    ): Boolean {
        val resolvedTypeface = typeface ?: resolveUrduTypeface(context)
        val lines: List<ReceiptLine> = text.split("\n").map { raw ->
            if (raw.isBlank()) ReceiptLine.Blank() else ReceiptLine.Left(raw)
        }
        val bitmap = renderReceiptLines(lines, 30f, resolvedTypeface, normalizeDotsWidth(dotsWidth))
        val chunks = bitmapToEscPosRasterChunks(bitmap)
        return sendChunks(context, type, address, chunks)
    }
}
