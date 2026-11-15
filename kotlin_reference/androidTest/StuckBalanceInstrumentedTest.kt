package com.grocerypos.v11

import androidx.room.Room
import androidx.sqlite.db.SupportSQLiteDatabase
import androidx.sqlite.db.SupportSQLiteOpenHelper
import androidx.sqlite.db.framework.FrameworkSQLiteOpenHelperFactory
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.grocerypos.v11.data.PartyRepository
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Instrumented tests for the Stuck Balance feature (Customer.stuckBalance).
 *
 * Covers, on a real on-device SQLite / in-memory Room database:
 *  1. MIGRATION_43_44 itself — adds the column with default 0.0 and keeps existing rows.
 *  2. A customer with a stuck amount round-trips through CustomerDao.
 *  3. Sales/payments (SyncQueueHelper.adjustCustomerBalance) move ONLY `balance`,
 *     never `stuckBalance` — so Daily Payable moves and the stuck part stays put.
 *  4. Fix Balances (PartyRepository.recalculateBalances) never touches `stuckBalance`.
 *
 * Run: `./gradlew connectedDebugAndroidTest` (device/emulator required, same as the other
 * files in this folder). No Firebase/network: every call below either omits the optional
 * `context` parameter or uses recalculateBalances() in a way that finds nothing to fix /
 * runs as a dry run, so SyncQueueHelper.trigger() (real WorkManager) never fires.
 *
 * NOT covered here (check by hand — see STUCK-BALANCE-PLAN.md, section 8):
 *  - Merge Duplicates summing stuck amounts (it always calls trigger()/WorkManager).
 *  - A Fix Balances run that actually corrects drift (same reason).
 *  - The UI (Daily / Stuck / Total split, Admin+Manager-only editing).
 *
 * Note: MigrationTest.kt only chains up to v33, so it does not exercise 43 -> 44. This file
 * tests MIGRATION_43_44 directly against a minimal v43 `customers` table instead, which
 * needs no exported schema JSON.
 */
@RunWith(AndroidJUnit4::class)
class StuckBalanceInstrumentedTest {

    private lateinit var db: PosDatabase

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

    // ================= 1) MIGRATION_43_44 =================

    @Test
    fun migration43to44_addsStuckColumn_defaultZero_keepsExistingRows() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        // name(null) => in-memory SQLite database, nothing left on disk.
        val helper = FrameworkSQLiteOpenHelperFactory().create(
            SupportSQLiteOpenHelper.Configuration.builder(context)
                .name(null)
                .callback(object : SupportSQLiteOpenHelper.Callback(43) {
                    override fun onCreate(db: SupportSQLiteDatabase) {
                        // Minimal version-43 shape of the customers table (no stuckBalance yet).
                        db.execSQL(
                            "CREATE TABLE customers (" +
                                "id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, " +
                                "name TEXT NOT NULL, phone TEXT NOT NULL, " +
                                "creditLimit REAL NOT NULL, openingBalance REAL NOT NULL, " +
                                "balance REAL NOT NULL, serverId TEXT, " +
                                "updatedAt INTEGER NOT NULL, dirty INTEGER NOT NULL)"
                        )
                    }

                    override fun onUpgrade(db: SupportSQLiteDatabase, oldVersion: Int, newVersion: Int) {}
                })
                .build()
        )
        val raw = helper.writableDatabase
        try {
            raw.execSQL(
                "INSERT INTO customers (name, phone, creditLimit, openingBalance, balance, serverId, updatedAt, dirty) " +
                    "VALUES ('Ali', '0300', 0.0, 25000.0, 1000.0, NULL, 0, 1)"
            )

            MIGRATION_43_44.migrate(raw)

            raw.query("SELECT name, openingBalance, balance, stuckBalance FROM customers").use { c ->
                assertEquals(1, c.count)
                c.moveToFirst()
                assertEquals("Ali", c.getString(0))
                assertEquals(25000.0, c.getDouble(1), 0.001)
                assertEquals(1000.0, c.getDouble(2), 0.001)
                assertEquals("existing customers must start with no stuck amount", 0.0, c.getDouble(3), 0.001)
            }

            // The new column is writable.
            raw.execSQL("UPDATE customers SET stuckBalance = 50000.0 WHERE name = 'Ali'")
            raw.query("SELECT stuckBalance FROM customers WHERE name = 'Ali'").use { c ->
                c.moveToFirst()
                assertEquals(50000.0, c.getDouble(0), 0.001)
            }
        } finally {
            raw.close()
        }
    }

    // ================= 2) Round trip through Room =================

    @Test
    fun customerWithStuck_roundTripsThroughDao() = runBlocking {
        val id = db.customerDao().insert(
            Customer(name = "Ali", openingBalance = 25000.0, stuckBalance = 50000.0)
        )
        val loaded = db.customerDao().find(id)!!
        assertEquals(50000.0, loaded.stuckBalance, 0.001)
        assertEquals(25000.0, loaded.dailyPayable(), 0.001)
        assertEquals(75000.0, loaded.totalPayable(), 0.001)
    }

    @Test
    fun customerWithoutStuck_defaultsToZero() = runBlocking {
        val id = db.customerDao().insert(Customer(name = "Bilal", openingBalance = 100.0))
        val loaded = db.customerDao().find(id)!!
        assertEquals(0.0, loaded.stuckBalance, 0.001)
        assertEquals(loaded.dailyPayable(), loaded.totalPayable(), 0.001)
    }

    // ================= 3) Sales / payments never move stuck =================

    @Test
    fun adjustCustomerBalance_movesDailyOnly_neverStuck() = runBlocking {
        val id = db.customerDao().insert(
            Customer(name = "Ali", openingBalance = 25000.0, stuckBalance = 50000.0)
        )

        // 10,000 credit sale
        SyncQueueHelper.adjustCustomerBalance(db, id, 10000.0)
        var c = db.customerDao().find(id)!!
        assertEquals(35000.0, c.dailyPayable(), 0.001)
        assertEquals(85000.0, c.totalPayable(), 0.001)
        assertEquals(50000.0, c.stuckBalance, 0.001)

        // then a 5,000 payment
        SyncQueueHelper.adjustCustomerBalance(db, id, -5000.0)
        c = db.customerDao().find(id)!!
        assertEquals(30000.0, c.dailyPayable(), 0.001)
        assertEquals(80000.0, c.totalPayable(), 0.001)
        assertEquals(50000.0, c.stuckBalance, 0.001)
    }

    // ================= 4) Fix Balances never touches stuck =================

    @Test
    fun recalculateBalances_leavesStuckAlone_whenNothingDrifted() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val id = db.customerDao().insert(
            Customer(name = "Ali", openingBalance = 25000.0, balance = 10000.0, stuckBalance = 50000.0)
        )
        // One unpaid 10,000 credit sale => the true running balance is exactly 10,000,
        // so recalculateBalances() finds no drift (and therefore never calls trigger()).
        db.saleDao().sale(
            Sale(
                invoice = "INV-STUCK-1", customerId = id,
                subtotal = 10000.0, discount = 0.0, tax = 0.0, total = 10000.0,
                paid = 0.0, paymentMethod = "credit"
            )
        )

        val result = PartyRepository(db, context.applicationContext).recalculateBalances()

        assertEquals(0, result.customersFixed)
        val c = db.customerDao().find(id)!!
        assertEquals(10000.0, c.balance, 0.001)
        assertEquals(50000.0, c.stuckBalance, 0.001)
        assertEquals(85000.0, c.totalPayable(), 0.001)
    }

    @Test
    fun recalculateBalances_dryRun_reportsDriftButChangesNothing() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val id = db.customerDao().insert(
            Customer(name = "Ali", openingBalance = 25000.0, balance = 10500.0, stuckBalance = 50000.0)
        )
        db.saleDao().sale(
            Sale(
                invoice = "INV-STUCK-2", customerId = id,
                subtotal = 10000.0, discount = 0.0, tax = 0.0, total = 10000.0,
                paid = 0.0, paymentMethod = "credit"
            )
        )

        // stored balance (10,500) != true balance (10,000) => 1 customer flagged, nothing written
        val result = PartyRepository(db, context.applicationContext).recalculateBalances(dryRun = true)

        assertEquals(1, result.customersFixed)
        val c = db.customerDao().find(id)!!
        assertEquals(10500.0, c.balance, 0.001)
        assertEquals(50000.0, c.stuckBalance, 0.001)
    }
}
