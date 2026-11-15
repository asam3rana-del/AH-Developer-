package com.grocerypos.v11

import com.google.gson.Gson
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for [SyncQueueHelper] (Improvement Pack P9 — sync tests).
 *
 * SCOPE: only the PURE parts of SyncQueueHelper are covered here — entity-id
 * generation and the JSON payload builders (customerJson/supplierJson/
 * productJson/paymentJson/expenseJson/cashTransactionJson/userJson/
 * cashRegisterJson). These
 * take a data object and return a String with no suspend/Room/Context
 * dependency, so they run as plain JVM tests, same as the rest of this
 * module (see TESTS-README.md — no Android SDK/Gradle in this sandbox).
 *
 * NOT covered here (needs a real/in-memory Room database + Robolectric or an
 * on-device instrumented test, since these are `suspend fun`s that read/write
 * PosDatabase directly):
 *   - enqueue()/trigger() and every enqueueX() wrapper (DB insert + WorkManager)
 *   - adjustCustomerBalance()/adjustSupplierBalance() (raw SQL UPDATE + enqueue)
 *   - decreaseProductStock()/increaseProductStock()/decreaseProductStockForce()
 *     (raw SQL UPDATE + stock_movements insert + enqueue)
 *   - saleJson()/purchaseJson() (suspend — look up line items via the DAO)
 *   - updateProductCost()
 * A Room in-memory instrumented test for these is the natural next step once
 * an Android/Gradle environment is available (see RELEASE_CHECKLIST.md).
 *
 * These tests exist because the sync payload shape encodes real correctness
 * rules that are easy to silently break in a future edit — most importantly:
 * "stock" and "openingStock" must NEVER appear in productJson(), and
 * "balance" must NEVER appear in customerJson()/supplierJson() (see the long
 * comment above SyncQueueHelper.adjustCustomerBalance() in the source — those
 * fields are only ever synced as increment deltas, never as a full snapshot,
 * or two offline devices selling/paying against the same record would
 * silently clobber each other's change instead of both being preserved).
 */
class SyncQueueHelperTest {

    private val gson = Gson()

    private fun jsonMap(json: String): Map<*, *> = gson.fromJson(json, Map::class.java)

    // ---------------- Entity ID generation ----------------

    @Test
    fun `customerEntityId embeds DeviceTag and local id`() {
        val customer = Customer(id = 42L, name = "Bilal Kiryana")
        val id = SyncQueueHelper.customerEntityId(customer)
        assertEquals("customer:${DeviceTag.current}-42", id)
    }

    // AUDIT FIX: a row that already carries a serverId (e.g. pulled from ANOTHER device) must keep
    // it — rebuilding the id from this device's tag re-stamped it and created a duplicate document.
    @Test
    fun `payment expense and cash transaction ids keep an existing serverId`() {
        val p = Payment(id = 5L, reference = "r", partyType = "customer", partyId = 1L, amount = 10.0, method = "cash", serverId = "payment:OTHER-9")
        val e = Expense(id = 5L, category = "Rent", description = "", amount = 10.0, serverId = "expense:OTHER-9")
        val t = CashTransaction(id = 5L, type = "IN", method = "cash", amount = 10.0, serverId = "cash_transaction:OTHER-9")
        assertEquals("payment:OTHER-9", SyncQueueHelper.paymentEntityId(p))
        assertEquals("expense:OTHER-9", SyncQueueHelper.expenseEntityId(e))
        assertEquals("cash_transaction:OTHER-9", SyncQueueHelper.cashTransactionEntityId(t))
        assertTrue(p.serverId == SyncQueueHelper.paymentJson(p).let { (jsonMap(it)["serverId"] as String) })
    }

    @Test
    fun `payment expense and cash transaction ids fall back to DeviceTag when never synced`() {
        val p = Payment(id = 5L, reference = "r", partyType = "customer", partyId = 1L, amount = 10.0, method = "cash")
        val e = Expense(id = 6L, category = "Rent", description = "", amount = 10.0)
        val t = CashTransaction(id = 7L, type = "IN", method = "cash", amount = 10.0)
        assertEquals("payment:${DeviceTag.current}-5", SyncQueueHelper.paymentEntityId(p))
        assertEquals("expense:${DeviceTag.current}-6", SyncQueueHelper.expenseEntityId(e))
        assertEquals("cash_transaction:${DeviceTag.current}-7", SyncQueueHelper.cashTransactionEntityId(t))
    }

    @Test
    fun `supplierEntityId embeds DeviceTag and local id`() {
        val supplier = Supplier(id = 7L, name = "ABC Traders")
        val id = SyncQueueHelper.supplierEntityId(supplier)
        assertEquals("supplier:${DeviceTag.current}-7", id)
    }

    @Test
    fun `productEntityId is just the barcode (naturally unique, no DeviceTag needed)`() {
        val product = Product(barcode = "8901030123", name = "Sugar 1kg")
        assertEquals("8901030123", SyncQueueHelper.productEntityId(product))
    }

    @Test
    fun `saleEntityId is keyed off invoice, not local id`() {
        val sale = Sale(
            invoice = "0926000001-AB12", customerId = null, subtotal = 100.0,
            discount = 0.0, tax = 0.0, total = 100.0, paid = 100.0, paymentMethod = "cash"
        )
        assertEquals("sale:0926000001-AB12", SyncQueueHelper.saleEntityId(sale))
    }

    @Test
    fun `purchaseEntityId is keyed off billNo, not local id`() {
        val purchase = Purchase(billNo = "PUR-Sep26-0001-AB12", supplierId = null, total = 500.0, paid = 500.0)
        assertEquals("purchase:PUR-Sep26-0001-AB12", SyncQueueHelper.purchaseEntityId(purchase))
    }

    @Test
    fun `paymentEntityId embeds DeviceTag and local id (reference alone is not unique)`() {
        val payment = Payment(id = 5L, reference = "0926000001-AB12", partyType = "customer", partyId = 1L, amount = 200.0, method = "cash")
        assertEquals("payment:${DeviceTag.current}-5", SyncQueueHelper.paymentEntityId(payment))
    }

    @Test
    fun `expenseEntityId embeds DeviceTag and local id`() {
        val expense = Expense(id = 3L, category = "Rent", description = "", amount = 1000.0)
        assertEquals("expense:${DeviceTag.current}-3", SyncQueueHelper.expenseEntityId(expense))
    }

    @Test
    fun `cashTransactionEntityId embeds DeviceTag and local id`() {
        val tx = CashTransaction(id = 9L, type = "IN", method = "cash", amount = 100.0)
        assertEquals("cash_transaction:${DeviceTag.current}-9", SyncQueueHelper.cashTransactionEntityId(tx))
    }

    @Test
    fun `userEntityId is keyed off username, not local id`() {
        val user = User(username = "admin", displayName = "Admin", role = "owner", passwordHash = "irrelevant-here")
        assertEquals("user:admin", SyncQueueHelper.userEntityId(user))
    }

    @Test
    fun `two devices' identically-numbered local rows never collide`() {
        // Same local id (5), simulating two different devices' 5th customer —
        // the whole point of mixing DeviceTag in. We can only directly assert
        // the id is present in the string (DeviceTag.current is fixed within
        // this JVM process), but this documents and locks in the collision-
        // avoidance contract described in DeviceTag.kt's class doc.
        val customer = Customer(id = 5L, name = "Same Local Id")
        val id = SyncQueueHelper.customerEntityId(customer)
        assertTrue("entity id must carry the device tag, not just the bare local id", id != "customer:5")
        assertTrue(id.startsWith("customer:"))
        assertTrue(id.endsWith("-5"))
    }

    // ---------------- customerJson() ----------------

    @Test
    fun `customerJson carries name, phone, credit limit and opening balance`() {
        val customer = Customer(id = 1L, name = "Ahmed", phone = "0300-1234567", creditLimit = 5000.0, openingBalance = 200.0, balance = 999.0)
        val map = jsonMap(SyncQueueHelper.customerJson(customer))

        assertEquals("Ahmed", map["name"])
        assertEquals("0300-1234567", map["phone"])
        assertEquals(5000.0, map["creditLimit"])
        assertEquals(200.0, map["openingBalance"])
        assertEquals(SyncQueueHelper.customerEntityId(customer), map["serverId"])
    }

    @Test
    fun `customerJson carries stuckBalance`() {
        val customer = Customer(id = 1L, name = "Ahmed", stuckBalance = 50000.0)
        val map = jsonMap(SyncQueueHelper.customerJson(customer))
        assertEquals(50000.0, map["stuckBalance"])
    }

    @Test
    fun `customerJson never leaks the live balance field (increment-only sync)`() {
        // Regression guard for the exact bug documented above
        // adjustCustomerBalance(): if "balance" ever sneaks back into this
        // snapshot, a routine name/phone edit on one offline device would
        // silently overwrite another device's balance-changing sale/payment.
        val customer = Customer(id = 1L, name = "Ahmed", balance = 12345.0)
        val map = jsonMap(SyncQueueHelper.customerJson(customer))
        assertFalse("balance must never be part of the full-snapshot customer payload", map.containsKey("balance"))
    }

    // ---------------- supplierJson() ----------------

    @Test
    fun `supplierJson carries name, phone and opening balance`() {
        val supplier = Supplier(id = 2L, name = "XYZ Distributors", phone = "021-1112222", openingBalance = 1000.0, balance = 5000.0)
        val map = jsonMap(SyncQueueHelper.supplierJson(supplier))

        assertEquals("XYZ Distributors", map["name"])
        assertEquals("021-1112222", map["phone"])
        assertEquals(1000.0, map["openingBalance"])
    }

    @Test
    fun `supplierJson never leaks the live balance field (increment-only sync)`() {
        val supplier = Supplier(id = 2L, name = "XYZ Distributors", balance = 5000.0)
        val map = jsonMap(SyncQueueHelper.supplierJson(supplier))
        assertFalse("balance must never be part of the full-snapshot supplier payload", map.containsKey("balance"))
    }

    // ---------------- productJson() ----------------

    @Test
    fun `productJson carries pricing, category and full 3-tier unit info`() {
        val product = Product(
            barcode = "8901030123", name = "Sugar", category = "Grocery",
            cost = 100.0, salePrice = 120.0, wholesalePrice = 110.0,
            reorderLevel = 5.0, expiry = "2027-01-01",
            unit = "Bag", unitSize = 1, unitNote = "50kg bag",
            secondaryUnit = "kg", secondaryUnitQty = 50.0,
            tertiaryUnit = "", tertiaryUnitQty = 0.0,
            stock = 999.0, openingStock = 999.0
        )
        val map = jsonMap(SyncQueueHelper.productJson(product))

        assertEquals("Sugar", map["name"])
        assertEquals("Grocery", map["category"])
        assertEquals(100.0, map["cost"])
        assertEquals(120.0, map["salePrice"])
        assertEquals(110.0, map["wholesalePrice"])
        assertEquals("Bag", map["unit"])
        assertEquals("kg", map["secondaryUnit"])
        assertEquals(50.0, map["secondaryUnitQty"])
        assertEquals("8901030123", map["barcode"])
    }

    @Test
    fun `productJson never leaks live stock or openingStock (increment-only sync)`() {
        // Same class of bug as the balance fields above, but for stock — this
        // is the one that would silently corrupt real inventory counts across
        // two offline devices selling/buying the same product.
        val product = Product(barcode = "8901030123", name = "Sugar", stock = 250.0, openingStock = 250.0)
        val map = jsonMap(SyncQueueHelper.productJson(product))
        assertFalse("stock must never be part of the full-snapshot product payload", map.containsKey("stock"))
        assertFalse("openingStock must never be part of the full-snapshot product payload", map.containsKey("openingStock"))
    }

    // ---------------- paymentJson() ----------------

    @Test
    fun `paymentJson carries reference, party and amount`() {
        val payment = Payment(id = 1L, reference = "0926000001-AB12", partyType = "customer", partyId = 4L, amount = 500.0, method = "cash", note = "Partial payment")
        val map = jsonMap(SyncQueueHelper.paymentJson(payment))

        assertEquals("0926000001-AB12", map["reference"])
        assertEquals("customer", map["partyType"])
        assertEquals(4.0, map["partyId"]) // Gson decodes numbers as Double
        assertEquals(500.0, map["amount"])
        assertEquals("cash", map["method"])
        assertEquals("Partial payment", map["note"])
    }

    // ---------------- expenseJson() ----------------

    @Test
    fun `expenseJson carries category, description and amount`() {
        val expense = Expense(id = 1L, category = "Rent", description = "Shop rent - Sep", amount = 15000.0)
        val map = jsonMap(SyncQueueHelper.expenseJson(expense))

        assertEquals("Rent", map["category"])
        assertEquals("Shop rent - Sep", map["description"])
        assertEquals(15000.0, map["amount"])
    }

    // ---------------- cashTransactionJson() ----------------

    @Test
    fun `cashTransactionJson carries type, method, amount, reason and reference`() {
        val tx = CashTransaction(id = 1L, type = "OUT", method = "bank", amount = 2500.0, reason = "Purchase", reference = "PUR-Sep26-0001-AB12")
        val map = jsonMap(SyncQueueHelper.cashTransactionJson(tx))

        assertEquals("OUT", map["type"])
        assertEquals("bank", map["method"])
        assertEquals(2500.0, map["amount"])
        assertEquals("Purchase", map["reason"])
        assertEquals("PUR-Sep26-0001-AB12", map["reference"])
    }

    // ---------------- userJson() ----------------

    @Test
    fun `userJson carries profile fields but never the password hash`() {
        val user = User(username = "cashier1", displayName = "Counter Staff", role = "cashier", passwordHash = "super-secret-pbkdf2-hash", active = true, phone = "0300-9998888")
        val map = jsonMap(SyncQueueHelper.userJson(user))

        assertEquals("cashier1", map["username"])
        assertEquals("Counter Staff", map["displayName"])
        assertEquals("cashier", map["role"])
        assertEquals(true, map["active"])
        assertEquals("0300-9998888", map["phone"])
        assertFalse("passwordHash must never leave the device / reach Firestore", map.containsKey("passwordHash"))
    }

    // ---------------- cashRegisterEntityId() / cashRegisterJson() ----------------

    @Test
    fun `cashRegisterEntityId is just the date (one shared register per branch per day, no DeviceTag)`() {
        val reg = CashRegister(date = "2026-09-16", openingCash = 1000.0)
        assertEquals("2026-09-16", SyncQueueHelper.cashRegisterEntityId(reg))
    }

    @Test
    fun `cashRegisterJson carries opening-closing balances and closed flag`() {
        val reg = CashRegister(
            date = "2026-09-16", openingCash = 1000.0, closingCash = 1500.0,
            openingBank = 200.0, closingBank = 300.0, closed = true
        )
        val map = jsonMap(SyncQueueHelper.cashRegisterJson(reg))

        assertEquals("2026-09-16", map["date"])
        assertEquals(1000.0, map["openingCash"])
        assertEquals(1500.0, map["closingCash"])
        assertEquals(200.0, map["openingBank"])
        assertEquals(300.0, map["closingBank"])
        assertEquals(true, map["closed"])
    }

    // ---------------- Cross-cutting: every payload carries branchId ----------------

    @Test
    fun `every payload builder stamps branchId so multi-branch data can be told apart`() {
        val customer = Customer(id = 1L, name = "A")
        val supplier = Supplier(id = 1L, name = "B")
        val product = Product(barcode = "X", name = "C")
        val payment = Payment(id = 1L, reference = "R", partyType = "customer", partyId = 1L, amount = 1.0, method = "cash")
        val expense = Expense(id = 1L, category = "Misc", description = "", amount = 1.0)
        val tx = CashTransaction(id = 1L, type = "IN", method = "cash", amount = 1.0)
        val user = User(username = "u", displayName = "U", role = "owner", passwordHash = "h")
        val cashRegister = CashRegister(date = "2026-09-16")

        listOf(
            SyncQueueHelper.customerJson(customer),
            SyncQueueHelper.supplierJson(supplier),
            SyncQueueHelper.productJson(product),
            SyncQueueHelper.paymentJson(payment),
            SyncQueueHelper.expenseJson(expense),
            SyncQueueHelper.cashTransactionJson(tx),
            SyncQueueHelper.userJson(user),
            SyncQueueHelper.cashRegisterJson(cashRegister)
        ).forEach { json ->
            assertTrue("payload missing branchId: $json", jsonMap(json).containsKey("branchId"))
        }
    }
}
