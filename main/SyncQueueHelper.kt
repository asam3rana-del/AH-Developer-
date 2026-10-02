package com.grocerypos.v11

import android.content.Context
import com.google.gson.Gson
import com.grocerypos.v11.sync.SyncWorker

// FIX (Phase 3 - Online): every ...Json() builder below stamps its payload with
// "branchId" (BranchConfigStore.current) before it's pushed to Firestore, so records from
// different branches can be told apart / filtered on pull (see SyncApi.kt).
//
// FIX (sync bug #2): previously NOTHING called db.syncQueueDao().enqueue(...) anywhere
// in the app, so sync_queue stayed empty forever no matter how many sales/customers/etc.
// were created. Below, every ...Json() builder now has a matching enqueueX() function
// that builds the JSON AND inserts the sync_queue row AND triggers a sync — in one call.
//
// Call the relevant enqueueX() right after each successful DAO insert/update, e.g.:
//
//     val newId = db.customerDao().insert(customer)
//     SyncQueueHelper.enqueueCustomer(db, customer.copy(id = newId))
//
//     db.saleDao().sale(sale)
//     db.saleDao().items(saleItems)
//     SyncQueueHelper.enqueueSale(db, sale, saleItems.size)
//
// Do this at every insert/update call site for: customers, suppliers, products, sales,
// purchases, payments, expenses, cash_transactions, users. Deletes should call
// SyncQueueHelper.enqueueDelete(db, entityType, entityId) instead.
object SyncQueueHelper {

    private val gson = Gson()

    // FIX (multi-device sync bug): customer/supplier/expense/cash_transaction/payment
    // IDs are built from a LOCAL autoincrement id, which two different devices can and
    // will generate identically (e.g. both devices' first customer is local id=1) —
    // without DeviceTag mixed in, one device's Firestore doc would silently overwrite
    // the other's. Sale/Purchase/Product/User don't need this: their keys (invoice,
    // billNo, barcode, username) are already naturally unique, not local-id-based.
    fun customerEntityId(c: Customer) = "customer:${DeviceTag.current}-${c.id}"
    fun supplierEntityId(s: Supplier) = "supplier:${DeviceTag.current}-${s.id}"
    fun productEntityId(p: Product) = p.barcode
    fun saleEntityId(sale: Sale) = "sale:${sale.invoice}"
    fun purchaseEntityId(purchase: Purchase) = "purchase:${purchase.billNo}"
    // NOTE: payment.reference is the invoice / billNo it belongs to — NOT unique on its
    // own, since a single invoice can receive multiple separate payments (e.g. a
    // customer pays 5,000 then later 3,000 against the same invoice). payment.id (a
    // local autoincrement, like customer/supplier/expense/cash_transaction) plus
    // DeviceTag is what's actually unique — see FIX (payment sync incomplete) at
    // paymentJson() below.
    // FIX (audit — foreign-origin rows re-stamped on edit => duplicates): these three used to
    // ALWAYS rebuild the id from THIS device's tag + THIS device's local autoincrement id,
    // even for a row that was pulled from another device (whose serverId is that other
    // device's id). Editing such a row (or a "force resync") therefore re-stamped it with a
    // brand-new id and pushed it as a NEW Firestore document, while the original document
    // stayed alive — the next pull then inserted the original again => duplicate
    // payment / expense / cash entry on every device. A row that already carries a serverId
    // keeps it; only a never-synced local row falls back to the device-tag id.
    fun paymentEntityId(payment: Payment) =
        payment.serverId?.takeIf { it.isNotBlank() } ?: "payment:${DeviceTag.current}-${payment.id}"
    fun expenseEntityId(expense: Expense) =
        expense.serverId?.takeIf { it.isNotBlank() } ?: "expense:${DeviceTag.current}-${expense.id}"
    fun cashTransactionEntityId(t: CashTransaction) =
        t.serverId?.takeIf { it.isNotBlank() } ?: "cash_transaction:${DeviceTag.current}-${t.id}"
    fun userEntityId(u: User) = "user:${u.username}"
    fun zakatYearEntityId(y: ZakatYear) = "zakat_year:${DeviceTag.current}-${y.id}"
    fun zakatPaymentEntityId(p: ZakatPayment) = "zakat_payment:${DeviceTag.current}-${p.id}"
    fun returnEntityId(r: ReturnLine) = "return:${DeviceTag.current}-${r.id}"
    // NEW (Stock/Cost History sync): same local-autoincrement-id shape as
    // returnEntityId above — a stock_movements row's id is per-device, so DeviceTag
    // keeps two devices' movement #7 from colliding on the same Firestore doc.
    fun stockMovementEntityId(m: StockMovement) = "stock_movement:${DeviceTag.current}-${m.id}"
    // NEW (Cash Register sync): date IS the primary key locally (like Product.barcode /
    // UnitType.name / Category.name above), so the Firestore doc id is just the date
    // string directly — no DeviceTag mixed in. Deliberate: a till is meant to be ONE
    // shared register per branch per day (open on one device, closed from another,
    // e.g. owner's phone vs. the counter tablet), not a separate per-device count —
    // if two devices ever DO open a register for the same date, the later push wins,
    // same last-write-wins tradeoff Units/Categories already accept for their
    // name-keyed docs. (This replaces the "local-only, per-device — CashRegister has
    // no serverId/dirty/updatedAt fields" design from CashRegisterActivity's original
    // header comment; see that comment for the earlier reasoning.)
    fun cashRegisterEntityId(r: CashRegister) = r.date
    // App Settings: only a whitelisted subset of keys are shop-wide identity (name,
    // phone, address, receipt footer, currency, tax rate) that every branch device
    // should share. Everything else in this table — login_method, printer_name/mac/
    // type/width, admin_seeded, last_username — is deliberately device-specific and
    // must NEVER sync (a paired Bluetooth printer or last-logged-in user on one
    // device means nothing, or actively misleads, on another).
    val SYNCED_APP_SETTING_KEYS = setOf(
        "shop_name", "shop_phone", "shop_address", "receipt_footer", "currency", "tax_percent"
    )
    fun appSettingEntityId(s: AppSetting) = s.key
    // Units/Categories: name IS the primary key locally (like Product.barcode), so
    // the Firestore doc id can just be the name directly — no DeviceTag needed since
    // there's no local-autoincrement collision risk (see the comment above).
    fun unitEntityId(u: UnitType) = u.name
    fun categoryEntityId(c: Category) = c.name

    // NEW (Shell Ledger sync): same serverId-preferred-else-device-tag shape as
    // paymentEntityId/expenseEntityId above — a shell_customers/shell_transactions/
    // shop_empty_shell_log row's id is a local autoincrement, so two devices'
    // "first shell customer" would otherwise collide.
    fun shellCustomerEntityId(c: ShellCustomer) =
        c.serverId?.takeIf { it.isNotBlank() } ?: "shell_customer:${DeviceTag.current}-${c.id}"
    fun shellTransactionEntityId(t: ShellTransaction) =
        t.serverId?.takeIf { it.isNotBlank() } ?: "shell_transaction:${DeviceTag.current}-${t.id}"
    fun shopEmptyShellLogEntityId(l: ShopEmptyShellLog) =
        l.serverId?.takeIf { it.isNotBlank() } ?: "shop_empty_shell_log:${DeviceTag.current}-${l.id}"

    suspend fun enqueue(db: PosDatabase, entityType: String, entityId: String, operation: String, payloadJson: String) {
        db.syncQueueDao().enqueue(
            SyncQueueEntry(
                entityType = entityType,
                entityId = entityId,
                operation = operation,
                payloadJson = payloadJson
            )
        )
    }

    // FIX (RESOURCE_EXHAUSTED retry storm): this is called after essentially every
    // save in the app (56 call sites — a payment, a cash entry, a party edit, a
    // purchase...). It used to call syncNowOnce(), which enqueues with
    // ExistingWorkPolicy.REPLACE — so doing a second thing (e.g. recording a cash
    // payment) while the sync from the FIRST thing was still mid-push cancelled it
    // and restarted from the same head-of-queue rows. None of those cancelled
    // attempts ever reached markSynced()/markFailed(), so a burst of ordinary,
    // quick actions (or two devices saving around the same time) could re-push the
    // same few rows over and over, burning the Firestore daily write quota and
    // producing repeated "RESOURCE_EXHAUSTED" entries in Sync History for the same
    // 2-3 rows. triggerNow() enqueues with KEEP instead — if a sync is already
    // running, this is a no-op and lets it finish naturally; the next save's
    // trigger() call (or the periodic worker) picks up whatever's still queued.
    // Only the user's own explicit "Sync Now" tap in Settings should force a
    // cancel-and-restart — that still goes straight to syncNowOnce() (REPLACE).
    fun trigger(context: Context) {
        SyncWorker.triggerNow(context)
    }

    // NEW (10/10 Priority #10 — Complete Audit Trail): a single shared writer for
    // the existing `audit` table (previously only written to by UserManagementActivity's
    // password-reset flow and SyncApi's conflict/failure logging). Every business
    // mutation that should be traceable — who did it, on what, when, with what
    // details — should call this instead of hand-rolling its own Audit(...) insert,
    // so the shape/username-lookup stays consistent everywhere.
    //
    // Reads the logged-in username the same way UserManagementActivity already
    // does (SharedPreferences "session"/"username"), defaulting to "unknown"
    // rather than crashing if no session is present (e.g. called from a background
    // sync path). Wrapped in runCatching so a logging failure can never abort the
    // business transaction it's describing.
    suspend fun logAudit(db: PosDatabase, context: Context, action: String, reference: String, details: String) {
        val username = context.getSharedPreferences("session", Context.MODE_PRIVATE)
            .getString("username", null) ?: "unknown"
        runCatching {
            db.auditDao().insert(
                Audit(username = username, action = action, reference = reference, details = details)
            )
        }
    }

    // ---------- One-call helpers: build payload + enqueue ----------
    // (context is optional — pass it if you want the sync to fire immediately instead
    // of waiting for the next periodic run; omit it to just queue the row.)

    // FIX (self-duplication on pull): entityId is deterministic (built purely from the
    // local row's own id), but the local row's own `serverId` column was never being
    // set to that same value — so on the very next pull, this device wouldn't recognize
    // its own just-pushed record (findByServerId would find nothing) and would insert
    // it again as a brand-new "pulled" row, duplicating it locally. Stamping serverId
    // onto the local row immediately (no need to wait for the actual network push,
    // since the id is computed locally and doesn't depend on the server) fixes this.
    suspend fun enqueueCustomer(db: PosDatabase, c: Customer, context: Context? = null) {
        val id = customerEntityId(c)
        if (c.serverId != id) db.customerDao().update(c.copy(serverId = id))
        enqueue(db, "customer", id, "upsert", customerJson(c))
        context?.let { trigger(it) }
    }

    suspend fun enqueueSupplier(db: PosDatabase, s: Supplier, context: Context? = null) {
        val id = supplierEntityId(s)
        if (s.serverId != id) db.supplierDao().update(s.copy(serverId = id))
        enqueue(db, "supplier", id, "upsert", supplierJson(s))
        context?.let { trigger(it) }
    }

    suspend fun enqueueProduct(db: PosDatabase, p: Product, context: Context? = null) {
        enqueue(db, "product", productEntityId(p), "upsert", productJson(p))
        context?.let { trigger(it) }
    }

    // ---------- Balance / stock adjustment wrappers ----------
    // FIX (sync bug #3 — the big one): db.customerDao().addBalance()/supplierDao()
    // .addBalance()/productDao().decrease()/increase()/decreaseForce() are raw SQL
    // UPDATE queries used everywhere a sale/purchase/return/edit/delete changes a
    // balance or stock level. NONE of these ever enqueued a sync row, so a customer's
    // running balance and a product's running stock — the two numbers that matter most
    // for two devices sharing one register — never actually synced, even though the
    // customer/supplier/product record itself looked like it was "syncing" whenever it
    // was first created. Use these wrappers instead of calling the DAO methods
    // directly, wherever a balance or stock change should be visible on other devices.
    //
    // FIX (conflict-safe sync): these used to push the ABSOLUTE resulting balance/stock
    // as a plain snapshot (via enqueueCustomer/enqueueSupplier/enqueueProduct). That's
    // fine when only one device ever touches a given customer/product between syncs —
    // but if TWO devices are offline at the same time and both sell from the same
    // product (or both adjust the same customer's balance), whichever device's snapshot
    // happens to push LAST silently overwrites the other's — the earlier device's sale
    // effect on stock/balance is lost even though the sale record itself is safe.
    // Now these send the DELTA as a Firestore FieldValue.increment() operation instead
    // (see SyncApi.push()'s "increment_stock"/"increment_balance" handling) — Firestore
    // applies increments from multiple offline devices atomically and additively on its
    // own servers, regardless of what order they arrive in, so no device's contribution
    // is ever lost. `stock` and `balance` are deliberately excluded from
    // productJson()/customerJson()/supplierJson() below for the same reason: those
    // full-snapshot payloads must never carry these two fields again, or a routine name/
    // price edit could clobber a correctly-merged server value back to a stale local one.
    suspend fun adjustCustomerBalance(db: PosDatabase, customerId: Long, amount: Double) {
        db.customerDao().addBalance(customerId, amount)
        val c = db.customerDao().find(customerId) ?: return
        enqueue(db, "customer", customerEntityId(c), "increment_balance", balanceDeltaJson(amount))
    }

    suspend fun adjustSupplierBalance(db: PosDatabase, supplierId: Long, amount: Double) {
        db.supplierDao().addBalance(supplierId, amount)
        val s = db.supplierDao().find(supplierId) ?: return
        enqueue(db, "supplier", supplierEntityId(s), "increment_balance", balanceDeltaJson(amount))
    }

    // ADDED (Inventory Accounting upgrade — stock_movements table): every stock
    // change funnels through these three wrappers (plus enqueueProductOpeningStock
    // below), so this is the one place that needs to write the stock_movements
    // ledger row for the new Stock History / Cost History screens — no call site
    // elsewhere needs to touch StockMovementDao directly.
    //
    // `type` is a short caps tag identifying WHY stock moved (e.g. "SALE",
    // "PURCHASE", "SALE_REVERSAL", "PURCHASE_EDIT", "OPENING_STOCK" — see each call
    // site's comment for the full list in use). `reference` is the invoice/billNo
    // this movement belongs to, so a movement can be traced back to the actual
    // sale/purchase document. `unitCost` is optional — pass it explicitly at any
    // call site that has ALREADY computed the product's new cost-per-unit right
    // before calling this (every purchase-related call site does, since
    // SyncQueueHelper.updateProductCost() is always called right alongside); when
    // omitted (sales, which never change cost), the product's current `cost`
    // field is used as-is.
    suspend fun decreaseProductStock(db: PosDatabase, barcode: String, qty: Double, type: String, reference: String = "", unitCost: Double? = null, note: String = ""): Int {
        val rows = db.productDao().decrease(barcode, qty)
        if (rows > 0) {
            enqueue(db, "product", barcode, "increment_stock", stockDeltaJson(-qty))
            logMovement(db, barcode, type, -qty, reference, unitCost, note)
        }
        return rows
    }

    suspend fun decreaseProductStockForce(db: PosDatabase, barcode: String, qty: Double, type: String, reference: String = "", unitCost: Double? = null, note: String = "") {
        db.productDao().decreaseForce(barcode, qty)
        enqueue(db, "product", barcode, "increment_stock", stockDeltaJson(-qty))
        logMovement(db, barcode, type, -qty, reference, unitCost, note)
    }

    suspend fun increaseProductStock(db: PosDatabase, barcode: String, qty: Double, type: String, reference: String = "", unitCost: Double? = null, note: String = "") {
        db.productDao().increase(barcode, qty)
        enqueue(db, "product", barcode, "increment_stock", stockDeltaJson(qty))
        logMovement(db, barcode, type, qty, reference, unitCost, note)
    }

    // NEW (Stock Audit — "fix once, proper system going forward"): unlike
    // increaseProductStock/decreaseProductStockForce above, this does NOT touch
    // Product.stock at all — it only inserts a StockMovement (type
    // "AUDIT_RECONCILE") so stock_movements' own sum catches up to whatever
    // Product.stock currently is.
    //
    // Why not just overwrite Product.stock to match the ledger instead? Because
    // the mismatch usually means some past write changed stock WITHOUT logging a
    // movement (a pre-fix bug, a direct DB write, a sync race) — the ledger is
    // the one that's incomplete, not necessarily the live stock number every
    // cashier is currently selling against. Silently overwriting live, in-use
    // stock from a possibly-incomplete historical sum is the riskier direction;
    // adding one auditable "we don't know why, but here's the gap" entry that
    // brings the ledger up to the live number is the safe, standard stock-take-
    // style reconciliation, and it's what StockAuditActivity's Reconcile action
    // calls. `qty` is the signed amount needed to close the gap, i.e.
    // (Product.stock - ledger sum) at the moment the audit ran.
    suspend fun recordAuditReconciliation(db: PosDatabase, barcode: String, qty: Double, note: String = "") {
        if (qty == 0.0) return
        val p = db.productDao().find(barcode)
        val row = StockMovement(
            barcode = barcode,
            type = "AUDIT_RECONCILE",
            qty = qty,
            unit = p?.smallestUnitName() ?: "",
            cost = p?.cost ?: 0.0,
            reference = "",
            note = note,
            createdAt = System.currentTimeMillis()
        )
        val newId = db.stockMovementDao().insert(row)
        enqueueStockMovement(db, row.copy(id = newId))
    }

    // CHANGED (Stock/Cost History sync): this used to be a fire-and-forget insert —
    // the row lived only in this device's local DB, so Stock History and Cost
    // History never showed anything from a second device. Now grabs the
    // auto-generated id back, stamps serverId onto the row, and enqueues it via
    // enqueueStockMovement() — same shape as every other local-autoincrement
    // entity in this file (Expense/CashTransaction/ReturnLine/etc).
    private suspend fun logMovement(db: PosDatabase, barcode: String, type: String, signedQty: Double, reference: String, unitCost: Double?, note: String) {
        val p = db.productDao().find(barcode)
        val row = StockMovement(
            barcode = barcode,
            type = type,
            qty = signedQty,
            unit = p?.smallestUnitName() ?: "",
            cost = unitCost ?: (p?.cost ?: 0.0),
            reference = reference,
            note = note,
            createdAt = System.currentTimeMillis()
        )
        val newId = db.stockMovementDao().insert(row)
        enqueueStockMovement(db, row.copy(id = newId))
    }

    // ADDED: db.productDao().updateCost() was being called directly in HistoryActivity
    // (return reversal) and PurchaseRepository (delete/edit reversal + new-purchase
    // weighted-avg update) — none of these enqueued a sync row, so a product's cost
    // silently diverged between devices after any purchase edit/delete/return. Unlike
    // stock/balance, cost is NOT excluded from productJson()'s full snapshot, so a plain
    // "upsert" (not a delta) is correct here — no increment_cost handling needed in SyncApi.
    suspend fun updateProductCost(db: PosDatabase, barcode: String, newCost: Double) {
        db.productDao().updateCost(barcode, newCost)
        val p = db.productDao().find(barcode) ?: return
        enqueue(db, "product", productEntityId(p), "upsert", productJson(p))
    }

    // NEW ("10/10 Purchase screen" item #7): same reasoning as updateProductCost above —
    // PurchaseActivity can now set/update a product's retail (salePrice) and wholesale
    // rate right at purchase time, and that change needs to sync like any other product
    // field edit (a plain upsert, not a delta).
    suspend fun updateProductPrices(db: PosDatabase, barcode: String, salePrice: Double, wholesalePrice: Double) {
        db.productDao().updatePrices(barcode, salePrice, wholesalePrice)
        val p = db.productDao().find(barcode) ?: return
        enqueue(db, "product", productEntityId(p), "upsert", productJson(p))
    }

    // ADDED for the increment fix above: a new product's opening stock has nowhere
    // else to go now that productJson() never carries "stock" — this treats the
    // opening stock the same as any other delta, incrementing up from an implicit 0
    // (Firestore's FieldValue.increment() on a field that doesn't exist yet on the
    // document starts from 0, so this correctly sets the very first value too).
    suspend fun enqueueProductOpeningStock(db: PosDatabase, barcode: String, qty: Double, unitCost: Double? = null) {
        if (qty == 0.0) return
        enqueue(db, "product", barcode, "increment_stock", stockDeltaJson(qty))
        logMovement(db, barcode, "OPENING_STOCK", qty, "", unitCost, "")
    }

    private fun stockDeltaJson(delta: Double): String {
        val map = mapOf(
            "delta" to delta,
            "updatedAt" to System.currentTimeMillis(),
            "branchId" to com.grocerypos.v11.BranchConfigStore.current
        )
        return gson.toJson(map)
    }

    private fun balanceDeltaJson(delta: Double): String {
        val map = mapOf(
            "delta" to delta,
            "updatedAt" to System.currentTimeMillis(),
            "branchId" to com.grocerypos.v11.BranchConfigStore.current
        )
        return gson.toJson(map)
    }

    suspend fun enqueueSale(db: PosDatabase, sale: Sale, context: Context? = null) {
        enqueue(db, "sale", saleEntityId(sale), "upsert", saleJson(db, sale))
        context?.let { trigger(it) }
    }

    suspend fun enqueuePurchase(db: PosDatabase, purchase: Purchase, context: Context? = null) {
        enqueue(db, "purchase", purchaseEntityId(purchase), "upsert", purchaseJson(db, purchase))
        context?.let { trigger(it) }
    }

    suspend fun enqueuePayment(db: PosDatabase, payment: Payment, context: Context? = null) {
        val id = paymentEntityId(payment)
        var stamped = if (payment.serverId != id) payment.copy(serverId = id) else payment
        // NEW (CRITICAL cross-device sync fix — see Payment.partyServerId's doc
        // comment in Database.kt): backfill the party's stable serverId from this
        // device's own local Customer/Supplier row BEFORE pushing, for any payment
        // that doesn't have one yet (either just-created, or a pre-fix legacy row
        // being re-enqueued). This device's own partyId IS correct for its own
        // party right now — that's exactly the value other devices must not trust
        // (see the field comment for why) — so this is the one place it's safe to
        // resolve it into a portable serverId.
        if (stamped.partyServerId.isNullOrBlank()) {
            val pid = stamped.partyId
            val resolvedServerId = if (pid != null) {
                when (stamped.partyType) {
                    "customer" -> db.customerDao().find(pid)?.serverId
                    "supplier" -> db.supplierDao().find(pid)?.serverId
                    else -> null
                }
            } else null
            if (resolvedServerId != null) stamped = stamped.copy(partyServerId = resolvedServerId)
        }
        if (stamped !== payment) db.paymentDao().update(stamped)
        enqueue(db, "payment", id, "upsert", paymentJson(stamped))
        context?.let { trigger(it) }
    }

    suspend fun enqueueExpense(db: PosDatabase, expense: Expense, context: Context? = null) {
        val id = expenseEntityId(expense)
        val stamped = if (expense.serverId != id) expense.copy(serverId = id) else expense
        if (stamped !== expense) db.expenseDao().update(stamped)
        enqueue(db, "expense", id, "upsert", expenseJson(stamped))
        context?.let { trigger(it) }
    }

    suspend fun enqueueCashTransaction(db: PosDatabase, t: CashTransaction, context: Context? = null) {
        val id = cashTransactionEntityId(t)
        val stamped = if (t.serverId != id) t.copy(serverId = id) else t
        if (stamped !== t) db.cashTransactionDao().update(stamped)
        enqueue(db, "cash_transaction", id, "upsert", cashTransactionJson(stamped))
        context?.let { trigger(it) }
    }

    suspend fun enqueueUser(db: PosDatabase, u: User, context: Context? = null) {
        enqueue(db, "user", userEntityId(u), "upsert", userJson(u))
        context?.let { trigger(it) }
    }

    // NEW (Units/Categories master-list sync): mirrors enqueueProduct's shape exactly
    // (name-as-id, no DeviceTag, plain upsert) — see productEntityId()'s comment above
    // for why these two don't need one either.
    suspend fun enqueueUnit(db: PosDatabase, u: UnitType, context: Context? = null) {
        enqueue(db, "unit", unitEntityId(u), "upsert", unitJson(u))
        context?.let { trigger(it) }
    }

    suspend fun enqueueCategory(db: PosDatabase, c: Category, context: Context? = null) {
        enqueue(db, "category", categoryEntityId(c), "upsert", categoryJson(c))
        context?.let { trigger(it) }
    }

    // NEW (Zakat sync): same serverId-stamping pattern as enqueueCustomer/enqueueSupplier
    // above (id computed locally, so stamp it onto the row immediately rather than
    // waiting for the network push — avoids self-duplication on the next pull).
    suspend fun enqueueZakatYear(db: PosDatabase, y: ZakatYear, context: Context? = null): ZakatYear {
        val id = zakatYearEntityId(y)
        val stamped = if (y.serverId != id) y.copy(serverId = id) else y
        if (y.serverId != id) db.zakatDao().updateYear(stamped)
        enqueue(db, "zakat_year", id, "upsert", zakatYearJson(stamped))
        context?.let { trigger(it) }
        return stamped
    }

    // yearServerId is the PARENT ZakatYear's serverId (NOT its local id) — see the
    // NOTE (sync) comment on the ZakatPayment entity in Database.kt for why.
    suspend fun enqueueZakatPayment(db: PosDatabase, p: ZakatPayment, yearServerId: String, context: Context? = null) {
        val id = zakatPaymentEntityId(p)
        if (p.serverId != id) db.zakatDao().updatePayment(p.copy(serverId = id))
        enqueue(db, "zakat_payment", id, "upsert", zakatPaymentJson(p, yearServerId))
        context?.let { trigger(it) }
    }

    // NEW (Returns sync): same serverId-stamping pattern as every other local-autoincrement
    // entity above (Customer/Supplier/Expense/CashTransaction/ZakatYear/ZakatPayment).
    suspend fun enqueueReturn(db: PosDatabase, r: ReturnLine, context: Context? = null) {
        val id = returnEntityId(r)
        if (r.serverId != id) db.returnDao().update(r.copy(serverId = id))
        enqueue(db, "return", id, "upsert", returnJson(r))
        context?.let { trigger(it) }
    }

    // NEW (Stock/Cost History sync): same serverId-stamping pattern as enqueueReturn
    // above. logMovement() below is the only call site — every stock change (sale,
    // purchase, damage, adjustment, stock-take, opening stock) already funnels
    // through it, so wiring it here is enough to sync both the Stock History and
    // Cost History screens (they both just read this one table) to another device.
    suspend fun enqueueStockMovement(db: PosDatabase, m: StockMovement, context: Context? = null) {
        val id = stockMovementEntityId(m)
        val stamped = if (m.serverId != id) m.copy(serverId = id) else m
        if (stamped !== m) db.stockMovementDao().update(stamped)
        enqueue(db, "stock_movement", id, "upsert", stockMovementJson(stamped))
        context?.let { trigger(it) }
    }

    // NEW (Cash Register sync): plain upsert, no serverId-stamping needed — the doc id
    // (r.date) is already the local row's own primary key, same as enqueueUnit/
    // enqueueCategory/enqueueProduct above. Call this right after every
    // db.cashRegisterDao().upsert(...) call site in CashRegisterActivity (open, edit
    // opening balance, close, reopen).
    suspend fun enqueueCashRegister(db: PosDatabase, r: CashRegister, context: Context? = null) {
        enqueue(db, "cash_register", cashRegisterEntityId(r), "upsert", cashRegisterJson(r))
        context?.let { trigger(it) }
    }

    // FIX (audit — cross-device OPEN REGISTER race): CashRegisterActivity's
    // insertIfAbsent() only makes the check-and-insert atomic on ONE device's local
    // SQLite. Two devices opening the same day's register while both offline each
    // pass that local check and separately queue an "upsert" — and SyncApi.push()'s
    // generic upsert branch is last-write-wins by updatedAt, so whichever device's
    // push lands second on Firestore silently overwrites the first one's opening
    // balance with no conflict signal at all (the exact residual gap the DAO
    // comment on insertIfAbsent() calls out as unresolved). OPEN specifically needs
    // to be enqueued as "create_if_absent" instead of "upsert" — see its dedicated
    // branch in SyncApi.push(), which only creates the Firestore doc if it does not
    // already exist, so the SECOND device's create is dropped server-side instead
    // of clobbering the first. That device's local row then gets corrected back to
    // the real opening balance on its next pull() (see the cash_register loop in
    // SyncApi.applyServerChanges, which is unconditional here — it only skips a
    // date that still has a pending *local* push of its own).
    suspend fun enqueueCashRegisterCreate(db: PosDatabase, r: CashRegister, context: Context? = null) {
        enqueue(db, "cash_register", cashRegisterEntityId(r), "create_if_absent", cashRegisterJson(r))
        context?.let { trigger(it) }
    }

    // NEW (App Settings sync): silently does nothing for a non-whitelisted key — see
    // SYNCED_APP_SETTING_KEYS above. Call sites don't need their own if-check.
    suspend fun enqueueAppSetting(db: PosDatabase, s: AppSetting, context: Context? = null) {
        if (s.key !in SYNCED_APP_SETTING_KEYS) return
        enqueue(db, "app_setting", appSettingEntityId(s), "upsert", appSettingJson(s))
        context?.let { trigger(it) }
    }

    /** Use for any entity delete (e.g. deleting a customer or product). */
    suspend fun enqueueDelete(db: PosDatabase, entityType: String, entityId: String, context: Context? = null) {
        enqueue(db, entityType, entityId, "delete", "{}")
        context?.let { trigger(it) }
    }

    // FIX (Shell Ledger sync): ShellLedgerActivity used to call db.shellDao().insertCustomer/
    // updateCustomer/insertTransaction/insertShopLog directly, so shellsOwed balances and
    // the shop's own empty-shell count never left this device — see the FIX comment above
    // the ShellCustomer entity. Same serverId-stamping shape as enqueueReturn/
    // enqueueStockMovement above (append-only-ish ledgers with a local-autoincrement id).
    suspend fun enqueueShellCustomer(db: PosDatabase, c: ShellCustomer, context: Context? = null) {
        val id = shellCustomerEntityId(c)
        val stamped = if (c.serverId != id) c.copy(serverId = id) else c
        if (stamped !== c) db.shellDao().updateCustomer(stamped)
        enqueue(db, "shell_customer", id, "upsert", shellCustomerJson(stamped))
        context?.let { trigger(it) }
    }

    suspend fun enqueueShellTransaction(db: PosDatabase, t: ShellTransaction, context: Context? = null) {
        val id = shellTransactionEntityId(t)
        val stamped = if (t.serverId != id) t.copy(serverId = id) else t
        if (stamped !== t) db.shellDao().updateTransaction(stamped)
        enqueue(db, "shell_transaction", id, "upsert", shellTransactionJson(db, stamped))
        context?.let { trigger(it) }
    }

    suspend fun enqueueShopEmptyShellLog(db: PosDatabase, l: ShopEmptyShellLog, context: Context? = null) {
        val id = shopEmptyShellLogEntityId(l)
        val stamped = if (l.serverId != id) l.copy(serverId = id) else l
        if (stamped !== l) db.shellDao().updateShopLog(stamped)
        enqueue(db, "shop_empty_shell_log", id, "upsert", shopEmptyShellLogJson(stamped))
        context?.let { trigger(it) }
    }

    // FIX (duplicate-payment-on-sync bug): every call site that used to do
    // `db.paymentDao().deleteByReference(ref)` / `db.cashTransactionDao().deleteByReference(ref)`
    // directly (purchase/sale edit, bill delete, returns, "edit billed item") removed the
    // row(s) from THIS device's Room database only — nothing ever told the sync queue a
    // payment/cash-transaction had been deleted, so the old row was never deleted on the
    // server or on any other device. The next edit of the same bill then inserted a brand
    // new payment for the (again full) paid amount, which synced out as normal — so the
    // OTHER device (or this same device after a fresh pull) ended up with both the old,
    // never-deleted payment AND the new one, silently doubling how much the party looked
    // like it had been paid. Repeated edits compound this (that's the "Rs 4,381,674 You'll
    // Get" on a supplier that should read close to Rs 0 — several edits' worth of stray
    // duplicate payments, each counted as an overpayment). These two helpers replace every
    // direct deleteByReference() call: they read the row(s) first (so the already-stamped
    // serverId is available — never recomputed from this device's own id, which would be
    // wrong for a row that originated on a different device), delete locally, and enqueue
    // a matching "delete" for each one so the removal actually propagates.
    suspend fun deletePaymentsByReference(db: PosDatabase, reference: String) {
        val payments = db.paymentDao().allByReference(reference)
        if (payments.isEmpty()) return
        db.paymentDao().deleteByReference(reference)
        for (p in payments) {
            enqueue(db, "payment", p.serverId ?: paymentEntityId(p), "delete", "{}")
        }
    }

    // ADDED (Cleanup Duplicate Payments): companion to deletePaymentsByReference() above,
    // but for removing exactly ONE stale duplicate row instead of every payment sharing a
    // reference — a duplicate group keeps its one correct payment and only deletes the
    // rest (see PartyRepository.findDuplicatePayments()/cleanupDuplicatePayments()). Same
    // reasoning as that fix: delete locally AND enqueue the matching sync delete, using
    // the row's own already-stamped serverId so this doesn't accidentally target the wrong
    // server-side record if the row originated on another device.
    suspend fun deletePayment(db: PosDatabase, payment: Payment) {
        db.paymentDao().deleteById(payment.id)
        enqueue(db, "payment", payment.serverId ?: paymentEntityId(payment), "delete", "{}")
    }

    suspend fun deleteCashTransactionsByReference(db: PosDatabase, reference: String) {
        val txns = db.cashTransactionDao().allByReference(reference)
        if (txns.isEmpty()) return
        db.cashTransactionDao().deleteByReference(reference)
        for (t in txns) {
            enqueue(db, "cash_transaction", t.serverId ?: cashTransactionEntityId(t), "delete", "{}")
        }
    }

    // ADDED (audit — bill return/delete left its linked payments behind): a payment recorded
    // via "Receive/Make Payment > link to a bill" is folded into the bill's `paid` AND kept as
    // its own payment + cash row. When the bill is returned or deleted those rows used to stay
    // as orphan "standalone" payments (skewing Fix Balances, Payments report and the cash book).
    //   refundType != null  -> RETURN: the money goes back, so record a dated reversal for
    //                          each linked payment's cash entry, then drop the payment row.
    //   refundType == null  -> DELETE (bill treated as never having happened, same as the bill's
    //                          own cash rows): drop the payment row and its cash rows.
    // Does NOT touch the party balance: the bill's own balance reversal already used
    // total - paid (paid includes these payments), so the balance is already right.
    suspend fun voidLinkedPayments(
        db: PosDatabase,
        billRef: String,
        refundType: String?,
        refundLabel: String,
        context: Context? = null
    ) {
        for (p in db.paymentDao().linkedPayments(billRef)) {
            if (refundType != null) {
                reverseCashByReference(db, p.reference, p.amount, refundType, refundLabel, context)
            } else {
                deleteCashTransactionsByReference(db, p.reference)
            }
            deletePayment(db, p)
        }
    }

    // ADDED (audit — one-time repair of the "expense saved twice" bug, see ExpenseActivity):
    // expenses created before the fix were pushed without a local serverId, so the next pull
    // inserted the server copy as a SECOND local row. Both rows describe the SAME Firestore
    // document, so the twin is removed LOCALLY ONLY (no sync-delete — that would tombstone the
    // shared document) and the original adopts the document's serverId. Safe by construction:
    // only an unstamped row with a twin that is identical down to the millisecond AND carries
    // this device's own id prefix is ever touched.
    suspend fun mergeOwnDuplicateExpenses(db: PosDatabase): Int {
        val prefix = "expense:${DeviceTag.current}-"
        var merged = 0
        for (orig in db.expenseDao().unstamped()) {
            val twin = db.expenseDao().findOwnTwin(prefix, orig.createdAt, orig.amount, orig.category, orig.description, orig.method) ?: continue
            if (twin.id == orig.id) continue
            db.expenseDao().delete(twin)
            db.expenseDao().update(orig.copy(serverId = twin.serverId, updatedAt = maxOf(orig.updatedAt, twin.updatedAt), dirty = false))
            merged++
        }
        return merged
    }

    // FIX (sale/purchase return had no visible effect in Cash Book / Day Book): a
    // return used to call deleteCashTransactionsByReference() (whole return) or
    // silently shrink the original cash_transactions row in place (partial return).
    // Both erase the ORIGINAL day's cash history retroactively (Day Book for that
    // date now under-reports what actually happened) and leave zero trace of the
    // return itself on the day it happened — nothing shows up in Cash Book or Day
    // Book to say "this money went back out/came back in".
    //
    // Proper fix: leave the original cash_transactions row(s) untouched (that cash
    // really was received/paid that day — Day Book/Cash Book for that date should
    // keep saying so) and record the return as a brand-new, dated-today reversal
    // entry instead. Split proportionally across whatever methods (cash/bank/etc.)
    // the original payment used, so a split-payment bill reverses correctly too.
    //
    // reference is tagged "return:<original>" (not blank, not "manual-", and never
    // equal to the original invoice/billNo) so it: (a) shows up as its own visible
    // line in Day Book (see DayBookActivity.loadDay()'s cashTx filter), and (b)
    // never gets swept up by an exact allByReference(invoice)/findByReference(invoice)
    // lookup elsewhere (e.g. a later edit on the same bill).
    suspend fun reverseCashByReference(
        db: PosDatabase,
        reference: String,
        amountToReverse: Double,
        reverseType: String, // "OUT" to reverse a sale (cash paid back to customer), "IN" to reverse a purchase (cash received back from supplier)
        reasonLabel: String,
        context: Context? = null
    ) {
        if (amountToReverse <= 0.009) return
        val original = db.cashTransactionDao().allByReference(reference)
        if (original.isEmpty()) return
        val originalTotal = original.sumOf { it.amount }
        if (originalTotal <= 0.009) return
        val ratio = (amountToReverse / originalTotal).coerceIn(0.0, 1.0)
        for (tx in original) {
            val portion = tx.amount * ratio
            if (portion <= 0.009) continue
            val reversal = CashTransaction(
                type = reverseType,
                method = tx.method,
                amount = portion,
                reason = reasonLabel,
                reference = "return:$reference"
            )
            val id = db.cashTransactionDao().insert(reversal)
            enqueueCashTransaction(db, reversal.copy(id = id), context)
        }
    }

    // ---------- Payload builders ----------

    fun customerJson(c: Customer): String {
        val map = mapOf(
            "serverId" to customerEntityId(c),
            "name" to c.name,
            "phone" to c.phone,
            // FIX (conflict-safe sync): "balance" deliberately excluded — see the big
            // comment above adjustCustomerBalance(). balance is now ONLY ever touched
            // via the increment_balance operation, never overwritten by a full snapshot.
            "creditLimit" to c.creditLimit,
            "openingBalance" to c.openingBalance,
            // NEW (Stuck Balance): a plain snapshot field like openingBalance — it never
            // moves with sales/payments, so (unlike "balance") last-write-wins is correct.
            "stuckBalance" to c.stuckBalance,
            "updatedAt" to System.currentTimeMillis(),
            "branchId" to com.grocerypos.v11.BranchConfigStore.current
        )
        return gson.toJson(map)
    }

    fun supplierJson(s: Supplier): String {
        val map = mapOf(
            "serverId" to supplierEntityId(s),
            "name" to s.name,
            "phone" to s.phone,
            // FIX (conflict-safe sync): "balance" excluded — same reasoning as customerJson.
            "openingBalance" to s.openingBalance,
            "updatedAt" to System.currentTimeMillis(),
            "branchId" to com.grocerypos.v11.BranchConfigStore.current
        )
        return gson.toJson(map)
    }

    fun productJson(p: Product): String {
        val map = mapOf(
            "barcode" to productEntityId(p),
            "name" to p.name,
            // FIX (product sync incomplete): the rest of Product's editable fields were
            // never actually added here — only barcode/name/updatedAt/branchId went out,
            // so a product created/edited on one device showed up on another with a
            // name and barcode but no price, category, or unit info. "stock" and
            // "openingStock" remain deliberately excluded — see the big comment above
            // decreaseProductStock()/increaseProductStock(). stock is ONLY ever touched
            // via the increment_stock operation (including a brand-new product's opening
            // stock — see enqueueProductOpeningStock()), never overwritten by a full
            // snapshot like this one.
            "category" to p.category,
            "cost" to p.cost,
            "salePrice" to p.salePrice,
            "wholesalePrice" to p.wholesalePrice,
            "reorderLevel" to p.reorderLevel,
            "expiry" to p.expiry,
            "unit" to p.unit,
            "unitSize" to p.unitSize,
            "unitNote" to p.unitNote,
            "secondaryUnit" to p.secondaryUnit,
            "secondaryUnitQty" to p.secondaryUnitQty,
            "tertiaryUnit" to p.tertiaryUnit,
            "tertiaryUnitQty" to p.tertiaryUnitQty,
            "defaultUnitIndex" to p.defaultUnitIndex,
            "quickSaleDefaultUnitIndex" to p.quickSaleDefaultUnitIndex,
            "searchTag" to p.searchTag,
            "updatedAt" to System.currentTimeMillis(),
            "branchId" to com.grocerypos.v11.BranchConfigStore.current
        )
        return gson.toJson(map)
    }

    // NEW (Units/Categories master-list sync): trivial payloads — these two entities
    // are just a name, so there's nothing to snapshot besides the name itself.
    fun unitJson(u: UnitType): String {
        val map = mapOf(
            "name" to u.name,
            "updatedAt" to System.currentTimeMillis(),
            "branchId" to com.grocerypos.v11.BranchConfigStore.current
        )
        return gson.toJson(map)
    }

    fun categoryJson(c: Category): String {
        val map = mapOf(
            "name" to c.name,
            "updatedAt" to System.currentTimeMillis(),
            "branchId" to com.grocerypos.v11.BranchConfigStore.current
        )
        return gson.toJson(map)
    }

    fun zakatYearJson(y: ZakatYear): String {
        val map = mapOf(
            "serverId" to zakatYearEntityId(y),
            "startDate" to y.startDate,
            "endDate" to y.endDate,
            "assetsSnapshot" to y.assetsSnapshot,
            "totalPayable" to y.totalPayable,
            // NEW (Zakat currency/calendar): carried through so another device shows the
            // same currency label and month-name style for this year instead of its own
            // local defaults.
            "currency" to y.currency,
            "calendarType" to y.calendarType,
            "createdAt" to y.createdAt,
            "updatedAt" to System.currentTimeMillis(),
            "branchId" to com.grocerypos.v11.BranchConfigStore.current
        )
        return gson.toJson(map)
    }

    fun zakatPaymentJson(p: ZakatPayment, yearServerId: String): String {
        val map = mapOf(
            "serverId" to zakatPaymentEntityId(p),
            "zakatYearServerId" to yearServerId,
            "amount" to p.amount,
            "method" to p.method,
            "note" to p.note,
            // NEW (Zakat payment date + category): see ZakatPayment's doc comment.
            "category" to p.category,
            "paymentDate" to p.paymentDate,
            "createdAt" to p.createdAt,
            "updatedAt" to System.currentTimeMillis(),
            "branchId" to com.grocerypos.v11.BranchConfigStore.current
        )
        return gson.toJson(map)
    }

    fun returnJson(r: ReturnLine): String {
        val map = mapOf(
            "serverId" to returnEntityId(r),
            "reference" to r.reference,
            "type" to r.type,
            "barcode" to r.barcode,
            "qty" to r.qty,
            "amount" to r.amount,
            "createdAt" to r.createdAt,
            "updatedAt" to System.currentTimeMillis(),
            "branchId" to com.grocerypos.v11.BranchConfigStore.current
        )
        return gson.toJson(map)
    }

    // NEW (Shell Ledger sync): full snapshot — shellsOwed is always written back via a
    // whole-row updateCustomer() call (never an increment_* delta), so a plain upsert is
    // correct here, same as zakatYearJson below.
    fun shellCustomerJson(c: ShellCustomer): String {
        val map = mapOf(
            "serverId" to shellCustomerEntityId(c),
            "name" to c.name,
            "phone" to c.phone,
            "shellsOwed" to c.shellsOwed,
            "createdAt" to c.createdAt,
            "updatedAt" to System.currentTimeMillis(),
            "branchId" to com.grocerypos.v11.BranchConfigStore.current
        )
        return gson.toJson(map)
    }

    // NOTE: suspend + takes db (like saleJson above) because customerId is a LOCAL
    // autoincrement id, meaningless on another device — the transaction must be linked
    // by the shell customer's own serverId instead, so the other device can match it
    // back to the right shell_customers row (mirrors how saleJson resolves customerId
    // the same way).
    suspend fun shellTransactionJson(db: PosDatabase, t: ShellTransaction): String {
        val customerServerId = db.shellDao().getCustomer(t.customerId)?.let { shellCustomerEntityId(it) }
        val map = mapOf(
            "serverId" to shellTransactionEntityId(t),
            "customerServerId" to customerServerId,
            "type" to t.type,
            "qty" to t.qty,
            "note" to t.note,
            "createdAt" to t.createdAt,
            "updatedAt" to System.currentTimeMillis(),
            "branchId" to com.grocerypos.v11.BranchConfigStore.current
        )
        return gson.toJson(map)
    }

    fun shopEmptyShellLogJson(l: ShopEmptyShellLog): String {
        val map = mapOf(
            "serverId" to shopEmptyShellLogEntityId(l),
            "delta" to l.delta,
            "reason" to l.reason,
            "note" to l.note,
            "createdAt" to l.createdAt,
            "updatedAt" to System.currentTimeMillis(),
            "branchId" to com.grocerypos.v11.BranchConfigStore.current
        )
        return gson.toJson(map)
    }

    // NEW (Stock/Cost History sync): same shape as returnJson above — the pulled
    // copy needs every field SyncApi.applyServerChanges() reads back off it to
    // reconstruct a StockMovement row on the other device (see that loop).
    fun stockMovementJson(m: StockMovement): String {
        val map = mapOf(
            "serverId" to (m.serverId ?: stockMovementEntityId(m)),
            "barcode" to m.barcode,
            "type" to m.type,
            "qty" to m.qty,
            "unit" to m.unit,
            "cost" to m.cost,
            "reference" to m.reference,
            "note" to m.note,
            "createdAt" to m.createdAt,
            "updatedAt" to System.currentTimeMillis(),
            "branchId" to com.grocerypos.v11.BranchConfigStore.current
        )
        return gson.toJson(map)
    }

    // NEW (Cash Register sync): full snapshot, same shape as unitJson/categoryJson
    // above — `date` doubles as both the local PK and the Firestore doc id, so it's
    // included in the payload too (mirrors how productJson includes barcode).
    fun cashRegisterJson(r: CashRegister): String {
        val map = mapOf(
            "date" to r.date,
            "openingCash" to r.openingCash,
            "closingCash" to r.closingCash,
            "openingBank" to r.openingBank,
            "closingBank" to r.closingBank,
            "closed" to r.closed,
            "updatedAt" to System.currentTimeMillis(),
            "branchId" to com.grocerypos.v11.BranchConfigStore.current
        )
        return gson.toJson(map)
    }

    fun appSettingJson(s: AppSetting): String {
        val map = mapOf(
            "key" to s.key,
            "value" to s.value,
            "updatedAt" to System.currentTimeMillis(),
            "branchId" to com.grocerypos.v11.BranchConfigStore.current
        )
        return gson.toJson(map)
    }

    // FIX (multi-device: sales/purchases weren't two-way syncable): previously only
    // itemCount was sent, so even if a sale/purchase document was ever pulled back
    // down to another device, there weren't enough details to reconstruct the actual
    // sale_items/purchase_items rows — the other device would see a total but not
    // what was actually sold/bought. Now sends the full item list. Suspend + takes db
    // because it needs to look the items up itself (every call site already has both
    // in scope, so nothing else needs to change).
    // FIX (cross-device party linkage): customerId/supplierId here used to be the raw
    // local Room autoincrement Long (sale.customerId / purchase.supplierId). That id is
    // only meaningful on the device that created it — customer id=5 on this device and
    // customer id=5 on another device are unrelated rows. Pushing the raw number meant
    // every sale/purchase pulled onto a different device silently linked to whatever
    // (wrong, or nonexistent) local customer/supplier happened to have that same id —
    // corrupting party ledgers/balances on the receiving device without any error.
    // Now resolves and sends the customer's/supplier's stable serverId string instead
    // (same one customerEntityId()/supplierEntityId() computes — deterministic, doesn't
    // require the customer to have synced yet); the pull side below resolves it back to
    // whatever local id it maps to on that device via findByServerId().
    suspend fun saleJson(db: PosDatabase, sale: Sale): String {
        val items = db.saleDao().itemsForInvoice(sale.invoice)
        val itemMaps = items.map {
            mapOf(
                "barcode" to it.barcode, "product" to it.product, "qty" to it.qty,
                "unit" to it.unit, "unitPrice" to it.unitPrice, "cost" to it.cost, "amount" to it.amount,
                // FIX (historical unit conversion bug): carry the transaction-time
                // conversion factor across devices too — otherwise a sale pulled onto
                // another device would have no conversionFactor recorded, and that
                // device's later delete/edit/return would silently fall back to ITS
                // current (possibly different) product config. See Database.kt's
                // SaleItem.smallestQty() comment.
                "conversionFactor" to it.conversionFactor,
                // NEW (Improvement Pack P2): carry each line's permanent UID across
                // devices too, so it stays the same everywhere instead of a fresh
                // random one being generated on every device that pulls this sale.
                "lineUid" to it.lineUid
            )
        }
        val customerServerId = sale.customerId?.let { db.customerDao().find(it)?.let { c -> customerEntityId(c) } }
        val map = mapOf(
            "serverId" to saleEntityId(sale),
            "invoice" to sale.invoice,
            // NEW (Improvement Pack P2): see Sale.saleUid in Database.kt.
            "saleUid" to sale.saleUid,
            "customerServerId" to customerServerId,
            "subtotal" to sale.subtotal,
            "discount" to sale.discount,
            "total" to sale.total,
            "paid" to sale.paid,
            "paymentMethod" to sale.paymentMethod,
            "saleType" to sale.saleType,
            "createdAt" to sale.createdAt,
            "status" to sale.status,
            // NEW (Due Date Reminders): synced like every other Sale field so a due
            // date set on one device (from DueRemindersActivity) shows up on the other.
            "dueDate" to sale.dueDate,
            "itemCount" to items.size,
            "items" to itemMaps,
            "updatedAt" to System.currentTimeMillis(),
            "branchId" to com.grocerypos.v11.BranchConfigStore.current
        )
        return gson.toJson(map)
    }

    suspend fun purchaseJson(db: PosDatabase, purchase: Purchase): String {
        val items = db.purchaseDao().itemsForBill(purchase.billNo)
        val itemMaps = items.map {
            mapOf(
                "barcode" to it.barcode, "qty" to it.qty, "unit" to it.unit,
                "unitCost" to it.unitCost, "amount" to it.amount,
                // FIX (historical unit conversion bug): see saleJson()'s itemMaps above.
                "conversionFactor" to it.conversionFactor,
                // NEW (Improvement Pack P2): see PurchaseItem.lineUid in Database.kt.
                "lineUid" to it.lineUid,
                // FIX (item name / retail-wholesale rate "gayab" after sync): sync this
                // row's own name/rate snapshot too, or a device that pulls this purchase
                // before it has (or ever gets) the matching product row would still show
                // the old barcode/blank-rate symptom. See PurchaseItem.itemName's comment.
                "itemName" to it.itemName,
                "retailRate" to it.retailRate,
                "wholesaleRate" to it.wholesaleRate
            )
        }
        val supplierServerId = purchase.supplierId?.let { db.supplierDao().find(it)?.let { s -> supplierEntityId(s) } }
        val map = mapOf(
            "serverId" to purchaseEntityId(purchase),
            "billNo" to purchase.billNo,
            // NEW (Improvement Pack P2): see Purchase.purchaseUid in Database.kt.
            "purchaseUid" to purchase.purchaseUid,
            "supplierServerId" to supplierServerId,
            "subtotal" to purchase.subtotal,
            "discount" to purchase.discount,
            "total" to purchase.total,
            "paid" to purchase.paid,
            "createdAt" to purchase.createdAt,
            "status" to purchase.status,
            "itemCount" to items.size,
            "items" to itemMaps,
            "updatedAt" to System.currentTimeMillis(),
            "branchId" to com.grocerypos.v11.BranchConfigStore.current
        )
        return gson.toJson(map)
    }

    fun paymentJson(payment: Payment): String {
        val map = mapOf(
            "serverId" to paymentEntityId(payment),
            "reference" to payment.reference,
            "partyType" to payment.partyType,
            "partyId" to payment.partyId,
            // NEW (CRITICAL cross-device sync fix): see Payment.partyServerId's doc
            // comment in Database.kt. The receiving device's pull loop now resolves
            // the correct LOCAL party via this stable id instead of trusting the
            // device-local `partyId` above.
            "partyServerId" to payment.partyServerId,
            "amount" to payment.amount,
            "method" to payment.method,
            "note" to payment.note,
            "billReference" to payment.billReference,
            "createdAt" to payment.createdAt,
            "updatedAt" to System.currentTimeMillis(),
            "branchId" to com.grocerypos.v11.BranchConfigStore.current
        )
        return gson.toJson(map)
    }

    fun expenseJson(expense: Expense): String {
        val map = mapOf(
            "serverId" to expenseEntityId(expense),
            "category" to expense.category,
            "description" to expense.description,
            "amount" to expense.amount,
            // FIX (Bug 2 — Cash in Hand): keep the paid-from method in sync too, so
            // another device pulling this expense still knows whether to treat it as
            // cash or bank when it later re-derives cash_transactions from it.
            "method" to expense.method,
            "createdAt" to expense.createdAt,
            "updatedAt" to System.currentTimeMillis(),
            "branchId" to com.grocerypos.v11.BranchConfigStore.current
        )
        return gson.toJson(map)
    }

    fun cashTransactionJson(t: CashTransaction): String {
        val map = mapOf(
            "serverId" to cashTransactionEntityId(t),
            "type" to t.type,
            "method" to t.method,
            "amount" to t.amount,
            "reason" to t.reason,
            "reference" to t.reference,
            "createdAt" to t.createdAt,
            "updatedAt" to System.currentTimeMillis(),
            "branchId" to com.grocerypos.v11.BranchConfigStore.current
        )
        return gson.toJson(map)
    }

    // NOTE: passwordHash is deliberately excluded so it never sits in Firestore.
    fun userJson(u: User): String {
        val map = mapOf(
            "serverId" to userEntityId(u),
            "username" to u.username,
            "displayName" to u.displayName,
            "role" to u.role,
            "phone" to u.phone,
            "active" to u.active,
            "updatedAt" to System.currentTimeMillis(),
            "branchId" to com.grocerypos.v11.BranchConfigStore.current
        )
        return gson.toJson(map)
    }

    // ADDED (force full resync): re-queues EVERY row currently in the local database
    // for a fresh push, regardless of whether it was ever marked "synced" before.
    //
    // Why this exists: older builds treated a push "conflict" (server's updatedAt
    // looked newer) as if it had succeeded — the queue row was removed either way —
    // so records that hit a conflict were silently never retried, forever, even
    // though they were never actually written to Firestore. On a device whose local
    // data is the one that should win (e.g. after wiping and reinstalling on another
    // device with stale/test cloud data), those old queue rows are long gone and
    // "Sync Now" has nothing left to push. This walks every local table directly and
    // re-enqueues it via the normal enqueueX() helpers, so the next sync pushes
    // everything this device has, from scratch. Safe to run more than once — it just
    // re-sends the current local state again.
    suspend fun resyncAllLocalData(db: PosDatabase, context: Context? = null) {
        for (c in db.customerDao().allList()) enqueueCustomer(db, c)
        for (s in db.supplierDao().allList()) enqueueSupplier(db, s)
        for (p in db.productDao().allList()) enqueueProduct(db, p)
        for (u in db.userDao().allList()) enqueueUser(db, u)
        for (sale in db.saleDao().allRaw()) enqueueSale(db, sale)
        for (purchase in db.purchaseDao().allRaw()) enqueuePurchase(db, purchase)
        for (payment in db.paymentDao().allRaw()) enqueuePayment(db, payment)
        for (expense in db.expenseDao().allList()) enqueueExpense(db, expense)
        for (t in db.cashTransactionDao().allList()) enqueueCashTransaction(db, t)
        // NEW (Units/Categories master-list sync): so pre-existing local units/
        // categories (added before this feature existed) also get pushed once.
        for (u in db.unitDao().allOnce()) enqueueUnit(db, u)
        for (c in db.categoryDao().allOnce()) enqueueCategory(db, c)
        // NEW (Zakat sync): push existing years first (each returns its stamped
        // serverId), then their payments — payments need the parent's serverId,
        // not its local id, so years must go first within this same loop.
        for (y in db.zakatDao().allYears()) {
            val stampedYear = enqueueZakatYear(db, y)
            for (p in db.zakatDao().paymentsForYear(y.id)) {
                enqueueZakatPayment(db, p, stampedYear.serverId ?: zakatYearEntityId(stampedYear))
            }
        }
        // NEW (Returns sync): push existing local returns too.
        for (r in db.returnDao().allList()) enqueueReturn(db, r)
        // NEW (Stock/Cost History sync): push every pre-existing movement row too —
        // covers devices that had stock_movements rows before this feature existed.
        for (m in db.stockMovementDao().allList()) enqueueStockMovement(db, m)
        // NEW (App Settings sync): only the whitelisted shop-identity keys, if present.
        for (key in SYNCED_APP_SETTING_KEYS) {
            db.appSettingDao().get(key)?.let { enqueueAppSetting(db, it) }
        }
        // NEW (Cash Register sync): push existing till history too, so a register
        // opened/closed before this feature existed also gets pushed once.
        for (r in db.cashRegisterDao().allOnce()) enqueueCashRegister(db, r)
        context?.let { trigger(it) }
    }

    // FIX (back-dated Purchase/Sale cash entries stuck on the wrong date): before
    // RoomPurchaseRepository/RoomSaleRepository passed createdAt explicitly, every
    // Purchase/Sale cash-drawer row was stamped with "now" (CashTransaction's
    // default), even for a bill the user had deliberately back-dated — so it showed
    // in the Cash Register under today instead of the bill's real date, and never
    // appeared when checking the register for that back-date. This is a one-time
    // repair for rows created before that fix: it walks every "Purchase"/"Sale"
    // cash-drawer row (Quick Sale is skipped — it has no date picker, "now" is
    // correct there), looks up that bill's own createdAt, and corrects the cash
    // row to match if it's different. Safe to run more than once — rows already
    // matching their bill's date are left untouched. Returns how many rows changed.
    suspend fun fixBackdatedCashTransactionDates(db: PosDatabase, context: Context? = null): Int {
        var fixed = 0
        for (t in db.cashTransactionDao().allList()) {
            val correctDate = when (t.reason) {
                "Purchase" -> db.purchaseDao().findPurchase(t.reference)?.createdAt
                "Sale" -> db.saleDao().findSale(t.reference)?.createdAt
                else -> null
            } ?: continue
            if (correctDate == t.createdAt) continue
            val corrected = t.copy(createdAt = correctDate, dirty = true)
            db.cashTransactionDao().update(corrected)
            enqueueCashTransaction(db, corrected)
            fixed++
        }
        context?.let { trigger(it) }
        return fixed
    }

    // FIX (party balance drift — "You'll Give/Get" not matching the visible bills):
    // Customer.balance / Supplier.balance are running totals nudged up/down by
    // adjustCustomerBalance()/adjustSupplierBalance() at every sale, purchase,
    // payment, edit, return and delete (see the many call sites across
    // RoomSaleRepository, RoomPurchaseRepository, PartyTransactionActivity,
    // HistoryActivity, PurchaseHistoryActivity, SaleHistoryActivity) — they are
    // NOT recalculated fresh from the ledger on every screen. If even one of
    // those call sites was ever missed, doubled, or landed differently on two
    // devices before a sync, the stored balance quietly drifts away from what
    // the actual Purchase/Sale + Payment rows add up to — showing a "You'll
    // Give/Get" figure with no bill in the party's own transaction list to
    // account for it.
    //
    // This recomputes each party's balance from scratch, straight from the
    // same rows PartyTransactionActivity's own list is built from:
    //   sum(bill.total - bill.paid) for every sale/purchase of that party
    //   MINUS sum(payment.amount) for every payment NOT tied to a specific
    //   bill (billReference blank) — a bill-linked payment already reduced
    //   that bill's own `paid`, via applyBillPaidDelta, so counting it again
    //   here would double-subtract it.
    // openingBalance is left untouched (it's a separate fixed starting point,
    // added on top for display — see PartyTransactionActivity.loadTransactions).
    // Only writes/reports a party whose stored balance actually differs.
    data class PartyBalanceFix(val name: String, val oldBalance: Double, val newBalance: Double)

    suspend fun recalculatePartyBalances(db: PosDatabase, context: Context? = null): List<PartyBalanceFix> {
        val fixes = mutableListOf<PartyBalanceFix>()
        for (c in db.customerDao().allList()) {
            // FIX (Settings > Fix Balances re-breaking already-returned bills): this
            // used to sum `total - paid` over EVERY sale, including returned ones —
            // a returned sale's total/paid don't change (only its status does, see
            // SaleHistoryActivity.returnSale()), so a returned credit sale's full
            // outstanding amount got added back into the "correct" balance here,
            // undoing the reduction returnSale() already applied via
            // adjustCustomerBalance() at return time. Mirrors PartyRepository.
            // recalculateBalances() (the other, already-correct "Recalculate"
            // entry point under Party Reports), which this now matches.
            val allSales = db.saleDao().salesByCustomer(c.id)
            val sales = allSales.filter { it.status != "returned" }
            // FIX (double-counted supplier-side "Purchase payment" bug, same class,
            // ported here): `billReference.isEmpty()` does NOT exclude the payment
            // row RoomPurchaseRepository.savePurchase() inserts at purchase time
            // (reference = billNo) — that row's `billReference` field is separate
            // and stays blank by default, so it slipped through as a "standalone"
            // payment and got subtracted a second time on top of `sale.paid`/
            // `purchase.paid` already reflecting it. Excluding by `reference`
            // matching a real invoice/billNo (this customer/supplier's own) is the
            // correct check — see PartyRepository.recalculateBalances()'s matching
            // comment.
            // FIX (audit — this duplicate implementation was missing two things
            // PartyRepository.recalculateBalances() already had): (1) built from the
            // status-FILTERED `sales`, so a returned sale's invoice fell out of the
            // set and any payment still linked to it got subtracted a second time —
            // same bug class as the returned-bill fix elsewhere, now using the
            // UNFILTERED `allSales` instead. (2) only checked `it.reference`, never
            // `it.billReference` — so a genuine "Receive/Make Payment" made WITH a
            // bill linked via the picker (reference = a unique manual timestamp,
            // billReference = the invoice) was never recognized as bill-covered at
            // all and got subtracted here on top of `sale.paid` already reflecting
            // it, every single time, bill still existing or not. Now checks both,
            // matching PartyRepository's filter exactly.
            val saleInvoices = allSales.map { it.invoice }.toHashSet()
            val correct = sales.sumOf { it.total - it.paid } -
                db.paymentDao().listByParty("customer", c.id)
                    .filter { it.reference !in saleInvoices && !(it.billReference.isNotBlank() && it.billReference in saleInvoices) }
                    .sumOf { it.amount }
            if (kotlin.math.abs(correct - c.balance) > 0.01) {
                fixes.add(PartyBalanceFix(c.name, c.balance, correct))
                // FIX (2-device wrong balance): this used to write `correct` straight into
                // the local row and enqueue an "upsert" — but customerJson() deliberately
                // EXCLUDES balance, so the correction never reached Firestore, and the next
                // pull() then overwrote the corrected local value with the server's old
                // one. Send it as an increment_balance delta instead (same path as
                // PartyRepository.recalculateBalances), so every device converges.
                adjustCustomerBalance(db, c.id, correct - c.balance)
            }
        }
        for (s in db.supplierDao().allList()) {
            val allPurchases = db.purchaseDao().purchasesBySupplier(s.id)
            val purchases = allPurchases.filter { it.status != "returned" }
            // FIX (audit — same two gaps as the customer loop above): billNos now built
            // from the UNFILTERED purchase list (a returned purchase still "counts" so
            // its linked payment isn't subtracted twice), and the payment filter also
            // checks `billReference`, not just `reference` — so a "Make Payment" made
            // WITH a bill linked is correctly recognized as already covered by that
            // bill's own `paid`, instead of always being treated as standalone.
            val billNos = allPurchases.map { it.billNo }.toHashSet()
            val correct = purchases.sumOf { it.total - it.paid } -
                db.paymentDao().listByParty("supplier", s.id)
                    .filter { it.reference !in billNos && !(it.billReference.isNotBlank() && it.billReference in billNos) }
                    .sumOf { it.amount }
            if (kotlin.math.abs(correct - s.balance) > 0.01) {
                fixes.add(PartyBalanceFix(s.name, s.balance, correct))
                // FIX (2-device wrong balance): see the customer loop above.
                adjustSupplierBalance(db, s.id, correct - s.balance)
            }
        }
        context?.let { trigger(it) }
        return fixes
    }
}
