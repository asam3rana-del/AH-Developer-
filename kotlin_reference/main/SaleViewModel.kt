package com.grocerypos.v11.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.grocerypos.v11.Customer
import com.grocerypos.v11.HeldBill
import com.grocerypos.v11.Product
import com.grocerypos.v11.Sale
import com.grocerypos.v11.SaleItem
import com.grocerypos.v11.domain.CreateCustomerUseCase
import com.grocerypos.v11.domain.DeleteHeldBillUseCase
import com.grocerypos.v11.domain.DeleteSaleUseCase
import com.grocerypos.v11.domain.HeldBillsUseCase
import com.grocerypos.v11.domain.HoldBillUseCase
import com.grocerypos.v11.domain.LoadFirmNameForSaleUseCase
import com.grocerypos.v11.domain.LoadSaleForEditUseCase
import com.grocerypos.v11.domain.ObserveCustomersForSaleUseCase
import com.grocerypos.v11.domain.ObserveProductsForSaleUseCase
import com.grocerypos.v11.domain.QuickSaleResult
import com.grocerypos.v11.domain.SaleForEdit
import com.grocerypos.v11.domain.SaleLine
import com.grocerypos.v11.domain.SaveQuickSaleUseCase
import com.grocerypos.v11.domain.SaveSaleResult
import com.grocerypos.v11.domain.SaveSaleUseCase
import com.grocerypos.v11.domain.TopSellingProductNamesUseCase
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/** Everything the Sale screen needs continuously — the Activity only reads
 * this for its customer/item autocomplete lists; it never queries Room
 * directly for them. */
data class SaleUiState(
    val customers: List<Customer> = emptyList(),
    val products: List<Product> = emptyList()
)

/** One-shot outcomes (toast text, navigation) that shouldn't re-fire just
 * because the Activity re-collects state (e.g. after a rotation). */
sealed class SaleEvent {
    data class SaveSuccess(val result: SaveSaleResult.Success) : SaleEvent()
    object EmptyItems : SaleEvent()
    object CustomerRequiredForDue : SaleEvent()
    data class StockIssue(val message: String) : SaleEvent()
    data class QuickSaleSuccess(val invoice: String, val isCredit: Boolean) : SaleEvent()
    data class QuickSaleStockIssue(val message: String) : SaleEvent()
    data class QuickSaleInvalidQty(val message: String) : SaleEvent()
    // NEW (Improvement Pack P6): duplicate-invoice guard in RoomSaleRepository.
    data class DuplicateInvoice(val message: String) : SaleEvent()
    data class QuickSaleDuplicateInvoice(val message: String) : SaleEvent()
    // NEW (Improvement Pack P6): qty<=0 / negative-rate line rejected before save.
    data class InvalidLine(val message: String) : SaleEvent()
    object SaleDeleted : SaleEvent()
    object BillHeld : SaleEvent()
    data class CustomerAdded(val name: String) : SaleEvent()
    // NEW (10/10 Priority #7 — Credit Limit + Due Management): the Activity shows
    // a confirm dialog for this and, if confirmed, re-calls saveSale/saveQuickSale
    // with overrideCreditLimit=true.
    data class CreditLimitExceeded(val customerName: String, val creditLimit: Double, val projectedBalance: Double) : SaleEvent()
    data class QuickSaleCreditLimitExceeded(val customerName: String, val creditLimit: Double, val projectedBalance: Double) : SaleEvent()
}

class SaleViewModel(
    private val observeCustomers: ObserveCustomersForSaleUseCase,
    private val observeProducts: ObserveProductsForSaleUseCase,
    private val loadFirmNameUseCase: LoadFirmNameForSaleUseCase,
    private val loadSaleForEdit: LoadSaleForEditUseCase,
    private val saveSaleUseCase: SaveSaleUseCase,
    private val saveQuickSaleUseCase: SaveQuickSaleUseCase,
    private val deleteSaleUseCase: DeleteSaleUseCase,
    private val createCustomerUseCase: CreateCustomerUseCase,
    private val topSellingProductNamesUseCase: TopSellingProductNamesUseCase,
    private val holdBillUseCase: HoldBillUseCase,
    private val heldBillsUseCase: HeldBillsUseCase,
    private val deleteHeldBillUseCase: DeleteHeldBillUseCase
) : ViewModel() {

    private val _uiState = MutableStateFlow(SaleUiState())
    val uiState: StateFlow<SaleUiState> = _uiState.asStateFlow()

    private val _events = MutableSharedFlow<SaleEvent>(extraBufferCapacity = 1)
    val events: SharedFlow<SaleEvent> = _events

    init {
        viewModelScope.launch {
            observeCustomers().collect { list -> _uiState.value = _uiState.value.copy(customers = list) }
        }
        viewModelScope.launch {
            observeProducts().collect { list -> _uiState.value = _uiState.value.copy(products = list) }
        }
    }

    /** One-shot fetch for the shop-name header — called on create and again on
     * resume so it picks up a change made in Settings while this screen was
     * backgrounded. */
    suspend fun firmName(): String? = loadFirmNameUseCase()

    /** One-shot fetch to repopulate the screen when opened for editing an
     * existing invoice. */
    suspend fun loadForEdit(invoice: String): SaleForEdit? = loadSaleForEdit(invoice)

    /** One-shot fetch for the Quick Sale dialog's "best sellers" shortcut row. */
    suspend fun topSellingProducts(): List<String> = topSellingProductNamesUseCase()

    /** One-shot fetch for the Hold/Recall dialog. */
    suspend fun heldBills(): List<HeldBill> = heldBillsUseCase()

    fun saveSale(
        editInvoice: String?,
        enteredCustomerName: String,
        saleTypeLabel: String,
        lines: List<SaleLine>,
        discountInput: Double,
        paidInput: Double,
        paymentMethodLabel: String,
        saleDateMillis: Long,
        original: Sale?,
        originalItems: List<SaleItem>,
        overrideCreditLimit: Boolean = false,
        // NEW (Split Payment): see SaveSaleUseCase's matching param doc.
        payments: List<Pair<String, Double>> = emptyList()
    ) {
        viewModelScope.launch {
            when (val result = saveSaleUseCase(
                editInvoice = editInvoice,
                enteredCustomerName = enteredCustomerName,
                knownCustomers = _uiState.value.customers,
                saleTypeLabel = saleTypeLabel,
                lines = lines,
                discountInput = discountInput,
                paidInput = paidInput,
                paymentMethodLabel = paymentMethodLabel,
                saleDateMillis = saleDateMillis,
                original = original,
                originalItems = originalItems,
                allowOverride = overrideCreditLimit,
                payments = payments
            )) {
                is SaveSaleResult.Success -> _events.emit(SaleEvent.SaveSuccess(result))
                is SaveSaleResult.EmptyItems -> _events.emit(SaleEvent.EmptyItems)
                is SaveSaleResult.CustomerRequiredForDue -> _events.emit(SaleEvent.CustomerRequiredForDue)
                is SaveSaleResult.StockIssue -> _events.emit(SaleEvent.StockIssue(result.message))
                is SaveSaleResult.DuplicateInvoice -> _events.emit(SaleEvent.DuplicateInvoice(result.message))
                is SaveSaleResult.InvalidLine -> _events.emit(SaleEvent.InvalidLine(result.message))
                is SaveSaleResult.CreditLimitExceeded -> _events.emit(
                    SaleEvent.CreditLimitExceeded(result.customerName, result.creditLimit, result.projectedBalance)
                )
            }
        }
    }

    fun saveQuickSale(product: Product, qty: Double, price: Double, unit: String, customerName: String, overrideCreditLimit: Boolean = false) {
        viewModelScope.launch {
            when (val result = saveQuickSaleUseCase(product, qty, price, unit, customerName, allowOverride = overrideCreditLimit)) {
                is QuickSaleResult.Success -> _events.emit(SaleEvent.QuickSaleSuccess(result.invoice, result.isCredit))
                is QuickSaleResult.StockIssue -> _events.emit(SaleEvent.QuickSaleStockIssue(result.message))
                is QuickSaleResult.InvalidQty -> _events.emit(SaleEvent.QuickSaleInvalidQty(result.message))
                is QuickSaleResult.DuplicateInvoice -> _events.emit(SaleEvent.QuickSaleDuplicateInvoice(result.message))
                is QuickSaleResult.CreditLimitExceeded -> _events.emit(
                    SaleEvent.QuickSaleCreditLimitExceeded(result.customerName, result.creditLimit, result.projectedBalance)
                )
            }
        }
    }

    fun deleteSale(invoice: String, original: Sale?, originalItems: List<SaleItem>) {
        viewModelScope.launch {
            deleteSaleUseCase(invoice, original, originalItems)
            _events.emit(SaleEvent.SaleDeleted)
        }
    }

    fun addCustomer(name: String, phone: String = "", creditLimit: Double = 0.0, openingBalance: Double = 0.0) {
        viewModelScope.launch {
            val customer = createCustomerUseCase(name, phone, creditLimit, openingBalance)
            if (customer != null) _events.emit(SaleEvent.CustomerAdded(customer.name))
        }
    }

    fun holdBill(payload: String) {
        viewModelScope.launch {
            holdBillUseCase(payload)
            _events.emit(SaleEvent.BillHeld)
        }
    }

    fun deleteHeldBill(bill: HeldBill) {
        viewModelScope.launch { deleteHeldBillUseCase(bill) }
    }
}
