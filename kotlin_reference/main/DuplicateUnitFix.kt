package com.grocerypos.v11.util

import com.grocerypos.v11.PosDatabase
import com.grocerypos.v11.SyncQueueHelper

/**
 * ================= One-time maintenance utility =================
 *
 * Detects and fixes unit names that got accidentally duplicated on entry —
 * e.g. "Box\nBox", "Box Box", "Pcs  Pcs" — where the same word was typed
 * twice into a single unit field (Primary / Secondary / Tertiary).
 *
 * This scans EVERY distinct unit value used anywhere in the products table
 * (all categories, not just one), so it fixes the problem everywhere in a
 * single run instead of editing products one by one.
 *
 * It reuses the existing rename functions in ProductDao
 * (renamePrimaryUnitInProducts / renameSecondaryUnitInProducts /
 * renameTertiaryUnitInProducts) — the same ones BulkTranslateActivity uses —
 * so no new database queries or schema changes are needed.
 *
 * HOW TO RUN THIS ONCE:
 *   1. Wire this up to a temporary button (e.g. in BulkTranslateActivity or
 *      Settings) — see wiring example at the bottom of this file.
 *   2. Tap it once. It will show how many unit values it fixed.
 *   3. You can remove the button afterward, or leave it — running it again
 *      on an already-clean database is harmless (it just finds nothing to fix).
 */
object DuplicateUnitFix {

    /**
     * If [raw] is exactly the same word repeated twice (any whitespace /
     * newline between them, case-insensitive), returns the single clean word.
     * Otherwise returns null (nothing to fix for this value).
     *
     * Examples:
     *   "Box\nBox"   -> "Box"
     *   "Box Box"    -> "Box"
     *   "box   BOX"  -> "box"   (keeps the first occurrence's casing)
     *   "Box"        -> null    (already clean)
     *   "Big Box"    -> null    (two DIFFERENT words — left untouched on purpose)
     */
    private fun dedupedName(raw: String): String? {
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) return null
        val parts = trimmed.split(Regex("\\s+")).filter { it.isNotBlank() }
        if (parts.size == 2 && parts[0].equals(parts[1], ignoreCase = true)) {
            return parts[0]
        }
        return null
    }

    /**
     * Scans Primary / Secondary / Tertiary unit values across every product
     * and fixes any that are a duplicated word. Returns how many distinct
     * unit values were fixed (for a confirmation Toast).
     *
     * Safe to run multiple times — already-clean values are simply skipped.
     */
    suspend fun run(db: PosDatabase): Int {
        val dao = db.productDao()
        var fixedCount = 0
        // FIX (#12 — category/unit master sync incomplete): same gap as
        // BulkTranslateActivity.saveAll() — the rename* queries below are raw
        // SQL UPDATEs that never touched sync on their own. Track every
        // barcode actually changed so it can be re-enqueued after the fix.
        val touchedBarcodes = mutableSetOf<String>()

        for (old in dao.distinctPrimaryUnits()) {
            val clean = dedupedName(old) ?: continue
            dao.findByPrimaryUnit(old).forEach { touchedBarcodes.add(it.barcode) }
            dao.renamePrimaryUnitInProducts(old, clean)
            fixedCount++
        }

        for (old in dao.distinctSecondaryUnits()) {
            val clean = dedupedName(old) ?: continue
            dao.findBySecondaryUnit(old).forEach { touchedBarcodes.add(it.barcode) }
            dao.renameSecondaryUnitInProducts(old, clean)
            fixedCount++
        }

        for (old in dao.distinctTertiaryUnits()) {
            val clean = dedupedName(old) ?: continue
            dao.findByTertiaryUnit(old).forEach { touchedBarcodes.add(it.barcode) }
            dao.renameTertiaryUnitInProducts(old, clean)
            fixedCount++
        }

        touchedBarcodes.forEach { barcode ->
            dao.find(barcode)?.let { p -> SyncQueueHelper.enqueueProduct(db, p) }
        }

        return fixedCount
    }
}

/*
 * ================= Example wiring (temporary button) =================
 *
 * Add this anywhere convenient — e.g. inside BulkTranslateActivity's
 * onCreate(), right after its existing UI setup — then tap it once:
 *
 *   val fixButton = Button(this).apply {
 *       text = "Fix Duplicate Unit Names"
 *       setOnClickListener {
 *           lifecycleScope.launch {
 *               val db = PosDatabase.get(this@BulkTranslateActivity)
 *               val count = com.grocerypos.v11.util.DuplicateUnitFix.run(db)
 *               Toast.makeText(
 *                   this@BulkTranslateActivity,
 *                   if (count > 0) "$count unit name(s) fixed across all products"
 *                   else "No duplicated unit names found",
 *                   Toast.LENGTH_LONG
 *               ).show()
 *           }
 *       }
 *   }
 *   root.addView(fixButton)   // add to whatever root layout the screen uses
 *
 * Once you've run it and confirmed the Toast shows the fix, you can delete
 * this button — the underlying DuplicateUnitFix.kt file can stay in the
 * project harmlessly for future use if this ever happens again.
 */
