package com.grocerypos.v11

import android.content.Context
import androidx.room.*
import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase
import kotlinx.coroutines.flow.Flow
import kotlin.math.roundToInt
import java.util.UUID

// ADDED (Parties tab — last transaction date per party): shared row shape for
// SaleDao.lastActivityByCustomer / PurchaseDao.lastActivityBySupplier /
// PaymentDao.lastActivityByPartyType, all of which return a bare (id, maxCreatedAt)
// pair — see PartyDashboardActivity.loadParties() where the three are merged.
data class PartyLastActivity(val partyId:Long, val lastAt:Long)
data class DailySales(val day:String,val total:Double)
data class TopProduct(val product:String,val totalQty:Double)
data class PurchaseWithSupplier(val billNo:String,val supplierName:String,val total:Double,val createdAt:Long,val status:String)
data class SupplierPurchaseTotal(val supplierName:String,val total:Double)
data class SaleWithCustomer(val invoice:String,val customerName:String,val total:Double,val paymentMethod:String,val createdAt:Long,val status:String)
// NEW (Dashboard Transactions tab — search by item name, not just party name):
// one row per line item, reference is the sale's invoice or purchase's billNo,
// so PartyDashboardActivity can group these into a reference -> [item names] map
// and match the search query against them alongside partyName.
data class TxItemName(val reference:String, val product:String)
// NEW (bill-wise profit in Sale History): per-invoice profit, same Gross Profit
// formula as profitBetween/dailyProfit above (sale.total, which is already
// discount-adjusted, minus that invoice's own COGS from sale_items.cost).
data class SaleProfit(val invoice:String,val profit:Double)
data class CustomerSalesTotal(val customerName:String,val total:Double)
data class DailyProfit(val day:String,val profit:Double)
data class PartyItemReport(val product:String,val totalAmount:Double,val totalQty:Double)
data class ItemSaleRecord(val customerName:String,val qty:Double,val unit:String,val unitPrice:Double,val createdAt:Long)
// NEW: per-customer custom rate lookup — used by the Sale screen to auto-fill
// the last rate actually charged to THIS customer for THIS item, so a
// deliberately-discounted (or up-charged) regular customer gets their usual
// rate suggested automatically instead of the shopkeeper having to remember
// and retype it every time.
data class CustomerItemRate(val unitPrice:Double, val unit:String, val createdAt:Long)
data class ItemPurchaseRecord(val supplierName:String,val qty:Double,val unit:String,val unitCost:Double,val createdAt:Long)

// ---- Day Book (Roznamcha) — merged chronological ledger read models ----
data class DayBookSale(val invoice:String,val customerName:String,val total:Double,val paid:Double,val createdAt:Long,val status:String)
data class DayBookPurchase(val billNo:String,val supplierName:String,val total:Double,val paid:Double,val createdAt:Long,val status:String)

// ---- NEW (Inventory Insights: Fast/Slow Moving Items) — per-product sales aggregate
// over a date range, keyed by barcode (unlike TopProduct/PartyItemReport above, which
// group by the free-text product NAME and so can't be joined back to a Product row for
// its current stock/reorderLevel/cost). Used by InventoryInsightsActivity's Movers tab.
data class ItemMovement(val barcode:String,val product:String,val totalQty:Double,val totalAmount:Double)

// ---- NEW (Due Date Reminders) — a credit/partially-paid sale that still owes money,
// joined with its customer's name and phone (phone lets the reminders screen offer a
// direct "call" action). dueDate is 0L for a sale whose owner hasn't set a reminder date
// yet — DueRemindersActivity still lists it (so nothing owed is ever hidden), just
// grouped as "no date set" instead of overdue/upcoming.
data class DueSale(val invoice:String,val customerId:Long?,val customerName:String,val customerPhone:String,val total:Double,val paid:Double,val dueDate:Long,val createdAt:Long)

// NEW (Overdue for suppliers): same shape as DueSale, for a purchase that still
// owes the supplier money. See PurchaseDao.duePurchases()/setDueDate().
data class DuePurchase(val billNo:String,val supplierId:Long?,val supplierName:String,val supplierPhone:String,val total:Double,val paid:Double,val dueDate:Long,val createdAt:Long)

@Entity(tableName="units")
data class UnitType(@PrimaryKey val name:String)

@Entity(tableName="categories")
data class Category(@PrimaryKey val name:String)

// ADDED (Inventory Accounting upgrade — stock_movements table): a chronological,
// append-only ledger of every stock change on every product — PURCHASE, SALE,
// their _REVERSAL/_EDIT/_ITEM_DELETE counterparts (delete/edit/return flows), and
// OPENING_STOCK for a brand-new product's starting quantity. `qty` is SIGNED (a
// SALE is negative, a PURCHASE is positive) in the product's smallest unit —
// mirrors the recommended table shape (Type/Qty/Unit/Cost/Reference/Date).
// `cost` is the product's cost-per-configured-unit (same convention as
// Product.cost) at the moment of this movement, so the Stock History and Cost
// History screens can both read off this one table instead of needing a
// separate cost ledger. Rows are written by SyncQueueHelper's
// decreaseProductStock()/increaseProductStock()/decreaseProductStockForce()/
// enqueueProductOpeningStock() wrappers — every call site that changes stock
// already goes through one of those four, so nothing else needs to write here
// directly.
@Entity(
    tableName="stock_movements",
    indices=[Index(value=["barcode"], name="index_stock_movements_barcode")]
)
data class StockMovement(
    @PrimaryKey(autoGenerate=true) val id:Long=0,
    val barcode:String,
    val type:String,
    val qty:Double,
    // FIX (crash: "Migration didn't properly handle: stock_movements"): these four
    // columns get an explicit SQL DEFAULT in MIGRATION_26_27's CREATE TABLE (so old
    // rows/any future ALTER stays valid), but Room's schema validator only trusts
    // @ColumnInfo(defaultValue=...) — a Kotlin default parameter value (val unit:String="")
    // is a compile-time constructor default only, it is NOT reflected into the SQL schema
    // Room expects. Without this annotation, Room compares "no default" (expected, from
    // the entity) against "has a default" (found, from the real on-device table created by
    // the migration) and throws IllegalStateException on every single app startup that
    // touches the database — which crashed the app instantly, before any UI could show.
    @ColumnInfo(defaultValue="''") val unit:String="",
    // NOTE: SQLite normalizes a stored "DEFAULT 0.0" numeric literal back to "0" when the
    // schema is read back (PRAGMA table_info) — so defaultValue must be "0" here, not "0.0",
    // or Room's schema validation will permanently mismatch against the actual on-disk table
    // no matter how many times a migration runs. See MIGRATION_27_28 below for the same fix
    // applied to the CREATE TABLE SQL itself, plus a rebuild for devices that already created
    // the table under the old (mismatched) definition.
    @ColumnInfo(defaultValue="0") val cost:Double=0.0,
    @ColumnInfo(defaultValue="''") val reference:String="",
    @ColumnInfo(defaultValue="''") val note:String="",
    val createdAt:Long=System.currentTimeMillis(),
    // NEW (Stock/Cost History sync): same shape as Expense/CashTransaction/ReturnLine
    // above (plain Kotlin defaults, no @ColumnInfo — MIGRATION_37_38 is a plain ALTER
    // TABLE ADD COLUMN, same as MIGRATION_36_37 which added this same trio to `returns`
    // and works fine without one; the @ColumnInfo annotations on unit/cost/reference/
    // note above exist for a different, CREATE-TABLE-recreate-specific reason — see
    // that comment — and aren't the relevant precedent here).
    val serverId:String?=null,
    val updatedAt:Long=0L,
    val dirty:Boolean=true
)

@Dao
interface StockMovementDao {
    @Insert suspend fun insert(m: StockMovement): Long
    // NEW (Stock/Cost History sync): needed to stamp serverId onto a row right
    // after insert (same pattern as ReturnDao.update/CustomerDao.update etc).
    @Update suspend fun update(m: StockMovement)
    @Query("SELECT * FROM stock_movements WHERE barcode=:barcode ORDER BY createdAt DESC, id DESC")
    fun forProduct(barcode: String): Flow<List<StockMovement>>
    // Cost History = only the movement types that can move Product.cost (a sale
    // never changes cost — see SyncQueueHelper's updateProductCost() call sites).
    @Query("SELECT * FROM stock_movements WHERE barcode=:barcode AND type IN ('PURCHASE','PURCHASE_EDIT','PURCHASE_REVERSAL','PURCHASE_ITEM_DELETE','OPENING_STOCK') ORDER BY createdAt DESC, id DESC")
    fun costHistoryForProduct(barcode: String): Flow<List<StockMovement>>
    @Query("SELECT DISTINCT barcode FROM stock_movements")
    suspend fun distinctBarcodes(): List<String>

    // ================= NEW: Stock Adjustment / Damage-Loss Report =================
    // "DAMAGE" and "ADJUSTMENT" are new `type` values written by StockAdjustmentActivity
    // (no schema change needed — type was always a free-text column). qty is stored
    // signed (negative for stock going down), cost is the product's per-unit cost AT
    // THE TIME of the adjustment, so damageBetween()'s value math survives later cost
    // changes on the product itself.
    @Query("SELECT * FROM stock_movements WHERE type='DAMAGE' AND createdAt BETWEEN :start AND :end ORDER BY createdAt DESC")
    suspend fun damageBetween(start:Long,end:Long):List<StockMovement>

    // NEW (10/10 Priority #9 — Stock Taking): every physical-count variance line
    // is logged here with type='STOCK_TAKE' (reference = the stock-take session
    // id, note = "system:X counted:Y") via the same SyncQueueHelper.increaseProductStock/
    // decreaseProductStock wrappers every other stock change already goes through —
    // no new table needed, this reuses the existing ledger. Grouped by `reference`
    // in StockTakingActivity to rebuild a past session's summary.
    @Query("SELECT * FROM stock_movements WHERE type='STOCK_TAKE' ORDER BY createdAt DESC")
    suspend fun stockTakeMovements(): List<StockMovement>

    // NEW (Stock/Cost History sync): resyncAllLocalData() snapshot + pull-apply
    // idempotency lookup, same pattern as ReturnDao.allList()/findByServerId() above.
    @Query("SELECT * FROM stock_movements") suspend fun allList(): List<StockMovement>
    @Query("SELECT * FROM stock_movements WHERE serverId=:serverId LIMIT 1")
    suspend fun findByServerId(serverId: String): StockMovement?

    // FIX (duplicate movement on pull race): a movement written locally is inserted
    // BEFORE it has a serverId (that's stamped moments later once the push succeeds).
    // If a sync PULL lands in that window, findByServerId() above finds nothing (the
    // local row still has serverId=null) and the pulled copy gets inserted as a
    // second row — same barcode/type/reference/qty/createdAt, duplicated in Stock
    // History. This finds that still-unclaimed local twin so the pull can attach the
    // serverId to it instead of inserting a duplicate.
    @Query("SELECT * FROM stock_movements WHERE serverId IS NULL AND barcode=:barcode AND type=:type AND reference=:reference AND qty=:qty AND createdAt=:createdAt LIMIT 1")
    suspend fun findUnclaimedMatch(barcode: String, type: String, reference: String, qty: Double, createdAt: Long): StockMovement?

    // NEW (Stock Audit report): sum of every movement's signed qty per product —
    // the "what the ledger says stock should be" number. StockAuditActivity
    // compares this against Product.stock for every product to surface any
    // product whose real stock has drifted away from its own history (sync
    // races, a bypassed direct write, a pre-fix unit-ladder edit, etc.) without
    // the user needing to already suspect a specific item.
    @Query("SELECT barcode, SUM(qty) as total FROM stock_movements GROUP BY barcode")
    suspend fun sumByBarcode(): List<BarcodeStockSum>
}

// NEW (Stock Audit report): plain Room @Query result row — see sumByBarcode() above.
data class BarcodeStockSum(val barcode: String, val total: Double)

@Entity(tableName="products")
data class Product(
    @PrimaryKey val barcode:String,
    val name:String,
    val category:String="",
    val cost:Double=0.0,
    val salePrice:Double=0.0,
    // FIX (fraction control): stock/reorderLevel/openingStock changed Int -> Double so
    // weight/volume-based items (smallest unit = Gram/ml) don't get silently rounded on
    // every purchase/sale. See MIGRATION_24_25. For piece-based items (smallest unit =
    // Piece/Bottle/Dabbi) the UI still enforces whole numbers — see isFractionalUnit()
    // below and the validation added in ProductActivity/PurchaseActivity/SaleActivity.
    val stock:Double=0.0,
    val reorderLevel:Double=0.0,
    val expiry:String="",
    val unit:String="pcs",
    val unitSize:Int=1,
    val unitNote:String="",
    val secondaryUnit:String="",
    val secondaryUnitQty:Double=0.0,
    val wholesalePrice:Double=0.0,
    val openingStock:Double=0.0,
    val tertiaryUnit:String="",
    val tertiaryUnitQty:Double=0.0,
    // NEW (manual default-unit override — MIGRATION_40_41): which unit tier
    // should be pre-selected on the Sale screen for this product. -1 means
    // "Auto" — keep using SaleCart.defaultUnitIndexFor()'s existing 1/2/3-tier
    // + Beverages-category logic. 0/1/2 means the shopkeeper picked a tier
    // explicitly in the "Add Item Unit" dialog, and that always wins over the
    // automatic guess. Added so the Beverages-only special case doesn't have to
    // be hand-edited in code for every product/category — see SaleCart.kt.
    val defaultUnitIndex:Int=-1,
    // NEW (Quick Sale-specific default unit — MIGRATION_44_45): same idea as
    // defaultUnitIndex above, but for the Quick Sale dialog only. Kept as its
    // own column (not a reuse of defaultUnitIndex) because the smallest unit
    // is picked far more often in Quick Sale than in the normal Sale screen,
    // so a shopkeeper may want e.g. "pcs" as normal Sale's default but
    // "piece"/smallest-tier as Quick Sale's default for the same product.
    // -1 means "Auto" — falls back to the same automatic 1/2/3-tier +
    // Beverages-category guess as defaultUnitIndex (autoDefaultUnitIndexFor()
    // in SaleCart.kt). See ProductUnitDialog.kt's second chip row and
    // SaleCart.kt's quickSaleDefaultUnitIndexFor().
    val quickSaleDefaultUnitIndex:Int=-1,
    val updatedAt:Long=0L,
    val dirty:Boolean=true,
    // NEW (English search alias): lets a product whose `name` is saved in Urdu
    // still be found by typing English/Roman letters, without needing to switch
    // the keyboard mid-search. Purely a search aid — never shown as the product's
    // display name anywhere, never required. See MIGRATION_38_39 and
    // Product.matchesQuery() below, which every product-name search screen should
    // go through instead of checking `name` alone.
    val searchTag:String=""
)

// Single source of truth for "does this product match what the user typed" —
// checks the Urdu/native `name` AND the optional English `searchTag` alias, so
// every search screen (dashboard quick-search, Item Search, Items list, Sale/
// Purchase item pickers, Stock screens, Rate Comparison, etc.) behaves the same
// way once wired through this instead of re-deriving `name.contains(...)` locally.
// FIX (English search not matching): was a single whole-phrase `contains` check,
// so typing more than one word (e.g. "aloo bukhara") only matched if that exact
// phrase — spacing and all — appeared verbatim in `name` OR in `searchTag`. A
// searchTag of just "Aloo" (or any tag not containing the full typed phrase)
// then showed "No matching items" even though the product does exist. Now the
// query is split into words and matched against `name` + `searchTag` COMBINED,
// requiring every typed word to appear somewhere in either field (any order) —
// so a tag like "Aloo Bukhara" matches "bukhara aloo", "aloo", or "bukhara"
// alike, and a query can also match partly off the Urdu name and partly off the
// English tag.
fun Product.matchesQuery(query: String): Boolean {
    val q = query.trim()
    if (q.isEmpty()) return true
    val haystack = "$name $searchTag".lowercase()
    val terms = q.lowercase().split(Regex("\\s+")).filter { it.isNotBlank() }
    if (terms.isEmpty()) return true
    return terms.all { haystack.contains(it) }
}

// FIX (Sale/Purchase item box ignoring English search alias): the Item Name
// AutoCompleteTextView on Sale/Purchase was wired to a plain
// `ArrayAdapter(products.map { it.name })`, which relies on Android's built-in
// dropdown filter — that filter only ever compares against each item's own
// toString() (the Urdu `name`), so it never saw `searchTag` at all. Every other
// search screen goes through Product.matchesQuery() (name + searchTag), which
// is why typing in English worked everywhere except the Sale/Purchase item box:
// turning off the Urdu keyboard and typing the English alias found nothing there.
// This adapter drives its own Filter off matchesQuery() instead of the default
// one, so Sale/Purchase now match the exact same way as every other screen.
class ProductNameAdapter(
    context: android.content.Context,
    private val allProducts: () -> List<Product>
) : android.widget.ArrayAdapter<String>(context, android.R.layout.simple_dropdown_item_1line, java.util.ArrayList()) {

    override fun getFilter(): android.widget.Filter = object : android.widget.Filter() {
        override fun performFiltering(constraint: CharSequence?): FilterResults {
            val q = constraint?.toString().orEmpty()
            val matched = allProducts().filter { it.matchesQuery(q) }.map { it.name }
            return FilterResults().apply { values = matched; count = matched.size }
        }

        @Suppress("UNCHECKED_CAST")
        override fun publishResults(constraint: CharSequence?, results: FilterResults?) {
            clear()
            (results?.values as? List<String>)?.let { addAll(it) }
            notifyDataSetChanged()
        }

        override fun convertResultToString(resultValue: Any?): CharSequence = resultValue as? String ?: ""
    }
}

// ================= 3-tier unit conversion helpers =================
// Single source of truth for converting between a product's primary, secondary,
// and tertiary units and its "smallest unit" (the unit `stock` is actually stored
// and compared in, e.g. reorderLevel/stock<=reorderLevel). Every screen that
// touches stock — Purchase, Purchase Return, Sale, Sale Return, Product opening
// stock — must go through these functions instead of re-deriving the math
// locally, so a fix here fixes every screen at once instead of drifting apart.

/** One tier of a product's unit ladder: this unit's name, and how many
 *  "smallest units" ONE of it equals. */
data class ProductUnitTier(val unit: String, val smallestPerUnit: Double)

// FIX: unit names are now compared trimmed + case-insensitive. Previously an
// exact `==` string match meant a unit string that differed only by casing or
// stray whitespace (easy to get from a Spinner/AutoCompleteTextView) silently
// fell through to the wrong branch and quietly corrupted stock.
private fun sameUnit(a: String, b: String): Boolean =
    a.isNotBlank() && b.isNotBlank() && a.trim().equals(b.trim(), ignoreCase = true)

/**
 * Ordered ladder of this product's units, SMALLEST first, each paired with how
 * many "smallest units" one of it equals. Always has at least one tier (the
 * primary unit, factor 1) — a plain 1-unit product. A 2-tier product (primary +
 * secondary, no tertiary) has 2 tiers with the secondary as smallest. A 3-tier
 * product has all 3, with tertiary as smallest.
 *
 * A malformed config (e.g. a tertiary unit typed in without a valid secondary)
 * degrades gracefully to a lower tier instead of producing a wrong/blown-up
 * factor — this is the single place that decides "is this product 1/2/3 tier",
 * so every other function below just reads off this list instead of
 * re-deciding it independently.
 */
fun Product.unitLadder(): List<ProductUnitTier> {
    val hasSecondary = secondaryUnit.isNotBlank() && secondaryUnitQty > 0
    val hasTertiary = hasSecondary && tertiaryUnit.isNotBlank() && tertiaryUnitQty > 0

    if (!hasSecondary) {
        // 1-tier: only the primary unit exists, and it IS the smallest unit.
        return listOf(ProductUnitTier(unit, 1.0))
    }

    if (!hasTertiary) {
        // 2-tier: secondary is the smallest unit; 1 primary = secondaryUnitQty secondary.
        return listOf(
            ProductUnitTier(secondaryUnit, 1.0),
            ProductUnitTier(unit, secondaryUnitQty)
        )
    }

    // 3-tier: tertiary is the smallest unit.
    // 1 secondary = tertiaryUnitQty tertiary; 1 primary = secondaryUnitQty secondary.
    return listOf(
        ProductUnitTier(tertiaryUnit, 1.0),
        ProductUnitTier(secondaryUnit, tertiaryUnitQty),
        ProductUnitTier(unit, secondaryUnitQty * tertiaryUnitQty)
    )
}

/** How many smallest units make up ONE of this product's primary unit. */
fun Product.smallestUnitFactor(): Double = unitLadder().last().smallestPerUnit

/** How many smallest units make up ONE secondary unit (1.0 if there's no secondary tier). */
fun Product.smallestPerSecondary(): Double =
    unitLadder().find { sameUnit(it.unit, secondaryUnit) }?.smallestPerUnit ?: 1.0

/** Name of the smallest unit this product's stock is actually stored/compared in. */
fun Product.smallestUnitName(): String = unitLadder().first().unit

/**
 * Converts [qty] entered in [enteredUnit] into the product's smallest-unit basis
 * (the same basis `stock` is stored in). This is THE function every screen must
 * call before adjusting `stock` — never re-derive this math locally.
 *
 * Falls back to the primary unit's factor if [enteredUnit] doesn't match any
 * tier (e.g. a stale/blank unit string) rather than silently returning the raw
 * qty unconverted, which would previously understate stock changes for
 * multi-tier products.
 */
fun Product.toSmallestUnits(qty: Double, enteredUnit: String): Double {
    val tier = unitLadder().find { sameUnit(it.unit, enteredUnit) } ?: unitLadder().last()
    return qty * tier.smallestPerUnit
}

/**
 * Reverse of [toSmallestUnits]: converts a quantity already expressed in
 * smallest units back into [targetUnit]. Used for return flows, display, and
 * for round-tripping a stored rate/qty into a different unit on the same
 * product — sharing this with toSmallestUnits keeps both directions in sync.
 */
fun Product.fromSmallestUnits(smallestQty: Double, targetUnit: String): Double {
    val tier = unitLadder().find { sameUnit(it.unit, targetUnit) } ?: unitLadder().last()
    return if (tier.smallestPerUnit > 0) smallestQty / tier.smallestPerUnit else smallestQty
}

/** How many smallest units make up ONE of [unitName] (any tier), reading off the same unitLadder(). */
fun Product.smallestPerUnitOf(unitName: String): Double =
    unitLadder().find { sameUnit(it.unit, unitName) }?.smallestPerUnit ?: 1.0

// FIX (historical unit conversion bug — Sale/Purchase edit/delete/return used the
// product's CURRENT unit configuration to reverse an OLD transaction's stock effect.
// If "1 Carton = 10 Box" at sale time later became "1 Carton = 12 Box" (product
// config edited afterwards), deleting/editing/returning that old sale would reverse
// the WRONG quantity — stock silently drifts every time a product's unit ladder is
// ever changed. Fix: SaleItem/PurchaseItem now stamp `conversionFactor` (smallest
// units per one `unit`) at the moment the transaction is created — see every
// SyncQueueHelper.enqueueSale/enqueuePurchase call site and SaleRepository/
// PurchaseRepository's item construction. These two functions are now THE way to
// find out how many smallest units a stored line item represents: they use that
// frozen, transaction-time factor when present, and only fall back to asking the
// CURRENT product (the old, sometimes-wrong behaviour) for rows saved before this
// fix (conversionFactor == 0.0, i.e. never captured).
fun SaleItem.smallestQty(product: Product?): Double =
    if (conversionFactor > 0) qty * conversionFactor
    else product?.toSmallestUnits(qty, unit.ifBlank { product.unit }) ?: qty

fun PurchaseItem.smallestQty(product: Product?): Double =
    if (conversionFactor > 0) qty * conversionFactor
    else product?.toSmallestUnits(qty, unit.ifBlank { product.unit }) ?: qty

/**
 * Converts a rate/price entered per [fromUnit] into the equivalent rate per the
 * product's PRIMARY unit (e.g. Rs per pcs -> Rs per carton). This is the single
 * source of truth for rate conversion, built on the same unitLadder() that backs
 * toSmallestUnits()/fromSmallestUnits() — previously PricingTierMath.kt kept a
 * second, independent unit-tier system for this, risking drift from this one.
 */
fun Product.toPrimaryUnitRate(entered: Double, fromUnit: String): Double {
    val perFromUnit = smallestPerUnitOf(fromUnit)
    if (perFromUnit <= 0) return entered
    return entered * (smallestUnitFactor() / perFromUnit)
}

/** Reverse of [toPrimaryUnitRate]: converts a primary-unit rate down to [chosenUnit]. */
fun Product.fromPrimaryUnitRate(mainRate: Double, chosenUnit: String): Double {
    val perChosenUnit = smallestPerUnitOf(chosenUnit)
    val factor = if (perChosenUnit > 0) smallestUnitFactor() / perChosenUnit else 1.0
    return if (factor > 0) mainRate / factor else mainRate
}

// FIX (fraction control): names of smallest units that are allowed to carry a
// fractional stock value (continuous/weight/volume units). Any smallest unit
// NOT in this list (Piece, Dabbi, Bottle, Dozen, etc.) is treated as
// indivisible — entries that would produce a fractional smallest-unit qty for
// such a product must be rejected by the UI instead of silently rounded, which
// is what used to happen when `stock` was an Int.
private val FRACTIONAL_UNIT_NAMES = setOf(
    "gram", "grams", "gm", "g", "kg", "kilogram", "kilograms",
    "ml", "milliliter", "millilitre", "litre", "liter", "l",
    "tola", "maund"
)

/** True if this product's smallest unit is a continuous/weight/volume unit
 *  (Gram, ml, etc.) and may therefore legally hold a fractional stock qty. */
fun Product.isFractionalUnit(): Boolean =
    smallestUnitName().trim().lowercase() in FRACTIONAL_UNIT_NAMES

/**
 * Whether [smallestQty] (already converted via toSmallestUnits) is a legal
 * quantity for this product: whole numbers only unless the smallest unit is a
 * fractional/continuous one. Every screen that converts an entered qty down to
 * smallest units (Purchase, Sale, Purchase Return, Sale Return, Opening Stock)
 * must call this before writing to `stock` and reject/re-prompt on failure
 * instead of letting a value like "0.5 Dabbi" silently corrupt stock.
 */
fun Product.isValidSmallestQty(smallestQty: Double): Boolean {
    if (isFractionalUnit()) return true
    return kotlin.math.abs(smallestQty - kotlin.math.round(smallestQty)) < 0.0001
}

/**
 * Human-readable stock breakdown, e.g. "1 carton 2 box 1 pcs". Built directly
 * off the same unitLadder() used by toSmallestUnits/fromSmallestUnits, so the
 * display can never drift out of sync with what's actually stored/converted —
 * previously this had its own separate divide/modulo math.
 */
private fun Double.trimZero(): String =
    if (this == kotlin.math.round(this)) this.toLong().toString()
    else String.format("%.3f", this).trimEnd('0').trimEnd('.')

fun Product.formatStockBreakdown(): String {
    val ladder = unitLadder()
    if (ladder.size == 1) return "${stock.trimZero()} ${ladder[0].unit}"

    val largestToSmallest = ladder.asReversed()
    var remaining = stock
    val parts = mutableListOf<String>()

    largestToSmallest.forEachIndexed { index, tier ->
        val isSmallestTier = index == largestToSmallest.lastIndex
        if (isSmallestTier) {
            // FIX: smallest tier can be fractional (Gram/ml) — show up to 3
            // decimals instead of truncating to Int, which used to drop
            // fractional leftovers like "0.5 Gram" from the display entirely.
            if (remaining > 0) parts.add("${remaining.trimZero()} ${tier.unit}")
        } else {
            val perUnit = tier.smallestPerUnit
            val count = kotlin.math.floor(remaining / perUnit)
            remaining -= count * perUnit
            if (count > 0) parts.add("${count.toLong()} ${tier.unit}")
        }
    }

    if (parts.isEmpty()) return "0 ${smallestUnitName()}"
    return parts.joinToString(" ")
}

@Entity(tableName="customers")
data class Customer(
    @PrimaryKey(autoGenerate=true) val id:Long=0,
    val name:String,
    val phone:String="",
    val creditLimit:Double=0.0,
    val openingBalance:Double=0.0,
    val balance:Double=0.0,
    val serverId:String?=null,
    val updatedAt:Long=0L,
    val dirty:Boolean=true,
    // NEW (Stuck Balance — MIGRATION_43_44): an old, frozen amount the customer owes that
    // does NOT move with daily sales/payments (unlike openingBalance + balance, which is
    // the "daily/running" part). 0.0 for almost every customer — the UI only shows the
    // Daily / Stuck / Total split when this is non-zero. Kept LAST with a default so no
    // existing Customer(...) call needs to change. See Customer.dailyPayable()/totalPayable().
    val stuckBalance:Double=0.0
)

// NEW (Stuck Balance): single source of truth for the two headline figures, so no screen
// re-derives them by hand (they used to write `openingBalance + balance` inline everywhere).
//   Daily Payable = the running part (opening + bills - payments) — what changes day to day.
//   Total Payable = Daily Payable + the stuck amount — what the customer owes in all.
// For a customer with stuckBalance == 0.0 both are identical to the old "closing" figure.
fun Customer.dailyPayable(): Double = openingBalance + balance
fun Customer.totalPayable(): Double = openingBalance + balance + stuckBalance
fun Customer.hasStuck(): Boolean = stuckBalance != 0.0

@Entity(tableName="suppliers")
data class Supplier(
    @PrimaryKey(autoGenerate=true) val id:Long=0,
    val name:String,
    val phone:String="",
    val openingBalance:Double=0.0,
    val balance:Double=0.0,
    val serverId:String?=null,
    val updatedAt:Long=0L,
    val dirty:Boolean=true
)

@Entity(tableName="sales", indices=[Index(value=["saleUid"], unique=true)])
data class Sale(
    @PrimaryKey val invoice:String,
    val customerId:Long?=null,
    val subtotal:Double,
    val discount:Double,
    val tax:Double,
    val total:Double,
    val paid:Double,
    val paymentMethod:String,
    val saleType:String="retail",
    val createdAt:Long=System.currentTimeMillis(),
    val status:String="active",
    val updatedAt:Long=0L,
    val dirty:Boolean=true,
    // NEW (Due Date Reminders): optional reminder date for a credit/partially-paid sale,
    // as an epoch-millis midnight timestamp. 0L means "no reminder set yet" — set/changed
    // from DueRemindersActivity, never touched by the normal checkout flow in SaleActivity.
    // See MIGRATION_29_30 for the matching ALTER TABLE.
    @ColumnInfo(defaultValue="0") val dueDate:Long=0L,
    // NEW (Improvement Pack P2 — safe unique sale identifiers): a permanent,
    // globally-unique id for this sale that is completely independent of the
    // human-readable `invoice` string. `invoice` stays the primary key and the
    // number printed on receipts (unchanged), but invoice numbers are still
    // partly time-based text meant for humans — this field is the real,
    // collision-proof identity of the sale for any future cross-device
    // reconciliation. Auto-generated for every new Sale object unless
    // explicitly overridden (e.g. when reconstructing one pulled from Firestore
    // in SyncApi.kt, so the same sale keeps the same saleUid on every device).
    // See MIGRATION_31_32 for the matching ALTER TABLE + backfill of existing rows.
    @ColumnInfo(defaultValue="") val saleUid:String=UUID.randomUUID().toString()
)

// FIX (fractional qty consistency): qty is REAL/Double, matching PurchaseItem.qty,
// ReturnLine.qty, and every in-memory line (SaleLine/PurchaseLine). Previously this was
// an Int, so any fractional quantity (e.g. 1.5 kg, 2.5 dozen) got silently rounded away
// the moment a sale was saved — the printed bill, sale history, item reports, and any
// later edit/return/delete of that sale all worked off the rounded number instead of
// what was actually sold. See MIGRATION_23_24 for the matching DB-side change.
@Entity(tableName="sale_items", indices=[Index(value=["lineUid"], unique=true)])
data class SaleItem(
    @PrimaryKey(autoGenerate=true) val id:Long=0,
    val invoice:String,
    val barcode:String,
    val product:String,
    val qty:Double,
    val unit:String="",
    val unitPrice:Double,
    val cost:Double,
    val amount:Double,
    // FIX (historical unit conversion bug): how many smallest-units ONE of
    // `unit` equaled AT THE TIME this line was sold — i.e. Product.smallestPerUnitOf(unit)
    // captured at transaction time. 0.0 means "not captured" (a pre-migration row),
    // in which case callers fall back to re-deriving it from the CURRENT product
    // config (the old, sometimes-wrong behaviour). See smallestQty() below and the
    // "Best solution" comment above MIGRATION_25_26.
    val conversionFactor:Double=0.0,
    // NEW (Improvement Pack P2): same reasoning as Sale.saleUid above, but for
    // this individual line — a permanent id independent of the local
    // autoGenerate `id` (which is only unique on this device) and independent
    // of `invoice`. See MIGRATION_31_32.
    @ColumnInfo(defaultValue="") val lineUid:String=UUID.randomUUID().toString()
)

@Entity(tableName="payments")
data class Payment(
    @PrimaryKey(autoGenerate=true) val id:Long=0,
    val reference:String,
    val partyType:String,
    val partyId:Long?,
    val amount:Double,
    val method:String,
    val note:String="",
    // NEW (Payments 10/10): optional link to the specific sale invoice / purchase
    // billNo this payment is against. Blank means it's a general payment against
    // the party's overall balance, not tied to one bill — the original behavior.
    val billReference:String="",
    val createdAt:Long=System.currentTimeMillis(),
    val serverId:String?=null,
    val updatedAt:Long=0L,
    val dirty:Boolean=true,
    // NEW (CRITICAL cross-device sync fix — "phantom payments attached to the
    // wrong party"): `partyId` above is this DEVICE's own local Room autoGenerate
    // primary key for the Customer/Supplier it points at — it is NOT globally
    // unique. Two different devices independently assign their own local ids
    // (1, 2, 3...) to their own parties, so "partyId=25" means a completely
    // different real-world party on each device. Until this field existed,
    // push/pull sent that raw local id as-is (see SyncQueueHelper's payment push
    // map and SyncApi's payments pull loop), so a payment pulled from another
    // device got silently re-attached to WHATEVER party happens to have that same
    // numeric id locally — producing large, unrelated "phantom" payments on a
    // party that never actually received them (see the September 2026 "Abdullah
    // Egg" investigation for the real-world symptom this caused). This new field
    // is the Customer/Supplier's own stable `serverId` (same identifier already
    // used for Sale.customerServerId/Purchase.supplierServerId), which IS the
    // same value on every device. Pull now resolves the correct LOCAL id by
    // looking this up via CustomerDao/SupplierDao.findByServerId() instead of
    // trusting the raw partyId. Null only for payments created before this fix
    // (SyncQueueHelper.enqueuePayment backfills it from partyId+partyType on
    // this, the originating, device before pushing) — for those legacy rows pull
    // still falls back to the old (unreliable) raw-partyId behavior.
    @ColumnInfo(defaultValue="") val partyServerId:String?=null
)

@Entity(tableName="purchases", indices=[Index(value=["purchaseUid"], unique=true)])
data class Purchase(
    @PrimaryKey val billNo:String,
    val supplierId:Long?,
    val total:Double,
    val paid:Double,
    val createdAt:Long=System.currentTimeMillis(),
    val subtotal:Double=0.0,
    val discount:Double=0.0,
    val status:String="active",
    val updatedAt:Long=0L,
    val dirty:Boolean=true,
    // NEW (Improvement Pack P2): same reasoning as Sale.saleUid — a permanent
    // id independent of the human-readable `billNo`. See MIGRATION_31_32.
    @ColumnInfo(defaultValue="") val purchaseUid:String=UUID.randomUUID().toString(),
    // NEW ("10/10 Purchase screen" item #2): the SUPPLIER's own invoice/bill
    // number (as printed on their paper bill), distinct from our own
    // auto-generated `billNo`. Blank means not entered. Used for a stronger,
    // exact duplicate-bill check (PurchaseDao.findDuplicateBySupplierInvoice)
    // alongside the existing same-party+same-amount heuristic. See MIGRATION_33_34.
    @ColumnInfo(defaultValue="") val supplierInvoiceNo:String="",
    // NEW (Overdue for suppliers — was always Rs 0.00 with no dueDate field to check
    // against): same plain-ADD-COLUMN shape and 0L "no date set" convention as
    // Sale.dueDate (MIGRATION_29_30). See MIGRATION_42_43.
    @ColumnInfo(defaultValue="0") val dueDate:Long=0L
)

@Entity(tableName="purchase_items", indices=[Index(value=["lineUid"], unique=true)])
data class PurchaseItem(
    @PrimaryKey(autoGenerate=true) val id:Long=0,
    val billNo:String,
    val barcode:String,
    val qty:Double,
    val unitCost:Double,
    val amount:Double,
    val unit:String="",
    // FIX (historical unit conversion bug): same as SaleItem.conversionFactor —
    // how many smallest-units ONE of `unit` equaled AT THE TIME this line was
    // purchased. 0.0 means "not captured" (pre-migration row); see smallestQty().
    val conversionFactor:Double=0.0,
    // NEW (Improvement Pack P2): same reasoning as SaleItem.lineUid above.
    @ColumnInfo(defaultValue="") val lineUid:String=UUID.randomUUID().toString(),
    // FIX (item name / retail-wholesale rate "gayab" after sync — MIGRATION_35_36):
    // this row used to have NO name or rate columns of its own — History/Edit/Return
    // always re-derived the name via a live `products` table lookup by barcode
    // (see the removed `product?.name ?: barcode` pattern), and the entered
    // retail/wholesale rate was never persisted here at all (loadForEdit() always
    // rebuilt it as 0.0). On a second device that hasn't yet synced/created that
    // barcode's product row (or where the product was later renamed/deleted), the
    // lookup came back null/stale and the name showed as the barcode, or the rate
    // field showed empty. Snapshotting these on the row itself — like SaleItem
    // already does with `product` — makes this row self-contained, same as a real
    // invoice line item should be. Blank/0.0 = pre-migration row; callers fall back
    // to the old live-lookup behaviour for those (see RoomPurchaseRepository).
    @ColumnInfo(defaultValue="") val itemName:String="",
    @ColumnInfo(defaultValue="0.0") val retailRate:Double=0.0,
    @ColumnInfo(defaultValue="0.0") val wholesaleRate:Double=0.0
)

@Entity(tableName="returns")
data class ReturnLine(
    @PrimaryKey(autoGenerate=true) val id:Long=0,
    val reference:String,
    val type:String,
    val barcode:String,
    val qty:Double,
    val amount:Double,
    val createdAt:Long=System.currentTimeMillis(),
    // NEW (Returns sync): same shape as Expense/CashTransaction — see MIGRATION_36_37.
    val serverId:String?=null,
    val updatedAt:Long=0L,
    val dirty:Boolean=true
)

@Entity(tableName="users")
data class User(
    @PrimaryKey val username:String,
    val displayName:String,
    val role:String,
    val passwordHash:String,
    val active:Boolean=true,
    val phone:String=""
)

@Entity(tableName="audit")
data class Audit(
    @PrimaryKey(autoGenerate=true) val id:Long=0,
    val username:String,
    val action:String,
    val reference:String="",
    val details:String="",
    val createdAt:Long=System.currentTimeMillis()
)

@Entity(tableName="expenses")
data class Expense(
    @PrimaryKey(autoGenerate=true) val id:Long=0,
    val category:String,
    val description:String,
    val amount:Double,
    // FIX (Bug 2 — expenses never touched Cash in Hand): which drawer this expense
    // was paid from ("cash" or "bank"), same values CashActivity/CashTransaction
    // already use. Defaulted to "cash" (the common case, and what every expense
    // recorded before this column existed was, implicitly) so ExpenseActivity.saveExpense()
    // can create a matching CashTransaction — see MIGRATION_41_42.
    @ColumnInfo(defaultValue="cash") val method:String="cash",
    val createdAt:Long=System.currentTimeMillis(),
    val serverId:String?=null,
    val updatedAt:Long=0L,
    val dirty:Boolean=true
)

// NEW (Zakat tracker): one row per Zakat year the user has started (Ramadan-to-Ramadan,
// per their request), holding the asset snapshot + 2.5% payable calculated at the time
// the year was started. `dirty`/`serverId` follow the same shape as every other synced
// entity in this app — see SyncQueueHelper.enqueueZakatYear()/SyncApi's zakat_years
// collection (wired up as of the full-sync-audit batch).
// UPDATED (Zakat currency + calendar option): currency is captured per-year (not just
// read live from Settings) so a year already started keeps showing in whatever currency
// it was started in even if the shop's default currency changes later. calendarType picks
// which month names the monthly plan (ZakatMonthPlan below) displays — "islamic" (Ramadan,
// Shawwal, ...) or "gregorian" (the actual Jan/Feb/... month each ~29.5-day slice falls in)
// — the underlying Ramadan-to-Ramadan year window itself is unchanged either way.
@Entity(tableName="zakat_years")
data class ZakatYear(
    @PrimaryKey(autoGenerate=true) val id:Long=0,
    val startDate:Long,
    val endDate:Long,
    val assetsSnapshot:Double,
    val totalPayable:Double,
    val currency:String="Rs",
    val calendarType:String="islamic", // "islamic" or "gregorian"
    val createdAt:Long=System.currentTimeMillis(),
    val serverId:String?=null,
    val updatedAt:Long=0L,
    val dirty:Boolean=true
)

// NEW (Zakat tracker): a partial or full payment recorded against a ZakatYear —
// letting the user pay all at once or spread across several installments.
// NOTE (sync): zakatYearId is a local autoincrement FK, meaningless on another
// device — the sync payload carries the parent's serverId string instead
// ("zakatYearServerId") and the pull-apply loop resolves it back to whatever
// local id that year has on THIS device. See SyncQueueHelper.zakatPaymentJson().
// UPDATED (Zakat payment date + category): paymentDate is the date the user says the
// payment was actually made (editable, defaults to today) — kept separate from createdAt
// (when the row was entered on this device) since the two can differ, e.g. logging a
// payment a few days after actually handing it over. category is an OPTIONAL label for
// which zakatable asset the payment relates to (Cash, Gold, Silver, Business Stock,
// Livestock, Crops, Other) — purely informational, left blank if not needed.
@Entity(tableName="zakat_payments")
data class ZakatPayment(
    @PrimaryKey(autoGenerate=true) val id:Long=0,
    val zakatYearId:Long,
    val amount:Double,
    val method:String,
    val note:String="",
    val category:String="",
    val paymentDate:Long=System.currentTimeMillis(),
    val createdAt:Long=System.currentTimeMillis(),
    val serverId:String?=null,
    val updatedAt:Long=0L,
    val dirty:Boolean=true
)

// NEW (Zakat monthly plan): one row per month (1-12, counted from the year's start —
// Ramadan if calendarType=="islamic") the user has customized — a chosen payable amount
// for that month (defaults to totalPayable/12 in the UI until the user edits/saves it)
// plus an optional description/note. Paid-per-month is NOT stored here — it's computed
// live from ZakatPayment rows whose paymentDate falls inside that month's date range
// (see ZakatActivity.monthStartMillis/monthEndMillis), so recording a payment always
// keeps the monthly breakdown in sync without a separate "mark as paid" step.
// Local-only for now (dirty/serverId-shaped fields kept out entirely, same reasoning as
// ShellCustomer above) — no matching server-side collection exists yet.
@Entity(tableName="zakat_month_plans")
data class ZakatMonthPlan(
    @PrimaryKey(autoGenerate=true) val id:Long=0,
    val zakatYearId:Long,
    val monthIndex:Int,
    val payableAmount:Double,
    val note:String="",
    val createdAt:Long=System.currentTimeMillis(),
    val updatedAt:Long=0L,
    val dirty:Boolean=true
)

// NEW (Bottle Shell Ledger): a customer who has been given a filled bottle without
// handing back an empty shell in exchange — shellsOwed is the running count of shells
// they still owe the shop. This is a standalone ledger (not tied to the Customer table)
// since a shell-taking "customer" here is often just a name/phone jotted down, not a
// full party record. serverId/updatedAt/dirty follow the same shape as ZakatYear above.
// FIX (Shell Ledger sync): this WAS local-only ("treat as local-only until a matching
// server-side endpoint exists") — now wired through SyncQueueHelper.enqueueShellCustomer/
// enqueueShellTransaction/enqueueShopEmptyShellLog (see ShellLedgerActivity call sites)
// and SyncApi's shell_customers/shell_transactions/shop_empty_shell_log collections.
@Entity(tableName="shell_customers")
data class ShellCustomer(
    @PrimaryKey(autoGenerate=true) val id:Long=0,
    val name:String,
    val phone:String="",
    val shellsOwed:Int=0,
    val createdAt:Long=System.currentTimeMillis(),
    val serverId:String?=null,
    val updatedAt:Long=0L,
    val dirty:Boolean=true
)

// NEW (Bottle Shell Ledger): one row per issue/return against a ShellCustomer, so the
// running shellsOwed total always has a history behind it (who took what, when).
@Entity(
    tableName="shell_transactions",
    indices=[Index(value=["customerId"], name="index_shell_transactions_customerId")]
)
data class ShellTransaction(
    @PrimaryKey(autoGenerate=true) val id:Long=0,
    val customerId:Long,
    val type:String, // "ISSUE" (filled given, shell owed) or "RETURN" (empty shell handed back)
    val qty:Int,
    val note:String="",
    val createdAt:Long=System.currentTimeMillis(),
    val serverId:String?=null,
    val updatedAt:Long=0L,
    val dirty:Boolean=true
)

// NEW (Bottle Shell Ledger): the shop's OWN empty-shell count — separate from what
// customers owe. A plain signed delta log (same shape as StockMovement above), summed
// for the current total, so "how many empties are sitting at the shop right now" always
// has a history behind it too (collected from a return, sent off for refill, or a
// manual recount correction).
@Entity(tableName="shop_empty_shell_log")
data class ShopEmptyShellLog(
    @PrimaryKey(autoGenerate=true) val id:Long=0,
    val delta:Int,
    val reason:String, // MANUAL_ADD, MANUAL_REMOVE, CUSTOMER_RETURN, SENT_FOR_REFILL
    val note:String="",
    val createdAt:Long=System.currentTimeMillis(),
    // NEW (Shell Ledger sync — MIGRATION_45_46): added so this table can finally push/
    // pull through SyncQueueHelper/SyncApi, same shape as ShellCustomer/ShellTransaction
    // above (which already had these three columns from day one but were never wired up).
    val serverId:String?=null,
    val updatedAt:Long=0L,
    val dirty:Boolean=true
)

@Entity(tableName="held_bills")
data class HeldBill(
    @PrimaryKey val holdId:String,
    val payload:String,
    val createdAt:Long=System.currentTimeMillis()
)

@Entity(tableName="cash_transactions")
data class CashTransaction(
    @PrimaryKey(autoGenerate=true) val id:Long=0,
    val type:String,
    val method:String,
    val amount:Double,
    val reason:String="",
    val reference:String="",
    val createdAt:Long=System.currentTimeMillis(),
    val serverId:String?=null,
    val updatedAt:Long=0L,
    val dirty:Boolean=true
)

@Entity(tableName="cash_register")
data class CashRegister(
    @PrimaryKey val date:String,
    val openingCash:Double=0.0,
    val closingCash:Double=0.0,
    val openingBank:Double=0.0,
    val closingBank:Double=0.0,
    val closed:Boolean=false
)

@Entity(tableName="app_settings")
data class AppSetting(@PrimaryKey val key:String, val value:String)

@Entity(tableName="sync_queue")
data class SyncQueueEntry(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val entityType: String,
    val entityId: String,
    val operation: String,
    val payloadJson: String,
    val createdAt: Long = System.currentTimeMillis(),
    val syncedAt: Long? = null,
    val retryCount: Int = 0,
    val lastError: String? = null
)

@Dao
interface ProductDao {
    @Query("SELECT * FROM products WHERE barcode=:code LIMIT 1")
    suspend fun find(code:String):Product?
    @Insert(onConflict=OnConflictStrategy.REPLACE) suspend fun upsert(p:Product)
    @Delete suspend fun delete(p:Product)
    @Query("UPDATE products SET stock=stock-:qty WHERE barcode=:code AND stock>=:qty")
    suspend fun decrease(code:String,qty:Double):Int
    @Query("UPDATE products SET stock=stock-:qty WHERE barcode=:code")
    suspend fun decreaseForce(code:String,qty:Double)
    @Query("UPDATE products SET stock=stock+:qty WHERE barcode=:code")
    suspend fun increase(code:String,qty:Double)
    @Query("UPDATE products SET cost=:newCost WHERE barcode=:code")
    suspend fun updateCost(code:String,newCost:Double)
    // NEW ("10/10 Purchase screen" item #7): lets the Purchase screen set/update a
    // product's retail (salePrice) and wholesale rate at the moment it's purchased,
    // instead of only ever being editable from the Product screen.
    @Query("UPDATE products SET salePrice=:salePrice, wholesalePrice=:wholesalePrice WHERE barcode=:code")
    suspend fun updatePrices(code:String,salePrice:Double,wholesalePrice:Double)
    @Query("UPDATE products SET unit=:unit WHERE barcode=:code")
    suspend fun updateUnit(code:String,unit:String)
    // NEW (Bulk Set Default Unit): products that have more than one unit tier
    // (a secondary unit set) but no manual default-unit override yet — the
    // queue BulkDefaultUnitActivity works through, one suggestion at a time.
    // See Product.defaultUnitIndex / SaleCart.kt's defaultUnitIndexFor().
    @Query("SELECT * FROM products WHERE secondaryUnit!='' AND defaultUnitIndex=-1 ORDER BY name")
    suspend fun productsNeedingDefaultUnitReview(): List<Product>
    @Query("UPDATE products SET defaultUnitIndex=:index, dirty=1, updatedAt=:ts WHERE barcode=:code")
    suspend fun updateDefaultUnitIndex(code:String, index:Int, ts:Long)
    // NEW (Quick Sale-specific default unit): same shape as updateDefaultUnitIndex()
    // above, for the separate quickSaleDefaultUnitIndex column.
    @Query("UPDATE products SET quickSaleDefaultUnitIndex=:index, dirty=1, updatedAt=:ts WHERE barcode=:code")
    suspend fun updateQuickSaleDefaultUnitIndex(code:String, index:Int, ts:Long)
    // NEW (Bulk Missing Rates — replaces the old CSV "Rate List" export/review):
    // every product where Retail (salePrice) or Wholesale rate hasn't been
    // entered yet (still 0), the queue BulkMissingRatesActivity works through
    // one at a time — same shape as productsNeedingDefaultUnitReview() above.
    @Query("SELECT * FROM products WHERE salePrice<=0 OR wholesalePrice<=0 ORDER BY name")
    suspend fun productsWithMissingRates(): List<Product>
    @Query("UPDATE products SET salePrice=:salePrice, wholesalePrice=:wholesalePrice, dirty=1, updatedAt=:ts WHERE barcode=:code")
    suspend fun updateRatesReview(code:String, salePrice:Double, wholesalePrice:Double, ts:Long)
    @Query("SELECT * FROM products WHERE stock<=reorderLevel ORDER BY name")
    fun lowStock():Flow<List<Product>>
    @Query("SELECT * FROM products WHERE expiry!='' ORDER BY expiry")
    fun expiring():Flow<List<Product>>
    @Query("SELECT * FROM products ORDER BY name")
    fun all():Flow<List<Product>>
    // ADDED (force full resync): one-shot suspend equivalent of all() above — the
    // resync helper runs inside a plain coroutine, not a Flow collector.
    @Query("SELECT * FROM products ORDER BY name")
    suspend fun allList():List<Product>
    // ADDED (Balance Sheet): current stock value at cost, for the "Stock in Hand" asset line.
    @Query("SELECT COALESCE(SUM(stock*cost),0) FROM products")
    suspend fun stockValueTotal():Double

    // ================= Bulk Translate support =================
    // Distinct Urdu/English values currently saved directly on product rows —
    // used by BulkTranslateActivity to find every value that needs renaming,
    // since category/unit are plain text columns on Product, not foreign keys.
    @Query("SELECT DISTINCT category FROM products WHERE category!=''")
    suspend fun distinctCategories(): List<String>
    @Query("SELECT DISTINCT unit FROM products WHERE unit!=''")
    suspend fun distinctPrimaryUnits(): List<String>
    @Query("SELECT DISTINCT secondaryUnit FROM products WHERE secondaryUnit!=''")
    suspend fun distinctSecondaryUnits(): List<String>
    @Query("SELECT DISTINCT tertiaryUnit FROM products WHERE tertiaryUnit!=''")
    suspend fun distinctTertiaryUnits(): List<String>
    // NEW (Bulk Translate — item search tags): distinct product NAMEs that still
    // have at least one row with a blank searchTag — i.e. not yet given an
    // English search alias. Once every product sharing a name has a tag saved,
    // that name drops out of this list on the next load, same "shrinks as you
    // go" behavior as the Categories/Units sections above.
    @Query("SELECT DISTINCT name FROM products WHERE searchTag=''")
    suspend fun distinctNamesWithoutSearchTag(): List<String>

    // FIX (#12 — category/unit master sync incomplete): the rename queries below
    // update product rows directly via SQL, bypassing normal per-row writes — so
    // the caller (BulkTranslateActivity) needs the list of affected products
    // BEFORE the rename (by their old value) to know which ones to re-enqueue
    // for sync AFTER the rename, since a plain SQL UPDATE doesn't go through
    // anything that would otherwise trigger a sync_queue entry.
    @Query("SELECT * FROM products WHERE category=:v")
    suspend fun findByCategory(v: String): List<Product>
    @Query("SELECT * FROM products WHERE unit=:v")
    suspend fun findByPrimaryUnit(v: String): List<Product>
    @Query("SELECT * FROM products WHERE secondaryUnit=:v")
    suspend fun findBySecondaryUnit(v: String): List<Product>
    @Query("SELECT * FROM products WHERE tertiaryUnit=:v")
    suspend fun findByTertiaryUnit(v: String): List<Product>
    // Same pattern for product-name search tags: find every row sharing a name
    // (so the caller can re-enqueue them for sync) and set their searchTag in
    // one UPDATE. Name itself is never touched — only the alias.
    @Query("SELECT * FROM products WHERE name=:v")
    suspend fun findByName(v: String): List<Product>
    @Query("UPDATE products SET searchTag=:tag WHERE name=:v")
    suspend fun updateSearchTagForName(v: String, tag: String)

    // Cascades a rename from BulkTranslateActivity into every product row that
    // used the old value, one column at a time (a unit name can appear in any
    // of the three unit slots, so all three are updated independently).
    @Query("UPDATE products SET category=:newVal WHERE category=:oldVal")
    suspend fun renameCategoryInProducts(oldVal: String, newVal: String)
    @Query("UPDATE products SET unit=:newVal WHERE unit=:oldVal")
    suspend fun renamePrimaryUnitInProducts(oldVal: String, newVal: String)
    @Query("UPDATE products SET secondaryUnit=:newVal WHERE secondaryUnit=:oldVal")
    suspend fun renameSecondaryUnitInProducts(oldVal: String, newVal: String)
    @Query("UPDATE products SET tertiaryUnit=:newVal WHERE tertiaryUnit=:oldVal")
    suspend fun renameTertiaryUnitInProducts(oldVal: String, newVal: String)
}

@Dao interface UnitDao {
    @Insert(onConflict=OnConflictStrategy.IGNORE) suspend fun insert(u:UnitType)
    @Delete suspend fun delete(u:UnitType)
    @Query("SELECT * FROM units ORDER BY name") fun all():Flow<List<UnitType>>
    // One-shot version of all() for screens (like BulkTranslateActivity) that just need
    // a snapshot once, without collecting a Flow.
    @Query("SELECT * FROM units ORDER BY name") suspend fun allOnce():List<UnitType>
    // Used by BulkTranslateActivity to remove the old Urdu master row after the
    // English name has been inserted in its place.
    @Query("DELETE FROM units WHERE name=:name") suspend fun deleteByName(name: String)
}

@Dao interface CategoryDao {
    @Insert(onConflict=OnConflictStrategy.IGNORE) suspend fun insert(c:Category)
    @Query("SELECT * FROM categories ORDER BY name") fun all():Flow<List<Category>>
    // One-shot version of all() for screens (like BulkTranslateActivity) that just need
    // a snapshot once, without collecting a Flow.
    @Query("SELECT * FROM categories ORDER BY name") suspend fun allOnce():List<Category>
    // Used by BulkTranslateActivity to remove the old Urdu master row after the
    // English name has been inserted in its place.
    @Query("DELETE FROM categories WHERE name=:name") suspend fun deleteByName(name: String)
}

@Dao interface CustomerDao {
    @Insert suspend fun insert(c:Customer):Long
    @Update suspend fun update(c:Customer)
    @Delete suspend fun delete(c:Customer)
    @Query("SELECT * FROM customers WHERE id=:id LIMIT 1") suspend fun find(id:Long):Customer?
    @Query("SELECT * FROM customers WHERE serverId=:serverId LIMIT 1") suspend fun findByServerId(serverId:String):Customer?
    @Query("SELECT * FROM customers ORDER BY name") fun all():Flow<List<Customer>>
    // ADDED (force full resync): one-shot suspend list, for the resync helper.
    @Query("SELECT * FROM customers ORDER BY name") suspend fun allList():List<Customer>
    @Query("UPDATE customers SET balance=balance+:amt WHERE id=:id")
    suspend fun addBalance(id:Long,amt:Double)
    @Query("SELECT COALESCE(name,'Walk-in') as customerName, SUM(total) as total FROM sales LEFT JOIN customers ON sales.customerId=customers.id GROUP BY customerId ORDER BY total DESC")
    suspend fun salesTotalsByCustomer():List<CustomerSalesTotal>
    // ADDED (Balance Sheet): balance>0 = customer owes us (Accounts Receivable, an Asset).
    // balance<0 = we've received an advance from them (a Liability), kept separate so the
    // two don't silently net against each other on the statement.
    @Query("SELECT COALESCE(SUM(balance),0) FROM customers WHERE balance>0")
    suspend fun receivablesTotal():Double
    @Query("SELECT COALESCE(SUM(-balance),0) FROM customers WHERE balance<0")
    suspend fun advancesReceivedTotal():Double
}

@Dao interface SupplierDao {
    @Insert suspend fun insert(s:Supplier):Long
    @Update suspend fun update(s:Supplier)
    @Delete suspend fun delete(s:Supplier)
    @Query("SELECT * FROM suppliers WHERE id=:id LIMIT 1") suspend fun find(id:Long):Supplier?
    @Query("SELECT * FROM suppliers WHERE serverId=:serverId LIMIT 1") suspend fun findByServerId(serverId:String):Supplier?
    @Query("UPDATE suppliers SET balance=balance+:amt WHERE id=:id") suspend fun addBalance(id:Long,amt:Double)
    @Query("SELECT * FROM suppliers ORDER BY name") fun all():Flow<List<Supplier>>
    // ADDED (force full resync): one-shot suspend list, for the resync helper.
    @Query("SELECT * FROM suppliers ORDER BY name") suspend fun allList():List<Supplier>
    @Query("SELECT COALESCE(name,'Cash Purchase') as supplierName, SUM(total) as total FROM purchases LEFT JOIN suppliers ON purchases.supplierId=suppliers.id GROUP BY supplierId ORDER BY total DESC")
    suspend fun purchaseTotalsBySupplier():List<SupplierPurchaseTotal>
    // ADDED (Balance Sheet): balance>0 = we owe the supplier (Accounts Payable, a Liability).
    // balance<0 = we've overpaid/advanced them (an Asset), kept separate for the same reason
    // as CustomerDao.advancesReceivedTotal().
    @Query("SELECT COALESCE(SUM(balance),0) FROM suppliers WHERE balance>0")
    suspend fun payablesTotal():Double
    @Query("SELECT COALESCE(SUM(-balance),0) FROM suppliers WHERE balance<0")
    suspend fun advancesPaidTotal():Double
}

@Dao interface SaleDao {
    @Insert suspend fun sale(s:Sale)
    // NOTE (10/10 Priority #3 — edit without delete/re-add): RoomSaleRepository's
    // edit path uses updateSale() (declared further down, originally added for
    // PartyTransactionActivity's billed-item editor) instead of the old
    // deleteSale()+sale() (delete-then-reinsert) sequence, so an edited sale keeps
    // its original `saleUid` and `dueDate` instead of silently getting a fresh
    // saleUid / a reset-to-0 dueDate on every edit — see the fix note in
    // RoomSaleRepository.saveSale().
    @Insert suspend fun items(items:List<SaleItem>)
    @Query("SELECT COUNT(*) FROM sales") suspend fun count():Int
    @Query("SELECT COALESCE(SUM(total),0) FROM sales") suspend fun totalSales():Double
    @Query("SELECT COALESCE(SUM(total),0) FROM sales WHERE createdAt BETWEEN :start AND :end AND status!='returned'") suspend fun totalSalesBetween(start:Long,end:Long):Double
    @Query("SELECT COUNT(*) FROM sales WHERE createdAt BETWEEN :start AND :end AND status!='returned'") suspend fun countBetween(start:Long,end:Long):Int
    @Query("SELECT strftime('%Y-%m-%d', createdAt/1000, 'unixepoch', 'localtime') as day, COALESCE(SUM(total),0) as total FROM sales WHERE createdAt BETWEEN :start AND :end AND status!='returned' GROUP BY day ORDER BY day") suspend fun dailySales(start:Long,end:Long):List<DailySales>
    @Query("SELECT product, SUM(qty) as totalQty FROM sale_items WHERE invoice IN (SELECT invoice FROM sales WHERE createdAt BETWEEN :start AND :end AND status!='returned') GROUP BY product ORDER BY totalQty DESC LIMIT 5") suspend fun topProducts(start:Long,end:Long):List<TopProduct>
    @Query("SELECT invoice, COALESCE((SELECT name FROM customers WHERE customers.id=sales.customerId),'Walk-in') as customerName, total, paymentMethod, createdAt, status FROM sales ORDER BY createdAt DESC") suspend fun allSales():List<SaleWithCustomer>
    // NEW (Dashboard Transactions tab item-name search): one row per sale line item.
    // FIX (English search not matching here — every other product search screen
    // goes through Product.matchesQuery(), i.e. name + searchTag; this one only
    // had the Urdu `product` snapshot): now also appends the live product's
    // searchTag (looked up by barcode), so typing the English alias matches too.
    @Query("SELECT invoice as reference, (si.product || ' ' || COALESCE((SELECT searchTag FROM products WHERE products.barcode=si.barcode),'')) as product FROM sale_items si") suspend fun allItemNamesForSales():List<TxItemName>
    // NEW (bill-wise profit in Sale History): profit per invoice, for the same
    // window as allSales() above (matched by invoice at the call site). Returned
    // sales are excluded (no profit to show once a bill is reversed).
    @Query("""
        SELECT s.invoice as invoice,
            (s.total - COALESCE((SELECT SUM(si.cost) FROM sale_items si WHERE si.invoice = s.invoice),0)) as profit
        FROM sales s
        WHERE s.status != 'returned'
        ORDER BY s.createdAt DESC
    """)
    suspend fun allSaleProfits():List<SaleProfit>
    @Query("SELECT * FROM sales WHERE customerId=:customerId ORDER BY createdAt DESC") suspend fun salesByCustomer(customerId:Long):List<Sale>
    // ADDED (Parties tab — show last transaction date instead of a static "Customer"
    // label, matching the Khatabook-style party list design): most recent sale date
    // per customer, so PartyDashboardActivity can badge each row with "05 Aug 2026"
    // style text like the reference screenshot.
    @Query("SELECT customerId as partyId, MAX(createdAt) as lastAt FROM sales WHERE customerId IS NOT NULL GROUP BY customerId") suspend fun lastActivityByCustomer():List<PartyLastActivity>
    @Query("SELECT * FROM sales WHERE invoice=:invoice LIMIT 1") suspend fun findSale(invoice:String):Sale?
    // ADDED (force full resync): every local sale row, unfiltered/unjoined — allSales()
    // above returns a display-only join (SaleWithCustomer), not usable for re-pushing.
    @Query("SELECT * FROM sales ORDER BY createdAt DESC") suspend fun allRaw():List<Sale>
    @Query("SELECT * FROM sale_items WHERE invoice=:invoice") suspend fun itemsForInvoice(invoice:String):List<SaleItem>
    @Query("DELETE FROM sale_items WHERE invoice=:invoice") suspend fun deleteItems(invoice:String)
    @Query("DELETE FROM sales WHERE invoice=:invoice") suspend fun deleteSale(invoice:String)
    @Query("UPDATE sales SET status='returned' WHERE invoice=:invoice") suspend fun markReturned(invoice:String)
    // FIX (Today's Profit / discount bug): previously
    //   SELECT SUM(si.amount - si.cost) FROM sale_items si JOIN sales s ...
    // si.amount is the PRE-DISCOUNT line total (qty * unitPrice) and is never reduced
    // when a bill-level discount is applied in SaleActivity/PurchaseActivity flows —
    // only sales.total is discount-adjusted. So the old query overstated profit by
    // exactly the discount amount on every sale that had one.
    //
    // Now computed per-sale as (sales.total - COGS for that sale), then summed. This
    // uses the already discount-adjusted sales.total and only sums sale_items.cost
    // (which discount never touches), so it matches Total Sales (totalSalesBetween)
    // minus COGS (cogsBetween) exactly — the same Gross Profit formula ReportsActivity
    // already uses, and what MainActivity's "Today's Profit" now also computes.
    @Query("""
        SELECT COALESCE(SUM(
            s.total - (SELECT COALESCE(SUM(si.cost),0) FROM sale_items si WHERE si.invoice = s.invoice)
        ),0)
        FROM sales s
        WHERE s.createdAt BETWEEN :start AND :end AND s.status!='returned'
    """)
    suspend fun profitBetween(start:Long,end:Long):Double
    // FIX (same discount bug as profitBetween above): per-day profit is now also
    // (sales.total - that sale's COGS) summed per day, instead of SUM(si.amount-si.cost).
    @Query("""
        SELECT strftime('%Y-%m-%d', s.createdAt/1000,'unixepoch','localtime') as day,
            COALESCE(SUM(
                s.total - (SELECT COALESCE(SUM(si.cost),0) FROM sale_items si WHERE si.invoice = s.invoice)
            ),0) as profit
        FROM sales s
        WHERE s.createdAt BETWEEN :start AND :end AND s.status!='returned'
        GROUP BY day ORDER BY day
    """)
    suspend fun dailyProfit(start:Long,end:Long):List<DailyProfit>
    @Query("SELECT COALESCE(SUM(si.cost),0) FROM sale_items si JOIN sales s ON si.invoice=s.invoice WHERE s.createdAt BETWEEN :start AND :end AND s.status!='returned'") suspend fun cogsBetween(start:Long,end:Long):Double
    @Query("SELECT si.product as product, COALESCE(SUM(si.amount),0) as totalAmount, COALESCE(SUM(si.qty),0) as totalQty FROM sale_items si JOIN sales s ON si.invoice=s.invoice WHERE s.customerId=:customerId AND s.status!='returned' GROUP BY si.product ORDER BY totalAmount DESC") suspend fun itemReportByCustomer(customerId:Long):List<PartyItemReport>
    @Query("SELECT COALESCE((SELECT name FROM customers WHERE customers.id=s.customerId),'Walk-in') as customerName, si.qty as qty, si.unit as unit, si.unitPrice as unitPrice, s.createdAt as createdAt FROM sale_items si JOIN sales s ON si.invoice=s.invoice WHERE si.barcode=:barcode ORDER BY s.createdAt DESC") suspend fun saleRecordsForItem(barcode:String):List<ItemSaleRecord>
    // NEW: last rate charged to a specific customer for a specific item (most
    // recent, returned sales excluded) — powers the Sale screen's "use this
    // customer's usual rate" auto-suggest.
    @Query("SELECT si.unitPrice as unitPrice, si.unit as unit, s.createdAt as createdAt FROM sale_items si JOIN sales s ON si.invoice=s.invoice WHERE si.barcode=:barcode AND s.customerId=:customerId AND s.status!='returned' ORDER BY s.createdAt DESC LIMIT 1") suspend fun lastRateForCustomerItem(customerId:Long, barcode:String):CustomerItemRate?
    @Query("SELECT COALESCE(SUM(qty),0) FROM sale_items WHERE barcode=:barcode AND invoice IN (SELECT invoice FROM sales WHERE status='active')") suspend fun totalActiveQtySold(barcode:String):Int
    @Query("SELECT si.product as product, COALESCE(SUM(si.amount),0) as totalAmount, COALESCE(SUM(si.qty),0) as totalQty FROM sale_items si JOIN sales s ON si.invoice=s.invoice WHERE s.status!='returned' GROUP BY si.product ORDER BY totalAmount DESC") suspend fun allTimeItemTotals():List<PartyItemReport>
    @Query("SELECT invoice, COALESCE((SELECT name FROM customers WHERE customers.id=sales.customerId),'Walk-in') as customerName, total, paid, createdAt, status FROM sales WHERE createdAt BETWEEN :start AND :end ORDER BY createdAt ASC") suspend fun salesBetween(start:Long,end:Long):List<DayBookSale>

    // ================= NEW: Inventory Insights (Fast/Slow Movers) =================
    // Same shape as topProducts()/itemReportByCustomer() above, but grouped by
    // si.barcode instead of si.product so results can be matched back to a live
    // Product row (current stock, reorderLevel, cost) for the Movers tab.
    @Query("""
        SELECT si.barcode as barcode, si.product as product,
            COALESCE(SUM(si.qty),0) as totalQty, COALESCE(SUM(si.amount),0) as totalAmount
        FROM sale_items si JOIN sales s ON si.invoice=s.invoice
        WHERE s.createdAt BETWEEN :start AND :end AND s.status!='returned'
        GROUP BY si.barcode ORDER BY totalQty DESC
    """)
    suspend fun itemMovementBetween(start:Long,end:Long):List<ItemMovement>

    // ================= NEW: Due Date Reminders =================
    // Any active sale still owing money (paid < total), regardless of whether a
    // reminder date has been set yet — DueRemindersActivity groups/sorts these
    // client-side (0 = no date set, sorted after real dates).
    @Query("""
        SELECT s.invoice as invoice, s.customerId as customerId,
            COALESCE(c.name,'Walk-in') as customerName, COALESCE(c.phone,'') as customerPhone,
            s.total as total, s.paid as paid, s.dueDate as dueDate, s.createdAt as createdAt
        FROM sales s LEFT JOIN customers c ON c.id=s.customerId
        WHERE s.status='active' AND (s.total - s.paid) > 0.009
        ORDER BY (s.dueDate = 0) ASC, s.dueDate ASC, s.createdAt ASC
    """)
    suspend fun dueSales():List<DueSale>

    @Query("UPDATE sales SET dueDate=:dueDate, updatedAt=:now, dirty=1 WHERE invoice=:invoice")
    suspend fun setDueDate(invoice:String,dueDate:Long,now:Long=System.currentTimeMillis())

    // ================= Party Transaction — billed item edit/delete support =================
    // Added for PartyTransactionActivity's editable "Billed Items" dialog: lets a single
    // sale_items row be looked up/updated/deleted by its own id (rather than the whole
    // invoice at once via items()/deleteItems()), plus a total update for the parent Sale
    // and an item-count check used to decide whether a delete should remove the whole sale.
    @Update suspend fun updateSale(s:Sale)
    @Query("SELECT * FROM sale_items WHERE id=:id LIMIT 1") suspend fun findItem(id:Long):SaleItem?
    @Update suspend fun updateItemRow(item:SaleItem)
    @Query("DELETE FROM sale_items WHERE id=:id") suspend fun deleteItemById(id:Long)
    @Query("SELECT COUNT(*) FROM sale_items WHERE invoice=:invoice") suspend fun itemCountForInvoice(invoice:String):Int

    // ADDED (multi-device two-way sync): applying a pulled sale from another device.
    // REPLACE-on-conflict is safe here because `invoice` is the natural, already-unique
    // key (not a local autoincrement id), so a "conflict" only ever means "this exact
    // sale already exists locally, overwrite it with the newer server copy".
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun upsertSale(s:Sale)
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun upsertItems(items:List<SaleItem>)
}

@Dao interface ExpenseDao {
    @Insert suspend fun insert(e:Expense): Long
    @Delete suspend fun delete(e:Expense)
    @Query("SELECT COALESCE(SUM(amount),0) FROM expenses") suspend fun total():Double
    @Query("SELECT COALESCE(SUM(amount),0) FROM expenses WHERE createdAt BETWEEN :start AND :end") suspend fun totalBetween(start:Long,end:Long):Double
    @Query("SELECT * FROM expenses ORDER BY createdAt DESC") fun all():Flow<List<Expense>>
    // ADDED (force full resync): one-shot suspend list, for the resync helper.
    @Query("SELECT * FROM expenses ORDER BY createdAt DESC") suspend fun allList():List<Expense>
    @Query("SELECT * FROM expenses WHERE createdAt BETWEEN :start AND :end ORDER BY createdAt ASC") suspend fun between(start:Long,end:Long):List<Expense>
    // ADDED (multi-device two-way sync): needed so a pulled expense that this same
    // device already pushed gets updated in place instead of inserted as a duplicate.
    @Update suspend fun update(e:Expense)
    @Query("SELECT * FROM expenses WHERE serverId=:serverId LIMIT 1") suspend fun findByServerId(serverId:String):Expense?
    // ADDED (audit — one-time cleanup of the "expense saved twice" bug): rows never stamped with
    // a serverId, and the pulled twin of such a row (same fields, serverId in THIS device's id
    // format). See SyncQueueHelper.mergeOwnDuplicateExpenses().
    @Query("SELECT * FROM expenses WHERE serverId IS NULL") suspend fun unstamped():List<Expense>
    @Query("SELECT * FROM expenses WHERE substr(serverId,1,length(:prefix))=:prefix AND createdAt=:createdAt AND amount=:amount AND category=:category AND description=:description AND method=:method LIMIT 1")
    suspend fun findOwnTwin(prefix:String, createdAt:Long, amount:Double, category:String, description:String, method:String):Expense?
}

@Dao interface HeldDao {
    @Insert(onConflict=OnConflictStrategy.REPLACE) suspend fun hold(h:HeldBill)
    @Query("SELECT * FROM held_bills ORDER BY createdAt DESC") fun all():Flow<List<HeldBill>>
    @Delete suspend fun delete(h:HeldBill)
    // NEW ("10/10 Purchase screen" item #12): Sale and Purchase Hold/Recall now share
    // this one held_bills table — holdId's prefix ("HOLD" for Sale, "PHOLD" for
    // Purchase, set at creation time in SaleUseCases.HoldBillUseCase /
    // PurchaseActivity.holdBill()) tells the two screens' recall lists apart so a
    // held Purchase bill never shows up in the Sale recall dialog and vice versa.
    @Query("SELECT * FROM held_bills WHERE holdId LIKE 'HOLD%' ORDER BY createdAt DESC") fun allSaleHolds():Flow<List<HeldBill>>
    @Query("SELECT * FROM held_bills WHERE holdId LIKE 'PHOLD%' ORDER BY createdAt DESC") fun allPurchaseHolds():Flow<List<HeldBill>>
}

// NEW (Zakat tracker)
@Dao interface ZakatDao {
    @Insert suspend fun insertYear(y:ZakatYear):Long
    @Update suspend fun updateYear(y:ZakatYear)
    @Query("SELECT * FROM zakat_years ORDER BY startDate DESC LIMIT 1") suspend fun latestYear():ZakatYear?
    @Query("SELECT * FROM zakat_years ORDER BY startDate DESC") suspend fun allYears():List<ZakatYear>
    // NEW (Zakat sync): lets the pull-apply loop find/update the local row that
    // matches a pulled document, and lets enqueueZakatPayment() resolve a parent
    // year's serverId without needing the caller to look it up separately.
    @Query("SELECT * FROM zakat_years WHERE serverId=:serverId LIMIT 1") suspend fun findYearByServerId(serverId:String):ZakatYear?
    @Query("SELECT * FROM zakat_years WHERE id=:id LIMIT 1") suspend fun findYearById(id:Long):ZakatYear?
    @Insert suspend fun insertPayment(p:ZakatPayment): Long
    @Update suspend fun updatePayment(p:ZakatPayment)
    @Query("SELECT * FROM zakat_payments WHERE zakatYearId=:yearId ORDER BY createdAt DESC") suspend fun paymentsForYear(yearId:Long):List<ZakatPayment>
    @Query("SELECT COALESCE(SUM(amount),0) FROM zakat_payments WHERE zakatYearId=:yearId") suspend fun totalPaidForYear(yearId:Long):Double
    // NEW (Zakat sync): mirrors findYearByServerId above, for the payments pull-apply loop.
    @Query("SELECT * FROM zakat_payments WHERE serverId=:serverId LIMIT 1") suspend fun findPaymentByServerId(serverId:String):ZakatPayment?

    // NEW (Zakat monthly plan): upsert-by-hand (no unique index on zakatYearId+monthIndex,
    // so callers check monthPlan(yearId, monthIndex) first and insert vs update accordingly
    // — same pattern used throughout this file, e.g. AppSettingDao.set()).
    @Insert suspend fun insertMonthPlan(m:ZakatMonthPlan):Long
    @Update suspend fun updateMonthPlan(m:ZakatMonthPlan)
    @Query("SELECT * FROM zakat_month_plans WHERE zakatYearId=:yearId ORDER BY monthIndex ASC") suspend fun monthPlansForYear(yearId:Long):List<ZakatMonthPlan>
    @Query("SELECT * FROM zakat_month_plans WHERE zakatYearId=:yearId AND monthIndex=:monthIndex LIMIT 1") suspend fun monthPlan(yearId:Long, monthIndex:Int):ZakatMonthPlan?
    // Paid-so-far for one month slice — see ZakatMonthPlan's doc comment for why this is
    // computed from payments' paymentDate rather than stored on the plan row itself.
    @Query("SELECT COALESCE(SUM(amount),0) FROM zakat_payments WHERE zakatYearId=:yearId AND paymentDate>=:start AND paymentDate<:end") suspend fun paidInRange(yearId:Long, start:Long, end:Long):Double
}

@Dao interface ShellDao {
    @Insert suspend fun insertCustomer(c:ShellCustomer):Long
    @Update suspend fun updateCustomer(c:ShellCustomer)
    @Query("SELECT * FROM shell_customers WHERE id=:id LIMIT 1") suspend fun getCustomer(id:Long):ShellCustomer?
    // COLLATE NOCASE: so "Ahmed" and "ahmed" resolve to the same ledger entry instead
    // of silently creating a duplicate customer with a fresh shellsOwed=0.
    @Query("SELECT * FROM shell_customers WHERE name=:name COLLATE NOCASE LIMIT 1") suspend fun findByName(name:String):ShellCustomer?
    @Query("SELECT * FROM shell_customers ORDER BY shellsOwed DESC, name COLLATE NOCASE ASC") suspend fun allCustomers():List<ShellCustomer>
    @Query("SELECT COALESCE(SUM(shellsOwed),0) FROM shell_customers") suspend fun totalOwedByCustomers():Int
    // NEW (Shell Ledger sync): pull-apply idempotency lookup, same pattern as every
    // other synced entity (CustomerDao.findByServerId/ZakatDao.findYearByServerId/etc).
    @Query("SELECT * FROM shell_customers WHERE serverId=:serverId LIMIT 1") suspend fun findCustomerByServerId(serverId:String):ShellCustomer?

    @Insert suspend fun insertTransaction(t:ShellTransaction):Long
    @Update suspend fun updateTransaction(t:ShellTransaction)
    @Query("SELECT * FROM shell_transactions WHERE customerId=:customerId ORDER BY createdAt DESC") suspend fun historyForCustomer(customerId:Long):List<ShellTransaction>
    @Query("SELECT * FROM shell_transactions WHERE serverId=:serverId LIMIT 1") suspend fun findTransactionByServerId(serverId:String):ShellTransaction?

    @Insert suspend fun insertShopLog(l:ShopEmptyShellLog):Long
    @Update suspend fun updateShopLog(l:ShopEmptyShellLog)
    @Query("SELECT COALESCE(SUM(delta),0) FROM shop_empty_shell_log") suspend fun shopStockTotal():Int
    @Query("SELECT * FROM shop_empty_shell_log ORDER BY createdAt DESC LIMIT 100") suspend fun shopLogHistory():List<ShopEmptyShellLog>
    @Query("SELECT * FROM shop_empty_shell_log WHERE serverId=:serverId LIMIT 1") suspend fun findShopLogByServerId(serverId:String):ShopEmptyShellLog?
}

@Dao interface PaymentDao {
    @Insert suspend fun insert(p:Payment): Long
    @Query("SELECT COALESCE(SUM(amount),0) FROM payments") suspend fun total():Double
    // ADDED (audit): total of the standalone payments linked to one bill via billReference
    // (i.e. NOT the bill's own embedded payment row, whose reference == the bill). Those are
    // already part of the bill's `paid`, so an edit of the bill must not re-record them.
    @Query("SELECT COALESCE(SUM(amount),0) FROM payments WHERE billReference=:bill AND reference!=:bill") suspend fun linkedPaidForBill(bill:String):Double
    // ADDED (audit): the standalone payments linked to one bill (see linkedPaidForBill above).
    @Query("SELECT * FROM payments WHERE billReference=:bill AND reference!=:bill") suspend fun linkedPayments(bill:String):List<Payment>
    @Query("SELECT COALESCE(SUM(amount),0) FROM payments WHERE method=:method AND createdAt BETWEEN :start AND :end") suspend fun totalByMethodBetween(method:String,start:Long,end:Long):Double
    @Query("DELETE FROM payments WHERE reference=:ref") suspend fun deleteByReference(ref:String)
    // FIX (duplicate-payment-on-sync bug): every deleteByReference() call site used to
    // delete straight from Room with no way to also tell the sync queue which specific
    // payment row(s) it just removed — see SyncQueueHelper.deletePaymentsByReference()
    // for why that silently left orphaned payments on other devices/the server.
    @Query("SELECT * FROM payments WHERE reference=:ref") suspend fun allByReference(ref:String):List<Payment>
    // ADDED (cash record consistency fix): lets a single billed-item edit/delete
    // (PartyTransactionActivity) find and adjust the one payment tied to a bill
    // instead of only being able to delete or total them.
    @Query("SELECT * FROM payments WHERE reference=:ref LIMIT 1") suspend fun findByReference(ref:String):Payment?
    // ADDED (Cleanup Duplicate Payments): deletePaymentsByReference() below removes every
    // payment sharing a reference — wrong here, since a duplicate-payment group has exactly
    // ONE row that's still correct (see PartyRepository.findDuplicatePayments()) and only the
    // rest should go. This deletes a single row by its own id instead.
    @Query("DELETE FROM payments WHERE id=:id") suspend fun deleteById(id:Long)
    // ADDED (force full resync): every local payment row, unfiltered.
    @Query("SELECT * FROM payments ORDER BY createdAt DESC") suspend fun allRaw():List<Payment>
    // ADDED (multi-device two-way sync): needed so a pulled payment that this same
    // device already pushed gets updated in place instead of inserted as a duplicate,
    // same reasoning as ExpenseDao/CashTransactionDao above.
    @Update suspend fun update(p:Payment)
    @Query("SELECT * FROM payments WHERE serverId=:serverId LIMIT 1") suspend fun findByServerId(serverId:String):Payment?
    @Query("DELETE FROM payments WHERE serverId=:serverId") suspend fun deleteByServerId(serverId:String)
    // ADDED (Amount Payable/Receivable — standalone payments): lets PartyTransactionActivity
    // show a party's manually-recorded "Receive Payment"/"Make Payment" entries (not tied to
    // a specific bill) alongside their sale/purchase history.
    @Query("SELECT * FROM payments WHERE partyType=:partyType AND partyId=:partyId ORDER BY createdAt DESC") suspend fun listByParty(partyType:String,partyId:Long):List<Payment>
    // ADDED (Parties tab — last transaction date): so a party whose most recent
    // activity is a standalone payment (not a sale/purchase) still shows the
    // correct date, e.g. a customer who only made a payment against an old balance.
    @Query("SELECT partyId as partyId, MAX(createdAt) as lastAt FROM payments WHERE partyType=:partyType AND partyId IS NOT NULL GROUP BY partyId") suspend fun lastActivityByPartyType(partyType:String):List<PartyLastActivity>
}

@Dao interface PurchaseDao {
    @Insert suspend fun purchase(p:Purchase)
    @Insert suspend fun items(items:List<PurchaseItem>)
    @Query("SELECT COALESCE(SUM(total),0) FROM purchases") suspend fun total():Double
    @Query("SELECT COALESCE(SUM(total),0) FROM purchases WHERE createdAt BETWEEN :start AND :end AND status!='returned'") suspend fun totalBetween(start:Long,end:Long):Double
    @Query("SELECT billNo, COALESCE((SELECT name FROM suppliers WHERE suppliers.id=purchases.supplierId),'Cash Purchase') as supplierName, total, createdAt, status FROM purchases ORDER BY createdAt DESC") suspend fun allPurchases():List<PurchaseWithSupplier>
    // NEW (Dashboard Transactions tab item-name search): one row per purchase line
    // item. itemName is the self-contained snapshot (see PurchaseItem.itemName);
    // pre-migration rows where that's blank fall back to a live products lookup by
    // barcode, same fallback RoomPurchaseRepository already uses elsewhere.
    // FIX (English search not matching): also appends the live product's
    // searchTag (see matching FIX on allItemNamesForSales above).
    @Query("SELECT billNo as reference, (CASE WHEN pi.itemName != '' THEN pi.itemName ELSE COALESCE((SELECT name FROM products WHERE products.barcode=pi.barcode),'') END || ' ' || COALESCE((SELECT searchTag FROM products WHERE products.barcode=pi.barcode),'')) as product FROM purchase_items pi") suspend fun allItemNamesForPurchases():List<TxItemName>
    @Query("SELECT * FROM purchases WHERE supplierId=:supplierId ORDER BY createdAt DESC") suspend fun purchasesBySupplier(supplierId:Long):List<Purchase>
    // ADDED (Parties tab — last transaction date, see SaleDao.lastActivityByCustomer
    // for the matching customer-side query and rationale).
    @Query("SELECT supplierId as partyId, MAX(createdAt) as lastAt FROM purchases WHERE supplierId IS NOT NULL GROUP BY supplierId") suspend fun lastActivityBySupplier():List<PartyLastActivity>
    @Query("SELECT * FROM purchases WHERE billNo=:bill LIMIT 1") suspend fun findPurchase(bill:String):Purchase?
    // ADDED (force full resync): every local purchase row, unfiltered/unjoined —
    // allPurchases() above returns a display-only join (PurchaseWithSupplier).
    @Query("SELECT * FROM purchases ORDER BY createdAt DESC") suspend fun allRaw():List<Purchase>
    @Query("SELECT * FROM purchase_items WHERE billNo=:bill") suspend fun itemsForBill(bill:String):List<PurchaseItem>
    @Query("DELETE FROM purchase_items WHERE billNo=:bill") suspend fun deleteItems(bill:String)
    @Query("DELETE FROM purchases WHERE billNo=:bill") suspend fun deletePurchase(bill:String)
    @Query("UPDATE purchases SET status='returned' WHERE billNo=:bill") suspend fun markReturned(bill:String)
    @Query("SELECT p.name as product, COALESCE(SUM(pi.amount),0) as totalAmount, COALESCE(SUM(pi.qty),0) as totalQty FROM purchase_items pi JOIN purchases pu ON pi.billNo=pu.billNo JOIN products p ON pi.barcode=p.barcode WHERE pu.supplierId=:supplierId AND pu.status!='returned' GROUP BY p.name ORDER BY totalAmount DESC") suspend fun itemReportBySupplier(supplierId:Long):List<PartyItemReport>
    @Query("SELECT COALESCE((SELECT name FROM suppliers WHERE suppliers.id=p.supplierId),'Cash Purchase') as supplierName, pi.qty as qty, pi.unit as unit, pi.unitCost as unitCost, p.createdAt as createdAt FROM purchase_items pi JOIN purchases p ON pi.billNo=p.billNo WHERE pi.barcode=:barcode ORDER BY p.createdAt DESC") suspend fun purchaseRecordsForItem(barcode:String):List<ItemPurchaseRecord>
    @Query("SELECT p.name as product, COALESCE(SUM(pi.amount),0) as totalAmount, COALESCE(SUM(pi.qty),0) as totalQty FROM purchase_items pi JOIN purchases pu ON pi.billNo=pu.billNo JOIN products p ON pi.barcode=p.barcode WHERE pu.status!='returned' GROUP BY p.name ORDER BY totalAmount DESC") suspend fun allTimeItemTotals():List<PartyItemReport>
    @Query("SELECT billNo, COALESCE((SELECT name FROM suppliers WHERE suppliers.id=purchases.supplierId),'Cash Purchase') as supplierName, total, paid, createdAt, status FROM purchases WHERE createdAt BETWEEN :start AND :end ORDER BY createdAt ASC") suspend fun purchasesBetween(start:Long,end:Long):List<DayBookPurchase>

    // ================= Party Transaction — billed item edit/delete support =================
    // Mirrors the SaleDao additions above, for purchase_items/purchases.
    @Update suspend fun updatePurchase(p:Purchase)
    @Query("SELECT * FROM purchase_items WHERE id=:id LIMIT 1") suspend fun findItem(id:Long):PurchaseItem?
    @Update suspend fun updateItemRow(item:PurchaseItem)
    @Query("DELETE FROM purchase_items WHERE id=:id") suspend fun deleteItemById(id:Long)
    @Query("SELECT COUNT(*) FROM purchase_items WHERE billNo=:billNo") suspend fun itemCountForBill(billNo:String):Int

    // ADDED (multi-device two-way sync): same reasoning as SaleDao.upsertSale above —
    // billNo is the natural unique key, so REPLACE just means "update with server copy".
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun upsertPurchase(p:Purchase)
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun upsertItems(items:List<PurchaseItem>)

    // NEW ("10/10 Purchase screen" item #2): exact duplicate check on the SUPPLIER's
    // own invoice number (blank supplierInvoiceNo never matches, so bills with no
    // invoice number entered fall through to the existing same-party+same-amount
    // heuristic in PurchaseActivity instead). excludeBillNo lets re-saving an edit of
    // itself not trigger a false alarm — pass "" when not editing.
    @Query("SELECT pu.* FROM purchases pu LEFT JOIN suppliers s ON pu.supplierId=s.id WHERE pu.supplierInvoiceNo=:invoiceNo AND pu.supplierInvoiceNo!='' AND pu.billNo!=:excludeBillNo AND s.name=:party COLLATE NOCASE LIMIT 1")
    suspend fun findDuplicateBySupplierInvoice(party:String, invoiceNo:String, excludeBillNo:String):Purchase?

    // NEW (Overdue for suppliers): same shape as SaleDao.setDueDate — lets a due
    // date be set/changed for a purchase without touching anything else on it.
    @Query("UPDATE purchases SET dueDate=:dueDate, updatedAt=:now, dirty=1 WHERE billNo=:billNo")
    suspend fun setDueDate(billNo:String, dueDate:Long, now:Long=System.currentTimeMillis())

    // NEW (Overdue for suppliers): mirrors SaleDao.dueSales() — every active purchase
    // still owing the supplier money, whether or not a due date has been set yet.
    @Query("""
        SELECT pu.billNo as billNo, pu.supplierId as supplierId,
            COALESCE(s.name,'Cash Purchase') as supplierName, COALESCE(s.phone,'') as supplierPhone,
            pu.total as total, pu.paid as paid, pu.dueDate as dueDate, pu.createdAt as createdAt
        FROM purchases pu LEFT JOIN suppliers s ON s.id=pu.supplierId
        WHERE pu.status='active' AND (pu.total - pu.paid) > 0.009
        ORDER BY (pu.dueDate = 0) ASC, pu.dueDate ASC, pu.createdAt ASC
    """)
    suspend fun duePurchases():List<DuePurchase>
}

@Dao interface ReturnDao {
    @Insert suspend fun insert(r:ReturnLine):Long
    @Update suspend fun update(r:ReturnLine)
    @Query("SELECT COALESCE(SUM(amount),0) FROM returns WHERE type=:type") suspend fun totalByType(type:String):Double
    @Query("SELECT COALESCE(SUM(amount),0) FROM returns WHERE type=:type AND createdAt BETWEEN :start AND :end") suspend fun totalByTypeBetween(type:String,start:Long,end:Long):Double
    @Query("SELECT * FROM returns WHERE reference=:reference") suspend fun forReference(reference:String):List<ReturnLine>
    // NEW (Returns sync): resyncAllLocalData() snapshot + pull-apply idempotency lookup,
    // same pattern as every other synced ledger entity (Expense/CashTransaction/etc).
    @Query("SELECT * FROM returns") suspend fun allList():List<ReturnLine>
    @Query("SELECT * FROM returns WHERE serverId=:serverId LIMIT 1") suspend fun findByServerId(serverId:String):ReturnLine?
}

@Dao interface UserDao {
    @Insert(onConflict=OnConflictStrategy.REPLACE) suspend fun upsert(u:User)
    @Query("SELECT * FROM users WHERE username=:u AND active=1 LIMIT 1") suspend fun find(u:String):User?
    @Query("SELECT * FROM users WHERE username=:u LIMIT 1") suspend fun findByUsername(u:String):User?
    @Query("SELECT * FROM users WHERE phone=:phone AND active=1 LIMIT 1") suspend fun findByPhone(phone:String):User?
    @Query("SELECT * FROM users ORDER BY username") fun all():Flow<List<User>>
    // ADDED (force full resync): one-shot suspend list, for the resync helper.
    @Query("SELECT * FROM users ORDER BY username") suspend fun allList():List<User>
    @Query("DELETE FROM users WHERE username=:u") suspend fun delete(u:String)
    // FIX (OTP first-link deadlock): a phone that Firebase already verified but that
    // isn't linked to any user has no in-app way to get linked, since Manage Users
    // itself requires being logged in first. When there's exactly one active user
    // (the common single-owner-store case), auto-link that verified phone to them
    // instead of dead-ending — see LoginActivity.verifyAndLogin().
    @Query("SELECT COUNT(*) FROM users WHERE active=1") suspend fun activeCount(): Int
    @Query("SELECT * FROM users WHERE active=1 LIMIT 1") suspend fun soleActiveUserOrNull(): User?
}

@Dao interface AuditDao {
    @Insert suspend fun insert(a:Audit)
    // ADDED (sync recoverability): lets Settings > Sync History show what happened,
    // especially conflicts — see SyncApi.kt's push()/applyServerChanges().
    @Query("SELECT * FROM audit ORDER BY createdAt DESC LIMIT 300") suspend fun recent(): List<Audit>
    @Query("SELECT * FROM audit WHERE action IN ('sync_conflict','sync_push_failed') ORDER BY createdAt DESC LIMIT 300") suspend fun syncIssues(): List<Audit>
    // ADDED: lets Settings > Sync History be cleared one-time from the UI — this
    // table is purely a local diagnostic log (never pushed/pulled via sync_queue),
    // so wiping it has no effect on the actual synced data on any device.
    @Query("DELETE FROM audit") suspend fun clearAll()
}

@Dao interface CashTransactionDao {
    @Insert suspend fun insert(t:CashTransaction): Long
    @Query("SELECT * FROM cash_transactions ORDER BY createdAt DESC") fun all():Flow<List<CashTransaction>>
    // ADDED (force full resync): one-shot suspend list, for the resync helper.
    @Query("SELECT * FROM cash_transactions ORDER BY createdAt DESC") suspend fun allList():List<CashTransaction>
    @Query("SELECT COALESCE(SUM(amount),0) FROM cash_transactions WHERE type=:type AND method=:method AND createdAt BETWEEN :start AND :end") suspend fun totalBetween(type:String,method:String,start:Long,end:Long):Double
    // ADDED (Balance Sheet): all-time IN/OUT total per method, for the Cash/Bank asset lines.
    @Query("SELECT COALESCE(SUM(amount),0) FROM cash_transactions WHERE type=:type AND method=:method") suspend fun totalAll(type:String,method:String):Double
    @Query("DELETE FROM cash_transactions WHERE reference=:ref") suspend fun deleteByReference(ref:String)
    // FIX (duplicate-payment-on-sync bug): see PaymentDao.allByReference() above —
    // same reasoning, for the matching cash-drawer entry.
    @Query("SELECT * FROM cash_transactions WHERE reference=:ref") suspend fun allByReference(ref:String):List<CashTransaction>
    // ADDED (cash record consistency fix): lets a single billed-item edit/delete
    // (PartyTransactionActivity) find and adjust the one cash transaction tied to a
    // bill instead of only being able to delete or total them.
    @Query("SELECT * FROM cash_transactions WHERE reference=:ref LIMIT 1") suspend fun findByReference(ref:String):CashTransaction?
    @Query("SELECT * FROM cash_transactions WHERE createdAt BETWEEN :start AND :end ORDER BY createdAt ASC") suspend fun between(start:Long,end:Long):List<CashTransaction>
    // ADDED (multi-device two-way sync): same reasoning as ExpenseDao above.
    @Update suspend fun update(t:CashTransaction)
    @Query("SELECT * FROM cash_transactions WHERE serverId=:serverId LIMIT 1") suspend fun findByServerId(serverId:String):CashTransaction?
    @Query("DELETE FROM cash_transactions WHERE serverId=:serverId") suspend fun deleteByServerId(serverId:String)
}

@Dao interface CashRegisterDao {
    @Insert(onConflict=OnConflictStrategy.REPLACE) suspend fun upsert(r:CashRegister)
    // FIX (audit — OPEN REGISTER race): CashRegisterActivity used to do find() then upsert()
    // as two separate steps, leaving a window where a double-tap (or, in principle, two
    // near-simultaneous OPEN attempts) could both pass the find()==null check before either
    // had inserted, and the second upsert() (REPLACE) would silently wipe the first one's
    // opening balance. onConflict=IGNORE makes the insert itself the atomic check: SQLite
    // either inserts the new row or, if `date` (the PK) already exists, skips it entirely and
    // returns -1 — one statement, no gap for a second caller to land in between. This is
    // local-device atomicity only. Two different *devices* opening the register offline
    // before either has synced is now handled too — CashRegisterActivity's OPEN button
    // enqueues via SyncQueueHelper.enqueueCashRegisterCreate() ("create_if_absent"), which
    // SyncApi.push() applies as a genuine server-side create-only transaction instead of the
    // ordinary updatedAt-newest-wins upsert used for edits/closes — so a losing device's
    // create is dropped rather than clobbering the winner's opening balance.
    @Insert(onConflict=OnConflictStrategy.IGNORE) suspend fun insertIfAbsent(r:CashRegister):Long
    @Query("SELECT * FROM cash_register WHERE date=:date LIMIT 1") suspend fun find(date:String):CashRegister?
    // ADDED (audit): most recent CLOSED register before `date` (keys are yyyy-MM-dd, so string
    // order == date order). Used to carry the opening balance forward even when the shop
    // skipped a day (holiday / forgot to open) instead of only looking at "yesterday".
    @Query("SELECT * FROM cash_register WHERE date < :date AND closed = 1 ORDER BY date DESC LIMIT 1") suspend fun lastClosedBefore(date:String):CashRegister?
    @Query("SELECT * FROM cash_register ORDER BY date DESC") fun all():Flow<List<CashRegister>>
    // NEW (Cash Register sync): one-shot snapshot for SyncQueueHelper.resyncAllLocalData(),
    // same pattern as UnitDao.allOnce()/CategoryDao.allOnce() — a plain suspend list instead
    // of a Flow, since resync just needs to walk the table once.
    @Query("SELECT * FROM cash_register ORDER BY date DESC") suspend fun allOnce():List<CashRegister>
}

@Dao interface AppSettingDao {
    @Insert(onConflict=OnConflictStrategy.REPLACE) suspend fun set(s:AppSetting)
    @Query("SELECT * FROM app_settings WHERE key=:key LIMIT 1") suspend fun get(key:String):AppSetting?
    @Query("SELECT * FROM app_settings") fun all():Flow<List<AppSetting>>
}

@Dao interface SyncQueueDao {
    @Insert suspend fun enqueue(e: SyncQueueEntry): Long
    // FIX (risk-free POS): previously this retried EVERY unsynced entry forever, with
    // no limit — a single permanently-broken entry (e.g. a malformed record from an old
    // bug) would retry on every single sync cycle forever, wasting time/battery and
    // spamming Sync History with the same failure repeatedly. Now stops auto-retrying
    // an entry once it's failed 10 times in a row — it stays in the table (nothing is
    // lost) but needs a manual "Retry Now" (see Settings > Sync History) to try again.
    @Query("SELECT * FROM sync_queue WHERE syncedAt IS NULL AND retryCount < 10 ORDER BY createdAt ASC LIMIT :limit")
    suspend fun pending(limit: Int = 50): List<SyncQueueEntry>
    @Query("SELECT * FROM sync_queue WHERE syncedAt IS NULL AND retryCount < 10 AND entityType=:entityType AND entityId=:entityId AND operation=:operation ORDER BY createdAt ASC")
    suspend fun pendingForEntity(entityType:String, entityId:String, operation:String):List<SyncQueueEntry>
    // FIX (leaking payable): pendingForEntity() above excludes rows once they've
    // failed 10 times, which is correct for the auto-retry loop (stop hammering a
    // permanently-broken push) but was ALSO being used to decide how much unsent
    // balance/stock delta to re-add on top of a pulled server value. That meant a
    // supplier/customer balance change that failed to push 10 times didn't just stop
    // retrying — the next pull for that same party silently erased its effect from
    // the local balance too, even though the underlying purchase/payment row was
    // still sitting right there in the app. This query keeps counting every unsynced
    // row (any retryCount) so a permanently-stuck entry keeps showing up locally and
    // in Settings > Sync History for the user to "Retry Now" instead of quietly
    // vanishing from the total.
    @Query("SELECT * FROM sync_queue WHERE syncedAt IS NULL AND entityType=:entityType AND entityId=:entityId AND operation=:operation ORDER BY createdAt ASC")
    suspend fun pendingForEntityAnyRetry(entityType:String, entityId:String, operation:String):List<SyncQueueEntry>
    // FIX (purchase/sale name reverts after sync — "M Deen & brother's" back to "Cash
    // Purchase"): whole-row pulls for purchases/sales (see SyncApi.applyServerChanges)
    // used to overwrite the local row unconditionally, with no equivalent of the
    // pendingDelta() guard already used for stock/balance deltas above. If a local
    // edit (e.g. attaching a supplier to a purchase) is still sitting unpushed in the
    // queue when a pull runs — slow network, large backlog, a transient push failure —
    // the pull would silently restore the old server copy over it, wiping the just-set
    // supplierId back to null even though the supplier's balance (synced separately as
    // a delta) stayed correct. Any operation, any retryCount — a stuck-but-unsynced
    // local edit should still block being overwritten, same reasoning as
    // pendingForEntityAnyRetry above.
    @Query("SELECT COUNT(*) FROM sync_queue WHERE syncedAt IS NULL AND entityType=:entityType AND entityId=:entityId")
    suspend fun pendingCountForEntity(entityType:String, entityId:String):Int
    @Query("UPDATE sync_queue SET syncedAt=:ts WHERE id=:id")
    suspend fun markSynced(id: Long, ts: Long = System.currentTimeMillis())
    @Query("UPDATE sync_queue SET retryCount=retryCount+1, lastError=:err WHERE id=:id")
    suspend fun markFailed(id: Long, err: String)
    @Query("DELETE FROM sync_queue WHERE syncedAt IS NOT NULL AND syncedAt < :before")
    suspend fun pruneSynced(before: Long)
    @Query("SELECT COUNT(*) FROM sync_queue WHERE syncedAt IS NULL")
    fun pendingCountFlow(): Flow<Int>
    // NEW (P1 security — item #4, Branch Change + Pending Queue Protection): a
    // one-shot version of pendingCountFlow() for a plain suspend check (e.g. before
    // letting the Branch Code be changed in Settings > Cloud Sync Setup) — see
    // SettingsSync.kt's openCloudSyncSetupDialog().
    @Query("SELECT COUNT(*) FROM sync_queue WHERE syncedAt IS NULL")
    suspend fun pendingCount(): Int
    // ADDED (risk-free POS): entries that gave up after 10 failed attempts — surfaced
    // in Settings > Sync History so they don't just vanish from view.
    @Query("SELECT * FROM sync_queue WHERE syncedAt IS NULL AND retryCount >= 10 ORDER BY createdAt ASC")
    suspend fun stuck(): List<SyncQueueEntry>
    // ADDED: resets a stuck entry's retry count so it's picked up by pending() again —
    // used by the "Retry Now" action.
    @Query("UPDATE sync_queue SET retryCount=0, lastError=NULL WHERE id=:id")
    suspend fun resetRetry(id: Long)
    @Query("UPDATE sync_queue SET retryCount=0, lastError=NULL WHERE syncedAt IS NULL AND retryCount >= 10")
    suspend fun resetAllStuck()
}

val MIGRATION_13_14 = object : Migration(13, 14) {
    override fun migrate(database: SupportSQLiteDatabase) {
        database.execSQL("ALTER TABLE purchase_items ADD COLUMN unit TEXT NOT NULL DEFAULT ''")
    }
}
val MIGRATION_14_15 = object : Migration(14, 15) {
    override fun migrate(database: SupportSQLiteDatabase) {
        database.execSQL("ALTER TABLE customers ADD COLUMN openingBalance REAL NOT NULL DEFAULT 0.0")
        database.execSQL("ALTER TABLE suppliers ADD COLUMN openingBalance REAL NOT NULL DEFAULT 0.0")
    }
}
val MIGRATION_15_16 = object : Migration(15, 16) {
    override fun migrate(database: SupportSQLiteDatabase) {
        database.execSQL("ALTER TABLE sales ADD COLUMN status TEXT NOT NULL DEFAULT 'active'")
        database.execSQL("ALTER TABLE purchases ADD COLUMN status TEXT NOT NULL DEFAULT 'active'")
    }
}
val MIGRATION_16_17 = object : Migration(16, 17) {
    override fun migrate(database: SupportSQLiteDatabase) {
        database.execSQL("ALTER TABLE products ADD COLUMN tertiaryUnit TEXT NOT NULL DEFAULT ''")
        database.execSQL("ALTER TABLE products ADD COLUMN tertiaryUnitQty REAL NOT NULL DEFAULT 0.0")
    }
}
val MIGRATION_17_18 = object : Migration(17, 18) {
    override fun migrate(database: SupportSQLiteDatabase) {
        database.execSQL("CREATE TABLE purchase_items_new (id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, billNo TEXT NOT NULL, barcode TEXT NOT NULL, qty REAL NOT NULL, unitCost REAL NOT NULL, amount REAL NOT NULL, unit TEXT NOT NULL DEFAULT '')")
        database.execSQL("INSERT INTO purchase_items_new (id, billNo, barcode, qty, unitCost, amount, unit) SELECT id, billNo, barcode, qty, unitCost, amount, unit FROM purchase_items")
        database.execSQL("DROP TABLE purchase_items")
        database.execSQL("ALTER TABLE purchase_items_new RENAME TO purchase_items")
        database.execSQL("CREATE TABLE returns_new (id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, reference TEXT NOT NULL, type TEXT NOT NULL, barcode TEXT NOT NULL, qty REAL NOT NULL, amount REAL NOT NULL, createdAt INTEGER NOT NULL)")
        database.execSQL("INSERT INTO returns_new (id, reference, type, barcode, qty, amount, createdAt) SELECT id, reference, type, barcode, qty, amount, createdAt FROM returns")
        database.execSQL("DROP TABLE returns")
        database.execSQL("ALTER TABLE returns_new RENAME TO returns")
    }
}
val MIGRATION_18_19 = object : Migration(18, 19) {
    override fun migrate(database: SupportSQLiteDatabase) {
        val factorExpr = "(CASE WHEN secondaryUnit != '' AND secondaryUnitQty > 0 THEN " +
            "secondaryUnitQty * (CASE WHEN tertiaryUnit != '' AND tertiaryUnitQty > 0 THEN tertiaryUnitQty ELSE 1 END) " +
            "ELSE 1 END)"
        database.execSQL("UPDATE products SET stock = CAST(ROUND(stock * $factorExpr) AS INTEGER)")
        database.execSQL("UPDATE products SET openingStock = CAST(ROUND(openingStock * $factorExpr) AS INTEGER)")
    }
}
val MIGRATION_19_20 = object : Migration(19, 20) {
    override fun migrate(database: SupportSQLiteDatabase) {
        database.execSQL("ALTER TABLE sale_items ADD COLUMN unit TEXT NOT NULL DEFAULT ''")
    }
}
val MIGRATION_20_21 = object : Migration(20, 21) {
    override fun migrate(database: SupportSQLiteDatabase) {
        database.execSQL("""
            CREATE TABLE sync_queue (
                id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                entityType TEXT NOT NULL,
                entityId TEXT NOT NULL,
                operation TEXT NOT NULL,
                payloadJson TEXT NOT NULL,
                createdAt INTEGER NOT NULL,
                syncedAt INTEGER,
                retryCount INTEGER NOT NULL DEFAULT 0,
                lastError TEXT
            )
        """.trimIndent())

        for (table in listOf("customers", "suppliers", "payments", "expenses", "cash_transactions")) {
            database.execSQL("ALTER TABLE $table ADD COLUMN serverId TEXT")
            database.execSQL("ALTER TABLE $table ADD COLUMN updatedAt INTEGER NOT NULL DEFAULT 0")
            database.execSQL("ALTER TABLE $table ADD COLUMN dirty INTEGER NOT NULL DEFAULT 1")
        }
        for (table in listOf("sales", "purchases", "products")) {
            database.execSQL("ALTER TABLE $table ADD COLUMN updatedAt INTEGER NOT NULL DEFAULT 0")
            database.execSQL("ALTER TABLE $table ADD COLUMN dirty INTEGER NOT NULL DEFAULT 1")
        }
    }
}

val MIGRATION_21_22 = object : Migration(21, 22) {
    override fun migrate(database: SupportSQLiteDatabase) {
        val factorExpr = "(CASE WHEN secondaryUnit != '' AND secondaryUnitQty > 0 THEN " +
            "secondaryUnitQty * (CASE WHEN tertiaryUnit != '' AND tertiaryUnitQty > 0 THEN tertiaryUnitQty ELSE 1 END) " +
            "ELSE 1 END)"
        database.execSQL("UPDATE products SET reorderLevel = CAST(ROUND(reorderLevel * $factorExpr) AS INTEGER)")
    }
}

val MIGRATION_22_23 = object : Migration(22, 23) {
    override fun migrate(database: SupportSQLiteDatabase) {
        database.execSQL("ALTER TABLE users ADD COLUMN phone TEXT NOT NULL DEFAULT ''")
    }
}

// FIX (fractional qty consistency): sale_items.qty was INTEGER, unlike purchase_items.qty
// and returns.qty which are already REAL (see MIGRATION_17_18). SQLite can't ALTER COLUMN
// a type directly, so this recreates the table with qty REAL, same table-recreate pattern
// as MIGRATION_17_18 used for purchase_items/returns. Existing rows keep their (already
// rounded) values — this only stops NEW sales from losing their fractional qty.
val MIGRATION_23_24 = object : Migration(23, 24) {
    override fun migrate(database: SupportSQLiteDatabase) {
        database.execSQL("CREATE TABLE sale_items_new (id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, invoice TEXT NOT NULL, barcode TEXT NOT NULL, product TEXT NOT NULL, qty REAL NOT NULL, unit TEXT NOT NULL DEFAULT '', unitPrice REAL NOT NULL, cost REAL NOT NULL, amount REAL NOT NULL)")
        database.execSQL("INSERT INTO sale_items_new (id, invoice, barcode, product, qty, unit, unitPrice, cost, amount) SELECT id, invoice, barcode, product, qty, unit, unitPrice, cost, amount FROM sale_items")
        database.execSQL("DROP TABLE sale_items")
        database.execSQL("ALTER TABLE sale_items_new RENAME TO sale_items")
    }
}

// FIX (fraction control): products.stock/reorderLevel/openingStock were INTEGER,
// so any product whose smallest unit is Gram/ml (Sugar, Daal, etc.) lost its
// fractional part on every purchase/sale/return — e.g. 2.5 Kg silently became
// 2 or 3 Kg. SQLite can't ALTER COLUMN type, so this recreates the table with
// those three columns as REAL, same table-recreate pattern as MIGRATION_17_18/
// MIGRATION_23_24. Existing rows keep their (already rounded) values — this
// only stops NEW purchases/sales from losing precision going forward.
val MIGRATION_24_25 = object : Migration(24, 25) {
    override fun migrate(database: SupportSQLiteDatabase) {
        database.execSQL("""
            CREATE TABLE products_new (
                barcode TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                category TEXT NOT NULL DEFAULT '',
                cost REAL NOT NULL DEFAULT 0.0,
                salePrice REAL NOT NULL DEFAULT 0.0,
                stock REAL NOT NULL DEFAULT 0.0,
                reorderLevel REAL NOT NULL DEFAULT 0.0,
                expiry TEXT NOT NULL DEFAULT '',
                unit TEXT NOT NULL DEFAULT 'pcs',
                unitSize INTEGER NOT NULL DEFAULT 1,
                unitNote TEXT NOT NULL DEFAULT '',
                secondaryUnit TEXT NOT NULL DEFAULT '',
                secondaryUnitQty REAL NOT NULL DEFAULT 0.0,
                wholesalePrice REAL NOT NULL DEFAULT 0.0,
                openingStock REAL NOT NULL DEFAULT 0.0,
                tertiaryUnit TEXT NOT NULL DEFAULT '',
                tertiaryUnitQty REAL NOT NULL DEFAULT 0.0,
                updatedAt INTEGER NOT NULL DEFAULT 0,
                dirty INTEGER NOT NULL DEFAULT 1
            )
        """.trimIndent())
        database.execSQL("""
            INSERT INTO products_new SELECT
                barcode, name, category, cost, salePrice, stock, reorderLevel, expiry,
                unit, unitSize, unitNote, secondaryUnit, secondaryUnitQty, wholesalePrice,
                openingStock, tertiaryUnit, tertiaryUnitQty, updatedAt, dirty
            FROM products
        """.trimIndent())
        database.execSQL("DROP TABLE products")
        database.execSQL("ALTER TABLE products_new RENAME TO products")
    }
}

// FIX (historical unit conversion bug): sale_items/purchase_items now carry the
// transaction-time conversion factor (smallest units per one `unit`) so a later
// edit to the product's unit configuration can never corrupt an old, already-saved
// transaction's stock reversal. Simple ADD COLUMN (unlike MIGRATION_23_24/24_25's
// table-recreate) since we're not changing an existing column's type — existing
// rows get 0.0, meaning "not captured", and smallestQty() (Database.kt) falls back
// to the old current-product-lookup behaviour for exactly those rows.
val MIGRATION_25_26 = object : Migration(25, 26) {
    override fun migrate(database: SupportSQLiteDatabase) {
        database.execSQL("ALTER TABLE sale_items ADD COLUMN conversionFactor REAL NOT NULL DEFAULT 0.0")
        database.execSQL("ALTER TABLE purchase_items ADD COLUMN conversionFactor REAL NOT NULL DEFAULT 0.0")
    }
}

// ADDED (Inventory Accounting upgrade): new append-only stock_movements table —
// see StockMovement's doc comment above. Plain CREATE TABLE, no data migration
// needed since this is a brand-new ledger with nothing to backfill.
val MIGRATION_26_27 = object : Migration(26, 27) {
    override fun migrate(database: SupportSQLiteDatabase) {
        database.execSQL("""
            CREATE TABLE IF NOT EXISTS stock_movements (
                id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                barcode TEXT NOT NULL,
                type TEXT NOT NULL,
                qty REAL NOT NULL,
                unit TEXT NOT NULL DEFAULT '',
                cost REAL NOT NULL DEFAULT 0.0,
                reference TEXT NOT NULL DEFAULT '',
                note TEXT NOT NULL DEFAULT '',
                createdAt INTEGER NOT NULL
            )
        """.trimIndent())
        database.execSQL("CREATE INDEX IF NOT EXISTS index_stock_movements_barcode ON stock_movements(barcode)")
    }
}

// FIX (white-screen crash — Room schema validation mismatch): MIGRATION_26_27's
// "cost REAL NOT NULL DEFAULT 0.0" gets normalized by SQLite itself to "DEFAULT 0" the
// moment the table is created — PRAGMA table_info always echoes numeric-literal defaults
// in their canonical (no trailing ".0") form. Room compares its *expected* schema (built
// from the @ColumnInfo(defaultValue=...) string, taken completely literally) against that
// canonical on-disk form on every app open, so "0.0" vs "0" was a permanent mismatch that
// re-threw the same IllegalStateException on every single launch, regardless of how many
// times a migration ran — it's not something a future migration re-running could ever
// close on its own. Any device that already created the table via MIGRATION_26_27 is stuck
// with that mismatch forever (bumping the entity annotation alone does nothing for a table
// that already exists), so this drops and rebuilds stock_movements with the exact defaults
// Room now expects ("0" for cost, unchanged '' for the text columns), copying over any
// rows a user already logged.
val MIGRATION_27_28 = object : Migration(27, 28) {
    override fun migrate(database: SupportSQLiteDatabase) {
        database.execSQL("ALTER TABLE stock_movements RENAME TO stock_movements_old_27")
        database.execSQL("""
            CREATE TABLE IF NOT EXISTS stock_movements (
                id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                barcode TEXT NOT NULL,
                type TEXT NOT NULL,
                qty REAL NOT NULL,
                unit TEXT NOT NULL DEFAULT '',
                cost REAL NOT NULL DEFAULT 0,
                reference TEXT NOT NULL DEFAULT '',
                note TEXT NOT NULL DEFAULT '',
                createdAt INTEGER NOT NULL
            )
        """.trimIndent())
        database.execSQL("""
            INSERT INTO stock_movements (id, barcode, type, qty, unit, cost, reference, note, createdAt)
            SELECT id, barcode, type, qty, unit, cost, reference, note, createdAt FROM stock_movements_old_27
        """.trimIndent())
        database.execSQL("DROP TABLE stock_movements_old_27")
        database.execSQL("CREATE INDEX IF NOT EXISTS index_stock_movements_barcode ON stock_movements(barcode)")
    }
}

// NEW (Zakat tracker): fresh tables, no data migration needed from any existing table.
val MIGRATION_28_29 = object : Migration(28, 29) {
    override fun migrate(database: SupportSQLiteDatabase) {
        database.execSQL("""
            CREATE TABLE IF NOT EXISTS zakat_years (
                id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                startDate INTEGER NOT NULL,
                endDate INTEGER NOT NULL,
                assetsSnapshot REAL NOT NULL,
                totalPayable REAL NOT NULL,
                createdAt INTEGER NOT NULL,
                serverId TEXT,
                updatedAt INTEGER NOT NULL DEFAULT 0,
                dirty INTEGER NOT NULL DEFAULT 1
            )
        """.trimIndent())
        database.execSQL("""
            CREATE TABLE IF NOT EXISTS zakat_payments (
                id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                zakatYearId INTEGER NOT NULL,
                amount REAL NOT NULL,
                method TEXT NOT NULL DEFAULT '',
                note TEXT NOT NULL DEFAULT '',
                createdAt INTEGER NOT NULL,
                serverId TEXT,
                updatedAt INTEGER NOT NULL DEFAULT 0,
                dirty INTEGER NOT NULL DEFAULT 1
            )
        """.trimIndent())
    }
}

// NEW (Due Date Reminders): Sale.dueDate, a plain nullable-by-default ADD COLUMN —
// same simple pattern as MIGRATION_25_26's returnReversed, no table recreate needed.
val MIGRATION_29_30 = object : Migration(29, 30) {
    override fun migrate(database: SupportSQLiteDatabase) {
        database.execSQL("ALTER TABLE sales ADD COLUMN dueDate INTEGER NOT NULL DEFAULT 0")
    }
}

// NEW (Bottle Shell Ledger): shell_customers/shell_transactions track what customers
// owe the shop; shop_empty_shell_log tracks the shop's own empty-shell count. All three
// are brand-new tables, same CREATE-TABLE-IF-NOT-EXISTS pattern as MIGRATION_28_29.
val MIGRATION_30_31 = object : Migration(30, 31) {
    override fun migrate(database: SupportSQLiteDatabase) {
        database.execSQL("""
            CREATE TABLE IF NOT EXISTS shell_customers (
                id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                name TEXT NOT NULL,
                phone TEXT NOT NULL DEFAULT '',
                shellsOwed INTEGER NOT NULL DEFAULT 0,
                createdAt INTEGER NOT NULL,
                serverId TEXT,
                updatedAt INTEGER NOT NULL DEFAULT 0,
                dirty INTEGER NOT NULL DEFAULT 1
            )
        """.trimIndent())
        database.execSQL("""
            CREATE TABLE IF NOT EXISTS shell_transactions (
                id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                customerId INTEGER NOT NULL,
                type TEXT NOT NULL,
                qty INTEGER NOT NULL,
                note TEXT NOT NULL DEFAULT '',
                createdAt INTEGER NOT NULL,
                serverId TEXT,
                updatedAt INTEGER NOT NULL DEFAULT 0,
                dirty INTEGER NOT NULL DEFAULT 1
            )
        """.trimIndent())
        database.execSQL("CREATE INDEX IF NOT EXISTS index_shell_transactions_customerId ON shell_transactions(customerId)")
        database.execSQL("""
            CREATE TABLE IF NOT EXISTS shop_empty_shell_log (
                id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                delta INTEGER NOT NULL,
                reason TEXT NOT NULL DEFAULT '',
                note TEXT NOT NULL DEFAULT '',
                createdAt INTEGER NOT NULL
            )
        """.trimIndent())
    }
}

val MIGRATION_31_32 = object : Migration(31, 32) {
    // Improvement Pack P2 — safe unique sale identifiers: add a permanent
    // UUID column to sales/sale_items/purchases/purchase_items, independent of
    // the human-readable invoice/billNo. Purely additive (default '' via
    // ALTER TABLE, matching every other backward-compatible migration in this
    // file) then backfilled row-by-row below so pre-existing records get a
    // real UUID too instead of staying blank forever.
    override fun migrate(database: SupportSQLiteDatabase) {
        database.execSQL("ALTER TABLE sales ADD COLUMN saleUid TEXT NOT NULL DEFAULT ''")
        database.execSQL("ALTER TABLE sale_items ADD COLUMN lineUid TEXT NOT NULL DEFAULT ''")
        database.execSQL("ALTER TABLE purchases ADD COLUMN purchaseUid TEXT NOT NULL DEFAULT ''")
        database.execSQL("ALTER TABLE purchase_items ADD COLUMN lineUid TEXT NOT NULL DEFAULT ''")

        backfillUidText(database, "sales", "invoice", "saleUid")
        backfillUidLong(database, "sale_items", "id", "lineUid")
        backfillUidText(database, "purchases", "billNo", "purchaseUid")
        backfillUidLong(database, "purchase_items", "id", "lineUid")
    }

    // Two variants (TEXT key vs INTEGER key) so the bound WHERE parameter's type
    // always matches the key column's real affinity, instead of relying on
    // SQLite's text/integer comparison coercion to do the right thing.
    private fun backfillUidText(database: SupportSQLiteDatabase, table: String, keyColumn: String, uidColumn: String) {
        val cursor = database.query("SELECT $keyColumn FROM $table WHERE $uidColumn='' OR $uidColumn IS NULL")
        cursor.use {
            while (it.moveToNext()) {
                val key = it.getString(0)
                database.execSQL("UPDATE $table SET $uidColumn=? WHERE $keyColumn=?", arrayOf<Any>(UUID.randomUUID().toString(), key))
            }
        }
    }

    private fun backfillUidLong(database: SupportSQLiteDatabase, table: String, keyColumn: String, uidColumn: String) {
        val cursor = database.query("SELECT $keyColumn FROM $table WHERE $uidColumn='' OR $uidColumn IS NULL")
        cursor.use {
            while (it.moveToNext()) {
                val key = it.getLong(0)
                database.execSQL("UPDATE $table SET $uidColumn=? WHERE $keyColumn=?", arrayOf<Any>(UUID.randomUUID().toString(), key))
            }
        }
    }
}

// NEW (safer sync identity — 2nd AI review, "UUID unique indexes"): saleUid/lineUid/
// purchaseUid/lineUid were added in MIGRATION_31_32 as plain columns with no uniqueness
// enforced at the database level — a bug anywhere in the backfill/generation logic
// could silently produce a duplicate UUID and nothing would catch it. By the time this
// runs, MIGRATION_31_32 has already backfilled every row with a real (non-empty)
// randomUUID(), so creating these as unique indexes now is safe and just adds a hard
// guarantee going forward.
//
// FIX (crash-loop on CREATE UNIQUE INDEX — real-world crash report): the assumption
// above ("every row already has a unique UUID") turned out not to hold for every
// device — e.g. a multi-device sync pull/edit race can leave two local sale_items (or
// purchase_items) rows sharing one lineUid on a device that's still on schema 32,
// where nothing enforced uniqueness yet. CREATE UNIQUE INDEX then throws
// SQLiteConstraintException, the migration never completes, and the app crashes on
// every single launch from then on with no way to recover short of a reinstall.
// Deduping each *Uid column down to one winner per duplicate value, right before its
// index is created, makes this migration self-healing regardless of how a duplicate
// got there — the loser rows keep all their real data and just get a fresh random UUID
// instead of losing anything.
val MIGRATION_32_33 = object : Migration(32, 33) {
    override fun migrate(database: SupportSQLiteDatabase) {
        dedupeUidColumn(database, "sales", "rowid", "saleUid")
        dedupeUidColumn(database, "sale_items", "id", "lineUid")
        dedupeUidColumn(database, "purchases", "rowid", "purchaseUid")
        dedupeUidColumn(database, "purchase_items", "id", "lineUid")

        database.execSQL("CREATE UNIQUE INDEX IF NOT EXISTS index_sales_saleUid ON sales(saleUid)")
        database.execSQL("CREATE UNIQUE INDEX IF NOT EXISTS index_sale_items_lineUid ON sale_items(lineUid)")
        database.execSQL("CREATE UNIQUE INDEX IF NOT EXISTS index_purchases_purchaseUid ON purchases(purchaseUid)")
        database.execSQL("CREATE UNIQUE INDEX IF NOT EXISTS index_purchase_items_lineUid ON purchase_items(lineUid)")
    }

    // For every uidColumn value shared by more than one row, keeps it on the
    // lowest-rowid row (arbitrary but deterministic) and assigns every other row a
    // brand-new random UUID, so a UNIQUE index can then be created without conflict.
    // keyColumn/rowid identifies rows individually; `purchases` has no autoGenerate id
    // so its own implicit rowid is used instead.
    private fun dedupeUidColumn(database: SupportSQLiteDatabase, table: String, keyColumn: String, uidColumn: String) {
        val cursor = database.query(
            "SELECT $keyColumn FROM $table WHERE $uidColumn IN (" +
                "SELECT $uidColumn FROM $table GROUP BY $uidColumn HAVING COUNT(*) > 1" +
            ") AND $keyColumn NOT IN (" +
                "SELECT MIN($keyColumn) FROM $table GROUP BY $uidColumn HAVING COUNT(*) > 1" +
            ")"
        )
        cursor.use {
            while (it.moveToNext()) {
                val key = it.getLong(0)
                database.execSQL(
                    "UPDATE $table SET $uidColumn=? WHERE $keyColumn=?",
                    arrayOf<Any>(UUID.randomUUID().toString(), key)
                )
            }
        }
    }
}

// NEW ("10/10 Purchase screen" item #2): supplierInvoiceNo added to Purchase as a
// plain column with a default — same low-risk shape as MIGRATION_31_32's
// purchaseUid/lineUid columns, no backfill needed since a blank value is exactly the
// correct "not entered" state for every pre-existing row.
val MIGRATION_33_34 = object : Migration(33, 34) {
    override fun migrate(database: SupportSQLiteDatabase) {
        database.execSQL("ALTER TABLE purchases ADD COLUMN supplierInvoiceNo TEXT NOT NULL DEFAULT ''")
    }
}

// NEW (Payments 10/10 — link a standalone payment to a specific bill): same
// low-risk shape as MIGRATION_33_34's supplierInvoiceNo — a plain TEXT column
// with a '' default, no backfill needed since blank is exactly the correct
// "not linked to any particular bill" state for every existing payment row.
val MIGRATION_34_35 = object : Migration(34, 35) {
    override fun migrate(database: SupportSQLiteDatabase) {
        database.execSQL("ALTER TABLE payments ADD COLUMN billReference TEXT NOT NULL DEFAULT ''")
    }
}

// FIX (item name / retail-wholesale rate "gayab" after sync): see PurchaseItem's
// itemName/retailRate/wholesaleRate comment in the entity above. Same low-risk
// plain-ADD-COLUMN shape as MIGRATION_33_34/34_35 — no table recreate needed.
// Pre-existing rows get itemName='' and rate=0.0, which callers (loadForEdit,
// history/return displays) treat exactly like they already treat any row from
// before this fix: fall back to the live product-table lookup for the name, and
// leave the rate field blank on edit — nothing regresses for old data.
val MIGRATION_35_36 = object : Migration(35, 36) {
    override fun migrate(database: SupportSQLiteDatabase) {
        database.execSQL("ALTER TABLE purchase_items ADD COLUMN itemName TEXT NOT NULL DEFAULT ''")
        database.execSQL("ALTER TABLE purchase_items ADD COLUMN retailRate REAL NOT NULL DEFAULT 0.0")
        database.execSQL("ALTER TABLE purchase_items ADD COLUMN wholesaleRate REAL NOT NULL DEFAULT 0.0")
    }
}

// NEW (Returns sync — full-sync-audit batch 3): same low-risk plain-ADD-COLUMN shape
// as MIGRATION_33_34/34_35/35_36 — no table recreate needed. Pre-existing return rows
// get serverId=NULL/updatedAt=0/dirty=1, which is exactly the state a locally-created-
// but-not-yet-pushed row should be in, so "Force full push" picks them all up correctly
// the first time it runs after this update.
val MIGRATION_36_37 = object : Migration(36, 37) {
    override fun migrate(database: SupportSQLiteDatabase) {
        database.execSQL("ALTER TABLE returns ADD COLUMN serverId TEXT")
        database.execSQL("ALTER TABLE returns ADD COLUMN updatedAt INTEGER NOT NULL DEFAULT 0")
        database.execSQL("ALTER TABLE returns ADD COLUMN dirty INTEGER NOT NULL DEFAULT 1")
    }
}

// NEW (Stock/Cost History sync): same plain-ADD-COLUMN shape as MIGRATION_36_37's
// returns columns — Stock History and Cost History both read off stock_movements
// (see StockMovementDao.forProduct()/costHistoryForProduct()), so giving this one
// table serverId/updatedAt/dirty makes both screens sync to another device at once.
// Pre-existing rows get serverId=NULL/updatedAt=0/dirty=1 — exactly the state a
// locally-created-but-not-yet-pushed row should be in, so "Force full push" (or the
// resyncAllLocalData() loop) picks every old movement up correctly the first time
// it runs after this update.
val MIGRATION_37_38 = object : Migration(37, 38) {
    override fun migrate(database: SupportSQLiteDatabase) {
        database.execSQL("ALTER TABLE stock_movements ADD COLUMN serverId TEXT")
        database.execSQL("ALTER TABLE stock_movements ADD COLUMN updatedAt INTEGER NOT NULL DEFAULT 0")
        database.execSQL("ALTER TABLE stock_movements ADD COLUMN dirty INTEGER NOT NULL DEFAULT 1")
    }
}

// NEW (English search alias for Urdu-named products): same plain-ADD-COLUMN shape
// as MIGRATION_36_37/37_38 — no table recreate needed. Pre-existing products get
// searchTag='' (blank), which matchesQuery() above treats as "no alias set yet" —
// search still falls back to matching the Urdu `name` exactly as before, nothing
// regresses for products that never get a tag filled in.
val MIGRATION_38_39 = object : Migration(38, 39) {
    override fun migrate(database: SupportSQLiteDatabase) {
        database.execSQL("ALTER TABLE products ADD COLUMN searchTag TEXT NOT NULL DEFAULT ''")
    }
}

// NEW (Zakat currency/calendar/month-plan): adds ZakatYear.currency, ZakatYear.calendarType,
// ZakatPayment.paymentDate, ZakatPayment.category as plain ADD COLUMNs (same low-risk shape
// as MIGRATION_33_34 etc.), plus the brand-new zakat_month_plans table (same CREATE-TABLE
// pattern as MIGRATION_30_31). Existing zakat_payments rows get paymentDate backfilled from
// their createdAt so old payments still land in the right month slice.
val MIGRATION_39_40 = object : Migration(39, 40) {
    override fun migrate(database: SupportSQLiteDatabase) {
        database.execSQL("ALTER TABLE zakat_years ADD COLUMN currency TEXT NOT NULL DEFAULT 'Rs'")
        database.execSQL("ALTER TABLE zakat_years ADD COLUMN calendarType TEXT NOT NULL DEFAULT 'islamic'")
        database.execSQL("ALTER TABLE zakat_payments ADD COLUMN paymentDate INTEGER NOT NULL DEFAULT 0")
        database.execSQL("ALTER TABLE zakat_payments ADD COLUMN category TEXT NOT NULL DEFAULT ''")
        database.execSQL("UPDATE zakat_payments SET paymentDate = createdAt WHERE paymentDate = 0")
        database.execSQL(
            "CREATE TABLE IF NOT EXISTS zakat_month_plans (" +
                "id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, " +
                "zakatYearId INTEGER NOT NULL, " +
                "monthIndex INTEGER NOT NULL, " +
                "payableAmount REAL NOT NULL, " +
                "note TEXT NOT NULL DEFAULT '', " +
                "createdAt INTEGER NOT NULL, " +
                "updatedAt INTEGER NOT NULL DEFAULT 0, " +
                "dirty INTEGER NOT NULL DEFAULT 1)"
        )
    }
}

// NEW (manual default-unit override): plain ADD COLUMN, same low-risk shape as
// MIGRATION_33_34/34_35/etc. Existing products get -1 (Auto), so every product
// saved before this update keeps behaving exactly as it does today until the
// shopkeeper opens it and picks a default unit explicitly.
val MIGRATION_40_41 = object : Migration(40, 41) {
    override fun migrate(database: SupportSQLiteDatabase) {
        database.execSQL("ALTER TABLE products ADD COLUMN defaultUnitIndex INTEGER NOT NULL DEFAULT -1")
    }
}

// FIX (Bug 2 — Expenses never touch Cash Register / Cash Activity / Balance Sheet's
// "Cash in Hand"): plain ADD COLUMN, same low-risk shape as MIGRATION_33_34/40_41/etc.
// Every expense recorded before this update gets 'cash' (matching how they behaved —
// there was no other option), so ExpenseActivity.saveExpense() can now also insert a
// CashTransaction(type="OUT") the same way RoomPurchaseRepository/PartyTransactionActivity
// already do for purchases/manual payments, making Balance Sheet's
// "all-time cash_transactions IN(cash) - OUT(cash)" formula finally include expenses.
val MIGRATION_41_42 = object : Migration(41, 42) {
    override fun migrate(database: SupportSQLiteDatabase) {
        database.execSQL("ALTER TABLE expenses ADD COLUMN method TEXT NOT NULL DEFAULT 'cash'")
    }
}

// NEW (Overdue for suppliers): Purchase.dueDate, same plain ADD COLUMN shape as
// MIGRATION_29_30's sales.dueDate. Every purchase recorded before this update gets
// 0 ("no date set" — same convention DueRemindersActivity already uses for sales),
// so nothing is ever wrongly marked overdue just because it predates this column.
val MIGRATION_42_43 = object : Migration(42, 43) {
    override fun migrate(database: SupportSQLiteDatabase) {
        database.execSQL("ALTER TABLE purchases ADD COLUMN dueDate INTEGER NOT NULL DEFAULT 0")
    }
}

// NEW (Stuck Balance): Customer.stuckBalance. Plain ADD COLUMN, default 0 — every existing
// customer keeps behaving exactly as before (no stuck amount) until one is entered.
val MIGRATION_43_44 = object : Migration(43, 44) {
    override fun migrate(database: SupportSQLiteDatabase) {
        database.execSQL("ALTER TABLE customers ADD COLUMN stuckBalance REAL NOT NULL DEFAULT 0.0")
    }
}

// NEW (Quick Sale-specific default unit): plain ADD COLUMN, same low-risk shape
// as MIGRATION_40_41's defaultUnitIndex. Existing products get -1 (Auto), so
// Quick Sale keeps picking exactly what it picks today until a shopkeeper opens
// "Add Item Unit" and pins a Quick Sale default explicitly.
val MIGRATION_44_45 = object : Migration(44, 45) {
    override fun migrate(database: SupportSQLiteDatabase) {
        database.execSQL("ALTER TABLE products ADD COLUMN quickSaleDefaultUnitIndex INTEGER NOT NULL DEFAULT -1")
    }
}

// NEW (Shell Ledger sync): shop_empty_shell_log was missing the serverId/updatedAt/
// dirty trio that shell_customers/shell_transactions already had — added now so all
// three Shell Ledger tables can push/pull through SyncQueueHelper/SyncApi (see the
// FIX comment above ShellCustomer). Every existing row gets dirty=1 so it gets
// picked up and pushed on the very next sync, same as any other newly-synced table.
val MIGRATION_45_46 = object : Migration(45, 46) {
    override fun migrate(database: SupportSQLiteDatabase) {
        database.execSQL("ALTER TABLE shop_empty_shell_log ADD COLUMN serverId TEXT")
        database.execSQL("ALTER TABLE shop_empty_shell_log ADD COLUMN updatedAt INTEGER NOT NULL DEFAULT 0")
        database.execSQL("ALTER TABLE shop_empty_shell_log ADD COLUMN dirty INTEGER NOT NULL DEFAULT 1")
    }
}

// NEW (CRITICAL cross-device sync fix): Payment.partyServerId — see the field's own
// doc comment in the Payment entity above for the full "phantom payment" bug this
// closes. Plain ADD COLUMN, default '' (treated as "not yet backfilled" the same
// way other serverId-ish columns in this app use blank/null interchangeably) —
// every existing payment keeps syncing exactly as before (old raw-partyId
// behavior) until SyncQueueHelper.enqueuePayment backfills it on its next push.
val MIGRATION_46_47 = object : Migration(46, 47) {
    override fun migrate(database: SupportSQLiteDatabase) {
        database.execSQL("ALTER TABLE payments ADD COLUMN partyServerId TEXT DEFAULT ''")
    }
}

// FIX (crash on open — "Migration didn't properly handle: payments"): the original
// MIGRATION_46_47 above added partyServerId with no SQL DEFAULT, but the Payment
// entity's @ColumnInfo(defaultValue="") expects the column's default to be ''.
// That mismatch made Room's post-migration schema check fail and crash every time
// the app opened. MIGRATION_46_47 has now been fixed for anyone jumping straight
// from 46, but any device that already reached version 47 before this fix is
// still carrying the bad column definition (SQLite can't ALTER a column's default
// in place), so this migration recreates `payments` with the correct default,
// same table-recreate pattern as MIGRATION_23_24/24_25. Existing rows are
// unaffected — this only fixes the column's default for future inserts.
val MIGRATION_47_48 = object : Migration(47, 48) {
    override fun migrate(database: SupportSQLiteDatabase) {
        database.execSQL("CREATE TABLE payments_new (id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, reference TEXT NOT NULL, partyType TEXT NOT NULL, partyId INTEGER, amount REAL NOT NULL, method TEXT NOT NULL, note TEXT NOT NULL DEFAULT '', billReference TEXT NOT NULL DEFAULT '', createdAt INTEGER NOT NULL, serverId TEXT, updatedAt INTEGER NOT NULL DEFAULT 0, dirty INTEGER NOT NULL DEFAULT 1, partyServerId TEXT DEFAULT '')")
        database.execSQL("INSERT INTO payments_new (id, reference, partyType, partyId, amount, method, note, billReference, createdAt, serverId, updatedAt, dirty, partyServerId) SELECT id, reference, partyType, partyId, amount, method, note, billReference, createdAt, serverId, updatedAt, dirty, partyServerId FROM payments")
        database.execSQL("DROP TABLE payments")
        database.execSQL("ALTER TABLE payments_new RENAME TO payments")
    }
}

@Database(
    entities=[Product::class,Customer::class,Supplier::class,Sale::class,SaleItem::class,
        Payment::class,Purchase::class,PurchaseItem::class,ReturnLine::class,User::class,Audit::class,
        Expense::class,HeldBill::class,UnitType::class,Category::class,CashTransaction::class,
        CashRegister::class,AppSetting::class,SyncQueueEntry::class,StockMovement::class,
        ZakatYear::class,ZakatPayment::class,ZakatMonthPlan::class,ShellCustomer::class,ShellTransaction::class,ShopEmptyShellLog::class],
    // FIX (Improvement Pack P3 — migration testing): was exportSchema=false, so Room
    // never wrote a schema JSON for any version — MigrationTestHelper needs those to
    // validate a migration's resulting schema (not just that it runs without an
    // exception). See app/build.gradle.kts's matching room.schemaLocation arg and
    // MigrationTest.kt's top comment for what this does and doesn't retroactively fix
    // for versions 13-32 (which predate this change).
    version=48, exportSchema=true
)
abstract class PosDatabase:RoomDatabase(){
    abstract fun productDao():ProductDao
    abstract fun customerDao():CustomerDao
    abstract fun supplierDao():SupplierDao
    abstract fun saleDao():SaleDao
    abstract fun expenseDao():ExpenseDao
    abstract fun paymentDao():PaymentDao
    abstract fun purchaseDao():PurchaseDao
    abstract fun returnDao():ReturnDao
    abstract fun userDao():UserDao
    abstract fun auditDao():AuditDao
    abstract fun heldDao():HeldDao
    abstract fun unitDao():UnitDao
    abstract fun categoryDao():CategoryDao
    abstract fun cashTransactionDao():CashTransactionDao
    abstract fun cashRegisterDao():CashRegisterDao
    abstract fun appSettingDao():AppSettingDao
    abstract fun syncQueueDao():SyncQueueDao
    abstract fun stockMovementDao():StockMovementDao
    abstract fun zakatDao():ZakatDao
    abstract fun shellDao():ShellDao
    companion object{
        @Volatile private var INSTANCE:PosDatabase?=null
        fun get(c:Context)=INSTANCE?: synchronized(this){
            INSTANCE?:Room.databaseBuilder(c.applicationContext,PosDatabase::class.java,"grocery_pos_v11.db")
                .addMigrations(MIGRATION_13_14, MIGRATION_14_15, MIGRATION_15_16, MIGRATION_16_17, MIGRATION_17_18, MIGRATION_18_19, MIGRATION_19_20, MIGRATION_20_21, MIGRATION_21_22, MIGRATION_22_23, MIGRATION_23_24, MIGRATION_24_25, MIGRATION_25_26, MIGRATION_26_27, MIGRATION_27_28, MIGRATION_28_29, MIGRATION_29_30, MIGRATION_30_31, MIGRATION_31_32, MIGRATION_32_33, MIGRATION_33_34, MIGRATION_34_35, MIGRATION_35_36, MIGRATION_36_37, MIGRATION_37_38, MIGRATION_38_39, MIGRATION_39_40, MIGRATION_40_41, MIGRATION_41_42, MIGRATION_42_43, MIGRATION_43_44, MIGRATION_44_45, MIGRATION_45_46, MIGRATION_46_47, MIGRATION_47_48)
                // FIX (crash on very old installs): versions 1-12 predate any explicit
                // Migration object (those builds only ever used a blanket
                // fallbackToDestructiveMigration()), so there is no real upgrade path
                // from them to 13. Without this, a device still sitting on DB version
                // 1-12 that installs this build would crash on first launch with
                // "Migration didn't properly handle...". Scoping the destructive
                // fallback to exactly those old starting versions keeps that same
                // wipe-and-recreate behavior those builds already had — nothing new is
                // lost that wasn't already at risk on them — while every device on 13+
                // still goes through the real, data-preserving migrations above.
                .fallbackToDestructiveMigrationFrom(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12)
                // Never destructively recreate a POS database on downgrade. A silent
                // database wipe would destroy sales, purchases, stock and balances.
                // Downgrades must be handled as an explicit supported migration or by
                // restoring a verified backup.
                .build().also{INSTANCE=it}
        }
        fun closeInstance() { INSTANCE?.close(); INSTANCE = null }
    }
}
