package com.grocerypos.v11.util

import androidx.room.withTransaction
import com.grocerypos.v11.PosDatabase
import com.grocerypos.v11.Product
import com.grocerypos.v11.SyncQueueHelper

/**
 * ================= One-time maintenance utility =================
 *
 * Finds products that are really the SAME item saved more than once under
 * different barcodes (same name, same unit setup) and merges them into a
 * single product row, combining their stock instead of leaving it split
 * across duplicates.
 *
 * This is a different problem from DuplicateUnitFix.kt (which fixes a
 * single unit VALUE like "Box Box" -> "Box"). Here the duplication is at
 * the PRODUCT level: two (or more) rows in the `products` table share the
 * same name — usually created via the "Save Anyway" override on the
 * "Possible Duplicate Item" prompt in ProductActivity, or via a sync
 * conflict — and each has its own separate stock number, so the shop's
 * real total stock for that item is silently split between them.
 *
 * SAFETY RULE: two products are only ever auto-merged when their name AND
 * their full unit configuration (primary unit, unit size, secondary/
 * tertiary unit + qty) match exactly. If the name matches but the unit
 * setup differs, merging the stock numbers would be comparing apples to
 * oranges (e.g. one row's stock counted in "Box" and the other's in
 * "pcs") — those groups are left untouched and reported separately so a
 * human can look at them instead of the script guessing.
 *
 * WHAT MERGING DOES, for each duplicate group:
 *   1. Picks one row as the KEEPER — the one with the most recent
 *      updatedAt (most recently edited is assumed most accurate for
 *      price/reorder/etc. fields).
 *   2. Stock and openingStock from every row in the group are SUMMED onto
 *      the keeper (nothing is lost).
 *   3. Every historical reference to a merged-away barcode — sale_items,
 *      purchase_items, returns, stock_movements — is repointed to the
 *      keeper's barcode, so Sale/Purchase history and the Stock History
 *      screen still show correctly instead of pointing at a deleted
 *      product.
 *   4. The merged-away product row(s) are deleted and a sync delete is
 *      enqueued for them; the keeper is re-enqueued with its new combined
 *      stock so other devices/branches pick up the merge too.
 *
 * NOT touched: `held_bills` (an in-progress cart snapshot, not permanent
 * history — if a held bill references a barcode that gets merged away,
 * it just won't find that product on resume; this is expected to be rare
 * and low-stakes enough not to add JSON-editing complexity here).
 *
 * HOW TO RUN THIS ONCE: same wiring pattern as DuplicateUnitFix — see the
 * example at the bottom of this file. Safe to run again afterward; a
 * clean database (no name+unit duplicates left) just reports 0 merges.
 */
object MergeDuplicateProductsFix {

    /** Report handed back so the caller can show a meaningful confirmation. */
    data class Result(
        val groupsMerged: Int,
        val productsRemoved: Int,
        val groupsSkippedUnitMismatch: Int
    )

    private data class UnitKey(
        val unit: String,
        val unitSize: Int,
        val secondaryUnit: String,
        val secondaryUnitQty: Double,
        val tertiaryUnit: String,
        val tertiaryUnitQty: Double
    )

    private fun Product.unitKey() = UnitKey(
        unit.trim(), unitSize, secondaryUnit.trim(), secondaryUnitQty,
        tertiaryUnit.trim(), tertiaryUnitQty
    )

    suspend fun run(db: PosDatabase): Result {
        val all = db.productDao().allList()
        // Group by normalized name only, first — this is how we detect the
        // duplicate at all.
        val byName = all.groupBy { it.name.trim().lowercase() }

        var groupsMerged = 0
        var productsRemoved = 0
        var groupsSkippedUnitMismatch = 0

        db.withTransaction {
            val raw = db.openHelper.writableDatabase

            for ((_, group) in byName) {
                if (group.size < 2) continue // nothing duplicated for this name

                // Split further by exact unit configuration — only same-config
                // sub-groups are safe to merge (see class doc SAFETY RULE).
                val byUnit = group.groupBy { it.unitKey() }
                val mergeableSubGroups = byUnit.values.filter { it.size >= 2 }
                val hadAnyUnitMismatch = byUnit.size > 1

                if (mergeableSubGroups.isEmpty()) {
                    if (hadAnyUnitMismatch) groupsSkippedUnitMismatch++
                    continue
                }
                if (hadAnyUnitMismatch) groupsSkippedUnitMismatch++

                for (sub in mergeableSubGroups) {
                    val keeper = sub.maxByOrNull { it.updatedAt } ?: continue
                    val losers = sub.filter { it.barcode != keeper.barcode }
                    if (losers.isEmpty()) continue

                    val combinedStock = sub.sumOf { it.stock }
                    val combinedOpeningStock = sub.sumOf { it.openingStock }
                    val now = System.currentTimeMillis()

                    // Repoint historical rows from every loser barcode onto the
                    // keeper BEFORE deleting the loser product rows.
                    for (loser in losers) {
                        raw.execSQL(
                            "UPDATE sale_items SET barcode=? WHERE barcode=?",
                            arrayOf(keeper.barcode, loser.barcode)
                        )
                        raw.execSQL(
                            "UPDATE purchase_items SET barcode=? WHERE barcode=?",
                            arrayOf(keeper.barcode, loser.barcode)
                        )
                        raw.execSQL(
                            "UPDATE returns SET barcode=? WHERE barcode=?",
                            arrayOf(keeper.barcode, loser.barcode)
                        )
                        raw.execSQL(
                            "UPDATE stock_movements SET barcode=? WHERE barcode=?",
                            arrayOf(keeper.barcode, loser.barcode)
                        )
                    }

                    val mergedKeeper = keeper.copy(
                        stock = combinedStock,
                        openingStock = combinedOpeningStock,
                        dirty = true,
                        updatedAt = now
                    )
                    db.productDao().upsert(mergedKeeper)
                    losers.forEach { db.productDao().delete(it) }

                    SyncQueueHelper.enqueueProduct(db, mergedKeeper)
                    losers.forEach { SyncQueueHelper.enqueueDelete(db, "product", it.barcode) }

                    groupsMerged++
                    productsRemoved += losers.size
                }
            }
        }

        return Result(groupsMerged, productsRemoved, groupsSkippedUnitMismatch)
    }
}

/*
 * ================= Example wiring (temporary button) =================
 *
 * Add this anywhere convenient — e.g. inside BulkTranslateActivity's
 * onCreate(), next to the "Fix Duplicate Unit Names" button from
 * DuplicateUnitFix — then tap it once:
 *
 *   val mergeButton = Button(this).apply {
 *       text = "Merge Duplicate Products"
 *       setOnClickListener {
 *           lifecycleScope.launch {
 *               val db = PosDatabase.get(this@BulkTranslateActivity)
 *               val result = com.grocerypos.v11.util.MergeDuplicateProductsFix.run(db)
 *               val msg = buildString {
 *                   append("${result.groupsMerged} duplicate item(s) merged")
 *                   if (result.productsRemoved > 0) append(" (${result.productsRemoved} row(s) removed, stock combined)")
 *                   if (result.groupsSkippedUnitMismatch > 0) append("\n${result.groupsSkippedUnitMismatch} name-match(es) skipped — different unit setup, needs manual review")
 *               }
 *               Toast.makeText(this@BulkTranslateActivity, msg, Toast.LENGTH_LONG).show()
 *           }
 *       }
 *   }
 *   root.addView(mergeButton)
 *
 * Run DuplicateUnitFix FIRST if unit-name typos (like "Box Box") are also
 * present — cleaning those up first means more products end up with a
 * genuinely matching unit config, so more real duplicates get merged here
 * instead of falling into "skipped — different unit setup".
 */
