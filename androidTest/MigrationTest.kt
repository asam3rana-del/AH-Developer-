package com.grocerypos.v11

import androidx.room.testing.MigrationTestHelper
import androidx.sqlite.db.framework.FrameworkSQLiteOpenHelperFactory
import androidx.sqlite.db.SupportSQLiteDatabase
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Instrumented Room migration test (Improvement Pack P3 — checklist item
 * "Test Room migrations from oldest supported version to 33").
 *
 * Runs on a device/emulator: `./gradlew connectedDebugAndroidTest` (or
 * Android Studio: right-click this file -> Run). Cannot run in a plain
 * JVM/sandbox environment — Room's MigrationTestHelper needs a real SQLite
 * implementation via instrumentation, same reason this lives in
 * `app/src/androidTest` and not `app/src/test`.
 *
 * ============================== IMPORTANT CAVEAT ==============================
 * `Database.kt`'s `@Database` annotation was `exportSchema=false` until this same
 * change (see the FIX comment right above `version=32` there) — so Room never
 * wrote out a schema JSON for versions 13 through 31. MigrationTestHelper
 * normally reads those JSON files (from `app/schemas/`, via the
 * `room.schemaLocation` arg added in `app/build.gradle.kts`) to know EXACTLY
 * what a version's schema should look like, both as the "before" state to
 * construct and as the "after" state to validate a migration against.
 *
 * Without those files for 13-31, `createV13Database()` below hand-builds the
 * version-13 SQLite schema from scratch, reverse-engineered by reading every
 * migration's `ALTER TABLE` / `CREATE TABLE` statement in Database.kt and
 * working out what must have existed *before* each one ran (e.g. MIGRATION_13_14
 * adding `purchase_items.unit` means that column must NOT exist yet at v13).
 * This is a best-effort reconstruction, not a captured historical schema — it
 * has NOT been verified against a real pre-v14 database file. Before relying on
 * this test as a release gate:
 *   1. If a backup/export from an old (pre-2023-ish) install of this app still
 *      exists anywhere, pull its .db file and compare its `sqlite3 .schema`
 *      output against `createV13Database()` below — fix any mismatch found.
 *   2. Failing that, install an old APK build (whichever one first shipped
 *      Room version 13) on a throwaway device/emulator, create a few
 *      products/sales/customers, then upgrade it to the current build and
 *      confirm the app opens cleanly and that data — see the manual checklist
 *      in MIGRATION_TEST_PLAN.md for exactly what to check.
 * From v32 onward, this problem cannot recur: schemas are now exported on every
 * build, so every future MIGRATION_32_33 (etc.) test can build its "before"
 * state from a real file instead of hand-written SQL.
 * ================================================================================
 */
@RunWith(AndroidJUnit4::class)
class MigrationTest {

    private val allMigrations = arrayOf(
        MIGRATION_13_14, MIGRATION_14_15, MIGRATION_15_16, MIGRATION_16_17, MIGRATION_17_18,
        MIGRATION_18_19, MIGRATION_19_20, MIGRATION_20_21, MIGRATION_21_22, MIGRATION_22_23,
        MIGRATION_23_24, MIGRATION_24_25, MIGRATION_25_26, MIGRATION_26_27, MIGRATION_27_28,
        MIGRATION_28_29, MIGRATION_29_30, MIGRATION_30_31, MIGRATION_31_32, MIGRATION_32_33
    )

    @get:Rule
    val helper: MigrationTestHelper = MigrationTestHelper(
        InstrumentationRegistry.getInstrumentation(),
        PosDatabase::class.java
    )

    /**
     * Hand-built version-13 schema — see the class-level caveat above. Every
     * table here either (a) is untouched by any migration 13-32, so its shape
     * is just the current @Entity minus nothing, or (b) has columns subtracted
     * out based on which migration first ADDs them, or a type reverted based on
     * which migration first changes it. Each table is commented with which
     * migration(s) justify its v13 shape.
     */
    private fun createV13Database(): SupportSQLiteDatabase {
        val db = helper.createDatabase(TEST_DB, 13)

        // Untouched by any migration 13-32 — same as the current entity.
        db.execSQL("CREATE TABLE units (name TEXT PRIMARY KEY NOT NULL)")
        db.execSQL("CREATE TABLE categories (name TEXT PRIMARY KEY NOT NULL)")
        db.execSQL(
            """CREATE TABLE audit (id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                username TEXT NOT NULL, action TEXT NOT NULL,
                reference TEXT NOT NULL DEFAULT '', details TEXT NOT NULL DEFAULT '',
                createdAt INTEGER NOT NULL)"""
        )
        db.execSQL(
            """CREATE TABLE held_bills (holdId TEXT PRIMARY KEY NOT NULL,
                payload TEXT NOT NULL, createdAt INTEGER NOT NULL)"""
        )
        db.execSQL(
            """CREATE TABLE cash_register (date TEXT PRIMARY KEY NOT NULL,
                openingCash REAL NOT NULL DEFAULT 0.0, closingCash REAL NOT NULL DEFAULT 0.0,
                openingBank REAL NOT NULL DEFAULT 0.0, closingBank REAL NOT NULL DEFAULT 0.0,
                closed INTEGER NOT NULL DEFAULT 0)"""
        )
        db.execSQL("CREATE TABLE app_settings (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)")
        // Same shape at v13 and v32 — MIGRATION_17_18 recreates this table but with
        // an identical column list (a rowid/constraint fix, not a schema change).
        db.execSQL(
            """CREATE TABLE returns (id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                reference TEXT NOT NULL, type TEXT NOT NULL, barcode TEXT NOT NULL,
                qty REAL NOT NULL, amount REAL NOT NULL, createdAt INTEGER NOT NULL)"""
        )

        // MIGRATION_16_17 adds tertiaryUnit/tertiaryUnitQty; MIGRATION_20_21 adds
        // updatedAt/dirty; MIGRATION_24_25 changes stock/reorderLevel/openingStock
        // from INTEGER to REAL — none of those exist/apply yet at v13.
        db.execSQL(
            """CREATE TABLE products (barcode TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL,
                category TEXT NOT NULL DEFAULT '', cost REAL NOT NULL DEFAULT 0.0,
                salePrice REAL NOT NULL DEFAULT 0.0, stock INTEGER NOT NULL DEFAULT 0,
                reorderLevel INTEGER NOT NULL DEFAULT 0, expiry TEXT NOT NULL DEFAULT '',
                unit TEXT NOT NULL DEFAULT 'pcs', unitSize INTEGER NOT NULL DEFAULT 1,
                unitNote TEXT NOT NULL DEFAULT '', secondaryUnit TEXT NOT NULL DEFAULT '',
                secondaryUnitQty REAL NOT NULL DEFAULT 0.0, wholesalePrice REAL NOT NULL DEFAULT 0.0,
                openingStock INTEGER NOT NULL DEFAULT 0)"""
        )

        // MIGRATION_14_15 adds openingBalance; MIGRATION_20_21 adds serverId/updatedAt/dirty.
        db.execSQL(
            """CREATE TABLE customers (id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                name TEXT NOT NULL, phone TEXT NOT NULL DEFAULT '', balance REAL NOT NULL DEFAULT 0.0)"""
        )
        db.execSQL(
            """CREATE TABLE suppliers (id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                name TEXT NOT NULL, phone TEXT NOT NULL DEFAULT '', balance REAL NOT NULL DEFAULT 0.0)"""
        )

        // MIGRATION_15_16 adds status; MIGRATION_20_21 adds updatedAt/dirty;
        // MIGRATION_29_30 adds dueDate; MIGRATION_31_32 adds saleUid.
        db.execSQL(
            """CREATE TABLE sales (invoice TEXT PRIMARY KEY NOT NULL, customerId INTEGER,
                subtotal REAL NOT NULL, discount REAL NOT NULL, tax REAL NOT NULL,
                total REAL NOT NULL, paid REAL NOT NULL, paymentMethod TEXT NOT NULL,
                saleType TEXT NOT NULL DEFAULT 'retail', createdAt INTEGER NOT NULL)"""
        )

        // MIGRATION_19_20 adds unit; MIGRATION_23_24 changes qty INTEGER -> REAL;
        // MIGRATION_25_26 adds conversionFactor; MIGRATION_31_32 adds lineUid.
        db.execSQL(
            """CREATE TABLE sale_items (id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                invoice TEXT NOT NULL, barcode TEXT NOT NULL, product TEXT NOT NULL,
                qty INTEGER NOT NULL, unitPrice REAL NOT NULL, cost REAL NOT NULL,
                amount REAL NOT NULL)"""
        )

        // MIGRATION_20_21 adds serverId/updatedAt/dirty.
        db.execSQL(
            """CREATE TABLE payments (id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                reference TEXT NOT NULL, partyType TEXT NOT NULL, partyId INTEGER,
                amount REAL NOT NULL, method TEXT NOT NULL, note TEXT NOT NULL DEFAULT '',
                createdAt INTEGER NOT NULL)"""
        )

        // MIGRATION_15_16 adds status; MIGRATION_20_21 adds updatedAt/dirty;
        // MIGRATION_31_32 adds purchaseUid.
        db.execSQL(
            """CREATE TABLE purchases (billNo TEXT PRIMARY KEY NOT NULL, supplierId INTEGER,
                total REAL NOT NULL, paid REAL NOT NULL, createdAt INTEGER NOT NULL,
                subtotal REAL NOT NULL DEFAULT 0.0, discount REAL NOT NULL DEFAULT 0.0)"""
        )

        // MIGRATION_13_14 (the very first migration in this chain) adds `unit` — so
        // it must NOT exist yet here. MIGRATION_25_26 adds conversionFactor;
        // MIGRATION_31_32 adds lineUid.
        db.execSQL(
            """CREATE TABLE purchase_items (id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                billNo TEXT NOT NULL, barcode TEXT NOT NULL, qty REAL NOT NULL,
                unitCost REAL NOT NULL, amount REAL NOT NULL)"""
        )

        // MIGRATION_22_23 adds phone.
        db.execSQL(
            """CREATE TABLE users (username TEXT PRIMARY KEY NOT NULL, displayName TEXT NOT NULL,
                role TEXT NOT NULL, passwordHash TEXT NOT NULL, active INTEGER NOT NULL DEFAULT 1)"""
        )

        // MIGRATION_20_21 adds serverId/updatedAt/dirty.
        db.execSQL(
            """CREATE TABLE expenses (id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                category TEXT NOT NULL, description TEXT NOT NULL, amount REAL NOT NULL,
                createdAt INTEGER NOT NULL)"""
        )

        // MIGRATION_20_21 adds serverId/updatedAt/dirty.
        db.execSQL(
            """CREATE TABLE cash_transactions (id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                type TEXT NOT NULL, method TEXT NOT NULL, amount REAL NOT NULL,
                reason TEXT NOT NULL DEFAULT '', reference TEXT NOT NULL DEFAULT '',
                createdAt INTEGER NOT NULL)"""
        )

        db.close()
        return db
    }

    /**
     * The headline test for this checklist item: every migration from the
     * oldest supported version (13) to the current version (33) runs, in
     * order, without throwing — on a real on-device SQLite engine, not a
     * mock. `validateDroppedTables = true` also fails the test if any
     * migration accidentally leaves a stray `_new`/`_old` table behind from
     * a table-recreate step (e.g. MIGRATION_17_18, MIGRATION_23_24,
     * MIGRATION_24_25, MIGRATION_27_28 each rename a temp table over the
     * original — this catches it if one of them ever forgets the final
     * DROP/RENAME step).
     */
    @Test
    fun migrateFromV13AllTheWayTo33_runsCleanly() {
        createV13Database()
        helper.runMigrationsAndValidate(TEST_DB, 33, true, *allMigrations)
    }

    /**
     * Every individual step also gets its own migrate-and-validate call, so a
     * failure in (say) MIGRATION_24_25 points straight at that migration
     * instead of forcing a bisection through the full chain.
     */
    @Test
    fun everyStepMigratesIndividually() {
        var version = 13
        createV13Database()
        for (migration in allMigrations) {
            val nextVersion = version + 1
            helper.runMigrationsAndValidate(TEST_DB, nextVersion, true, migration)
            version = nextVersion
        }
        assertEquals(33, version)
    }

    /**
     * Data-integrity check for MIGRATION_18_19 / MIGRATION_21_22: these
     * UPDATE existing products' stock/openingStock/reorderLevel to account
     * for the (then-new) secondary/tertiary unit ladder, using
     * `stock * secondaryUnitQty * tertiaryUnitQty` (falling back to 1 for a
     * missing tier). A product with a 2-tier ladder (Box of 12 Pcs, no
     * tertiary tier) with stock=5 boxes should come out as 60 (smallest-unit)
     * pieces after both migrations, not silently stay at 5 or corrupt to 0.
     */
    @Test
    fun unitLadderMigration_convertsStockToSmallestUnitsCorrectly() {
        val v13 = createV13Database()
        // Product with a 2-tier ladder: 1 Box = 12 Pcs, no tertiary tier, stock=5 (boxes).
        v13.execSQL(
            "INSERT INTO products (barcode, name, unit, secondaryUnit, secondaryUnitQty, stock, reorderLevel, openingStock) " +
                "VALUES ('TESTBOX', 'Test Box Item', 'Box', 'Pcs', 12.0, 5, 1, 5)"
        )
        v13.close()

        helper.runMigrationsAndValidate(
            TEST_DB, 22, true,
            MIGRATION_13_14, MIGRATION_14_15, MIGRATION_15_16, MIGRATION_16_17, MIGRATION_17_18,
            MIGRATION_18_19, MIGRATION_19_20, MIGRATION_20_21, MIGRATION_21_22
        )

        val after = helper.runMigrationsAndValidate(TEST_DB, 22, true)
        val cursor = after.query("SELECT stock, reorderLevel, openingStock FROM products WHERE barcode='TESTBOX'")
        cursor.use {
            assertTrue("expected the seeded TESTBOX row to survive the migration chain", it.moveToFirst())
            assertEquals(60, it.getInt(0)) // 5 boxes * 12 pcs/box
            assertEquals(12, it.getInt(1)) // 1 box * 12 pcs/box
            assertEquals(60, it.getInt(2)) // 5 boxes * 12 pcs/box
        }
    }

    /**
     * Data-integrity check for MIGRATION_31_32's UUID backfill: a
     * pre-existing sale/purchase (created before this migration ever ran)
     * must come out with a real, non-blank saleUid/purchaseUid afterward —
     * not left as the '' the plain ADD COLUMN default would otherwise leave
     * it at.
     */
    @Test
    fun saleUidBackfill_givesExistingSalesARealUid() {
        val v13 = createV13Database()
        v13.execSQL(
            "INSERT INTO sales (invoice, customerId, subtotal, discount, tax, total, paid, paymentMethod, saleType, createdAt) " +
                "VALUES ('PRE-EXISTING-INV', NULL, 100.0, 0.0, 0.0, 100.0, 100.0, 'cash', 'retail', 1690000000000)"
        )
        v13.close()

        helper.runMigrationsAndValidate(TEST_DB, 33, true, *allMigrations)

        val after = helper.runMigrationsAndValidate(TEST_DB, 33, true)
        val cursor = after.query("SELECT saleUid FROM sales WHERE invoice='PRE-EXISTING-INV'")
        cursor.use {
            assertTrue(it.moveToFirst())
            val saleUid = it.getString(0)
            assertTrue("pre-existing sale must be backfilled with a non-blank saleUid, was: '$saleUid'", saleUid.isNotBlank())
        }
    }

    /**
     * Data-integrity + enforcement check for MIGRATION_32_33 (2nd AI review,
     * "UUID unique indexes"): saleUid/lineUid/purchaseUid/lineUid previously had
     * no database-level uniqueness constraint — a bug anywhere upstream (backfill,
     * enqueue helpers, a future edit) could silently produce a duplicate and
     * nothing would ever catch it. This confirms two things on a real on-device
     * SQLite engine: (1) two pre-existing, genuinely-distinct sales survive the
     * migration with their own saleUid intact, and (2) the resulting index truly
     * is UNIQUE — inserting a second row that reuses an existing saleUid must
     * throw, not silently succeed.
     */
    @Test
    fun migration32to33_addsWorkingUniqueIndexOnSaleUid() {
        val v13 = createV13Database()
        v13.execSQL(
            "INSERT INTO sales (invoice, customerId, subtotal, discount, tax, total, paid, paymentMethod, saleType, createdAt) " +
                "VALUES ('INV-ONE', NULL, 50.0, 0.0, 0.0, 50.0, 50.0, 'cash', 'retail', 1690000000000)"
        )
        v13.execSQL(
            "INSERT INTO sales (invoice, customerId, subtotal, discount, tax, total, paid, paymentMethod, saleType, createdAt) " +
                "VALUES ('INV-TWO', NULL, 75.0, 0.0, 0.0, 75.0, 75.0, 'cash', 'retail', 1690000000001)"
        )
        v13.close()

        val after = helper.runMigrationsAndValidate(TEST_DB, 33, true, *allMigrations)

        // Both pre-existing sales kept their own distinct, non-blank saleUid.
        val uids = mutableListOf<String>()
        after.query("SELECT invoice, saleUid FROM sales ORDER BY invoice").use { c ->
            while (c.moveToNext()) uids.add(c.getString(1))
        }
        assertEquals(2, uids.size)
        assertTrue("both backfilled saleUids must be non-blank", uids.all { it.isNotBlank() })
        assertTrue("the two pre-existing sales must not share a saleUid", uids[0] != uids[1])

        // The index must actually be UNIQUE, not just present: reusing an
        // existing saleUid on a brand-new row must be rejected by SQLite itself.
        val duplicateUid = uids[0]
        var threw = false
        try {
            after.execSQL(
                "INSERT INTO sales (invoice, customerId, subtotal, discount, tax, total, paid, paymentMethod, saleType, createdAt, status, updatedAt, dirty, dueDate, saleUid) " +
                    "VALUES ('INV-DUPLICATE', NULL, 10.0, 0.0, 0.0, 10.0, 10.0, 'cash', 'retail', 1690000000002, 'active', 0, 1, 0, ?)",
                arrayOf<Any>(duplicateUid)
            )
        } catch (e: Exception) {
            threw = true
        }
        assertTrue("inserting a duplicate saleUid must be rejected by the unique index", threw)
    }

    companion object {
        private const val TEST_DB = "migration-test"
    }
}
