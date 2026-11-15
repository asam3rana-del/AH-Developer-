package com.grocerypos.v11.pricing

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Tests for [DiscountCalculator.compute] — the single source of truth for
 * subtotal -> discount -> total -> paid -> due math used by both the live
 * Sale screen preview and the actual save path. A bug here would silently
 * miscalculate every bill in the app, so every clamp boundary is covered.
 */
class DiscountCalculatorTest {

    @Test
    fun `no discount, full payment - due is zero`() {
        val result = DiscountCalculator.compute(subtotal = 1000.0, discountInput = 0.0, paidInput = 1000.0)
        assertEquals(1000.0, result.subtotal, 0.0)
        assertEquals(0.0, result.discount, 0.0)
        assertEquals(1000.0, result.total, 0.0)
        assertEquals(1000.0, result.paid, 0.0)
        assertEquals(0.0, result.due, 0.0)
    }

    @Test
    fun `partial payment leaves a due balance`() {
        val result = DiscountCalculator.compute(subtotal = 1000.0, discountInput = 0.0, paidInput = 400.0)
        assertEquals(1000.0, result.total, 0.0)
        assertEquals(400.0, result.paid, 0.0)
        assertEquals(600.0, result.due, 0.0)
    }

    @Test
    fun `discount reduces total correctly`() {
        val result = DiscountCalculator.compute(subtotal = 1000.0, discountInput = 150.0, paidInput = 850.0)
        assertEquals(150.0, result.discount, 0.0)
        assertEquals(850.0, result.total, 0.0)
        assertEquals(0.0, result.due, 0.0)
    }

    @Test
    fun `discount larger than subtotal is clamped to subtotal`() {
        // e.g. cashier mistypes a discount bigger than the bill itself.
        val result = DiscountCalculator.compute(subtotal = 500.0, discountInput = 700.0, paidInput = 0.0)
        assertEquals(500.0, result.discount, 0.0)
        assertEquals(0.0, result.total, 0.0)
        assertEquals(0.0, result.due, 0.0)
    }

    @Test
    fun `negative discount input is clamped to zero`() {
        val result = DiscountCalculator.compute(subtotal = 500.0, discountInput = -50.0, paidInput = 500.0)
        assertEquals(0.0, result.discount, 0.0)
        assertEquals(500.0, result.total, 0.0)
    }

    @Test
    fun `paid more than total is clamped to total - no negative due`() {
        // e.g. cashier overtypes the paid amount.
        val result = DiscountCalculator.compute(subtotal = 300.0, discountInput = 0.0, paidInput = 1000.0)
        assertEquals(300.0, result.paid, 0.0)
        assertEquals(0.0, result.due, 0.0)
    }

    @Test
    fun `negative paid input is clamped to zero`() {
        val result = DiscountCalculator.compute(subtotal = 300.0, discountInput = 0.0, paidInput = -20.0)
        assertEquals(0.0, result.paid, 0.0)
        assertEquals(300.0, result.due, 0.0)
    }

    @Test
    fun `negative subtotal is clamped to zero - never a negative bill`() {
        val result = DiscountCalculator.compute(subtotal = -100.0, discountInput = 0.0, paidInput = 0.0)
        assertEquals(0.0, result.subtotal, 0.0)
        assertEquals(0.0, result.total, 0.0)
        assertEquals(0.0, result.due, 0.0)
    }

    @Test
    fun `zero subtotal with zero payment is fully settled`() {
        val result = DiscountCalculator.compute(subtotal = 0.0, discountInput = 0.0, paidInput = 0.0)
        assertEquals(0.0, result.total, 0.0)
        assertEquals(0.0, result.due, 0.0)
    }

    @Test
    fun `full credit sale - nothing paid`() {
        val result = DiscountCalculator.compute(subtotal = 2500.0, discountInput = 100.0, paidInput = 0.0)
        assertEquals(2400.0, result.total, 0.0)
        assertEquals(0.0, result.paid, 0.0)
        assertEquals(2400.0, result.due, 0.0)
    }
}
