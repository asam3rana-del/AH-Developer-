package com.grocerypos.v11.domain

import com.grocerypos.v11.data.PurchaseLine
import com.grocerypos.v11.data.SavePurchaseResult
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Tests for [SavePurchaseUseCase] — the validation layer added in
 * Improvement Pack P6 (empty-bill / qty>0 / rate>=0 guards) between the
 * Purchase screen and [com.grocerypos.v11.data.PurchaseRepository]. Uses
 * [FakePurchaseRepository] so these run as plain JVM unit tests, no Room/
 * Android Context needed — see IMPROVEMENTS_APPLIED.md, Improvement Pack P9.
 */
class SavePurchaseUseCaseTest {

    private lateinit var fakeRepository: FakePurchaseRepository
    private lateinit var useCase: SavePurchaseUseCase

    private fun line(itemName: String = "Item1", amount: Double = 100.0, qty: Double = 1.0, rate: Double? = null) =
        PurchaseLine(
            itemName = itemName,
            barcode = itemName,
            qty = qty,
            unit = "Piece",
            rate = rate ?: (amount / qty),
            amount = amount,
            mainUnit = "Piece",
            secondaryUnit = "",
            secondaryUnitQty = 0.0
        )

    @Before
    fun setUp() {
        fakeRepository = FakePurchaseRepository()
        useCase = SavePurchaseUseCase(fakeRepository)
    }

    @Test
    fun `empty bill returns Error and never calls repository`() = runBlocking {
        val result = useCase(
            editBillNo = null,
            party = "",
            grandTotal = 0.0,
            amountPaid = 0.0,
            discount = 0.0,
            paymentMethod = "Cash",
            purchaseDateMillis = System.currentTimeMillis(),
            lines = emptyList(),
            original = null,
            originalItems = emptyList(),
            suppliers = emptyList()
        )

        assertTrue(result is SavePurchaseResult.Error)
        assertNull(fakeRepository.lastSavePurchaseCall)
    }

    @Test
    fun `zero qty line returns Error and never calls repository`() = runBlocking {
        val result = useCase(
            editBillNo = null,
            party = "Supplier A",
            grandTotal = 100.0,
            amountPaid = 100.0,
            discount = 0.0,
            paymentMethod = "Cash",
            purchaseDateMillis = System.currentTimeMillis(),
            lines = listOf(line(amount = 100.0, qty = 0.0)),
            original = null,
            originalItems = emptyList(),
            suppliers = emptyList()
        )

        assertTrue(result is SavePurchaseResult.Error)
        assertNull(fakeRepository.lastSavePurchaseCall)
    }

    @Test
    fun `negative qty line returns Error and never calls repository`() = runBlocking {
        val result = useCase(
            editBillNo = null,
            party = "Supplier A",
            grandTotal = 100.0,
            amountPaid = 100.0,
            discount = 0.0,
            paymentMethod = "Cash",
            purchaseDateMillis = System.currentTimeMillis(),
            lines = listOf(line(amount = 100.0, qty = -2.0)),
            original = null,
            originalItems = emptyList(),
            suppliers = emptyList()
        )

        assertTrue(result is SavePurchaseResult.Error)
        assertNull(fakeRepository.lastSavePurchaseCall)
    }

    @Test
    fun `negative rate line returns Error and never calls repository`() = runBlocking {
        val result = useCase(
            editBillNo = null,
            party = "Supplier A",
            grandTotal = 0.0,
            amountPaid = 0.0,
            discount = 0.0,
            paymentMethod = "Cash",
            purchaseDateMillis = System.currentTimeMillis(),
            lines = listOf(line(amount = 100.0, qty = 1.0, rate = -50.0)),
            original = null,
            originalItems = emptyList(),
            suppliers = emptyList()
        )

        assertTrue(result is SavePurchaseResult.Error)
        assertNull(fakeRepository.lastSavePurchaseCall)
    }

    @Test
    fun `one bad line among several still blocks the whole bill before saving`() = runBlocking {
        val result = useCase(
            editBillNo = null,
            party = "Supplier A",
            grandTotal = 150.0,
            amountPaid = 150.0,
            discount = 0.0,
            paymentMethod = "Cash",
            purchaseDateMillis = System.currentTimeMillis(),
            lines = listOf(line(itemName = "Item1", amount = 100.0, qty = 1.0), line(itemName = "Item2", amount = 50.0, qty = 0.0)),
            original = null,
            originalItems = emptyList(),
            suppliers = emptyList()
        )

        assertTrue(result is SavePurchaseResult.Error)
        assertNull(fakeRepository.lastSavePurchaseCall)
    }

    @Test
    fun `valid bill is forwarded to the repository and its result is returned`() = runBlocking {
        fakeRepository.savePurchaseResult = SavePurchaseResult.Success(billNo = "PUR-Sep26-0001-DEV1", isUpdate = false)

        val result = useCase(
            editBillNo = null,
            party = "Supplier A",
            grandTotal = 100.0,
            amountPaid = 100.0,
            discount = 0.0,
            paymentMethod = "Cash",
            purchaseDateMillis = System.currentTimeMillis(),
            lines = listOf(line(amount = 100.0, qty = 1.0)),
            original = null,
            originalItems = emptyList(),
            suppliers = emptyList()
        )

        assertTrue(result is SavePurchaseResult.Success)
        assertEquals("PUR-Sep26-0001-DEV1", (result as SavePurchaseResult.Success).billNo)
        assertEquals("Supplier A", fakeRepository.lastSavePurchaseCall?.party)
        assertEquals(1, fakeRepository.lastSavePurchaseCall?.lineCount)
    }

    @Test
    fun `repository-level Error (e_g_ costing refusal) is passed through unchanged`() = runBlocking {
        fakeRepository.savePurchaseResult = SavePurchaseResult.Error("Stock is purchase ke baad already kam ho chuka hai")

        val result = useCase(
            editBillNo = "PUR-Sep26-0001-DEV1",
            party = "Supplier A",
            grandTotal = 100.0,
            amountPaid = 100.0,
            discount = 0.0,
            paymentMethod = "Cash",
            purchaseDateMillis = System.currentTimeMillis(),
            lines = listOf(line(amount = 100.0, qty = 1.0)),
            original = null,
            originalItems = emptyList(),
            suppliers = emptyList()
        )

        assertTrue(result is SavePurchaseResult.Error)
        assertEquals("Stock is purchase ke baad already kam ho chuka hai", (result as SavePurchaseResult.Error).message)
    }
}
