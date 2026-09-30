package com.grocerypos.v11.domain

import com.grocerypos.v11.Customer
import com.grocerypos.v11.data.DuplicateInvoiceException
import com.grocerypos.v11.data.SaleSaveResult
import com.grocerypos.v11.data.StockUnavailableException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Tests for [SaveSaleUseCase] — the validation + orchestration layer between
 * the Sale screen and [com.grocerypos.v11.data.SaleRepository]. Uses
 * [FakeSaleRepository] so these run as plain JVM unit tests, no Room/Android
 * Context needed.
 */
class SaveSaleUseCaseTest {

    private lateinit var fakeRepository: FakeSaleRepository
    private lateinit var useCase: SaveSaleUseCase

    private fun line(barcode: String = "B1", amount: Double = 100.0, qty: Double = 1.0) = SaleLine(
        barcode = barcode,
        itemName = "Item $barcode",
        qty = qty,
        unit = "Piece",
        unitPrice = amount / qty,
        cost = 0.0,
        amount = amount,
        mainUnit = "Piece",
        secondaryUnit = "",
        secondaryUnitQty = 0.0
    )

    @Before
    fun setUp() {
        fakeRepository = FakeSaleRepository()
        useCase = SaveSaleUseCase(fakeRepository)
    }

    @Test
    fun `empty lines returns EmptyItems and never calls repository`() = runBlocking {
        val result = useCase(
            editInvoice = null,
            enteredCustomerName = "",
            knownCustomers = emptyList(),
            saleTypeLabel = "Retail",
            lines = emptyList(),
            discountInput = 0.0,
            paidInput = 0.0,
            paymentMethodLabel = "Cash",
            saleDateMillis = System.currentTimeMillis(),
            original = null,
            originalItems = emptyList()
        )

        assertTrue(result is SaveSaleResult.EmptyItems)
        assertNull(fakeRepository.lastSaveSaleCall)
    }

    @Test
    fun `due balance without a customer name returns CustomerRequiredForDue`() = runBlocking {
        // subtotal 100, nothing paid -> due 100, but no customer name entered.
        val result = useCase(
            editInvoice = null,
            enteredCustomerName = "",
            knownCustomers = emptyList(),
            saleTypeLabel = "Retail",
            lines = listOf(line(amount = 100.0)),
            discountInput = 0.0,
            paidInput = 0.0,
            paymentMethodLabel = "Cash",
            saleDateMillis = System.currentTimeMillis(),
            original = null,
            originalItems = emptyList()
        )

        assertTrue(result is SaveSaleResult.CustomerRequiredForDue)
        assertNull(fakeRepository.lastSaveSaleCall)
    }

    @Test
    fun `fully paid cash sale succeeds with entered payment method`() = runBlocking {
        fakeRepository.saveSaleResult = SaleSaveResult(customer = null, stockWarnings = emptyList())

        val result = useCase(
            editInvoice = null,
            enteredCustomerName = "",
            knownCustomers = emptyList(),
            saleTypeLabel = "Retail",
            lines = listOf(line(amount = 500.0)),
            discountInput = 0.0,
            paidInput = 500.0,
            paymentMethodLabel = "Cash",
            saleDateMillis = System.currentTimeMillis(),
            original = null,
            originalItems = emptyList()
        )

        assertTrue(result is SaveSaleResult.Success)
        result as SaveSaleResult.Success
        assertEquals(500.0, result.total, 0.0)
        assertEquals(0.0, result.discount, 0.0)
        assertEquals("Cash", result.paymentMethod)
        assertEquals(false, result.isUpdate)

        val recorded = fakeRepository.lastSaveSaleCall!!
        assertEquals("Cash", recorded.method)
        assertEquals("retail", recorded.saleType)
    }

    @Test
    fun `zero paid amount forces payment method to credit regardless of label`() = runBlocking {
        // Customer given, so CustomerRequiredForDue does not trigger.
        val result = useCase(
            editInvoice = null,
            enteredCustomerName = "Ali",
            knownCustomers = emptyList(),
            saleTypeLabel = "Retail",
            lines = listOf(line(amount = 300.0)),
            discountInput = 0.0,
            paidInput = 0.0,
            paymentMethodLabel = "Cash", // should be overridden
            saleDateMillis = System.currentTimeMillis(),
            original = null,
            originalItems = emptyList()
        )

        assertTrue(result is SaveSaleResult.Success)
        result as SaveSaleResult.Success
        assertEquals("credit", result.paymentMethod)
        assertEquals("credit", fakeRepository.lastSaveSaleCall!!.method)
    }

    @Test
    fun `wholesale sale type label maps to lowercase wholesale`() = runBlocking {
        useCase(
            editInvoice = null,
            enteredCustomerName = "",
            knownCustomers = emptyList(),
            saleTypeLabel = "Wholesale",
            lines = listOf(line(amount = 200.0)),
            discountInput = 0.0,
            paidInput = 200.0,
            paymentMethodLabel = "Cash",
            saleDateMillis = System.currentTimeMillis(),
            original = null,
            originalItems = emptyList()
        )

        assertEquals("wholesale", fakeRepository.lastSaveSaleCall!!.saleType)
    }

    @Test
    fun `editing an existing invoice reuses the invoice number and marks isUpdate true`() = runBlocking {
        val existingSale = com.grocerypos.v11.Sale(
            invoice = "0926000001",
            subtotal = 100.0, discount = 0.0, tax = 0.0, total = 100.0, paid = 100.0,
            paymentMethod = "cash"
        )

        val result = useCase(
            editInvoice = "0926000001",
            enteredCustomerName = "",
            knownCustomers = emptyList(),
            saleTypeLabel = "Retail",
            lines = listOf(line(amount = 100.0)),
            discountInput = 0.0,
            paidInput = 100.0,
            paymentMethodLabel = "Cash",
            saleDateMillis = System.currentTimeMillis(),
            original = existingSale,
            originalItems = emptyList()
        )

        assertTrue(result is SaveSaleResult.Success)
        result as SaveSaleResult.Success
        assertEquals("0926000001", result.invoice)
        assertEquals(true, result.isUpdate)
        assertEquals("0926000001", fakeRepository.lastSaveSaleCall!!.invoice)
    }

    @Test
    fun `discount is applied before checking due - fully discounted sale needs no customer`() = runBlocking {
        // subtotal 100, discount 100 -> total 0 -> due 0, so no customer name required
        // even though paid is 0.
        val result = useCase(
            editInvoice = null,
            enteredCustomerName = "",
            knownCustomers = emptyList(),
            saleTypeLabel = "Retail",
            lines = listOf(line(amount = 100.0)),
            discountInput = 100.0,
            paidInput = 0.0,
            paymentMethodLabel = "Cash",
            saleDateMillis = System.currentTimeMillis(),
            original = null,
            originalItems = emptyList()
        )

        assertTrue(result is SaveSaleResult.Success)
        result as SaveSaleResult.Success
        assertEquals(100.0, result.discount, 0.0)
        assertEquals(0.0, result.total, 0.0)
    }

    @Test
    fun `known customer name match is matched case-insensitively`() = runBlocking {
        val ali = Customer(id = 7, name = "Ali Khan")
        val result = useCase(
            editInvoice = null,
            enteredCustomerName = "ali khan",
            knownCustomers = listOf(ali),
            saleTypeLabel = "Retail",
            lines = listOf(line(amount = 100.0)),
            discountInput = 0.0,
            paidInput = 0.0,
            paymentMethodLabel = "Cash",
            saleDateMillis = System.currentTimeMillis(),
            original = null,
            originalItems = emptyList()
        )

        assertTrue(result is SaveSaleResult.Success)
        result as SaveSaleResult.Success
        assertEquals(ali, result.customer)
    }

    @Test
    fun `stock issue from repository is surfaced as StockIssue with the message`() = runBlocking {
        fakeRepository.saveSaleThrows = StockUnavailableException("Sirf 2 Piece available hai")

        val result = useCase(
            editInvoice = null,
            enteredCustomerName = "",
            knownCustomers = emptyList(),
            saleTypeLabel = "Retail",
            lines = listOf(line(amount = 100.0)),
            discountInput = 0.0,
            paidInput = 100.0,
            paymentMethodLabel = "Cash",
            saleDateMillis = System.currentTimeMillis(),
            original = null,
            originalItems = emptyList()
        )

        assertTrue(result is SaveSaleResult.StockIssue)
        assertEquals("Sirf 2 Piece available hai", (result as SaveSaleResult.StockIssue).message)
    }

    // ---- Improvement Pack P6: qty>0 / rate>=0 / duplicate-invoice guards ----

    @Test
    fun `zero qty line returns InvalidLine and never calls repository`() = runBlocking {
        val result = useCase(
            editInvoice = null,
            enteredCustomerName = "",
            knownCustomers = emptyList(),
            saleTypeLabel = "Retail",
            lines = listOf(line(amount = 100.0, qty = 0.0)),
            discountInput = 0.0,
            paidInput = 100.0,
            paymentMethodLabel = "Cash",
            saleDateMillis = System.currentTimeMillis(),
            original = null,
            originalItems = emptyList()
        )

        assertTrue(result is SaveSaleResult.InvalidLine)
        assertNull(fakeRepository.lastSaveSaleCall)
    }

    @Test
    fun `negative qty line returns InvalidLine and never calls repository`() = runBlocking {
        val result = useCase(
            editInvoice = null,
            enteredCustomerName = "",
            knownCustomers = emptyList(),
            saleTypeLabel = "Retail",
            lines = listOf(line(amount = 100.0, qty = -2.0)),
            discountInput = 0.0,
            paidInput = 100.0,
            paymentMethodLabel = "Cash",
            saleDateMillis = System.currentTimeMillis(),
            original = null,
            originalItems = emptyList()
        )

        assertTrue(result is SaveSaleResult.InvalidLine)
        assertNull(fakeRepository.lastSaveSaleCall)
    }

    @Test
    fun `negative rate line returns InvalidLine and never calls repository`() = runBlocking {
        // amount negative -> unitPrice = amount/qty is negative for a qty=1 line.
        val result = useCase(
            editInvoice = null,
            enteredCustomerName = "",
            knownCustomers = emptyList(),
            saleTypeLabel = "Retail",
            lines = listOf(line(amount = -50.0, qty = 1.0)),
            discountInput = 0.0,
            paidInput = 0.0,
            paymentMethodLabel = "Cash",
            saleDateMillis = System.currentTimeMillis(),
            original = null,
            originalItems = emptyList()
        )

        assertTrue(result is SaveSaleResult.InvalidLine)
        assertNull(fakeRepository.lastSaveSaleCall)
    }

    @Test
    fun `one bad line among several still blocks the whole sale before saving`() = runBlocking {
        val result = useCase(
            editInvoice = null,
            enteredCustomerName = "",
            knownCustomers = emptyList(),
            saleTypeLabel = "Retail",
            lines = listOf(line(barcode = "B1", amount = 100.0, qty = 1.0), line(barcode = "B2", amount = 50.0, qty = 0.0)),
            discountInput = 0.0,
            paidInput = 150.0,
            paymentMethodLabel = "Cash",
            saleDateMillis = System.currentTimeMillis(),
            original = null,
            originalItems = emptyList()
        )

        assertTrue(result is SaveSaleResult.InvalidLine)
        assertNull(fakeRepository.lastSaveSaleCall)
    }

    @Test
    fun `duplicate invoice from repository is surfaced as DuplicateInvoice with the message`() = runBlocking {
        fakeRepository.saveSaleThrowsDuplicate = DuplicateInvoiceException("Invoice number pehle se mojood hai")

        val result = useCase(
            editInvoice = null,
            enteredCustomerName = "",
            knownCustomers = emptyList(),
            saleTypeLabel = "Retail",
            lines = listOf(line(amount = 100.0)),
            discountInput = 0.0,
            paidInput = 100.0,
            paymentMethodLabel = "Cash",
            saleDateMillis = System.currentTimeMillis(),
            original = null,
            originalItems = emptyList()
        )

        assertTrue(result is SaveSaleResult.DuplicateInvoice)
        assertEquals("Invoice number pehle se mojood hai", (result as SaveSaleResult.DuplicateInvoice).message)
    }
}
