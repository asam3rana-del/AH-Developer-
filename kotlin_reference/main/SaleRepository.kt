package com.grocerypos.v11.data

import com.grocerypos.v11.Customer
import com.grocerypos.v11.HeldBill
import com.grocerypos.v11.Product
import com.grocerypos.v11.Sale
import com.grocerypos.v11.SaleItem
import com.grocerypos.v11.domain.SaleLine
import kotlinx.coroutines.flow.Flow

/** Thrown by [SaleRepository.saveSale] / [SaleRepository.saveQuickSale] when
 * stock changed under us (item disappeared, insufficient stock). The message
 * is already the exact user-facing text — SaveSaleUseCase/SaveQuickSaleUseCase
 * just forward it into their Result. */
class StockUnavailableException(message: String) : Exception(message)

/** Thrown by [SaleRepository.saveQuickSale] when the requested quantity can't
 * convert to a whole smallest-unit quantity for a non-fractional item. */
class InvalidQuantityException(message: String) : Exception(message)

/** Thrown by [SaleRepository.saveSale] when saving a NEW sale (not an edit)
 * whose invoice number already exists in the database — e.g. a double-tap on
 * Save re-submitting the same generated invoice, or (very unlikely with the
 * DeviceTag-suffixed generator) two saves landing on the identical string.
 * Without this check a plain @Insert would instead surface a raw
 * SQLiteConstraintException to the cashier (Improvement Pack P6). */
class DuplicateInvoiceException(message: String) : Exception(message)

data class SaleSaveResult(val customer: Customer?, val stockWarnings: List<String>)
data class QuickSaleSaveResult(val invoice: String, val isCredit: Boolean)

/**
 * Repository abstraction for creating, editing, and deleting Sales
 * (SaleActivity), plus the held-bill drafts (Hold/Recall) that live
 * alongside them.
 *
 * This is an interface (rather than a concrete class) so the domain layer
 * (SaleUseCases: SaveSaleUseCase, SaveQuickSaleUseCase, LoadSaleForEditUseCase,
 * etc.) can be unit tested against a lightweight in-memory FakeSaleRepository
 * instead of needing a real Room database — see
 * app/src/test/java/com/grocerypos/v11/domain/FakeSaleRepository.kt.
 *
 * The only production implementation is [RoomSaleRepository]
 * (RoomSaleRepository.kt), which is what SaleViewModelFactory wires up — all
 * the real SaleDao/ProductDao/CustomerDao/CashTransactionDao/HeldDao/
 * AppSettingDao/SyncQueueHelper logic lives there, unchanged from before this
 * interface was extracted.
 */
interface SaleRepository {

    fun observeCustomers(): Flow<List<Customer>>

    fun observeProducts(): Flow<List<Product>>

    suspend fun firmName(): String?

    suspend fun findSale(invoice: String): Sale?

    suspend fun itemsForInvoice(invoice: String): List<SaleItem>

    suspend fun customersSnapshot(): List<Customer>

    suspend fun productsSnapshot(): List<Product>

    suspend fun topProductNames(sinceMillis: Long, uptoMillis: Long): List<String>

    // ---- ADDED (full quick-add form — Roman Urdu request: "jab new party add karte
    // hain to sirf party name aata hai, sale/purchase ke waqt Sara form khulna
    // chahiye"): phone/creditLimit/openingBalance now optional params so the quick-add
    // dialog in SaleActivity can save the same fields PartyActivity's full form does,
    // instead of a name-only Customer row. Defaults keep any other caller compiling
    // unchanged. ----
    suspend fun createCustomer(name: String, phone: String = "", creditLimit: Double = 0.0, openingBalance: Double = 0.0): Customer

    suspend fun heldBills(): List<HeldBill>

    suspend fun holdBill(holdId: String, payload: String)

    suspend fun deleteHeldBill(bill: HeldBill)

    /**
     * Persists a new or edited sale.
     *
     * @throws StockUnavailableException with an exact user-facing message if
     * an item disappeared or has insufficient stock — callers should show it
     * as-is.
     */
    suspend fun saveSale(
        invoice: String,
        enteredCustomerName: String,
        existingCustomer: Customer?,
        saleType: String,
        method: String,
        saleDateMillis: Long,
        subtotal: Double,
        discount: Double,
        total: Double,
        paid: Double,
        lines: List<SaleLine>,
        original: Sale?,
        originalItems: List<SaleItem>,
        // NEW (Split Payment / multiple payment methods): when the bill was paid
        // using more than one method (e.g. Rs 300 Cash + Rs 200 Bank), this carries
        // each (method, amount) pair so RoomSaleRepository can log one cash-drawer
        // entry per method instead of a single combined one — Reports/Day Book/Cash
        // Register then split correctly by method. Empty (the default) means "single
        // method" and behaves exactly as before this feature existed: one entry of
        // (method, paid).
        payments: List<Pair<String, Double>> = emptyList()
    ): SaleSaveResult

    /** Deletes a sale: reverses its stock and customer-balance effect and
     * removes the sale, its line items, and its cash transaction. */
    suspend fun deleteSale(invoice: String, original: Sale?, originalItems: List<SaleItem>)

    // NEW (Split Payment): reconstructs the (method, amount) breakdown for an
    // existing invoice from its cash-drawer entries — used to repopulate the
    // Split Payment dialog when editing a sale that was originally paid with
    // more than one method.
    suspend fun paymentsForInvoice(invoice: String): List<Pair<String, Double>>

    /**
     * Persists a Quick Sale line (single-item, no draft/discount workflow).
     *
     * @throws StockUnavailableException if stock changed under us.
     * @throws InvalidQuantityException if [qty] can't convert to a whole
     * smallest-unit quantity for a non-fractional item.
     */
    suspend fun saveQuickSale(
        product: Product,
        qty: Double,
        price: Double,
        unit: String,
        customerName: String
    ): QuickSaleSaveResult
}
