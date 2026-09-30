package com.grocerypos.v11.domain

import com.grocerypos.v11.PurchaseItem
import com.grocerypos.v11.SaleItem
import com.grocerypos.v11.data.PurchaseLine

/**
 * Single source of truth for the "did this edit actually touch any item's
 * barcode/qty/unit/rate?" check that both [com.grocerypos.v11.RoomSaleRepository]
 * and [com.grocerypos.v11.RoomPurchaseRepository] use to decide whether an
 * edit needs to reverse+reapply stock (and, for purchases, cost) at all.
 *
 * FIX (regression guard): this used to be two near-identical private
 * `itemsUnchanged()` functions, one copy-pasted into each repository. Pure
 * logic living only inside a class that needs a Room [android.content.Context]
 * to construct meant it could never be exercised by a plain JVM unit test —
 * a future edit to either copy (e.g. "fix" the rounding, add a field to
 * compare) could silently break the "unchanged items never touch stock"
 * guarantee and no test would catch it. Pulling it out here, with no Android
 * dependency, lets [StockTouchPolicyTest] cover both call sites directly.
 */
object StockTouchPolicy {

    // Same tolerance both original copies used: values are compared after
    // rounding to 6 decimal places, so float noise well below any real qty/rate
    // never counts as "changed".
    private fun key(barcode: String, qty: Double, unit: String, rate: Double) =
        "$barcode|${"%.6f".format(qty)}|$unit|${"%.6f".format(rate)}"

    /** True when [lines] (the edited Sale screen state) describe exactly the
     * same set of barcode/qty/unit/rate combinations as [originalItems] (what
     * was actually saved before) — order does not matter. */
    fun saleItemsUnchanged(lines: List<SaleLine>, originalItems: List<SaleItem>): Boolean {
        if (lines.size != originalItems.size) return false
        val lineKeys = lines.map { key(it.barcode, it.qty, it.unit, it.unitPrice) }.sorted()
        val itemKeys = originalItems.map { key(it.barcode, it.qty, it.unit, it.unitPrice) }.sorted()
        return lineKeys == itemKeys
    }

    /**
     * Result of [saleEditDiff]: what an EDITED sale bill actually changed, line by line.
     *
     * @property itemsToReverse original bill rows that no longer appear as-is — only THESE
     *   get their stock given back.
     * @property changedLineIndices indices (into the edited `lines` list) of lines that are
     *   new or modified — only THESE get stock deducted again (and stock-checked).
     * @property unchangedOriginalByIndex for every line the user left completely alone, the
     *   original [SaleItem] it matches — so its frozen `conversionFactor` can be carried over.
     */
    class SaleEditDiff(
        val itemsToReverse: List<SaleItem>,
        val changedLineIndices: Set<Int>,
        val unchangedOriginalByIndex: Map<Int, SaleItem>
    )

    // FIX (sale edit silently changes stock of an UNTOUCHED item): saleItemsUnchanged() above
    // is whole-bill — editing even ONE line (or just adding a new one) made
    // RoomSaleRepository reverse the stock of EVERY original line using its FROZEN
    // conversionFactor and then deduct EVERY line again using the product's CURRENT unit
    // ladder. Whenever those two disagreed for an untouched line (unit ladder edited since the
    // sale, unit renamed, old row with no factor...) that line's stock drifted on every edit —
    // "edit karte waqat koi na koi item ka stock kam ho jata hai". Same root cause and same
    // cure as purchaseChangedLines() below: pair off every line the user left exactly as it
    // was (multiset match on barcode|qty|unit|rate) and skip it on BOTH sides; only leftovers
    // are reversed / reapplied. Index-based (not equality-based) so two identical lines on one
    // bill are handled correctly.
    fun saleEditDiff(lines: List<SaleLine>, originalItems: List<SaleItem>): SaleEditDiff {
        val remainingOriginal = originalItems.toMutableList()
        val changed = mutableSetOf<Int>()
        val unchanged = mutableMapOf<Int, SaleItem>()
        lines.forEachIndexed { index, line ->
            val lineKey = key(line.barcode, line.qty, line.unit, line.unitPrice)
            val matchIndex = remainingOriginal.indexOfFirst {
                key(it.barcode, it.qty, it.unit, it.unitPrice) == lineKey
            }
            if (matchIndex >= 0) {
                unchanged[index] = remainingOriginal.removeAt(matchIndex)
            } else {
                changed.add(index)
            }
        }
        return SaleEditDiff(remainingOriginal, changed, unchanged)
    }

    /** Same comparison as [saleItemsUnchanged], for the Purchase screen. A
     * null [PurchaseLine.barcode] is treated as "" — matching how
     * RoomPurchaseRepository.savePurchase already persists it (`line.barcode
     * ?: ""`) when it builds the [PurchaseItem] row. */
    fun purchaseItemsUnchanged(lines: List<PurchaseLine>, originalItems: List<PurchaseItem>): Boolean {
        if (lines.size != originalItems.size) return false
        val lineKeys = lines.map { key(it.barcode ?: "", it.qty, it.unit, it.rate) }.sorted()
        val itemKeys = originalItems.map { key(it.barcode, it.qty, it.unit, it.unitCost) }.sorted()
        return lineKeys == itemKeys
    }

    // FIX (edit-blocked-by-UNRELATED-line bug): purchaseItemsUnchanged() above is
    // whole-bill — editing even ONE line (leaving every other line untouched) makes
    // it report "changed", which used to make RoomPurchaseRepository reverse+reapply
    // EVERY original line, not just the one actually edited. If a later sale had
    // since eaten into some OTHER, untouched line's stock, reversing that untouched
    // line would go negative and reverseStockAndCostForItems() correctly refused the
    // whole edit ("... ka stock is purchase ke baad already kam ho chuka hai...") —
    // even though the line actually being edited had nothing to do with that
    // product. This does a multiset match (same barcode|qty|unit|rate key as
    // itemsUnchanged) between [originalItems] and [lines]: every exact match is a
    // line the user left alone and is paired off (skipped entirely, both sides);
    // whatever's left over on each side is what actually changed — the leftover
    // original items need their stock/cost reversed, the leftover lines need it
    // reapplied. A fully-unchanged edit (e.g. only Paid Amount changed) naturally
    // returns two empty lists here, same as skipStockTouch used to short-circuit.
    fun purchaseChangedLines(
        lines: List<PurchaseLine>,
        originalItems: List<PurchaseItem>
    ): Pair<List<PurchaseItem>, List<PurchaseLine>> {
        val remainingOriginal = originalItems.toMutableList()
        val linesNeedingReapply = mutableListOf<PurchaseLine>()
        for (line in lines) {
            val lineKey = key(line.barcode ?: "", line.qty, line.unit, line.rate)
            val matchIndex = remainingOriginal.indexOfFirst {
                key(it.barcode, it.qty, it.unit, it.unitCost) == lineKey
            }
            if (matchIndex >= 0) {
                remainingOriginal.removeAt(matchIndex)
            } else {
                linesNeedingReapply.add(line)
            }
        }
        return remainingOriginal to linesNeedingReapply
    }

    /** Purchase twin of [SaleEditDiff]: index-based result of [purchaseEditDiff]. */
    class PurchaseEditDiff(
        val itemsToReverse: List<PurchaseItem>,
        val changedLineIndices: Set<Int>,
        val unchangedOriginalByIndex: Map<Int, PurchaseItem>
    )

    // FIX (purchase edit — same bug family as saleEditDiff): purchaseChangedLines() above
    // returns the leftover LINES as values, and RoomPurchaseRepository looked them up with
    // `line in hashSet` — data-class EQUALITY. With two identical lines on a bill (e.g. the
    // user adds a second "Sugar 10 Kg @ 200" next to an existing one) the leftover new line
    // equals the untouched one, so BOTH matched the set and the untouched line's stock/cost
    // got applied a second time (stock inflated). Matching by index removes that ambiguity,
    // and also hands back the untouched line's original row so its frozen conversionFactor
    // (and its retail/wholesale snapshot) can be carried over instead of re-stamped.
    fun purchaseEditDiff(lines: List<PurchaseLine>, originalItems: List<PurchaseItem>): PurchaseEditDiff {
        val remainingOriginal = originalItems.toMutableList()
        val changed = mutableSetOf<Int>()
        val unchanged = mutableMapOf<Int, PurchaseItem>()
        lines.forEachIndexed { index, line ->
            val lineKey = key(line.barcode ?: "", line.qty, line.unit, line.rate)
            val matchIndex = remainingOriginal.indexOfFirst {
                key(it.barcode, it.qty, it.unit, it.unitCost) == lineKey
            }
            if (matchIndex >= 0) {
                unchanged[index] = remainingOriginal.removeAt(matchIndex)
            } else {
                changed.add(index)
            }
        }
        return PurchaseEditDiff(remainingOriginal, changed, unchanged)
    }
}
