package com.grocerypos.v11

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Stuck Balance — the Daily / Total Payable helpers on Customer.
 *
 * Daily Payable = openingBalance + balance   (the running part)
 * Total Payable = Daily Payable + stuckBalance
 */
class CustomerPayableTest {

    @Test
    fun customerWithoutStuck_totalEqualsDaily() {
        val c = Customer(id = 1L, name = "Ali", openingBalance = 25000.0, balance = 1000.0)
        assertEquals(26000.0, c.dailyPayable(), 0.001)
        assertEquals(26000.0, c.totalPayable(), 0.001)
        assertFalse(c.hasStuck())
    }

    @Test
    fun stuckIsAddedToTotalOnly() {
        // Opening 25,000 (paper bills) + stuck 50,000 -> Daily 25,000, Total 75,000
        val c = Customer(id = 1L, name = "Ali", openingBalance = 25000.0, balance = 0.0, stuckBalance = 50000.0)
        assertEquals(25000.0, c.dailyPayable(), 0.001)
        assertEquals(75000.0, c.totalPayable(), 0.001)
        assertTrue(c.hasStuck())
    }

    @Test
    fun dailySalesAndPaymentsMoveDailyButNeverStuck() {
        val base = Customer(id = 1L, name = "Ali", openingBalance = 25000.0, stuckBalance = 50000.0)

        // 10,000 credit sale -> Daily 35,000, Total 85,000
        val afterSale = base.copy(balance = 10000.0)
        assertEquals(35000.0, afterSale.dailyPayable(), 0.001)
        assertEquals(85000.0, afterSale.totalPayable(), 0.001)
        assertEquals(50000.0, afterSale.stuckBalance, 0.001)

        // then a 5,000 payment -> Daily 30,000, Total 80,000
        val afterPayment = afterSale.copy(balance = 5000.0)
        assertEquals(30000.0, afterPayment.dailyPayable(), 0.001)
        assertEquals(80000.0, afterPayment.totalPayable(), 0.001)
        assertEquals(50000.0, afterPayment.stuckBalance, 0.001)
    }

    @Test
    fun advancePaymentOnDaily_stillOffsetsTotal() {
        // Customer over-pays the daily part: running goes negative, Total stays correct.
        val c = Customer(id = 1L, name = "Ali", openingBalance = 0.0, balance = -7000.0, stuckBalance = 50000.0)
        assertEquals(-7000.0, c.dailyPayable(), 0.001)
        assertEquals(43000.0, c.totalPayable(), 0.001)
    }
}
