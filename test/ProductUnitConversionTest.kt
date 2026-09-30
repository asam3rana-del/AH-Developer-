package com.grocerypos.v11

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Tests for the 3-tier unit conversion helpers in Database.kt
 * (unitLadder / toSmallestUnits / fromSmallestUnits / isValidSmallestQty /
 * toPrimaryUnitRate). This is the single source of truth every screen
 * (Purchase, Sale, Returns, Opening Stock) relies on to convert between a
 * product's primary/secondary/tertiary units and the "smallest unit" that
 * `stock` is actually stored in — a bug here silently corrupts stock across
 * the whole app, so each tier count and both conversion directions are
 * covered.
 */
class ProductUnitConversionTest {

    private fun product(
        unit: String = "Carton",
        secondaryUnit: String = "",
        secondaryUnitQty: Double = 0.0,
        tertiaryUnit: String = "",
        tertiaryUnitQty: Double = 0.0,
        stock: Double = 0.0
    ) = Product(
        barcode = "TEST123",
        name = "Test Product",
        unit = unit,
        secondaryUnit = secondaryUnit,
        secondaryUnitQty = secondaryUnitQty,
        tertiaryUnit = tertiaryUnit,
        tertiaryUnitQty = tertiaryUnitQty,
        stock = stock
    )

    // ---- unitLadder() tier detection ----

    @Test
    fun `single-tier product - only primary unit`() {
        val p = product(unit = "Piece")
        val ladder = p.unitLadder()
        assertEquals(1, ladder.size)
        assertEquals("Piece", ladder[0].unit)
        assertEquals(1.0, ladder[0].smallestPerUnit, 0.0)
    }

    @Test
    fun `two-tier product - primary and secondary`() {
        // 1 Carton = 10 Box
        val p = product(unit = "Carton", secondaryUnit = "Box", secondaryUnitQty = 10.0)
        val ladder = p.unitLadder()
        assertEquals(2, ladder.size)
        assertEquals("Box", ladder[0].unit) // smallest first
        assertEquals("Carton", ladder[1].unit)
        assertEquals(10.0, ladder[1].smallestPerUnit, 0.0)
    }

    @Test
    fun `three-tier product - primary, secondary, tertiary`() {
        // 1 Carton = 10 Box, 1 Box = 12 Pcs
        val p = product(
            unit = "Carton", secondaryUnit = "Box", secondaryUnitQty = 10.0,
            tertiaryUnit = "Pcs", tertiaryUnitQty = 12.0
        )
        val ladder = p.unitLadder()
        assertEquals(3, ladder.size)
        assertEquals("Pcs", ladder[0].unit)
        assertEquals(1.0, ladder[0].smallestPerUnit, 0.0)
        assertEquals("Box", ladder[1].unit)
        assertEquals(12.0, ladder[1].smallestPerUnit, 0.0)
        assertEquals("Carton", ladder[2].unit)
        assertEquals(120.0, ladder[2].smallestPerUnit, 0.0) // 10 * 12
    }

    @Test
    fun `tertiary without a valid secondary degrades to single tier`() {
        // Malformed config: tertiary set but secondary missing/zero.
        val p = product(unit = "Carton", tertiaryUnit = "Pcs", tertiaryUnitQty = 12.0)
        val ladder = p.unitLadder()
        assertEquals(1, ladder.size)
        assertEquals("Carton", ladder[0].unit)
    }

    // ---- toSmallestUnits() / fromSmallestUnits() round trip ----

    @Test
    fun `toSmallestUnits converts primary unit correctly - three tier`() {
        val p = product(
            unit = "Carton", secondaryUnit = "Box", secondaryUnitQty = 10.0,
            tertiaryUnit = "Pcs", tertiaryUnitQty = 12.0
        )
        // 2 Cartons = 2 * 120 = 240 Pcs
        assertEquals(240.0, p.toSmallestUnits(2.0, "Carton"), 0.0)
        // 3 Box = 3 * 12 = 36 Pcs
        assertEquals(36.0, p.toSmallestUnits(3.0, "Box"), 0.0)
        // 5 Pcs = 5 Pcs
        assertEquals(5.0, p.toSmallestUnits(5.0, "Pcs"), 0.0)
    }

    @Test
    fun `toSmallestUnits is case and whitespace insensitive`() {
        val p = product(unit = "Carton", secondaryUnit = "Box", secondaryUnitQty = 10.0)
        // Box is the smallest tier here (no tertiary), so 2 Box = 2 smallest units.
        assertEquals(2.0, p.toSmallestUnits(2.0, "  box "), 0.0)
        assertEquals(2.0, p.toSmallestUnits(2.0, "BOX"), 0.0)
    }

    @Test
    fun `toSmallestUnits falls back to primary unit factor for unknown unit string`() {
        val p = product(unit = "Carton", secondaryUnit = "Box", secondaryUnitQty = 10.0)
        // "Dabbi" isn't a configured unit for this product — falls back to the
        // primary tier's factor rather than silently returning the raw qty.
        assertEquals(10.0, p.toSmallestUnits(1.0, "Dabbi"), 0.0)
    }

    @Test
    fun `fromSmallestUnits reverses toSmallestUnits`() {
        val p = product(
            unit = "Carton", secondaryUnit = "Box", secondaryUnitQty = 10.0,
            tertiaryUnit = "Pcs", tertiaryUnitQty = 12.0
        )
        val smallest = p.toSmallestUnits(2.5, "Box") // 30 Pcs
        assertEquals(2.5, p.fromSmallestUnits(smallest, "Box"), 0.0001)
    }

    // ---- isValidSmallestQty() — whole-number enforcement for piece-based units ----

    @Test
    fun `whole number is valid for piece-based smallest unit`() {
        val p = product(unit = "Piece")
        assertTrue(p.isValidSmallestQty(5.0))
    }

    @Test
    fun `fractional quantity is invalid for piece-based smallest unit`() {
        val p = product(unit = "Piece")
        assertFalse(p.isValidSmallestQty(5.5))
    }

    @Test
    fun `fractional quantity is valid for weight-based smallest unit`() {
        val p = product(unit = "Kg", secondaryUnit = "Gram", secondaryUnitQty = 1000.0)
        assertTrue(p.isValidSmallestQty(250.5))
    }

    // ---- toPrimaryUnitRate() / fromPrimaryUnitRate() ----

    @Test
    fun `toPrimaryUnitRate converts a per-box rate up to a per-carton rate`() {
        // 1 Carton = 10 Box. Rs 50 per Box -> Rs 500 per Carton.
        val p = product(unit = "Carton", secondaryUnit = "Box", secondaryUnitQty = 10.0)
        assertEquals(500.0, p.toPrimaryUnitRate(50.0, "Box"), 0.0001)
    }

    @Test
    fun `fromPrimaryUnitRate reverses toPrimaryUnitRate`() {
        val p = product(unit = "Carton", secondaryUnit = "Box", secondaryUnitQty = 10.0)
        val primaryRate = p.toPrimaryUnitRate(50.0, "Box")
        assertEquals(50.0, p.fromPrimaryUnitRate(primaryRate, "Box"), 0.0001)
    }
}
