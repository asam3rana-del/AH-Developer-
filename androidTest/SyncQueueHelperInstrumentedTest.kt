package com.grocerypos.v11

import androidx.room.Room
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.google.gson.Gson
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Instrumented tests for [SyncQueueHelper] (Improvement Pack P9 — the part
 * `SyncQueueHelperTest.kt`'s doc comment explicitly leaves as NOT covered):
 * enqueue()/trigger() and every enqueueX() wrapper, adjustCustomerBalance()/
 * adjustSupplierBalance(), decrease/increase/decreaseProductStockForce(),
 * updateProductCost()/updateProductPrices(), enqueueProductOpeningStock(), and
 * saleJson()/purchaseJson() — all `suspend fun`s that read/write PosDatabase
 * directly, so they need a real or in-memory Room database rather than a plain
 * JVM test.
 *
 * Pure logic (entity-id generation, the no-context JSON payload builders,
 * including the balance/stock/passwordHash-never-leaks regression guards)
 * stays in the plain-JVM `SyncQueueHelperTest.kt` — this file does not repeat
 * those, only the DB-writing half.
 *
 * Run: `./gradlew connectedDebugAndroidTest` (device/emulator required, same
 * as `MigrationTest.kt`). No Firebase/network — everything here uses an
 * in-memory Room database only.
 *
 * IMPORTANT: every call below omits the optional `context` parameter, so
 * SyncQueueHelper.trigger() (which calls SyncWorker.syncNowOnce — real
 * WorkManager) never fires. Only the DB side effects (sync_queue rows,
 * stock_movements rows, product/customer/supplier/etc. row updates) are
 * under test here.
 */
@RunWith(AndroidJUnit4::class)
class SyncQueueHelperInstrumentedTest {

    private lateinit var db: PosDatabase
    private val gson = Gson()

    @Before
    fun setUp() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        db = Room.inMemoryDatabaseBuilder(context, PosDatabase::class.java)
            .allowMainThreadQueries()
            .build()
    }

    @After
    fun tearDown() {
        db.close()
    }

    private suspend fun queuedDeltaFor(entityType: String, entityId: String, operation: String): Double? {
        val rows = db.syncQueueDao().pendingForEntity(entityType, entityId, operation)
        if (rows.isEmpty()) return null
        @Suppress("UNCHECKED_CAST")
        return (gson.fromJson(rows.last().payloadJson, Map::class.java)["delta"] as? Number)?.toDouble()
    }

    // ================= enqueueCustomer / enqueueSupplier / enqueueProduct =================

    /** A local customer's own generated entityId must be stamped onto its serverId
     *  column immediately (not left until the network push happens) — otherwise
     *  the very next pull would fail to recognize this device's own record and
     *  duplicate it locally (see SyncQueueHelper.kt's FIX comment above
     *  enqueueCustomer). */
    @Test
    fun enqueueCustomerStampsServerIdImmediatelyAndQueuesAnUpsert() = runBlocking {
        val id = db.customerDao().insert(Customer(name = "Bilal", phone = "0300"))
        val customer = db.customerDao().find(id)!!
        assertTrue("serverId should start unset", customer.serverId != SyncQueueHelper.customerEntityId(customer))

        SyncQueueHelper.enqueueCustomer(db, customer)

        val updated = db.customerDao().find(id)!!
        assertEquals(SyncQueueHelper.customerEntityId(customer), updated.serverId)
        val queued = db.syncQueueDao().pendingForEntity("customer", updated.serverId!!, "upsert")
        assertEquals(1, queued.size)
        assertFalse("customer's balance must never be present in a full-snapshot upsert payload",
            queued[0].payloadJson.contains("balance"))
    }

    @Test
    fun enqueueSupplierStampsServerIdImmediatelyAndQueuesAnUpsert() = runBlocking {
        val id = db.supplierDao().insert(Supplier(name = "Wholesaler A", phone = "0300"))
        val supplier = db.supplierDao().find(id)!!
        SyncQueueHelper.enqueueSupplier(db, supplier)
        val updated = db.supplierDao().find(id)!!
        assertEquals(SyncQueueHelper.supplierEntityId(supplier), updated.serverId)
        assertEquals(1, db.syncQueueDao().pendingForEntity("supplier", updated.serverId!!, "upsert").size)
    }

    @Test
    fun enqueueProductQueuesAnUpsertWithoutStockField() = runBlocking {
        val product = Product(barcode = "BC-1", name = "Soap", stock = 50.0)
        db.productDao().upsert(product)
        SyncQueueHelper.enqueueProduct(db, product)
        val queued = db.syncQueueDao().pendingForEntity("product", "BC-1", "upsert")
        assertEquals(1, queued.size)
        assertFalse("product stock must never ride along in a full-snapshot upsert — only as increment_stock",
            queued[0].payloadJson.contains("\"stock\""))
    }

    // ================= adjustCustomerBalance / adjustSupplierBalance =================

    @Test
    fun adjustCustomerBalanceUpdatesLocalRowAndQueuesMatchingDelta() = runBlocking {
        val id = db.customerDao().insert(Customer(name = "Ali", phone = "0300", balance = 1000.0))
        val customer = db.customerDao().find(id)!!
        SyncQueueHelper.enqueueCustomer(db, customer) // stamp serverId first, like real call sites do

        SyncQueueHelper.adjustCustomerBalance(db, id, 300.0)

        val updated = db.customerDao().find(id)!!
        assertEquals(1300.0, updated.balance, 0.0001)
        val delta = queuedDeltaFor("customer", updated.serverId!!, "increment_balance")
        assertEquals(300.0, delta!!, 0.0001)
    }

    @Test
    fun adjustSupplierBalanceUpdatesLocalRowAndQueuesMatchingDelta() = runBlocking {
        val id = db.supplierDao().insert(Supplier(name = "Wholesaler A", phone = "0300", balance = 0.0))
        val supplier = db.supplierDao().find(id)!!
        SyncQueueHelper.enqueueSupplier(db, supplier)

        SyncQueueHelper.adjustSupplierBalance(db, id, -200.0)

        val updated = db.supplierDao().find(id)!!
        assertEquals(-200.0, updated.balance, 0.0001)
        val delta = queuedDeltaFor("supplier", updated.serverId!!, "increment_balance")
        assertEquals(-200.0, delta!!, 0.0001)
    }

    // ================= stock wrappers =================

    @Test
    fun decreaseProductStockUpdatesRowQueuesNegativeDeltaAndLogsMovement() = runBlocking {
        db.productDao().upsert(Product(barcode = "BC-1", name = "Soap", stock = 10.0, cost = 15.0))
        val rows = SyncQueueHelper.decreaseProductStock(db, "BC-1", 2.0, type = "SALE", reference = "INV-1")

        assertEquals(1, rows)
        assertEquals(8.0, db.productDao().find("BC-1")!!.stock, 0.0001)
        val delta = queuedDeltaFor("product", "BC-1", "increment_stock")
        assertEquals(-2.0, delta!!, 0.0001)
        val movements = db.stockMovementDao().forProduct("BC-1").first()
        assertTrue(movements.any { it.type == "SALE" && it.qty == -2.0 && it.reference == "INV-1" })
        // logMovement() also syncs the movement row itself (Stock/Cost History sync).
        val movementRow = movements.first { it.type == "SALE" }
        assertTrue("stock_movement's own row must get a serverId stamped, then queue its own upsert",
            movementRow.serverId != null &&
                db.syncQueueDao().pendingForEntity("stock_movement", movementRow.serverId!!, "upsert").isNotEmpty())
    }

    /** Insufficient stock: decrease() (the guarded version) must neither change the
     *  row nor queue a delta nor log a movement — 0 rows affected means "did nothing"
     *  everywhere, not just in the products table. */
    @Test
    fun decreaseProductStockDoesNothingWhenInsufficientStock() = runBlocking {
        db.productDao().upsert(Product(barcode = "BC-1", name = "Soap", stock = 1.0))
        val rows = SyncQueueHelper.decreaseProductStock(db, "BC-1", 5.0, type = "SALE")

        assertEquals(0, rows)
        assertEquals(1.0, db.productDao().find("BC-1")!!.stock, 0.0001)
        assertTrue(db.syncQueueDao().pendingForEntity("product", "BC-1", "increment_stock").isEmpty())
    }

    @Test
    fun decreaseProductStockForceGoesNegativeAndStillQueuesAndLogs() = runBlocking {
        db.productDao().upsert(Product(barcode = "BC-1", name = "Soap", stock = 1.0))
        SyncQueueHelper.decreaseProductStockForce(db, "BC-1", 5.0, type = "SALE_REVERSAL", reference = "INV-2")

        assertEquals(-4.0, db.productDao().find("BC-1")!!.stock, 0.0001)
        val delta = queuedDeltaFor("product", "BC-1", "increment_stock")
        assertEquals(-5.0, delta!!, 0.0001)
    }

    @Test
    fun increaseProductStockUpdatesRowQueuesPositiveDeltaAndLogsMovement() = runBlocking {
        db.productDao().upsert(Product(barcode = "BC-1", name = "Soap", stock = 10.0))
        SyncQueueHelper.increaseProductStock(db, "BC-1", 5.0, type = "PURCHASE", reference = "BILL-1", unitCost = 12.0)

        assertEquals(15.0, db.productDao().find("BC-1")!!.stock, 0.0001)
        val delta = queuedDeltaFor("product", "BC-1", "increment_stock")
        assertEquals(5.0, delta!!, 0.0001)
        val movements = db.stockMovementDao().forProduct("BC-1").first()
        assertTrue(movements.any { it.type == "PURCHASE" && it.qty == 5.0 && it.cost == 12.0 })
    }

    @Test
    fun enqueueProductOpeningStockQueuesDeltaAndSkipsZero() = runBlocking {
        db.productDao().upsert(Product(barcode = "BC-1", name = "Soap", stock = 0.0))
        SyncQueueHelper.enqueueProductOpeningStock(db, "BC-1", 20.0)
        assertEquals(20.0, queuedDeltaFor("product", "BC-1", "increment_stock")!!, 0.0001)

        // A zero-quantity opening stock must not queue a no-op delta.
        db.productDao().upsert(Product(barcode = "BC-2", name = "Rice", stock = 0.0))
        SyncQueueHelper.enqueueProductOpeningStock(db, "BC-2", 0.0)
        assertTrue(db.syncQueueDao().pendingForEntity("product", "BC-2", "increment_stock").isEmpty())
    }

    // ================= updateProductCost / updateProductPrices =================

    @Test
    fun updateProductCostUpdatesRowAndQueuesFullUpsertWithNewCost() = runBlocking {
        db.productDao().upsert(Product(barcode = "BC-1", name = "Soap", cost = 15.0))
        SyncQueueHelper.updateProductCost(db, "BC-1", 18.0)

        assertEquals(18.0, db.productDao().find("BC-1")!!.cost, 0.0001)
        val queued = db.syncQueueDao().pendingForEntity("product", "BC-1", "upsert")
        assertEquals(1, queued.size)
        assertTrue(queued[0].payloadJson.contains("\"cost\":18.0"))
    }

    @Test
    fun updateProductPricesUpdatesRowAndQueuesFullUpsert() = runBlocking {
        db.productDao().upsert(Product(barcode = "BC-1", name = "Soap", salePrice = 25.0, wholesalePrice = 20.0))
        SyncQueueHelper.updateProductPrices(db, "BC-1", salePrice = 30.0, wholesalePrice = 24.0)

        val product = db.productDao().find("BC-1")!!
        assertEquals(30.0, product.salePrice, 0.0001)
        assertEquals(24.0, product.wholesalePrice, 0.0001)
        val queued = db.syncQueueDao().pendingForEntity("product", "BC-1", "upsert")
        assertEquals(1, queued.size)
    }

    // ================= saleJson / purchaseJson =================

    /** saleJson() must carry every line item plus the resolved customerServerId
     *  (never the raw local customer id, which is meaningless on another device). */
    @Test
    fun saleJsonIncludesResolvedCustomerAndAllLineItems() = runBlocking {
        val custId = db.customerDao().insert(Customer(name = "Ali", phone = "0300"))
        val customer = db.customerDao().find(custId)!!
        SyncQueueHelper.enqueueCustomer(db, customer) // stamp serverId

        val sale = Sale(invoice = "INV-1", customerId = custId, subtotal = 25.0, discount = 0.0, tax = 0.0, total = 25.0, paid = 25.0, paymentMethod = "cash")
        db.saleDao().sale(sale)
        db.saleDao().items(listOf(SaleItem(invoice = "INV-1", barcode = "BC-1", product = "Soap", qty = 1.0, unitPrice = 25.0, cost = 15.0, amount = 25.0)))

        val json = SyncQueueHelper.saleJson(db, sale)
        @Suppress("UNCHECKED_CAST")
        val map = gson.fromJson(json, Map::class.java) as Map<String, Any?>
        assertEquals(db.customerDao().find(custId)!!.serverId, map["customerServerId"])
        val items = map["items"] as List<Map<String, Any?>>
        assertEquals(1, items.size)
        assertEquals("BC-1", items[0]["barcode"])
        assertEquals(1, (map["itemCount"] as Number).toInt())
    }

    /** purchaseJson() must carry the resolved supplierServerId and every line
     *  item, including the itemName/retailRate/wholesaleRate snapshot fields
     *  added for the "gayab after sync" fix. */
    @Test
    fun purchaseJsonIncludesResolvedSupplierAndAllLineItemsWithRateSnapshot() = runBlocking {
        val suppId = db.supplierDao().insert(Supplier(name = "Wholesaler A", phone = "0300"))
        val supplier = db.supplierDao().find(suppId)!!
        SyncQueueHelper.enqueueSupplier(db, supplier)

        val purchase = Purchase(billNo = "BILL-1", supplierId = suppId, total = 150.0, paid = 150.0, subtotal = 150.0, discount = 0.0)
        db.purchaseDao().purchase(purchase)
        db.purchaseDao().items(listOf(
            PurchaseItem(billNo = "BILL-1", barcode = "BC-1", qty = 10.0, unitCost = 15.0, amount = 150.0,
                itemName = "Soap", retailRate = 25.0, wholesaleRate = 20.0)
        ))

        val json = SyncQueueHelper.purchaseJson(db, purchase)
        @Suppress("UNCHECKED_CAST")
        val map = gson.fromJson(json, Map::class.java) as Map<String, Any?>
        assertEquals(db.supplierDao().find(suppId)!!.serverId, map["supplierServerId"])
        val items = map["items"] as List<Map<String, Any?>>
        assertEquals(1, items.size)
        assertEquals("BC-1", items[0]["barcode"])
        assertEquals("Soap", items[0]["itemName"])
        assertEquals(25.0, (items[0]["retailRate"] as Number).toDouble(), 0.0001)
    }

    // ================= enqueueSale / enqueuePurchase =================

    @Test
    fun enqueueSaleQueuesAnUpsertWithSaleJsonPayload() = runBlocking {
        val sale = Sale(invoice = "INV-1", subtotal = 10.0, discount = 0.0, tax = 0.0, total = 10.0, paid = 10.0, paymentMethod = "cash")
        db.saleDao().sale(sale)
        SyncQueueHelper.enqueueSale(db, sale)
        val queued = db.syncQueueDao().pendingForEntity("sale", SyncQueueHelper.saleEntityId(sale), "upsert")
        assertEquals(1, queued.size)
        assertTrue(queued[0].payloadJson.contains("\"invoice\":\"INV-1\""))
    }

    @Test
    fun enqueuePurchaseQueuesAnUpsertWithPurchaseJsonPayload() = runBlocking {
        val purchase = Purchase(billNo = "BILL-1", supplierId = null, total = 50.0, paid = 50.0, subtotal = 50.0, discount = 0.0)
        db.purchaseDao().purchase(purchase)
        SyncQueueHelper.enqueuePurchase(db, purchase)
        val queued = db.syncQueueDao().pendingForEntity("purchase", SyncQueueHelper.purchaseEntityId(purchase), "upsert")
        assertEquals(1, queued.size)
        assertTrue(queued[0].payloadJson.contains("\"billNo\":\"BILL-1\""))
    }

    // ================= enqueueCashRegister (Improvement Pack P11) =================

    /** New under P11 — Cash Register (daily till) sync. Plain upsert keyed by
     *  the register's own date, no serverId-stamping needed. */
    @Test
    fun enqueueCashRegisterQueuesAnUpsert() = runBlocking {
        val register = CashRegister(date = "2026-09-18", openingCash = 5000.0, closingCash = 0.0, closed = false)
        db.cashRegisterDao().upsert(register)
        SyncQueueHelper.enqueueCashRegister(db, register)
        val queued = db.syncQueueDao().pendingForEntity("cash_register", "2026-09-18", "upsert")
        assertEquals(1, queued.size)
        assertTrue(queued[0].payloadJson.contains("\"openingCash\":5000.0"))
    }

    // ================= enqueueDelete =================

    @Test
    fun enqueueDeleteQueuesADeleteOperation() = runBlocking {
        SyncQueueHelper.enqueueDelete(db, "customer", "customer:A-1")
        val queued = db.syncQueueDao().pendingForEntity("customer", "customer:A-1", "delete")
        assertEquals(1, queued.size)
    }
}
