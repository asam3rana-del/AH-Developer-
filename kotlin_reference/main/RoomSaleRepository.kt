package com.grocerypos.v11.data

import android.content.Context
import androidx.room.withTransaction
import com.grocerypos.v11.CashTransaction
import com.grocerypos.v11.Customer
import com.grocerypos.v11.DeviceTag
import com.grocerypos.v11.HeldBill
import com.grocerypos.v11.PosDatabase
import com.grocerypos.v11.Product
import com.grocerypos.v11.Sale
import com.grocerypos.v11.SaleItem
import com.grocerypos.v11.SyncQueueHelper
import com.grocerypos.v11.domain.SaleLine
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
 * Room-backed implementation of [SaleRepository] — the only place in the app
 * that should call SaleDao/ProductDao/CustomerDao/CashTransactionDao/HeldDao/
 * AppSettingDao for sale-related work. UseCases and SaleViewModel go through
 * the [SaleRepository] interface instead of touching PosDatabase directly,
 * and every write stays paired with its SyncQueueHelper call.
 *
 * (Split out from SaleRepository.kt, which now holds just the interface, so
 * SaveSaleUseCase/SaveQuickSaleUseCase/etc. can be unit tested against a
 * fake instead of this real Room-backed class — behavior here is unchanged.)
 *
 * [appContext] should be an application Context (not an Activity one) since
 * this repository is expected to outlive any single screen.
 */
class RoomSaleRepository(
    private val db: PosDatabase,
    private val appContext: Context
) : SaleRepository {

    override fun observeCustomers(): Flow<List<Customer>> = db.customerDao().all()

    override fun observeProducts(): Flow<List<Product>> = db.productDao().all()

    override suspend fun firmName(): String? = db.appSettingDao().get("shop_name")?.value

    override suspend fun findSale(invoice: String): Sale? = db.saleDao().findSale(invoice)

    override suspend fun itemsForInvoice(invoice: String): List<SaleItem> = db.saleDao().itemsForInvoice(invoice)

    override suspend fun customersSnapshot(): List<Customer> = db.customerDao().all().first()

    override suspend fun productsSnapshot(): List<Product> = db.productDao().all().first()

    override suspend fun topProductNames(sinceMillis: Long, uptoMillis: Long): List<String> = try {
        db.saleDao().topProducts(sinceMillis, uptoMillis).map { it.product }
    } catch (e: Exception) {
        emptyList()
    }

    override suspend fun createCustomer(name: String, phone: String, creditLimit: Double, openingBalance: Double): Customer {
        val newCustomer = Customer(name = name, phone = phone, creditLimit = creditLimit, openingBalance = openingBalance)
        val newId = db.customerDao().insert(newCustomer)
        val saved = newCustomer.copy(id = newId)
        SyncQueueHelper.enqueueCustomer(db, saved)
        SyncQueueHelper.trigger(appContext)
        return saved
    }

    override suspend fun heldBills(): List<HeldBill> = db.heldDao().allSaleHolds().first()

    override suspend fun holdBill(holdId: String, payload: String) {
        db.heldDao().hold(HeldBill(holdId = holdId, payload = payload))
    }

    override suspend fun deleteHeldBill(bill: HeldBill) {
        db.heldDao().delete(bill)
    }

    /**
     * Persists a new or edited sale: reverses the original's stock/balance
     * effect (edit only), re-validates stock against current levels, writes
     * the sale + items, decrements stock, adjusts the customer's balance, and
     * logs a cash-in transaction — all inside one Room transaction (Phase 1
     * data-safety fix: a crash/kill partway through can no longer leave
     * stock, the sale row, and the customer balance out of sync with each
     * other).
     */
    // FIX (false "Stock badal gaya hai" on unrelated sale edit): editing an existing
    // sale used to ALWAYS reverse every original line's stock and re-validate against
    // CURRENT stock — even when the edit only touched something unrelated (customer
    // name, date, payment method) and every item/qty/unit/rate was left untouched.
    // Since other sales/purchases keep moving the same product's stock in the
    // meantime, that reverse+re-check could fail for a bill that never actually
    // needed its stock touched at all — exactly what RoomPurchaseRepository's
    // itemsUnchanged()/skipStockTouch already guards against for purchases; this is
    // the same fix, mirrored here for sales.
    // FIX (regression guard): the comparison lives in StockTouchPolicy (saleEditDiff, now
    // per-line instead of whole-bill) so it is covered by a plain JVM unit test — see
    // StockTouchPolicyTest.
    override suspend fun saveSale(
        invoice: String,
        enteredCustomerName: String,
        existingCustomer: Customer?,
        saleType: String,
        method: String,
        saleDateMillis: Long,
        subtotal: Double,
        discount: Double,
        total: Double,
        paid: Double,
        lines: List<SaleLine>,
        original: Sale?,
        originalItems: List<SaleItem>,
        payments: List<Pair<String, Double>>
    ): SaleSaveResult {
        var customer = existingCustomer
        val stockWarnings = mutableListOf<String>()
        // FIX (sale edit silently changes stock of an UNTOUCHED item): was a single
        // whole-bill skipStockTouch boolean — see StockTouchPolicy.saleEditDiff()'s comment.
        // Now only lines the user actually added/changed (and only original rows that no
        // longer match) ever touch stock; a line left alone is skipped on both the reverse
        // and the re-apply side. A brand-new sale (original == null) has no diff, so every
        // line counts as "changed" and behaves exactly as before.
        val diff = if (original != null)
            com.grocerypos.v11.domain.StockTouchPolicy.saleEditDiff(lines, originalItems)
        else null
        fun lineNeedsStock(index: Int): Boolean = diff == null || index in diff.changedLineIndices

        db.withTransaction {
            if (original != null) {
                // Only the original rows that were actually changed/removed give their
                // stock back — untouched rows keep the stock they already deducted.
                diff?.itemsToReverse?.forEach { si ->
                    val p = db.productDao().find(si.barcode)
                    val smallestQty = si.smallestQty(p)
                    SyncQueueHelper.increaseProductStock(db, si.barcode, smallestQty, "SALE_EDIT_REVERSAL", invoice)
                }
                // FIX (overpaid-bill balance gap): was `> 0`, so an original bill that
                // had been OVERpaid (originalOutstanding negative — the excess had been
                // credited to the customer as an advance, see the forward-adjustment
                // below) never had that advance reversed on edit/delete, permanently
                // stranding it in the customer's balance. Reversing on any nonzero
                // outstanding (due OR advance) keeps this symmetric with the
                // forward-adjustment change below.
                val originalOutstanding = original.total - original.paid
                if (original.customerId != null && kotlin.math.abs(originalOutstanding) > 0.009) {
                    SyncQueueHelper.adjustCustomerBalance(db, original.customerId, -originalOutstanding)
                }
                // FIX (10/10 Priority #3 — edit without delete/re-add): line items
                // still get replaced wholesale (they carry no identity of their own
                // in the on-screen line model), but the SALE ROW ITSELF is no
                // longer deleted here — see the updateSale()/sale() branch below,
                // which UPDATEs this row in place instead of re-inserting it.
                // Deleting-then-reinserting the sale row used to hand it a brand
                // new `saleUid` (Sale's stable, sync-critical identity — see its
                // doc comment) on every single edit, silently defeating the whole
                // point of that field, and also silently reset `dueDate` (a Due
                // Date Reminder the user may have set on this bill) back to 0.
                db.saleDao().deleteItems(invoice)
                // FIX (deleted-payment-survives-sync bug): raw deleteByReference() deletes
                // locally but never enqueues the removal, so the old cash-transaction row
                // (about to be replaced below with the edited amount) stayed behind on
                // every other device/Firestore forever — see RoomPurchaseRepository.
                // deletePurchase()'s matching comment.
                SyncQueueHelper.deleteCashTransactionsByReference(db, invoice)
            }

            val productsByBarcode = mutableMapOf<String, Product>()
            for ((barcode, group) in lines.withIndex().groupBy({ it.value.barcode }, { it })) {
                val current = db.productDao().find(barcode)
                // Stock is only validated for lines that will actually deduct stock. An
                // untouched line whose product has since been deleted must not block an
                // unrelated edit — it is simply saved back as it was.
                val needsStock = group.any { lineNeedsStock(it.index) }
                if (current == null) {
                    if (needsStock) throw StockUnavailableException("Stock badal gaya hai — item nahi mila. Bill dobara check karen.")
                    continue
                }
                if (needsStock) {
                    val neededSmallest = group.filter { lineNeedsStock(it.index) }
                        .sumOf { current.toSmallestUnits(it.value.qty, it.value.unit) }
                    if (current.stock < neededSmallest) {
                        throw StockUnavailableException(
                            "Stock badal gaya hai — \"${current.name}\" mein sirf ${formatQty(current.stock.toDouble())} ${current.smallestUnitName()} available hai. Bill dobara check karen."
                        )
                    }
                }
                productsByBarcode[barcode] = current
            }

            if (customer == null && enteredCustomerName.isNotEmpty()) {
                val newCustomer = Customer(name = enteredCustomerName)
                val newId = db.customerDao().insert(newCustomer)
                customer = newCustomer.copy(id = newId)
                // FIX (sync): new customer created inline during Save Sale was never
                // enqueued — the SyncQueueHelper.trigger() call at the end of this
                // function now also pushes this along with the sale.
                SyncQueueHelper.enqueueCustomer(db, customer!!)
            }

            // FIX (Improvement Pack P6): reject a duplicate invoice for a brand-new
            // sale (original == null — an edit reuses its own existing invoice row
            // via updateSale() below, so it's naturally exempt from this check).
            // Without this, a re-submitted Save (double-tap, retry after a
            // timeout, etc.) would hit the sales table's plain @Insert and surface
            // a raw SQLiteConstraintException instead of a clear, catchable error.
            if (original == null && db.saleDao().findSale(invoice) != null) {
                throw DuplicateInvoiceException("Invoice number \"$invoice\" pehle se mojood hai. Dobara try karen.")
            }

            if (original != null) {
                // FIX (10/10 Priority #3): true in-place UPDATE, matched by the
                // `invoice` primary key — preserves `saleUid` and `dueDate` from
                // the original row (neither is part of what this screen edits)
                // instead of the old behavior of silently regenerating/wiping
                // them via delete+reinsert. `status` is likewise carried
                // forward (e.g. a "returned" sale stays "returned" through an
                // edit unless something else explicitly changes it).
                db.saleDao().updateSale(
                    Sale(
                        invoice = invoice,
                        customerId = customer?.id,
                        subtotal = subtotal,
                        discount = discount,
                        tax = 0.0,
                        total = total,
                        paid = paid,
                        paymentMethod = method.lowercase(),
                        saleType = saleType,
                        createdAt = saleDateMillis,
                        status = original.status,
                        updatedAt = System.currentTimeMillis(),
                        dirty = true,
                        dueDate = original.dueDate,
                        saleUid = original.saleUid
                    )
                )
            } else {
                db.saleDao().sale(
                    Sale(
                        invoice = invoice,
                        customerId = customer?.id,
                        subtotal = subtotal,
                        discount = discount,
                        tax = 0.0,
                        total = total,
                        paid = paid,
                        paymentMethod = method.lowercase(),
                        saleType = saleType,
                        createdAt = saleDateMillis
                    )
                )
            }

            val saleItems = lines.mapIndexed { index, it ->
                val lineProduct = productsByBarcode[it.barcode]
                // An untouched line keeps the conversionFactor frozen when it was originally
                // sold — re-stamping it with the CURRENT unit ladder would make a later
                // delete/return reverse a different quantity than was actually deducted.
                val unchangedOriginal = diff?.unchangedOriginalByIndex?.get(index)
                SaleItem(
                    invoice = invoice,
                    barcode = it.barcode,
                    product = it.itemName,
                    qty = it.qty,
                    unit = it.unit,
                    unitPrice = it.unitPrice,
                    cost = it.cost,
                    amount = it.amount,
                    // FIX (historical unit conversion bug): freeze this line's
                    // smallest-units-per-`unit` factor at sale time — see
                    // Database.kt's SaleItem.smallestQty()/conversionFactor comment.
                    conversionFactor = unchangedOriginal?.conversionFactor
                        ?: lineProduct?.smallestPerUnitOf(it.unit) ?: 0.0
                )
            }
            db.saleDao().items(saleItems)

            val savedSale = db.saleDao().findSale(invoice)!!
            SyncQueueHelper.enqueue(
                db, "sale", SyncQueueHelper.saleEntityId(savedSale), if (original != null) "update" else "create",
                SyncQueueHelper.saleJson(db, savedSale)
            )

            lines.forEachIndexed { index, line ->
                if (!lineNeedsStock(index)) return@forEachIndexed
                val product = productsByBarcode[line.barcode] ?: db.productDao().find(line.barcode)
                if (product == null) return@forEachIndexed
                val smallestQty = product.toSmallestUnits(line.qty, line.unit)
                val rowsAffected = SyncQueueHelper.decreaseProductStock(db, line.barcode, smallestQty, "SALE", invoice)
                if (rowsAffected == 0) {
                    stockWarnings.add("Warning: \"${line.itemName}\" ka stock update nahi ho saka — check karen.")
                }
            }

            // FIX (overpaid-bill → party balance gap): was `paid < total`, so an
            // overpaid bill (paid > total) never touched the customer's balance at
            // all — the extra amount just vanished instead of showing up as a
            // credit/advance (a negative balance — see CustomerPayableTest's
            // advancePaymentOnDaily_stillOffsetsTotal). Any nonzero difference now
            // adjusts the balance: positive total-paid still records a due, negative
            // total-paid now records the overpayment as an advance.
            if (customer != null && kotlin.math.abs(total - paid) > 0.009) {
                SyncQueueHelper.adjustCustomerBalance(db, customer!!.id, total - paid)
            }

            // NEW (Split Payment / multiple payment methods): one cash-drawer
            // entry per (method, amount) pair instead of a single combined one,
            // so Reports/Day Book/Cash Register still split correctly by method
            // for a bill paid e.g. Rs 300 Cash + Rs 200 Bank. When `payments` is
            // empty (the single-method path, unchanged from before this feature)
            // this falls back to exactly the old single-entry behavior.
            val effectivePayments = if (payments.isNotEmpty()) payments
                else if (paid > 0.009) listOf(method to paid) else emptyList()
            // FIX (audit — editing a bill that already had a bill-linked payment counted that
            // money twice in the cash book): the edit screen pre-fills `paid` with sale.paid,
            // which already includes payments recorded later via "Receive Payment > link to
            // bill". Those payments have their own cash entry (manual-...), so re-creating a
            // full-`paid` cash-in here doubled them. Skip that part.
            var linkedToSkip = if (original != null) db.paymentDao().linkedPaidForBill(invoice) else 0.0
            for ((payMethod, rawAmount) in effectivePayments) {
                var amount = rawAmount
                if (linkedToSkip > 0.009) {
                    val cut = minOf(linkedToSkip, amount)
                    amount -= cut
                    linkedToSkip -= cut
                }
                if (amount <= 0.009) continue
                // FIX (same bug as RoomPurchaseRepository.savePurchase): a back-dated
                // sale's cash-in entry defaulted to createdAt=now instead of the
                // sale's own date, so it showed under today in the Cash Register and
                // never appeared when checking the register for the actual sale date.
                val cashTx = CashTransaction(
                    type = "IN",
                    method = payMethod.lowercase(),
                    amount = amount,
                    reason = "Sale",
                    reference = invoice,
                    createdAt = saleDateMillis
                )
                val cashTxId = db.cashTransactionDao().insert(cashTx)
                val savedCashTx = cashTx.copy(id = cashTxId)
                SyncQueueHelper.enqueueCashTransaction(db, savedCashTx)
            }
        }

        SyncQueueHelper.trigger(appContext)

        // NEW (10/10 Priority #10 — Complete Audit Trail): who saved/edited this
        // bill and when. Logged after the transaction has committed successfully,
        // so a failed/rolled-back save (stock issue, duplicate invoice, etc.)
        // never produces a misleading audit entry.
        SyncQueueHelper.logAudit(
            db, appContext,
            action = if (original != null) "sale_edit" else "sale_create",
            reference = invoice,
            details = "total=$total paid=$paid method=$method customer=${customer?.name ?: enteredCustomerName}"
        )

        return SaleSaveResult(customer = customer, stockWarnings = stockWarnings)
    }

    // NEW (Split Payment): rebuilds the (method, amount) breakdown for an
    // invoice from its "Sale" cash-drawer entries, so the Split Payment dialog
    // can repopulate correctly when editing a bill that was originally paid
    // with more than one method. Ordered by id so rows come back in the same
    // order they were entered at checkout.
    override suspend fun paymentsForInvoice(invoice: String): List<Pair<String, Double>> =
        db.cashTransactionDao().allByReference(invoice)
            .filter { it.type == "IN" && it.reason == "Sale" }
            .sortedBy { it.id }
            .map { it.method to it.amount }

    /** Deletes a sale: reverses its stock and customer-balance effect and
     * removes the sale, its line items, and its cash transaction — all in one
     * transaction (Phase 1 data-safety fix, same as [saveSale]). */
    override suspend fun deleteSale(invoice: String, original: Sale?, originalItems: List<SaleItem>) {
        val sale = original ?: db.saleDao().findSale(invoice) ?: return
        val items = originalItems.ifEmpty { db.saleDao().itemsForInvoice(invoice) }

        db.withTransaction {
            items.forEach { si ->
                val p = db.productDao().find(si.barcode)
                val smallestQty = si.smallestQty(p)
                SyncQueueHelper.increaseProductStock(db, si.barcode, smallestQty, "SALE_REVERSAL", invoice)
            }
            // FIX (overpaid-bill balance gap): see saveSale()'s matching comment —
            // deleting an overpaid bill must reverse its advance credit too, not
            // just a due.
            val outstanding = sale.total - sale.paid
            if (sale.customerId != null && kotlin.math.abs(outstanding) > 0.009) {
                SyncQueueHelper.adjustCustomerBalance(db, sale.customerId, -outstanding)
            }
            db.saleDao().deleteItems(invoice)
            db.saleDao().deleteSale(invoice)
            // FIX (deleted-payment-survives-sync bug): raw deleteByReference() never
            // enqueued the removal — see RoomPurchaseRepository.deletePurchase()'s
            // matching comment.
            SyncQueueHelper.deleteCashTransactionsByReference(db, invoice)
            // FIX (audit): bill-linked payments would otherwise live on as orphan payments.
            SyncQueueHelper.voidLinkedPayments(db, invoice, null, "")
        }
        // FIX (deleted sale never disappears on other devices): this deleted the sale
        // row locally and triggered a sync push, but never actually enqueued a "sale"
        // delete entry — so every other device (and Firestore) kept the sale forever.
        // Mirrors RoomPurchaseRepository.deletePurchase()'s "purchase" delete enqueue.
        SyncQueueHelper.enqueueDelete(db, "sale", SyncQueueHelper.saleEntityId(sale))
        SyncQueueHelper.trigger(appContext)

        // NEW (10/10 Priority #10 — Complete Audit Trail).
        SyncQueueHelper.logAudit(
            db, appContext,
            action = "sale_delete",
            reference = invoice,
            details = "total=${sale.total} paid=${sale.paid} customerId=${sale.customerId ?: "walk-in"}"
        )
    }

    /** Persists a Quick Sale line (single-item, no draft/discount workflow).
     * FIX (atomicity): the whole write path (sale insert, item insert, stock
     * decrease, customer balance adjust, cash transaction) now runs inside a
     * single db.withTransaction {} — same pattern as [saveSale]/[deleteSale] —
     * so a mid-way crash can no longer leave the sale row saved without its
     * matching stock/balance/cash effects (or vice versa).
     */
    override suspend fun saveQuickSale(
        product: Product,
        qty: Double,
        price: Double,
        unit: String,
        customerName: String
    ): QuickSaleSaveResult {
        var resultInvoice = ""
        var resultIsCredit = false

        db.withTransaction {
            val current = db.productDao().find(product.barcode)
            if (current == null || current.stock < current.toSmallestUnits(qty, unit)) {
                throw StockUnavailableException("Stock badal gaya hai, dobara try karen")
            }
            // FIX (fraction control): reject a sale qty that would leave a fractional
            // smallest-unit qty for a non-fractional item (Piece/Dabbi/Bottle etc.).
            if (!current.isValidSmallestQty(current.toSmallestUnits(qty, unit))) {
                throw InvalidQuantityException("Qty ($qty $unit) whole ${current.smallestUnitName()} mein convert nahi hoti")
            }

            var customer: Customer? = null
            val isCredit = customerName.isNotEmpty()
            if (isCredit) {
                customer = db.customerDao().all().first().find { it.name.equals(customerName, ignoreCase = true) }
                if (customer == null) {
                    val newCustomer = Customer(name = customerName)
                    val newId = db.customerDao().insert(newCustomer)
                    customer = newCustomer.copy(id = newId)
                    // FIX (sync): new customer created inline during Quick Sale was
                    // never enqueued — the SyncQueueHelper.trigger() call later in this
                    // function will now also push this along with the sale.
                    SyncQueueHelper.enqueueCustomer(db, customer)
                }
            }

            val amount = qty * price
            val smallestQtyForCost = current.toSmallestUnits(qty, unit)
            val factor = current.smallestUnitFactor()
            val costPerSmallest = if (factor > 0) current.cost / factor else current.cost
            val lineCost = smallestQtyForCost * costPerSmallest

            val now = System.currentTimeMillis()
            val mmYY = SimpleDateFormat("MMyy", Locale.getDefault()).format(Date(now))
            // FIX (Improvement Pack P2): same collision-safety fix as SaleUseCases.kt's
            // main-sale-flow invoice generator — see the comment there.
            val invoice = mmYY + now.toString().takeLast(8) + "-" + DeviceTag.current

            val paid = if (isCredit) 0.0 else amount
            val method = if (isCredit) "credit" else "cash"

            // FIX (Improvement Pack P6): same duplicate-invoice guard as saveSale()
            // above — protects against a retried/double-tapped Quick Sale hitting
            // the sales table's plain @Insert with a raw SQLiteConstraintException.
            if (db.saleDao().findSale(invoice) != null) {
                throw DuplicateInvoiceException("Invoice number \"$invoice\" pehle se mojood hai. Dobara try karen.")
            }

            db.saleDao().sale(
                Sale(
                    invoice = invoice,
                    customerId = customer?.id,
                    subtotal = amount,
                    discount = 0.0,
                    tax = 0.0,
                    total = amount,
                    paid = paid,
                    paymentMethod = method,
                    saleType = "retail",
                    createdAt = now
                )
            )

            val saleItem = SaleItem(
                invoice = invoice,
                barcode = current.barcode,
                product = current.name,
                qty = qty,
                unit = unit,
                unitPrice = price,
                cost = lineCost,
                amount = amount,
                // FIX (historical unit conversion bug): see saveSale() above.
                conversionFactor = current.smallestPerUnitOf(unit)
            )
            db.saleDao().items(listOf(saleItem))

            SyncQueueHelper.decreaseProductStock(db, current.barcode, smallestQtyForCost, "SALE", invoice)

            if (isCredit && customer != null) {
                SyncQueueHelper.adjustCustomerBalance(db, customer.id, amount)
            }

            val savedSale = db.saleDao().findSale(invoice)!!
            SyncQueueHelper.enqueue(
                db, "sale", SyncQueueHelper.saleEntityId(savedSale), "create",
                SyncQueueHelper.saleJson(db, savedSale)
            )

            if (paid > 0) {
                val cashTx = CashTransaction(
                    type = "IN",
                    method = method,
                    amount = paid,
                    reason = "Quick Sale",
                    reference = invoice
                )
                val cashTxId = db.cashTransactionDao().insert(cashTx)
                val savedCashTx = cashTx.copy(id = cashTxId)
                SyncQueueHelper.enqueueCashTransaction(db, savedCashTx)
            }

            resultInvoice = invoice
            resultIsCredit = isCredit
        }

        SyncQueueHelper.trigger(appContext)

        // NEW (10/10 Priority #10 — Complete Audit Trail).
        SyncQueueHelper.logAudit(
            db, appContext,
            action = "quick_sale_create",
            reference = resultInvoice,
            details = "product=${product.name} qty=$qty credit=$resultIsCredit"
        )

        return QuickSaleSaveResult(invoice = resultInvoice, isCredit = resultIsCredit)
    }

    private fun formatQty(v: Double): String =
        if (v == v.toLong().toDouble()) v.toLong().toString() else v.toString()
}
