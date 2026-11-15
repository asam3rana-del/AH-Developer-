package com.grocerypos.v11.data

import android.content.Context
import androidx.room.withTransaction
import com.grocerypos.v11.CashTransaction
import com.grocerypos.v11.Category
import com.grocerypos.v11.DeviceTag
import com.grocerypos.v11.Payment
import com.grocerypos.v11.PosDatabase
import com.grocerypos.v11.Product
import com.grocerypos.v11.Purchase
import com.grocerypos.v11.PurchaseItem
import com.grocerypos.v11.Supplier
import com.grocerypos.v11.SyncQueueHelper
import com.grocerypos.v11.UnitType
import com.grocerypos.v11.isValidSmallestQty
import com.grocerypos.v11.smallestPerUnitOf
import com.grocerypos.v11.smallestQty
import com.grocerypos.v11.smallestUnitFactor
import com.grocerypos.v11.smallestUnitName
import com.grocerypos.v11.toSmallestUnits
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Room-backed implementation of [PurchaseRepository] (see that file for the
 * interface contract and the reason it exists).
 *
 * This is the only place in the app that should call PurchaseDao/SupplierDao/
 * ProductDao/UnitDao/CategoryDao/PaymentDao/CashTransactionDao/AppSettingDao
 * for purchase-related work — UseCases and the ViewModel go through the
 * PurchaseRepository interface instead of touching PosDatabase directly, and
 * every write stays paired with the matching SyncQueueHelper call (exactly as
 * PurchaseActivity used to do inline). The save/delete paths keep their
 * single-transaction guarantee: stock, cost, and supplier balance can never
 * go out of sync with the purchase record, even on a crash mid-save.
 *
 * [appContext] should be an application Context (not an Activity one) since
 * this repository is expected to outlive any single screen.
 */
class RoomPurchaseRepository(
    private val db: PosDatabase,
    private val appContext: Context
) : PurchaseRepository {

    override fun observeSuppliers(): Flow<List<Supplier>> = db.supplierDao().all()

    override fun observeProducts(): Flow<List<Product>> = db.productDao().all()

    override fun observeUnits(): Flow<List<UnitType>> = db.unitDao().all()

    override suspend fun getFirmName(): String? = db.appSettingDao().get("shop_name")?.value

    override suspend fun categories(): List<String> =
        (listOf("General") + db.categoryDao().all().first().map { it.name }).distinct()

    override suspend fun addUnit(name: String) {
        val newUnit = UnitType(name)
        db.unitDao().insert(newUnit)
        SyncQueueHelper.enqueueUnit(db, newUnit)
    }

    // NEW (Purchase screen inline "Add New Category"): same master-table insert
    // as ProductActivity's "Add New Category" button, just triggered from the
    // Purchase screen's "Add New Product" dialog so the shop owner doesn't have
    // to leave Purchase to create a category first.
    override suspend fun addCategory(name: String) {
        val newCategory = Category(name)
        db.categoryDao().insert(newCategory)
        SyncQueueHelper.enqueueCategory(db, newCategory)
    }

    // NEW (Purchase screen inline unit translate): lets the shop owner rename an
    // existing unit (typically Urdu, e.g. "عدد") to its English name (e.g. "pcs")
    // right from the Purchase screen's unit picker, instead of having to close
    // Purchase, go to Items > Bulk Translate to do it, then come back and re-pick
    // the product. Same steps as BulkTranslateActivity's "Units" rename: swap the
    // master units-table row, cascade into every product's primary/secondary/
    // tertiary unit column, then push both the new unit and the touched products
    // to sync so other devices/branches see the rename too.
    override suspend fun renameUnitToEnglish(oldValue: String, newValue: String) {
        val old = oldValue.trim()
        val new = newValue.trim()
        if (old.isEmpty() || new.isEmpty() || old == new) return
        val dao = db.productDao()
        val touchedBarcodes = mutableSetOf<String>()
        dao.findByPrimaryUnit(old).forEach { touchedBarcodes.add(it.barcode) }
        dao.findBySecondaryUnit(old).forEach { touchedBarcodes.add(it.barcode) }
        dao.findByTertiaryUnit(old).forEach { touchedBarcodes.add(it.barcode) }
        val newUnit = UnitType(new)
        db.unitDao().insert(newUnit)
        db.unitDao().deleteByName(old)
        dao.renamePrimaryUnitInProducts(old, new)
        dao.renameSecondaryUnitInProducts(old, new)
        dao.renameTertiaryUnitInProducts(old, new)
        SyncQueueHelper.enqueueUnit(db, newUnit)
        SyncQueueHelper.enqueueDelete(db, "unit", old)
        touchedBarcodes.forEach { barcode ->
            dao.find(barcode)?.let { p -> SyncQueueHelper.enqueueProduct(db, p) }
        }
        if (touchedBarcodes.isNotEmpty()) SyncQueueHelper.trigger(appContext)
    }

    // Same write BulkDefaultUnitActivity's stepper does for one product at a
    // time — exposed here so the Purchase screen can set/change it inline too.
    override suspend fun updateDefaultUnitIndex(barcode: String, index: Int) {
        db.productDao().updateDefaultUnitIndex(barcode, index, System.currentTimeMillis())
        db.productDao().find(barcode)?.let { updated ->
            SyncQueueHelper.enqueueProduct(db, updated)
            SyncQueueHelper.trigger(appContext)
        }
    }

    override suspend fun addSupplier(name: String, phone: String, openingBalance: Double): Supplier {
        val supplier = Supplier(name = name, phone = phone, openingBalance = openingBalance)
        val id = db.supplierDao().insert(supplier)
        val saved = supplier.copy(id = id)
        // FIX (cross-device "Give"/payables mismatch): this used to only insert the
        // supplier LOCALLY and never enqueue it for sync at all — unlike
        // RoomSaleRepository.createCustomer()'s identical quick-add path, which
        // correctly does. Since every later adjustSupplierBalance() call for this
        // supplier's purchases pushes an "increment_balance" delta keyed to THIS
        // supplier's own entity id, and SyncApi's pull-side skips any supplier
        // document with no "name" field (see the `?: continue` in applyRemoteChanges),
        // a supplier added via this screen's "+" button silently never reached the
        // other device — its whole balance (and thus that amount of "You'll Give")
        // was invisible there, while it still counted normally on this device.
        SyncQueueHelper.enqueueSupplier(db, saved)
        SyncQueueHelper.trigger(appContext)
        return saved
    }

    override suspend fun addProduct(product: Product) {
        db.productDao().upsert(product)
        // FIX (cross-device product/stock mismatch — same root cause as addSupplier
        // above): this used to only insert the product LOCALLY, exactly like the
        // pre-fix addSupplier bug. A product quick-added via the Purchase screen's
        // manual "+ Add New Product" dialog never reached the other device at all —
        // not its name, price, unit config, or (once this purchase's own
        // increaseProductStock/updateProductCost calls run) its stock and cost either,
        // since those are keyed to a barcode that only exists locally. Mirrors the
        // exact enqueue+trigger pattern ProductActivity's own "Save Product" already
        // uses.
        SyncQueueHelper.enqueue(
            db, "product", SyncQueueHelper.productEntityId(product), "create",
            SyncQueueHelper.productJson(product)
        )
        // Stock is deliberately excluded from productJson()'s snapshot (see the big
        // comment on adjustCustomerBalance/adjustSupplierBalance above) — a brand-new
        // product's opening stock must be sent as its own increment. Both quick-add
        // paths always create with stock=0.0, so this is a no-op today, but keeps this
        // in step with ProductActivity's pattern if that ever changes.
        SyncQueueHelper.enqueueProductOpeningStock(db, product.barcode, product.stock, product.cost)
        SyncQueueHelper.trigger(appContext)
    }

    override suspend fun createProductForScan(name: String, cost: Double, seed: Int): Product {
        val newProduct = Product(
            barcode = "P" + System.currentTimeMillis() + seed,
            name = name, category = "General", cost = cost, salePrice = 0.0, wholesalePrice = 0.0,
            stock = 0.0, openingStock = 0.0, unit = "pcs", secondaryUnit = "", secondaryUnitQty = 0.0,
            tertiaryUnit = "", tertiaryUnitQty = 0.0
        )
        db.productDao().upsert(newProduct)
        // FIX (cross-device product mismatch): same reasoning as addProduct() above —
        // a bill-scan auto-created product used to exist only on the scanning device,
        // so the other device would never see this product at all (and later, once
        // this purchase updates its stock/cost, those changes would target a barcode
        // that doesn't exist there either).
        SyncQueueHelper.enqueue(
            db, "product", SyncQueueHelper.productEntityId(newProduct), "create",
            SyncQueueHelper.productJson(newProduct)
        )
        SyncQueueHelper.enqueueProductOpeningStock(db, newProduct.barcode, newProduct.stock, newProduct.cost)
        SyncQueueHelper.trigger(appContext)
        return newProduct
    }

    override suspend fun loadForEdit(billNo: String): PurchaseEditData? {
        val purchase = db.purchaseDao().findPurchase(billNo) ?: return null
        val items = db.purchaseDao().itemsForBill(billNo)
        val supplierName = purchase.supplierId?.let { id -> db.supplierDao().find(id)?.name } ?: ""
        val lines = items.map { pi ->
            val product = db.productDao().find(pi.barcode)
            PurchaseLine(
                // FIX (item name "gayab" after sync): prefer the name snapshotted on
                // this row at purchase time; only fall back to a live product lookup
                // for rows saved before MIGRATION_35_36 (itemName=="" there). See
                // PurchaseItem.itemName's comment in Database.kt.
                itemName = pi.itemName.ifBlank { product?.name ?: pi.barcode },
                barcode = pi.barcode,
                qty = pi.qty,
                unit = pi.unit.ifBlank { product?.unit ?: "" },
                rate = pi.unitCost,
                amount = pi.amount,
                mainUnit = product?.unit ?: "",
                secondaryUnit = product?.secondaryUnit ?: "",
                secondaryUnitQty = product?.secondaryUnitQty ?: 0.0,
                tertiaryUnit = product?.tertiaryUnit ?: "",
                tertiaryUnitQty = product?.tertiaryUnitQty ?: 0.0,
                // FIX (retail/wholesale rate "gayab" on edit): this used to always be
                // hardcoded 0.0 here because the rate the user entered was never saved
                // anywhere — only the *product's* current price got updated. Now it's
                // read back from this row's own snapshot. 0.0 on a pre-migration row
                // just means "not captured", same as before.
                retailRate = pi.retailRate,
                wholesaleRate = pi.wholesaleRate
            )
        }
        return PurchaseEditData(purchase, items, supplierName, lines)
    }

    // NEW (Split Payment): rebuilds the (method, amount) breakdown for a bill
    // from its "Purchase" cash-drawer entries, so the Split Payment dialog can
    // repopulate correctly when editing a bill that was originally paid with
    // more than one method. Ordered by id so rows come back in the same order
    // they were entered — mirrors RoomSaleRepository.paymentsForInvoice.
    override suspend fun paymentsForBill(billNo: String): List<Pair<String, Double>> =
        db.cashTransactionDao().allByReference(billNo)
            .filter { it.type == "OUT" && it.reason == "Purchase" }
            .sortedBy { it.id }
            .map { it.method to it.amount }

    override suspend fun findLastPurchaseRate(barcode: String, excludeBillNo: String?): Pair<Double, String>? {
        if (barcode.isBlank()) return null
        val candidatePurchases = db.purchaseDao().allPurchases()
            .filter { it.billNo != excludeBillNo }
            .sortedByDescending { it.createdAt }
        for (purchase in candidatePurchases) {
            val items = db.purchaseDao().itemsForBill(purchase.billNo)
            val match = items.find { it.barcode == barcode }
            if (match != null) return match.unitCost to match.unit
        }
        return null
    }

    // FIX (multi-device collision bug): billNo used to be a pure local sequence number
    // ("PUR-Aug26-0001", "0002", ...) with nothing device-specific in it. Two different
    // devices at the same branch would independently generate the exact same billNo
    // (e.g. both devices' very first purchase this month becomes "PUR-Aug26-0001"), and
    // since billNo is also the Firestore document ID this purchase syncs under, one
    // device's purchase would silently overwrite the other's instead of both existing.
    // Appending each device's DeviceTag makes billNo unique across devices while keeping
    // the same readable per-device sequence.
    private suspend fun genBillNo(): String {
        val prefix = "PUR-" + SimpleDateFormat("MMMyy", Locale.getDefault()).format(Date()) + "-"
        val existing = db.purchaseDao().allPurchases().map { it.billNo }.toHashSet()
        var seqNum = existing.count { it.startsWith(prefix) } + 1
        var candidate = prefix + seqNum.toString().padStart(4, '0') + "-" + DeviceTag.current
        while (existing.contains(candidate)) {
            seqNum++
            candidate = prefix + seqNum.toString().padStart(4, '0') + "-" + DeviceTag.current
        }
        return candidate
    }

    // FIX (Purchase costing safety, item #7): reversing a purchase (on edit or
    // delete) used to reconstruct "cost before this purchase" by subtracting
    // this purchase's amount from (currentStock * currentAverageCost) — a
    // simple average-cost algebra trick that is only valid if NOTHING else
    // (no sale, no other purchase) has touched this product's stock/cost
    // since this purchase was recorded. In a real sequence like
    // Purchase -> Sale -> Purchase -> Sale -> [delete the first Purchase],
    // that assumption is already broken: sales in between consumed stock at
    // an average cost that had this purchase's value mixed in, so naively
    // subtracting this purchase's amount no longer recovers a correct number.
    // A fully correct fix needs a per-transaction inventory ledger (see
    // README/plan) — a larger change than this pass. Until that lands, this
    // validates FIRST (before any writes) that reversing every line would
    // not need to remove more units than are currently in stock; if any
    // line's already been drawn down below its own purchased quantity by
    // later sales, we refuse the whole edit/delete rather than silently
    // producing a corrupted stock/cost number. The user should record a
    // stock adjustment instead in that case.
    private suspend fun reverseStockAndCostForItems(items: List<PurchaseItem>) {
        items.forEach { pi ->
            val product = db.productDao().find(pi.barcode) ?: return@forEach
            val smallestQty = pi.smallestQty(product)
            if (smallestQty > 0 && smallestQty > product.stock) {
                throw IllegalStateException(
                    "\"${product.name}\" ka stock is purchase ke baad already kam ho chuka hai " +
                    "(sale ya doosri entry se) — is purchase ko edit/delete karna cost ko galat kar dega. " +
                    "Iski jagah stock adjustment karen."
                )
            }
        }
        items.forEach { pi ->
            val product = db.productDao().find(pi.barcode) ?: return@forEach
            val factor = product.smallestUnitFactor()
            // FIX (historical unit conversion bug): use the factor frozen on this
            // line AT PURCHASE TIME (pi.conversionFactor) instead of re-deriving it
            // from the product's CURRENT unit configuration — see Database.kt's
            // PurchaseItem.smallestQty() comment. Otherwise editing a product's unit
            // ladder after the fact (e.g. "1 Carton = 10 Box" -> "= 12 Box") would
            // silently reverse the wrong quantity for every old purchase on delete/edit.
            val smallestQty = pi.smallestQty(product)
            if (smallestQty <= 0) return@forEach

            val currentCostPerSmallest = if (factor > 0) product.cost / factor else product.cost
            val currentStock = product.stock
            val newStock = currentStock - smallestQty

            val totalValueBefore = currentStock * currentCostPerSmallest
            val totalValueAfterRemoval = (totalValueBefore - pi.amount).coerceAtLeast(0.0)

            val newCostPerSmallest = if (newStock > 0) totalValueAfterRemoval / newStock else 0.0
            val newCost = newCostPerSmallest * factor

            SyncQueueHelper.decreaseProductStockForce(db, pi.barcode, smallestQty, "PURCHASE_REVERSAL", pi.billNo, newCost)
            SyncQueueHelper.updateProductCost(db, pi.barcode, newCost)
        }
    }

    // FIX (edit-blocked-by-unrelated-stock-change bug — whole bill): editing a purchase
    // used to ALWAYS reverse every original line's stock/cost and then reapply the
    // (possibly identical) new lines — even when the edit only changed something
    // unrelated like Paid Amount and every item (barcode/qty/unit/rate) was left
    // untouched. Since reverseStockAndCostForItems() safety-checks that the product
    // still has enough stock to reverse, a later sale that ate into that item's stock
    // would block the edit entirely ("... ka stock is purchase ke baad already kam ho
    // chuka hai ..."), even though a no-op reverse-then-reapply of unchanged items
    // never needed to touch stock/cost in the first place.
    // FIX (edit-blocked-by-UNRELATED-LINE bug — one line, not the whole bill): the
    // above only covered a fully-unchanged bill. Editing just ONE line still reversed
    // and reapplied EVERY line, so an untouched line already drawn down by a later
    // sale could block an edit to a completely different product. savePurchase() now
    // calls StockTouchPolicy.purchaseChangedLines() directly instead of a single
    // whole-bill boolean here — see its doc comment and StockTouchPolicyTest for the
    // per-line matching this replaced this function with.

    // FIX (Phase 1 - Data Safety): stock/cost reversal + supplier balance reversal + all
    // row deletes now run as one atomic Room transaction (previously separate sequential
    // writes — same class of bug as savePurchase()/HistoryActivity.deletePurchase(), which
    // were already fixed; this was the one remaining unguarded purchase-delete path).
    override suspend fun deletePurchase(billNo: String, original: Purchase?, originalItems: List<PurchaseItem>) {
        val purchase = original ?: db.purchaseDao().findPurchase(billNo) ?: return
        val items = originalItems.ifEmpty { db.purchaseDao().itemsForBill(billNo) }
        db.withTransaction {
            reverseStockAndCostForItems(items)
            // FIX (overpaid-bill balance gap): see savePurchase()'s matching comment —
            // deleting an overpaid purchase must reverse its advance credit too, not
            // just an amount owed to the supplier.
            val outstanding = purchase.total - purchase.paid
            if (purchase.supplierId != null && kotlin.math.abs(outstanding) > 0.009) {
                SyncQueueHelper.adjustSupplierBalance(db, purchase.supplierId, -outstanding)
            }
            db.purchaseDao().deleteItems(billNo)
            db.purchaseDao().deletePurchase(billNo)
            // FIX (deleted purchase's payment "survives" — shows in Payments Report/
            // other devices with no purchase behind it): these two used to call
            // db.paymentDao().deleteByReference()/db.cashTransactionDao().deleteByReference()
            // directly, which deletes the rows LOCALLY but never enqueues a matching sync
            // delete — see SyncQueueHelper.deletePaymentsByReference()'s big comment above,
            // which documents exactly this class of bug for the edit path. The purchase
            // itself WAS enqueued for delete below and disappears everywhere correctly;
            // its payment/cash-transaction rows did not carry the same enqueue and so
            // silently stayed behind on every other device (and in Firestore) forever.
            SyncQueueHelper.deletePaymentsByReference(db, billNo)
            SyncQueueHelper.deleteCashTransactionsByReference(db, billNo)
            // FIX (audit): bill-linked payments would otherwise live on as orphan payments.
            SyncQueueHelper.voidLinkedPayments(db, billNo, null, "")
        }
        SyncQueueHelper.enqueue(
            db, "purchase", "purchase:$billNo", "delete",
            org.json.JSONObject().apply { put("billNo", billNo) }.toString()
        )
        SyncQueueHelper.trigger(appContext)
    }

    // FIX (Phase 1 - Data Safety): everything below (supplier insert, reversal
    // of the original purchase on edit, purchase+items insert, stock/cost
    // update per line, supplier balance update, payment + cash transaction
    // insert) runs inside one Room transaction instead of as separate
    // sequential writes — a crash/kill partway through previously could leave
    // stock, cost, and supplier balance out of sync with the purchase record.
    override suspend fun savePurchase(
        editBillNo: String?,
        party: String,
        grandTotal: Double,
        amountPaid: Double,
        discount: Double,
        paymentMethod: String,
        purchaseDateMillis: Long,
        lines: List<PurchaseLine>,
        original: Purchase?,
        originalItems: List<PurchaseItem>,
        suppliers: List<Supplier>,
        supplierInvoiceNo: String,
        payments: List<Pair<String, Double>>
    ): SavePurchaseResult {
        return try {
            val matchedSupplier = suppliers.find { it.name.equals(party, ignoreCase = true) }
            var supplierId = matchedSupplier?.id
            val billNo = editBillNo ?: genBillNo()
            // FIX (edit-blocked-by-unrelated-line bug): used to be a single whole-bill
            // skipStockTouch boolean (itemsUnchanged()) — editing even one line made it
            // reverse+reapply EVERY original line, so an untouched line already drawn
            // down by a later sale could block an edit that never even touched that
            // product. purchaseChangedLines() instead pairs off every line the user left
            // alone (matched exactly, both sides skipped) and returns only what actually
            // changed: itemsToReverse (leftover original lines — reverse these) and
            // linesToApply (leftover edited lines — reapply stock/cost for these only).
            // A fully-unchanged edit (e.g. only Paid Amount changed) naturally yields two
            // empty lists, same as the old skipStockTouch=true short-circuit.
            // Index-based (purchaseEditDiff) instead of the old `line in hashSet` lookup —
            // see StockTouchPolicy.purchaseEditDiff()'s comment for the duplicate-line bug.
            val diff = if (original != null)
                com.grocerypos.v11.domain.StockTouchPolicy.purchaseEditDiff(lines, originalItems)
            else null
            val itemsToReverse = diff?.itemsToReverse ?: emptyList()
            fun lineNeedsStock(index: Int): Boolean = diff == null || index in diff.changedLineIndices
            db.withTransaction {
                if (supplierId == null && party.isNotEmpty()) {
                    val newSupplier = Supplier(name = party)
                    val newId = db.supplierDao().insert(newSupplier)
                    supplierId = newId
                    // FIX (supplier name edited from Purchase screen not syncing):
                    // this inline supplier insert was never enqueued for sync, so a
                    // renamed/new supplier typed here stayed local-only — the purchase
                    // itself synced fine (hence other data looked fine), but the other
                    // device could never resolve supplierServerId to a name.
                    SyncQueueHelper.enqueueSupplier(db, newSupplier.copy(id = newId))
                }
                if (original != null) {
                    if (itemsToReverse.isNotEmpty()) {
                        reverseStockAndCostForItems(itemsToReverse)
                    }
                    // FIX (overpaid-bill balance gap): was `> 0` — an original purchase
                    // that had been OVERpaid (originalOutstanding negative, credited to
                    // the supplier as an advance by the forward-adjustment fix below)
                    // never had that advance reversed on edit, permanently stranding it.
                    val originalOutstanding = original.total - original.paid
                    if (original.supplierId != null && kotlin.math.abs(originalOutstanding) > 0.009) {
                        SyncQueueHelper.adjustSupplierBalance(db, original.supplierId, -originalOutstanding)
                    }
                    db.purchaseDao().deleteItems(billNo)
                    db.purchaseDao().deletePurchase(billNo)
                    // FIX: same enqueue-missing bug as deletePurchase() above, hit here on
                    // every EDIT too (original purchase is deleted and recreated) — see the
                    // comment there and SyncQueueHelper.deletePaymentsByReference()'s.
                    SyncQueueHelper.deletePaymentsByReference(db, billNo)
                    SyncQueueHelper.deleteCashTransactionsByReference(db, billNo)
                }
                val purchaseRecord = Purchase(
                    billNo = billNo, supplierId = supplierId, total = grandTotal, paid = amountPaid,
                    createdAt = purchaseDateMillis, subtotal = lines.sumOf { it.amount }, discount = discount,
                    supplierInvoiceNo = supplierInvoiceNo
                )
                db.purchaseDao().purchase(purchaseRecord)
                val purchaseItems = lines.mapIndexed { index, line ->
                    val lineProduct = line.barcode?.let { db.productDao().find(it) }
                    // An untouched line keeps the conversionFactor frozen at its original
                    // purchase time — re-stamping it with the CURRENT unit ladder would make a
                    // later delete/edit/return reverse a different quantity than was added.
                    val unchangedOriginal = diff?.unchangedOriginalByIndex?.get(index)
                    PurchaseItem(
                        billNo = billNo, barcode = line.barcode ?: "", qty = line.qty,
                        unitCost = line.rate, amount = line.amount, unit = line.unit,
                        // FIX (historical unit conversion bug): freeze this line's
                        // smallest-units-per-`unit` factor at purchase time — see
                        // Database.kt's PurchaseItem.smallestQty()/conversionFactor comment.
                        conversionFactor = unchangedOriginal?.conversionFactor
                            ?: lineProduct?.smallestPerUnitOf(line.unit) ?: 0.0,
                        // FIX (item name / retail-wholesale rate "gayab" after sync):
                        // snapshot this line's own name + entered rates on the row
                        // itself instead of relying on a live products-table lookup
                        // later — see PurchaseItem.itemName's comment in Database.kt.
                        itemName = line.itemName,
                        retailRate = line.retailRate,
                        wholesaleRate = line.wholesaleRate
                    )
                }
                db.purchaseDao().items(purchaseItems)
                SyncQueueHelper.enqueue(
                    db, "purchase", SyncQueueHelper.purchaseEntityId(purchaseRecord), if (original != null) "update" else "create",
                    SyncQueueHelper.purchaseJson(db, purchaseRecord)
                )
                lines.forEachIndexed { index, line ->
                    val barcode = line.barcode ?: return@forEachIndexed
                    val before = db.productDao().find(barcode) ?: return@forEachIndexed
                    // See purchaseChangedLines() comment above: only lines that actually
                    // changed (or are newly added) are flagged by lineNeedsStock() — a line the
                    // user left alone keeps its stock/cost exactly as-is instead of being
                    // reversed and reapplied as a no-op. This is what lets an edit to ONE
                    // line go through even when a later sale has since eaten into some
                    // OTHER, untouched line's stock.
                    if (lineNeedsStock(index)) {
                        val purchasedSmallest = before.toSmallestUnits(line.qty, line.unit)
                        // FIX (fraction control): reject a purchase line that would leave a
                        // fractional smallest-unit qty for a non-fractional item (Piece/Dabbi/
                        // Bottle etc.) instead of silently rounding it away — previously stock
                        // was an Int so e.g. "2.5 Dabbi" quietly became "2 Dabbi" or "3 Dabbi".
                        if (!before.isValidSmallestQty(purchasedSmallest)) {
                            throw IllegalStateException("\"${before.name}\" ke liye qty (${line.qty} ${line.unit}) whole ${before.smallestUnitName()} mein convert nahi hoti — qty check karen.")
                        }
                        // Compute the new weighted-average cost BEFORE the stock increase below
                        // (uses `before.stock`, i.e. pre-increase) so the stock_movements row
                        // logged by increaseProductStock() carries the correct just-computed
                        // cost instead of the stale pre-purchase one.
                        var newCostForMovement = before.cost
                        if (purchasedSmallest > 0) {
                            val oldStockSmallest = before.stock
                            val factor = before.smallestUnitFactor()
                            val oldCostPerSmallest = if (factor > 0) before.cost / factor else before.cost
                            val purchaseRatePerSmallest = line.amount / purchasedSmallest
                            val newCostPerSmallest = if (oldStockSmallest <= 0) purchaseRatePerSmallest
                                else ((oldStockSmallest * oldCostPerSmallest) + (purchasedSmallest * purchaseRatePerSmallest)) / (oldStockSmallest + purchasedSmallest)
                            newCostForMovement = newCostPerSmallest * factor
                        }
                        SyncQueueHelper.increaseProductStock(db, barcode, purchasedSmallest, "PURCHASE", billNo, newCostForMovement)
                        if (purchasedSmallest > 0) {
                            SyncQueueHelper.updateProductCost(db, barcode, newCostForMovement)
                        }
                    }
                    // NEW ("10/10 Purchase screen" item #7): set/update the product's
                    // retail (salePrice) / wholesale rate right here at purchase time —
                    // 0.0 on either field means "leave that rate unchanged" (see
                    // PurchaseLine.retailRate/wholesaleRate).
                    // FIX (purchase edit reset sale prices): an untouched line whose retail/
                    // wholesale entries are also unchanged must not push its OLD purchase-time
                    // rates back onto the product — that silently overwrote any newer price set
                    // on the Product screen every time an unrelated field (Paid, date) was edited.
                    val origForRates = diff?.unchangedOriginalByIndex?.get(index)
                    val ratesUntouched = origForRates != null &&
                        origForRates.retailRate == line.retailRate &&
                        origForRates.wholesaleRate == line.wholesaleRate
                    if ((line.retailRate > 0.0 || line.wholesaleRate > 0.0) && !ratesUntouched) {
                        val newSalePrice = if (line.retailRate > 0.0) line.retailRate else before.salePrice
                        val newWholesalePrice = if (line.wholesaleRate > 0.0) line.wholesaleRate else before.wholesalePrice
                        SyncQueueHelper.updateProductPrices(db, barcode, newSalePrice, newWholesalePrice)
                    }
                }
                // FIX (overpaid-bill → party balance gap): was `outstanding > 0`, so an
                // overpaid purchase (amountPaid > grandTotal) never touched the
                // supplier's balance — the excess just vanished instead of showing up
                // as a credit/advance (a negative balance, mirroring
                // CustomerPayableTest's advance case on the customer side). Any nonzero
                // difference now adjusts the balance: positive still records an amount
                // owed to the supplier, negative now records the overpayment as an
                // advance from the supplier.
                val outstanding = grandTotal - amountPaid
                if (supplierId != null && kotlin.math.abs(outstanding) > 0.009) {
                    SyncQueueHelper.adjustSupplierBalance(db, supplierId!!, outstanding)
                }
                // FIX (audit — editing a purchase that already had a bill-linked payment counted
                // that money twice in Payments/cash book): see RoomSaleRepository.saveSale().
                // amountPaid includes payments recorded later via "Make Payment > link to bill";
                // those keep their own payment + cash rows, so only the remainder is re-recorded.
                val linkedPaid = if (original != null) db.paymentDao().linkedPaidForBill(billNo) else 0.0
                val ownPaid = (amountPaid - linkedPaid).coerceAtLeast(0.0)
                if (supplierId != null && ownPaid > 0) {
                    // FIX (audit): createdAt used to default to "now" while the matching cash
                    // entry below uses the purchase's own (possibly back-dated) date, so the
                    // same money sat on two different days.
                    val payment = Payment(reference = billNo, partyType = "supplier", partyId = supplierId, amount = ownPaid, method = paymentMethod, note = if (original != null) "Purchase payment (edited)" else "Purchase payment", createdAt = purchaseDateMillis)
                    val paymentId = db.paymentDao().insert(payment)
                    SyncQueueHelper.enqueuePayment(db, payment.copy(id = paymentId))
                }
                // NEW (Split Payment / multiple payment methods): one cash-drawer
                // entry per (method, amount) pair instead of a single combined one,
                // so Reports/Day Book/Cash Register still split correctly by method
                // for a bill paid e.g. Rs 300 Cash + Rs 200 Bank. When `payments` is
                // empty (the single-method path, unchanged from before this feature)
                // this falls back to exactly the old single-entry behavior. Mirrors
                // RoomSaleRepository.saveSale's effectivePayments.
                val effectivePayments = if (payments.isNotEmpty()) payments
                    else if (amountPaid > 0.009) listOf(paymentMethod to amountPaid) else emptyList()
                var linkedToSkip = linkedPaid
                for ((payMethod, rawAmount) in effectivePayments) {
                    var amount = rawAmount
                    if (linkedToSkip > 0.009) {
                        val cut = minOf(linkedToSkip, amount)
                        amount -= cut
                        linkedToSkip -= cut
                    }
                    if (amount <= 0.009) continue
                    // FIX (back-dated purchase missing from Cash Register on that date):
                    // this always defaulted to CashTransaction's createdAt=now, so a
                    // purchase entered today but dated e.g. 29 Aug showed up in the
                    // Cash Register under TODAY's date instead of 29 Aug, and never
                    // appeared when checking the Cash Register for 29 Aug itself.
                    val cashTx = CashTransaction(type = "OUT", method = payMethod.lowercase(), amount = amount, reason = "Purchase", reference = billNo, createdAt = purchaseDateMillis)
                    val cashTxId = db.cashTransactionDao().insert(cashTx)
                    val savedCashTx = cashTx.copy(id = cashTxId)
                    SyncQueueHelper.enqueueCashTransaction(db, savedCashTx)
                }
            } // end db.withTransaction
            SyncQueueHelper.trigger(appContext)
            SavePurchaseResult.Success(billNo, original != null)
        } catch (e: IllegalStateException) {
            SavePurchaseResult.Error(e.message ?: "Save failed")
        }
    }
}
