package com.grocerypos.v11.domain

import com.grocerypos.v11.PurchaseItem
import com.grocerypos.v11.SaleItem
import com.grocerypos.v11.data.PurchaseLine
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Regression guard for [StockTouchPolicy] — the "did this edit actually
 * touch any item?" check both RoomSaleRepository and RoomPurchaseRepository
 * use to decide whether an edit needs to reverse+reapply stock/cost at all.
 *
 * This is exactly the itemsUnchanged() bug class described in
 * RoomSaleRepository/RoomPurchaseRepository's comments: an edit that only
 * changes something unrelated (customer name, Paid Amount, date) must NOT
 * touch stock, while ANY change to a line's barcode/qty/unit/rate MUST.
 * These tests exist so a future change to the comparison (rounding,
 * ordering, a forgotten field) gets caught here instead of surfacing as a
 * false "Stock badal gaya hai" or a silent double-decrement in production.
 */
class StockTouchPolicyTest {

    // ---------------------------------------------------------------------
    // Sale side
    // ---------------------------------------------------------------------

    private fun saleLine(
        barcode: String = "B1",
        qty: Double = 2.0,
        unit: String = "Piece",
        unitPrice: Double = 50.0
    ) = SaleLine(
        barcode = barcode,
        itemName = "Item $barcode",
        qty = qty,
        unit = unit,
        unitPrice = unitPrice,
        cost = 0.0,
        amount = qty * unitPrice,
        mainUnit = "Piece",
        secondaryUnit = "",
        secondaryUnitQty = 0.0
    )

    private fun saleItem(
        barcode: String = "B1",
        qty: Double = 2.0,
        unit: String = "Piece",
        unitPrice: Double = 50.0
    ) = SaleItem(
        invoice = "INV1",
        barcode = barcode,
        product = "Item $barcode",
        qty = qty,
        unit = unit,
        unitPrice = unitPrice,
        cost = 0.0,
        amount = qty * unitPrice
    )

    @Test
    fun `identical single sale line is unchanged`() {
        assertTrue(StockTouchPolicy.saleItemsUnchanged(listOf(saleLine()), listOf(saleItem())))
    }

    @Test
    fun `sale lines in a different order are still unchanged`() {
        val lines = listOf(saleLine(barcode = "B2"), saleLine(barcode = "B1"))
        val items = listOf(saleItem(barcode = "B1"), saleItem(barcode = "B2"))
        assertTrue(StockTouchPolicy.saleItemsUnchanged(lines, items))
    }

    @Test
    fun `different qty on a sale line counts as changed`() {
        val lines = listOf(saleLine(qty = 3.0))
        val items = listOf(saleItem(qty = 2.0))
        assertFalse(StockTouchPolicy.saleItemsUnchanged(lines, items))
    }

    @Test
    fun `different unit on a sale line counts as changed`() {
        val lines = listOf(saleLine(unit = "Dozen"))
        val items = listOf(saleItem(unit = "Piece"))
        assertFalse(StockTouchPolicy.saleItemsUnchanged(lines, items))
    }

    @Test
    fun `different rate on a sale line counts as changed`() {
        val lines = listOf(saleLine(unitPrice = 55.0))
        val items = listOf(saleItem(unitPrice = 50.0))
        assertFalse(StockTouchPolicy.saleItemsUnchanged(lines, items))
    }

    @Test
    fun `different barcode counts as changed even with same qty-unit-rate`() {
        val lines = listOf(saleLine(barcode = "B9"))
        val items = listOf(saleItem(barcode = "B1"))
        assertFalse(StockTouchPolicy.saleItemsUnchanged(lines, items))
    }

    @Test
    fun `adding or removing a sale line counts as changed`() {
        val lines = listOf(saleLine(barcode = "B1"), saleLine(barcode = "B2"))
        val items = listOf(saleItem(barcode = "B1"))
        assertFalse(StockTouchPolicy.saleItemsUnchanged(lines, items))
    }

    @Test
    fun `sub-tolerance float noise on qty and rate still counts as unchanged`() {
        // Both round to the same value at 6 decimal places — must not trip a
        // stock reverse+reapply over floating point noise.
        val lines = listOf(saleLine(qty = 2.0000001, unitPrice = 50.0000004))
        val items = listOf(saleItem(qty = 2.0, unitPrice = 50.0))
        assertTrue(StockTouchPolicy.saleItemsUnchanged(lines, items))
    }

    // ---------------------------------------------------------------------
    // Sale side — saleEditDiff() (per-line, not whole-bill)
    // ---------------------------------------------------------------------

    @Test
    fun `saleEditDiff - fully unchanged bill touches nothing`() {
        val d = StockTouchPolicy.saleEditDiff(
            listOf(saleLine(barcode = "B1"), saleLine(barcode = "B2")),
            listOf(saleItem(barcode = "B2"), saleItem(barcode = "B1"))
        )
        assertTrue(d.itemsToReverse.isEmpty())
        assertTrue(d.changedLineIndices.isEmpty())
        assertEquals(setOf(0, 1), d.unchangedOriginalByIndex.keys)
    }

    @Test
    fun `saleEditDiff - editing one line leaves the other line's stock alone`() {
        // B1 qty 2 -> 5 (changed); B2 untouched.
        val lines = listOf(saleLine(barcode = "B1", qty = 5.0), saleLine(barcode = "B2"))
        val items = listOf(saleItem(barcode = "B1", qty = 2.0), saleItem(barcode = "B2"))
        val d = StockTouchPolicy.saleEditDiff(lines, items)
        assertEquals(listOf("B1"), d.itemsToReverse.map { it.barcode })
        assertEquals(setOf(0), d.changedLineIndices)
        assertEquals("B2", d.unchangedOriginalByIndex[1]?.barcode)
    }

    @Test
    fun `saleEditDiff - adding a new line reverses nothing and applies only the new line`() {
        val lines = listOf(saleLine(barcode = "B1"), saleLine(barcode = "B9"))
        val items = listOf(saleItem(barcode = "B1"))
        val d = StockTouchPolicy.saleEditDiff(lines, items)
        assertTrue(d.itemsToReverse.isEmpty())
        assertEquals(setOf(1), d.changedLineIndices)
    }

    @Test
    fun `saleEditDiff - removing a line only reverses the removed line`() {
        val lines = listOf(saleLine(barcode = "B1"))
        val items = listOf(saleItem(barcode = "B1"), saleItem(barcode = "B2"))
        val d = StockTouchPolicy.saleEditDiff(lines, items)
        assertEquals(listOf("B2"), d.itemsToReverse.map { it.barcode })
        assertTrue(d.changedLineIndices.isEmpty())
    }

    @Test
    fun `saleEditDiff - two identical lines with one edited only changes one of them`() {
        // Original bill: B1 x2 twice. Edit turns the second one into qty 4.
        val lines = listOf(saleLine(barcode = "B1", qty = 2.0), saleLine(barcode = "B1", qty = 4.0))
        val items = listOf(saleItem(barcode = "B1", qty = 2.0), saleItem(barcode = "B1", qty = 2.0))
        val d = StockTouchPolicy.saleEditDiff(lines, items)
        assertEquals(1, d.itemsToReverse.size)
        assertEquals(setOf(1), d.changedLineIndices)
        assertEquals(setOf(0), d.unchangedOriginalByIndex.keys)
    }

    // ---------------------------------------------------------------------
    // Purchase side
    // ---------------------------------------------------------------------

    private fun purchaseLine(
        barcode: String? = "B1",
        qty: Double = 2.0,
        unit: String = "Piece",
        rate: Double = 40.0
    ) = PurchaseLine(
        itemName = "Item ${barcode ?: ""}",
        barcode = barcode,
        qty = qty,
        unit = unit,
        rate = rate,
        amount = qty * rate,
        mainUnit = "Piece",
        secondaryUnit = "",
        secondaryUnitQty = 0.0
    )

    private fun purchaseItem(
        barcode: String = "B1",
        qty: Double = 2.0,
        unit: String = "Piece",
        unitCost: Double = 40.0
    ) = PurchaseItem(
        billNo = "BILL1",
        barcode = barcode,
        qty = qty,
        unitCost = unitCost,
        amount = qty * unitCost,
        unit = unit
    )

    @Test
    fun `purchaseEditDiff - adding a duplicate of an existing line applies only the new one`() {
        // Original: Sugar x2. Edit adds a second identical line. Only index 1 is new —
        // index 0 must NOT be re-applied (old equality-based lookup applied both).
        val lines = listOf(purchaseLine(barcode = "B1"), purchaseLine(barcode = "B1"))
        val items = listOf(purchaseItem(barcode = "B1"))
        val d = StockTouchPolicy.purchaseEditDiff(lines, items)
        assertTrue(d.itemsToReverse.isEmpty())
        assertEquals(setOf(1), d.changedLineIndices)
        assertEquals(setOf(0), d.unchangedOriginalByIndex.keys)
    }

    @Test
    fun `purchaseEditDiff - editing one line leaves the untouched line alone`() {
        val lines = listOf(purchaseLine(barcode = "B1", qty = 9.0), purchaseLine(barcode = "B2"))
        val items = listOf(purchaseItem(barcode = "B1", qty = 2.0), purchaseItem(barcode = "B2"))
        val d = StockTouchPolicy.purchaseEditDiff(lines, items)
        assertEquals(listOf("B1"), d.itemsToReverse.map { it.barcode })
        assertEquals(setOf(0), d.changedLineIndices)
        assertEquals("B2", d.unchangedOriginalByIndex[1]?.barcode)
    }

    @Test
    fun `purchaseEditDiff - fully unchanged bill touches nothing`() {
        val d = StockTouchPolicy.purchaseEditDiff(listOf(purchaseLine()), listOf(purchaseItem()))
        assertTrue(d.itemsToReverse.isEmpty())
        assertTrue(d.changedLineIndices.isEmpty())
    }

    @Test
    fun `identical single purchase line is unchanged`() {
        assertTrue(StockTouchPolicy.purchaseItemsUnchanged(listOf(purchaseLine()), listOf(purchaseItem())))
    }

    @Test
    fun `different qty on a purchase line counts as changed`() {
        val lines = listOf(purchaseLine(qty = 5.0))
        val items = listOf(purchaseItem(qty = 2.0))
        assertFalse(StockTouchPolicy.purchaseItemsUnchanged(lines, items))
    }

    @Test
    fun `different rate on a purchase line counts as changed`() {
        val lines = listOf(purchaseLine(rate = 45.0))
        val items = listOf(purchaseItem(unitCost = 40.0))
        assertFalse(StockTouchPolicy.purchaseItemsUnchanged(lines, items))
    }

    @Test
    fun `different unit on a purchase line counts as changed`() {
        val lines = listOf(purchaseLine(unit = "Dozen"))
        val items = listOf(purchaseItem(unit = "Piece"))
        assertFalse(StockTouchPolicy.purchaseItemsUnchanged(lines, items))
    }

    @Test
    fun `adding or removing a purchase line counts as changed`() {
        val lines = listOf(purchaseLine(barcode = "B1"), purchaseLine(barcode = "B2"))
        val items = listOf(purchaseItem(barcode = "B1"))
        assertFalse(StockTouchPolicy.purchaseItemsUnchanged(lines, items))
    }

    @Test
    fun `null barcode purchase line is treated as empty string, matching how it is persisted`() {
        val lines = listOf(purchaseLine(barcode = null))
        val items = listOf(purchaseItem(barcode = ""))
        assertTrue(StockTouchPolicy.purchaseItemsUnchanged(lines, items))
    }

    @Test
    fun `purchase lines in a different order are still unchanged`() {
        val lines = listOf(purchaseLine(barcode = "B2"), purchaseLine(barcode = "B1"))
        val items = listOf(purchaseItem(barcode = "B1"), purchaseItem(barcode = "B2"))
        assertTrue(StockTouchPolicy.purchaseItemsUnchanged(lines, items))
    }

    // ---------------------------------------------------------------------
    // Purchase side — purchaseChangedLines() (per-line, not whole-bill)
    // ---------------------------------------------------------------------

    @Test
    fun `changedLines - fully unchanged bill yields two empty lists`() {
        val lines = listOf(purchaseLine(barcode = "B1"), purchaseLine(barcode = "B2"))
        val items = listOf(purchaseItem(barcode = "B1"), purchaseItem(barcode = "B2"))
        val (toReverse, toApply) = StockTouchPolicy.purchaseChangedLines(lines, items)
        assertTrue(toReverse.isEmpty())
        assertTrue(toApply.isEmpty())
    }

    @Test
    fun `changedLines - editing one line leaves the other line untouched on both sides`() {
        // B1 edited (qty 2 -> 5), B2 left exactly as it was.
        val lines = listOf(purchaseLine(barcode = "B1", qty = 5.0), purchaseLine(barcode = "B2"))
        val items = listOf(purchaseItem(barcode = "B1", qty = 2.0), purchaseItem(barcode = "B2"))
        val (toReverse, toApply) = StockTouchPolicy.purchaseChangedLines(lines, items)
        // Only B1's original row needs reversing...
        assertTrue(toReverse.size == 1 && toReverse[0].barcode == "B1")
        // ...and only B1's edited line needs reapplying. B2 never appears on
        // either side, so its stock/cost is left completely alone — this is
        // the exact case that used to trip "already kam ho chuka hai" on B2
        // just because B1 was the one actually being edited.
        assertTrue(toApply.size == 1 && toApply[0].barcode == "B1")
    }

    @Test
    fun `changedLines - a newly added line has no original counterpart to reverse`() {
        val lines = listOf(purchaseLine(barcode = "B1"), purchaseLine(barcode = "B2"))
        val items = listOf(purchaseItem(barcode = "B1"))
        val (toReverse, toApply) = StockTouchPolicy.purchaseChangedLines(lines, items)
        assertTrue(toReverse.isEmpty())
        assertTrue(toApply.size == 1 && toApply[0].barcode == "B2")
    }

    @Test
    fun `changedLines - a removed line has no edited counterpart to reapply`() {
        val lines = listOf(purchaseLine(barcode = "B1"))
        val items = listOf(purchaseItem(barcode = "B1"), purchaseItem(barcode = "B2"))
        val (toReverse, toApply) = StockTouchPolicy.purchaseChangedLines(lines, items)
        assertTrue(toReverse.size == 1 && toReverse[0].barcode == "B2")
        assertTrue(toApply.isEmpty())
    }
}
