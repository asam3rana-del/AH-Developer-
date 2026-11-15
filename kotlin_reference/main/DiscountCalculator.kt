package com.grocerypos.v11.pricing

/**
 * Result of a bill calculation: subtotal, clamped discount, final total,
 * clamped paid amount, and remaining due.
 */
data class BillTotals(
    val subtotal: Double,
    val discount: Double,
    val total: Double,
    val paid: Double,
    val due: Double
)

/**
 * Single source of truth for turning (subtotal, entered discount, entered paid)
 * into a consistent, safely-clamped set of bill totals. Used by both the live
 * on-screen preview (recomputeAmounts/refreshDue) and the actual save path
 * (saveSale) so they can never disagree.
 */
object DiscountCalculator {

    fun compute(subtotal: Double, discountInput: Double, paidInput: Double): BillTotals {
        val safeSubtotal = subtotal.coerceAtLeast(0.0)
        val discount = discountInput.coerceIn(0.0, safeSubtotal)
        val total = (safeSubtotal - discount).coerceAtLeast(0.0)
        val paid = paidInput.coerceIn(0.0, total)
        val due = (total - paid).coerceAtLeast(0.0)
        return BillTotals(
            subtotal = safeSubtotal,
            discount = discount,
            total = total,
            paid = paid,
            due = due
        )
    }
}
