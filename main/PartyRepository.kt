package com.grocerypos.v11.data

import android.content.Context
import com.grocerypos.v11.Customer
import com.grocerypos.v11.PosDatabase
import com.grocerypos.v11.Purchase
import com.grocerypos.v11.Sale
import com.grocerypos.v11.Supplier
import com.grocerypos.v11.SyncQueueHelper
import kotlinx.coroutines.flow.Flow

/**
 * Repository for Customer/Supplier data, plus the sale/purchase history shown
 * on their ledgers (PartyActivity's "tap for history" dialogs).
 *
 * This is the only place in the app that should call CustomerDao/SupplierDao/
 * SaleDao/PurchaseDao for party-related work — UseCases and the ViewModel go
 * through here instead of touching PosDatabase directly, and every write stays
 * paired with the matching SyncQueueHelper call (exactly as PartyActivity used
 * to do inline), so a screen can never insert/update/delete a party and forget
 * to queue it for sync.
 *
 * [appContext] should be an application Context (not an Activity one) since
 * this repository is expected to outlive any single screen.
 */
class PartyRepository(
    private val db: PosDatabase,
    private val appContext: Context
) {

    fun observeCustomers(): Flow<List<Customer>> = db.customerDao().all()

    fun observeSuppliers(): Flow<List<Supplier>> = db.supplierDao().all()

    suspend fun saveCustomer(customer: Customer): Long {
        val newId = db.customerDao().insert(customer)
        SyncQueueHelper.enqueueCustomer(db, customer.copy(id = newId))
        SyncQueueHelper.trigger(appContext)
        return newId
    }

    suspend fun saveSupplier(supplier: Supplier): Long {
        val newId = db.supplierDao().insert(supplier)
        SyncQueueHelper.enqueueSupplier(db, supplier.copy(id = newId))
        SyncQueueHelper.trigger(appContext)
        return newId
    }

    suspend fun updateCustomer(customer: Customer) {
        db.customerDao().update(customer)
        SyncQueueHelper.enqueueCustomer(db, customer)
        SyncQueueHelper.trigger(appContext)
    }

    suspend fun updateSupplier(supplier: Supplier) {
        db.supplierDao().update(supplier)
        SyncQueueHelper.enqueueSupplier(db, supplier)
        SyncQueueHelper.trigger(appContext)
    }

    suspend fun deleteCustomer(customer: Customer) {
        db.customerDao().delete(customer)
        // Prefer the id already stamped on this row (matches whatever was actually
        // pushed, even pre-DeviceTag data) — only compute fresh if this customer
        // was somehow never synced at all. (Preserved from the original inline logic.)
        SyncQueueHelper.enqueue(
            db, "customer",
            customer.serverId ?: SyncQueueHelper.customerEntityId(customer),
            "delete", "{}"
        )
        SyncQueueHelper.trigger(appContext)
    }

    suspend fun deleteSupplier(supplier: Supplier) {
        db.supplierDao().delete(supplier)
        SyncQueueHelper.enqueue(
            db, "supplier",
            supplier.serverId ?: SyncQueueHelper.supplierEntityId(supplier),
            "delete", "{}"
        )
        SyncQueueHelper.trigger(appContext)
    }

    suspend fun salesByCustomer(customerId: Long): List<Sale> =
        db.saleDao().salesByCustomer(customerId)

    suspend fun purchasesBySupplier(supplierId: Long): List<Purchase> =
        db.purchaseDao().purchasesBySupplier(supplierId)

    // NEW (Recalculate Balances): `customer.balance` / `supplier.balance` are running
    // totals — nudged up/down by SyncQueueHelper.adjustCustomerBalance/
    // adjustSupplierBalance on every sale, purchase, payment, edit, return, and delete
    // (see those functions' comments) — rather than something computed fresh from the
    // visible transaction list each time it's shown. That makes them fast to read, but
    // it also means any adjustment that ever fired without a matching real transaction
    // (a duplicate bill saved and deleted before the double-entry guard existed, an
    // interrupted multi-device sync, etc.) leaves a permanent drift that the ledger
    // itself never shows — the party's "You'll Give/Get" stops matching the sum of
    // their own bills. This recomputes each party's balance from scratch, straight
    // from their actual active (non-returned) bills and recorded payments, and nudges
    // the stored field back in line with only the *difference* — via the same
    // adjustCustomerBalance/adjustSupplierBalance path every other write already
    // uses — so the correction is a normal, sync-safe increment like any other,
    // not a raw overwrite that could clobber another device's not-yet-synced change.
    // [dryRun] = true (ADDED, audit): only COUNT the parties whose stored balance has drifted from
    // their bills/payments, without writing or queuing anything — used by the Balance Sheet's
    // data-check line.
    // PERMANENT FIX (balance drift — "paid supplier still shows You'll Get"): the
    // stored `customer.balance`/`supplier.balance` fields are only ever nudged by
    // SyncQueueHelper.adjustCustomerBalance/adjustSupplierBalance — they are NOT the
    // source of truth, the actual bills + standalone payments are. Any place that
    // ever fired one of those adjust calls without a perfectly matching real
    // transaction (an orphaned/duplicate payment row, an interrupted sync, an old
    // build's bug) leaves the stored field permanently wrong, with nothing to ever
    // correct it again on its own — that's exactly the "fully paid supplier still
    // shows You'll Get" bug.
    //
    // trueCustomerBalance()/trueSupplierBalance() below are the single, canonical
    // definition of "what this party actually owes/is owed", computed FRESH from
    // their real bills + payments every time — never from the stored field. Every
    // screen that shows a party's closing balance (Party Dashboard, Parties list,
    // Party Transaction screen, Home summary) should call one of these (or the
    // liveCustomerBalances()/liveSupplierBalances() batch versions) instead of
    // reading `.balance` directly, so what's on screen can never drift: there is no
    // stored number to go stale, it's recomputed from the ledger on every load.
    //
    // The stored `.balance` field itself is kept (adjustCustomerBalance/
    // adjustSupplierBalance still update it) purely because the Firestore
    // increment_balance sync path depends on it for conflict-safe multi-device
    // merging — recalculateBalances() below still uses it to detect and correct
    // drift for that stored copy, which keeps sync-merge math and any older code
    // path that still reads `.balance` consistent too. But no on-screen balance
    // should depend on that stored copy being right anymore.
    private suspend fun trueCustomerBalance(customerId: Long): Double {
        val allSales = db.saleDao().salesByCustomer(customerId)
        val sales = allSales.filter { it.status != "returned" }
        // FIX (Fix Balances double-counting cash bills — mirrors the supplier/
        // purchase side below, kept symmetric in case a sale-side payment row
        // is ever added the way purchases already have one): if a payment
        // row's `reference` ever matches one of this customer's own invoice
        // numbers, it means that amount is already reflected in `sale.paid`
        // (and therefore in `sales.sumOf{total-paid}`) — subtracting it again
        // via the payments sum would double-count it. Only genuinely
        // standalone payments — the "Receive/Make Payment" ones, whose
        // reference is a unique timestamp, never a real invoice number —
        // should reduce the balance here.
        // FIX (returned/deleted bill still "owns" its payment — balance flips to
        // an unexplained "You'll Get/Give"): this set used to come from `sales`
        // (already filtered to non-returned), so a RETURNED sale's invoice fell
        // out of it. Its bill-linked payment (billReference == that invoice) then
        // failed the "already inside sale.paid" check below and got subtracted a
        // SECOND time, on top of `sale.paid` already covering it — the exact bug
        // PartyTransactionActivity.loadTransactions()'s own "You'll Get/Give" card
        // never had, because it only checks `billReference.isBlank()` with no
        // existence/status requirement. Now built from the UNFILTERED list so a
        // returned (or since-deleted-then-recreated-with-the-same-invoice) sale's
        // invoice still counts as "known", matching that already-correct logic.
        val saleInvoices = allSales.map { it.invoice }.toHashSet()
        // FIX (audit — "Fix Balances" corrupted parties that had a bill-linked payment): a
        // payment linked to a bill (billReference) is already inside that bill's `paid`
        // (applyBillPaidDelta), so it must not be subtracted a second time here.
        val payments = db.paymentDao().listByParty("customer", customerId)
            .filter { it.reference !in saleInvoices && !(it.billReference.isNotBlank() && it.billReference in saleInvoices) }
        return sales.sumOf { it.total - it.paid } - payments.sumOf { it.amount }
    }

    private suspend fun trueSupplierBalance(supplierId: Long): Double {
        val allPurchases = db.purchaseDao().purchasesBySupplier(supplierId)
        val purchases = allPurchases.filter { it.status != "returned" }
        // FIX (Fix Balances double-counting cash bills): same reasoning as the
        // customer/sale side above — RoomPurchaseRepository.savePurchase()
        // inserts a "Purchase payment" row for whatever was paid at purchase
        // time (reference == that purchase's billNo), on top of already
        // setting `purchase.paid`. Exclude those bill-embedded rows so only
        // standalone payments (unique timestamped reference, never a real
        // billNo) get subtracted here.
        // FIX (returned/deleted bill still "owns" its payment — see the matching
        // comment on the customer side above): built from the UNFILTERED purchase
        // list now, so a returned purchase's billNo still "counts" for this check
        // instead of silently dropping out and causing its bill-linked payment to
        // get subtracted a second time (balance swings into an unexplained
        // "You'll Get" exactly equal to that payment's amount).
        val billNos = allPurchases.map { it.billNo }.toHashSet()
        // FIX (audit): same as the customer side — skip bill-linked payments.
        val payments = db.paymentDao().listByParty("supplier", supplierId)
            .filter { it.reference !in billNos && !(it.billReference.isNotBlank() && it.billReference in billNos) }
        return purchases.sumOf { it.total - it.paid } - payments.sumOf { it.amount }
    }

    /** Every customer's live "running" balance (excludes openingBalance/stuckBalance —
     * add those in at the call site, same as `.balance` used to be combined). Computed
     * fresh from bills+payments, never from the stored field — see the big comment above. */
    suspend fun liveCustomerBalances(): Map<Long, Double> =
        db.customerDao().allList().associate { it.id to trueCustomerBalance(it.id) }

    /** Every supplier's live "running" balance — see [liveCustomerBalances]. */
    suspend fun liveSupplierBalances(): Map<Long, Double> =
        db.supplierDao().allList().associate { it.id to trueSupplierBalance(it.id) }

    // ADDED (balance drift — Purchase/Sale entry screens): a cheap single-party version
    // of the above, for screens that only need one party's live balance right now (e.g.
    // the running "Party balance" shown while filling out a Purchase/Sale bill) instead
    // of recomputing every party in the shop just to read one number. Same source of
    // truth as liveSupplierBalances()/liveCustomerBalances() — never the stored
    // `.balance` field — so this can never show a different figure than the Dashboard
    // or Party screens for the same party.
    suspend fun liveSupplierBalance(supplierId: Long): Double = trueSupplierBalance(supplierId)

    /** Single-customer version of [liveSupplierBalance] — see that comment. */
    suspend fun liveCustomerBalance(customerId: Long): Double = trueCustomerBalance(customerId)

    suspend fun recalculateBalances(dryRun: Boolean = false): RecalcResult {
        var customersFixed = 0
        var suppliersFixed = 0
        val customers = db.customerDao().allList()
        for (c in customers) {
            val trueBalance = trueCustomerBalance(c.id)
            val delta = trueBalance - c.balance
            if (Math.abs(delta) > 0.009) {
                if (!dryRun) SyncQueueHelper.adjustCustomerBalance(db, c.id, delta)
                customersFixed++
            }
        }
        val suppliers = db.supplierDao().allList()
        for (s in suppliers) {
            val trueBalance = trueSupplierBalance(s.id)
            val delta = trueBalance - s.balance
            if (Math.abs(delta) > 0.009) {
                if (!dryRun) SyncQueueHelper.adjustSupplierBalance(db, s.id, delta)
                suppliersFixed++
            }
        }
        if (!dryRun && (customersFixed > 0 || suppliersFixed > 0)) SyncQueueHelper.trigger(appContext)
        return RecalcResult(customersFixed, suppliersFixed)
    }

    // NEW (Merge Duplicate Parties): fixes the multi-device "two devices created
    // the same customer/supplier independently before their first sync" problem —
    // e.g. "Arfan Brothers" existing twice with two separate purchase histories
    // and two separate running balances, neither of which is wrong on its own,
    // they just never got combined into one party. Groups customers/suppliers by
    // exact name (trimmed, case-insensitive), and for every group with more than
    // one member: keeps the lowest-id (earliest-created) row, re-points every
    // other member's sales/purchases/payments onto it, folds the other member's
    // openingBalance into the keeper, deletes the other member, and enqueues sync
    // for every one of those changes so the merge itself propagates to other
    // devices instead of only fixing this one. `balance` (as opposed to
    // openingBalance) is deliberately NOT hand-adjusted here — recalculateBalances()
    // is called at the end, once every bill/payment has been re-pointed, so the
    // keeper's balance is simply recomputed from its now-complete bill/payment
    // history, the same safe path used for ordinary balance drift.
    suspend fun mergeDuplicateParties(): MergeResult {
        var customersMerged = 0
        var suppliersMerged = 0
        val now = System.currentTimeMillis()

        val customerGroups = db.customerDao().allList().groupBy { it.name.trim().lowercase() }
        for (group in customerGroups.values) {
            if (group.size < 2) continue
            val sorted = group.sortedBy { it.id }
            var keeper = sorted.first()
            for (dup in sorted.drop(1)) {
                for (sale in db.saleDao().salesByCustomer(dup.id)) {
                    val updated = sale.copy(customerId = keeper.id, dirty = true)
                    db.saleDao().updateSale(updated)
                    SyncQueueHelper.enqueue(db, "sale", SyncQueueHelper.saleEntityId(updated), "update", SyncQueueHelper.saleJson(db, updated))
                }
                for (payment in db.paymentDao().listByParty("customer", dup.id)) {
                    val updated = payment.copy(partyId = keeper.id, dirty = true, updatedAt = now)
                    db.paymentDao().update(updated)
                    SyncQueueHelper.enqueuePayment(db, updated)
                }
                // NEW (Stuck Balance): a duplicate's stuck amount must not be lost in the merge —
                // it is summed into the keeper exactly like openingBalance.
                if (dup.openingBalance != 0.0 || dup.stuckBalance != 0.0) {
                    keeper = keeper.copy(
                        openingBalance = keeper.openingBalance + dup.openingBalance,
                        stuckBalance = keeper.stuckBalance + dup.stuckBalance,
                        dirty = true
                    )
                    db.customerDao().update(keeper)
                    SyncQueueHelper.enqueueCustomer(db, keeper)
                }
                db.customerDao().delete(dup)
                SyncQueueHelper.enqueue(db, "customer", dup.serverId ?: SyncQueueHelper.customerEntityId(dup), "delete", "{}")
                customersMerged++
            }
        }

        val supplierGroups = db.supplierDao().allList().groupBy { it.name.trim().lowercase() }
        for (group in supplierGroups.values) {
            if (group.size < 2) continue
            val sorted = group.sortedBy { it.id }
            var keeper = sorted.first()
            for (dup in sorted.drop(1)) {
                for (purchase in db.purchaseDao().purchasesBySupplier(dup.id)) {
                    val updated = purchase.copy(supplierId = keeper.id, dirty = true)
                    db.purchaseDao().updatePurchase(updated)
                    SyncQueueHelper.enqueue(db, "purchase", SyncQueueHelper.purchaseEntityId(updated), "update", SyncQueueHelper.purchaseJson(db, updated))
                }
                for (payment in db.paymentDao().listByParty("supplier", dup.id)) {
                    val updated = payment.copy(partyId = keeper.id, dirty = true, updatedAt = now)
                    db.paymentDao().update(updated)
                    SyncQueueHelper.enqueuePayment(db, updated)
                }
                if (dup.openingBalance != 0.0) {
                    keeper = keeper.copy(openingBalance = keeper.openingBalance + dup.openingBalance, dirty = true)
                    db.supplierDao().update(keeper)
                    SyncQueueHelper.enqueueSupplier(db, keeper)
                }
                db.supplierDao().delete(dup)
                SyncQueueHelper.enqueue(db, "supplier", dup.serverId ?: SyncQueueHelper.supplierEntityId(dup), "delete", "{}")
                suppliersMerged++
            }
        }

        if (customersMerged > 0 || suppliersMerged > 0) {
            recalculateBalances()
            SyncQueueHelper.trigger(appContext)
        }
        return MergeResult(customersMerged, suppliersMerged)
    }

    // NEW (Cleanup Duplicate Payments): finds the stray "orphan" payment rows left behind
    // by the duplicate-payment-on-sync bug (see SyncQueueHelper.deletePaymentsByReference's
    // comment for the full story) — every purchase/sale edit before that fix deleted the old
    // payment on this device only, so a second, third, etc. edit of the same bill kept adding
    // one more payment row that the party's balance counted as real money paid, without ever
    // removing the stale ones. A bill should only ever have ONE payment row tied to it — a
    // manual "Receive/Make Payment" always gets its own unique timestamped reference (see
    // PartyTransactionActivity.savePayment()), so it can never collide here — so grouping
    // every payment by (partyType, partyId, reference) and keeping only groups with more than
    // one row finds exactly the stuck duplicates and nothing else. Within a group, the most
    // recently updated/created row is the one that reflects the bill's current state; every
    // other row in the group is the leftover this cleans up.
    suspend fun findDuplicatePayments(): List<DuplicatePaymentGroup> {
        val customerNames = db.customerDao().allList().associate { it.id to it.name }
        val supplierNames = db.supplierDao().allList().associate { it.id to it.name }
        return db.paymentDao().allRaw()
            .filter { it.partyId != null }
            .groupBy { Triple(it.partyType, it.partyId, it.reference) }
            .values
            .filter { it.size > 1 }
            .map { group ->
                val sorted = group.sortedWith(compareBy({ it.updatedAt }, { it.createdAt }, { it.id }))
                val keep = sorted.last()
                val remove = sorted.dropLast(1)
                val first = group.first()
                val partyName = (if (first.partyType == "customer") customerNames[first.partyId] else supplierNames[first.partyId])
                    ?: "#${first.partyId}"
                DuplicatePaymentGroup(
                    partyType = first.partyType,
                    partyId = first.partyId,
                    partyName = partyName,
                    reference = first.reference,
                    keep = keep,
                    remove = remove
                )
            }
            .sortedByDescending { g -> g.remove.sumOf { it.amount } }
    }

    // NEW (Cleanup Duplicate Payments): removes exactly the stale rows [findDuplicatePayments]
    // found (keeping the one correct payment per bill) via SyncQueueHelper.deletePayment() so
    // the removal propagates to other devices/the server too, then recomputes every balance —
    // the same recalculateBalances() used elsewhere — since those duplicate rows are what was
    // inflating payments.sumOf{amount} and throwing the party's balance off in the first place.
    suspend fun cleanupDuplicatePayments(groups: List<DuplicatePaymentGroup>? = null): CleanupPaymentsResult {
        val target = groups ?: findDuplicatePayments()
        var removed = 0
        for (group in target) {
            for (payment in group.remove) {
                SyncQueueHelper.deletePayment(db, payment)
                removed++
            }
        }
        val recalc = if (removed > 0) recalculateBalances() else RecalcResult(0, 0)
        return CleanupPaymentsResult(removed, recalc)
    }

    // NEW (Cleanup Orphaned Payments): a different leftover than the duplicate-payment
    // case above. Every Purchase/Sale save inserts its own "Purchase payment"/"Sale
    // payment" row for whatever was paid at bill time, with reference == that bill's
    // billNo/invoice (see RoomPurchaseRepository.savePurchase()/RoomSaleRepository.
    // saveSale()) — a manual "Receive/Make Payment" always gets a unique
    // "manual-..." reference instead (see PartyTransactionActivity.savePayment()), so
    // it can never be mistaken for one of these. deletePurchase()/deleteSale() now
    // correctly delete this row along with the bill (see
    // SyncQueueHelper.deletePaymentsByReference's comment on the sync side of that
    // fix), but a bill deleted by an older build before that fix only removed the
    // bill itself — its bill-embedded payment row was left behind, pointing at a
    // billNo/invoice that no longer exists. recalculateBalances() still counts that
    // orphan as a real standalone payment (its reference isn't a *duplicate* of any
    // current bill, so findDuplicatePayments() above never catches it either) and
    // subtracts it — which is exactly backwards for a supplier/customer that was
    // paid in full and should net to zero: it shows up "You'll Get" for the exact
    // amount of a purchase/sale that isn't there anymore. This finds every payment
    // whose reference isn't the "manual-" pattern and doesn't match any existing
    // bill, and removes it the same sync-safe way as cleanupDuplicatePayments()
    // above, then recalculates.
    suspend fun findOrphanedPayments(): List<com.grocerypos.v11.Payment> =
        db.paymentDao().allRaw().filter { p ->
            !p.reference.startsWith("manual-") && when (p.partyType) {
                "supplier" -> db.purchaseDao().findPurchase(p.reference) == null
                "customer" -> db.saleDao().findSale(p.reference) == null
                else -> false
            }
        }

    suspend fun cleanupOrphanedPayments(payments: List<com.grocerypos.v11.Payment>? = null): CleanupPaymentsResult {
        val target = payments ?: findOrphanedPayments()
        for (payment in target) SyncQueueHelper.deletePayment(db, payment)
        val recalc = if (target.isNotEmpty()) recalculateBalances() else RecalcResult(0, 0)
        return CleanupPaymentsResult(target.size, recalc)
    }
}

/** Result of [PartyRepository.recalculateBalances] — how many customers/suppliers
 * actually had a drifted balance corrected (0/0 means everything already matched). */
data class RecalcResult(val customersFixed: Int, val suppliersFixed: Int)

/** Result of [PartyRepository.mergeDuplicateParties] — how many duplicate
 * customer/supplier ROWS were merged away (a group of 3 same-name suppliers
 * counts as 2 merged, since one survives as the keeper). 0/0 means no
 * same-name duplicates were found. */
data class MergeResult(val customersMerged: Int, val suppliersMerged: Int)

/** One bill's worth of stuck duplicate payments, as found by
 * [PartyRepository.findDuplicatePayments] — [keep] is the row judged current/correct,
 * [remove] is everything else tied to the same party+bill that
 * [PartyRepository.cleanupDuplicatePayments] will delete. */
data class DuplicatePaymentGroup(
    val partyType: String,
    val partyId: Long?,
    val partyName: String,
    val reference: String,
    val keep: com.grocerypos.v11.Payment,
    val remove: List<com.grocerypos.v11.Payment>
)

/** Result of [PartyRepository.cleanupDuplicatePayments] — how many stray duplicate
 * payment rows were deleted, plus the balance recalculation that followed (0 removed
 * means no duplicates were found, and [recalc] is untouched in that case). */
data class CleanupPaymentsResult(val paymentsRemoved: Int, val recalc: RecalcResult)
