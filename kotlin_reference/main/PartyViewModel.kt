package com.grocerypos.v11.ui
import com.grocerypos.v11.SyncQueueHelper

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.grocerypos.v11.Customer
import com.grocerypos.v11.Supplier
import com.grocerypos.v11.data.DuplicatePaymentGroup
import com.grocerypos.v11.domain.CleanupDuplicatePaymentsUseCase
import com.grocerypos.v11.domain.CleanupOrphanedPaymentsUseCase
import com.grocerypos.v11.domain.DeleteCustomerUseCase
import com.grocerypos.v11.domain.DeleteSupplierUseCase
import com.grocerypos.v11.domain.FindDuplicatePaymentsUseCase
import com.grocerypos.v11.domain.FindOrphanedPaymentsUseCase
import com.grocerypos.v11.domain.GetLiveBalancesUseCase
import com.grocerypos.v11.domain.GetCustomerHistoryUseCase
import com.grocerypos.v11.domain.GetSupplierHistoryUseCase
import com.grocerypos.v11.domain.MergeDuplicatePartiesUseCase
import com.grocerypos.v11.domain.ObserveCustomersUseCase
import com.grocerypos.v11.domain.ObserveSuppliersUseCase
import com.grocerypos.v11.domain.RecalculateBalancesUseCase
import com.grocerypos.v11.domain.SaveCustomerUseCase
import com.grocerypos.v11.domain.SavePartyResult
import com.grocerypos.v11.domain.SaveSupplierUseCase
import com.grocerypos.v11.domain.UpdateCustomerUseCase
import com.grocerypos.v11.domain.UpdateSupplierUseCase
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/** Everything the Customers & Suppliers screen needs to render — the Activity
 * only reads this, it never queries Room or SyncQueueHelper itself. */
data class PartyUiState(
    val showingCustomers: Boolean = true,
    val customers: List<Customer> = emptyList(),
    val suppliers: List<Supplier> = emptyList(),
    // PERMANENT FIX (balance drift — "paid supplier still shows You'll Get"): the
    // party list's closing ("You'll Get/Give") figures must come from these —
    // PartyRepository's live, recomputed-from-the-ledger balances — never from
    // customer.balance/supplier.balance directly. See GetLiveBalancesUseCase /
    // PartyRepository.liveCustomerBalances() for why the stored field can drift.
    val customerBalances: Map<Long, Double> = emptyMap(),
    val supplierBalances: Map<Long, Double> = emptyMap()
)

/** One-shot outcomes (toast text, clearing the Add form) that shouldn't re-fire
 * just because the Activity re-collects state (e.g. after a rotation). */
sealed class PartyEvent {
    object NameRequired : PartyEvent()
    object Saved : PartyEvent()
    object Updated : PartyEvent()
    object Deleted : PartyEvent()
    // NEW (Recalculate Balances): how many customers/suppliers actually had a
    // drifted balance corrected — 0/0 means everything already matched.
    data class BalancesRecalculated(val customersFixed: Int, val suppliersFixed: Int) : PartyEvent()
    // NEW (Merge Duplicate Parties): how many duplicate customer/supplier ROWS
    // were merged away — 0/0 means no same-name duplicates were found.
    data class DuplicatesMerged(val customersMerged: Int, val suppliersMerged: Int) : PartyEvent()
    // NEW (Cleanup Duplicate Payments): preview step — the stray duplicate payment
    // groups found, for the confirmation dialog to list before anything is deleted.
    // An empty list means none were found.
    data class DuplicatePaymentsFound(val groups: List<DuplicatePaymentGroup>) : PartyEvent()
    // NEW (Cleanup Duplicate Payments): how many stray payment rows were actually
    // deleted, plus how many customer/supplier balances that correction fixed.
    data class DuplicatePaymentsCleaned(
        val paymentsRemoved: Int,
        val customersFixed: Int,
        val suppliersFixed: Int
    ) : PartyEvent()
    // NEW (Cleanup Orphaned Payments): preview step — bill-embedded payment rows
    // whose purchase/sale no longer exists (see PartyRepository.findOrphanedPayments()),
    // for the confirmation dialog to list before anything is deleted. An empty list
    // means none were found.
    data class OrphanedPaymentsFound(val payments: List<com.grocerypos.v11.Payment>) : PartyEvent()
    // NEW (Cleanup Orphaned Payments): how many orphaned payment rows were actually
    // deleted, plus how many customer/supplier balances that correction fixed.
    data class OrphanedPaymentsCleaned(
        val paymentsRemoved: Int,
        val customersFixed: Int,
        val suppliersFixed: Int
    ) : PartyEvent()
}

class PartyViewModel(
    private val observeCustomers: ObserveCustomersUseCase,
    private val observeSuppliers: ObserveSuppliersUseCase,
    private val getLiveBalances: GetLiveBalancesUseCase,
    private val saveCustomer: SaveCustomerUseCase,
    private val saveSupplier: SaveSupplierUseCase,
    private val updateCustomer: UpdateCustomerUseCase,
    private val updateSupplier: UpdateSupplierUseCase,
    private val deleteCustomer: DeleteCustomerUseCase,
    private val deleteSupplier: DeleteSupplierUseCase,
    private val getCustomerHistory: GetCustomerHistoryUseCase,
    private val getSupplierHistory: GetSupplierHistoryUseCase,
    private val recalculateBalancesUseCase: RecalculateBalancesUseCase,
    private val mergeDuplicatePartiesUseCase: MergeDuplicatePartiesUseCase,
    private val findDuplicatePaymentsUseCase: FindDuplicatePaymentsUseCase,
    private val cleanupDuplicatePaymentsUseCase: CleanupDuplicatePaymentsUseCase,
    private val findOrphanedPaymentsUseCase: FindOrphanedPaymentsUseCase,
    private val cleanupOrphanedPaymentsUseCase: CleanupOrphanedPaymentsUseCase
) : ViewModel() {

    private val _uiState = MutableStateFlow(PartyUiState())
    val uiState: StateFlow<PartyUiState> = _uiState.asStateFlow()

    private val _events = MutableSharedFlow<PartyEvent>(extraBufferCapacity = 1)
    val events: SharedFlow<PartyEvent> = _events

    init {
        viewModelScope.launch {
            observeCustomers().collect { list ->
                _uiState.value = _uiState.value.copy(customers = list)
                refreshBalances()
            }
        }
        viewModelScope.launch {
            observeSuppliers().collect { list ->
                _uiState.value = _uiState.value.copy(suppliers = list)
                refreshBalances()
            }
        }
    }

    // PERMANENT FIX (balance drift): the customer/supplier Flow above only re-emits
    // when a customer/supplier ROW itself changes (name, opening balance, etc.) — not
    // when a sale/purchase/payment changes, which is what the live balance actually
    // depends on. So this is also called explicitly (PartyActivity.onResume) any time
    // this screen becomes visible again — e.g. coming back from a payment made on the
    // Party Transaction screen — to pick up the latest ledger-computed figures.
    fun refreshBalances() {
        viewModelScope.launch {
            val (customerBal, supplierBal) = getLiveBalances()
            _uiState.value = _uiState.value.copy(customerBalances = customerBal, supplierBalances = supplierBal)
        }
    }

    fun showCustomers() {
        _uiState.value = _uiState.value.copy(showingCustomers = true)
    }

    fun showSuppliers() {
        _uiState.value = _uiState.value.copy(showingCustomers = false)
    }

    /** Add-form Save button — adds a customer or supplier depending on the
     * currently selected tab. */
    fun addParty(name: String, phone: String, creditLimit: Double, openingBalance: Double, stuckBalance: Double = 0.0) {
        viewModelScope.launch {
            val result = if (_uiState.value.showingCustomers) {
                saveCustomer(name, phone, creditLimit, openingBalance, stuckBalance)
            } else {
                saveSupplier(name, phone, openingBalance)
            }
            _events.emit(if (result is SavePartyResult.Success) PartyEvent.Saved else PartyEvent.NameRequired)
        }
    }

    fun editCustomer(existing: Customer, name: String, phone: String, creditLimit: Double, openingBalance: Double, stuckBalance: Double? = null) {
        viewModelScope.launch {
            val result = updateCustomer(existing, name, phone, creditLimit, openingBalance, stuckBalance)
            _events.emit(if (result is SavePartyResult.Success) PartyEvent.Updated else PartyEvent.NameRequired)
        }
    }

    fun editSupplier(existing: Supplier, name: String, phone: String, openingBalance: Double) {
        viewModelScope.launch {
            val result = updateSupplier(existing, name, phone, openingBalance)
            _events.emit(if (result is SavePartyResult.Success) PartyEvent.Updated else PartyEvent.NameRequired)
        }
    }

    fun removeCustomer(customer: Customer) {
        viewModelScope.launch {
            deleteCustomer(customer)
            _events.emit(PartyEvent.Deleted)
        }
    }

    fun removeSupplier(supplier: Supplier) {
        viewModelScope.launch {
            deleteSupplier(supplier)
            _events.emit(PartyEvent.Deleted)
        }
    }

    /** Fetched on demand for the "tap for history" dialog — not part of
     * continuous UI state since it's only needed while that dialog is open. */
    suspend fun customerHistory(customer: Customer) = getCustomerHistory(customer)

    suspend fun supplierHistory(supplier: Supplier) = getSupplierHistory(supplier)

    /** "Recalculate Balances" action — see RecalculateBalancesUseCase /
     * PartyRepository.recalculateBalances() for what actually gets fixed. */
    fun recalculateBalances() {
        viewModelScope.launch {
            val result = recalculateBalancesUseCase()
            _events.emit(PartyEvent.BalancesRecalculated(result.customersFixed, result.suppliersFixed))
            refreshBalances()
        }
    }

    /** "Merge Duplicates" action — see MergeDuplicatePartiesUseCase /
     * PartyRepository.mergeDuplicateParties() for what actually gets merged. */
    fun mergeDuplicateParties() {
        viewModelScope.launch {
            val result = mergeDuplicatePartiesUseCase()
            _events.emit(PartyEvent.DuplicatesMerged(result.customersMerged, result.suppliersMerged))
            refreshBalances()
        }
    }

    /** "Cleanup Payments" chip — step 1: look for stray duplicate payment rows and
     * report what was found so the Activity can show a preview dialog before anything
     * is deleted. See FindDuplicatePaymentsUseCase / PartyRepository.findDuplicatePayments(). */
    fun findDuplicatePayments() {
        viewModelScope.launch {
            val groups = findDuplicatePaymentsUseCase()
            _events.emit(PartyEvent.DuplicatePaymentsFound(groups))
        }
    }

    /** "Cleanup Payments" chip — step 2: called once the shop owner confirms the preview.
     * [groups] should be exactly what the preview dialog showed, so a payment that arrived
     * mid-confirmation (e.g. from a sync pull) isn't swept up too — see
     * CleanupDuplicatePaymentsUseCase / PartyRepository.cleanupDuplicatePayments(). */
    fun cleanupDuplicatePayments(groups: List<DuplicatePaymentGroup>) {
        viewModelScope.launch {
            val result = cleanupDuplicatePaymentsUseCase(groups)
            _events.emit(
                PartyEvent.DuplicatePaymentsCleaned(
                    result.paymentsRemoved,
                    result.recalc.customersFixed,
                    result.recalc.suppliersFixed
                )
            )
            refreshBalances()
        }
    }

    /** "Cleanup Orphaned Payments" chip — step 1: look for bill-embedded payment rows
     * whose purchase/sale no longer exists and report what was found, so the Activity
     * can show a preview dialog before anything is deleted. See
     * FindOrphanedPaymentsUseCase / PartyRepository.findOrphanedPayments(). */
    fun findOrphanedPayments() {
        viewModelScope.launch {
            val payments = findOrphanedPaymentsUseCase()
            _events.emit(PartyEvent.OrphanedPaymentsFound(payments))
        }
    }

    /** "Cleanup Orphaned Payments" chip — step 2: called once the shop owner confirms
     * the preview. [payments] should be exactly what the preview dialog showed — see
     * CleanupOrphanedPaymentsUseCase / PartyRepository.cleanupOrphanedPayments(). */
    fun cleanupOrphanedPayments(payments: List<com.grocerypos.v11.Payment>) {
        viewModelScope.launch {
            val result = cleanupOrphanedPaymentsUseCase(payments)
            _events.emit(
                PartyEvent.OrphanedPaymentsCleaned(
                    result.paymentsRemoved,
                    result.recalc.customersFixed,
                    result.recalc.suppliersFixed
                )
            )
            refreshBalances()
        }
    }
}
