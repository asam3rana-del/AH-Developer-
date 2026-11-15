package com.grocerypos.v11.domain

import com.grocerypos.v11.Product
import com.grocerypos.v11.data.DuplicateInvoiceException
import com.grocerypos.v11.data.InvalidQuantityException
import com.grocerypos.v11.data.QuickSaleSaveResult
import com.grocerypos.v11.data.StockUnavailableException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Tests for [SaveQuickSaleUseCase] — the thin wrapper around
 * [com.grocerypos.v11.data.SaleRepository.saveQuickSale] used by the Quick
 * Sale dialog. It's mostly exception-to-Result translation, so these tests
 * focus on making sure each repository outcome maps to the right
 * [QuickSaleResult].
 */
class SaveQuickSaleUseCaseTest {

    private lateinit var fakeRepository: FakeSaleRepository
    private lateinit var useCase: SaveQuickSaleUseCase

    private val testProduct = Product(barcode = "P1", name = "Sugar", unit = "Kg", stock = 10.0)

    @Before
    fun setUp() {
        fakeRepository = FakeSaleRepository()
        useCase = SaveQuickSaleUseCase(fakeRepository)
    }

    @Test
    fun `successful quick sale returns Success with invoice and credit flag`() = runBlocking {
        fakeRepository.saveQuickSaleResult = QuickSaleSaveResult(invoice = "0926000123", isCredit = false)

        val result = useCase(testProduct, qty = 2.0, price = 150.0, unit = "Kg", customerName = "")

        assertTrue(result is QuickSaleResult.Success)
        result as QuickSaleResult.Success
        assertEquals("0926000123", result.invoice)
        assertEquals(false, result.isCredit)
    }

    @Test
    fun `credit quick sale is reported as credit`() = runBlocking {
        fakeRepository.saveQuickSaleResult = QuickSaleSaveResult(invoice = "0926000124", isCredit = true)

        val result = useCase(testProduct, qty = 1.0, price = 150.0, unit = "Kg", customerName = "Ali")

        assertTrue(result is QuickSaleResult.Success)
        assertEquals(true, (result as QuickSaleResult.Success).isCredit)
    }

    @Test
    fun `customer name is trimmed before being passed to the repository`() = runBlocking {
        useCase(testProduct, qty = 1.0, price = 150.0, unit = "Kg", customerName = "  Ali  ")

        assertEquals("Ali", fakeRepository.lastSaveQuickSaleCall!!.customerName)
    }

    @Test
    fun `stock unavailable from repository maps to StockIssue`() = runBlocking {
        fakeRepository.saveQuickSaleThrowsStock = StockUnavailableException("Stock khatam ho gaya")

        val result = useCase(testProduct, qty = 5.0, price = 150.0, unit = "Kg", customerName = "")

        assertTrue(result is QuickSaleResult.StockIssue)
        assertEquals("Stock khatam ho gaya", (result as QuickSaleResult.StockIssue).message)
    }

    @Test
    fun `invalid quantity from repository maps to InvalidQty`() = runBlocking {
        fakeRepository.saveQuickSaleThrowsInvalidQty = InvalidQuantityException("Qty whole Piece mein convert nahi hoti")

        val result = useCase(testProduct, qty = 0.5, price = 150.0, unit = "Piece", customerName = "")

        assertTrue(result is QuickSaleResult.InvalidQty)
        assertEquals("Qty whole Piece mein convert nahi hoti", (result as QuickSaleResult.InvalidQty).message)
    }

    @Test
    fun `product qty price and unit are forwarded to the repository unchanged`() = runBlocking {
        useCase(testProduct, qty = 3.5, price = 200.0, unit = "Kg", customerName = "")

        val recorded = fakeRepository.lastSaveQuickSaleCall!!
        assertEquals(testProduct, recorded.product)
        assertEquals(3.5, recorded.qty, 0.0)
        assertEquals(200.0, recorded.price, 0.0)
        assertEquals("Kg", recorded.unit)
    }

    // ---- Improvement Pack P6: qty>0 / rate>=0 / duplicate-invoice guards ----

    @Test
    fun `zero qty returns InvalidQty and never calls repository`() = runBlocking {
        val result = useCase(testProduct, qty = 0.0, price = 150.0, unit = "Kg", customerName = "")

        assertTrue(result is QuickSaleResult.InvalidQty)
        assertEquals(null, fakeRepository.lastSaveQuickSaleCall)
    }

    @Test
    fun `negative qty returns InvalidQty and never calls repository`() = runBlocking {
        val result = useCase(testProduct, qty = -1.0, price = 150.0, unit = "Kg", customerName = "")

        assertTrue(result is QuickSaleResult.InvalidQty)
        assertEquals(null, fakeRepository.lastSaveQuickSaleCall)
    }

    @Test
    fun `negative price returns InvalidQty and never calls repository`() = runBlocking {
        val result = useCase(testProduct, qty = 1.0, price = -10.0, unit = "Kg", customerName = "")

        assertTrue(result is QuickSaleResult.InvalidQty)
        assertEquals(null, fakeRepository.lastSaveQuickSaleCall)
    }

    @Test
    fun `duplicate invoice from repository maps to DuplicateInvoice`() = runBlocking {
        fakeRepository.saveQuickSaleThrowsDuplicate = DuplicateInvoiceException("Invoice number pehle se mojood hai")

        val result = useCase(testProduct, qty = 1.0, price = 150.0, unit = "Kg", customerName = "")

        assertTrue(result is QuickSaleResult.DuplicateInvoice)
        assertEquals("Invoice number pehle se mojood hai", (result as QuickSaleResult.DuplicateInvoice).message)
    }
}
