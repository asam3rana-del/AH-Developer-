package com.grocerypos.v11.ui
import com.grocerypos.v11.SyncQueueHelper

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.grocerypos.v11.Product
import com.grocerypos.v11.Purchase
import com.grocerypos.v11.PurchaseItem
import com.grocerypos.v11.Supplier
import com.grocerypos.v11.data.PurchaseEditData
import com.grocerypos.v11.data.PurchaseLine
import com.grocerypos.v11.data.SavePurchaseResult
import com.grocerypos.v11.domain.AddCategoryUseCase
import com.grocerypos.v11.domain.AddProductUseCase
import com.grocerypos.v11.domain.AddSupplierUseCase
import com.grocerypos.v11.domain.AddUnitUseCase
import com.grocerypos.v11.domain.DeletePurchaseUseCase
import com.grocerypos.v11.domain.FindLastPurchaseRateUseCase
import com.grocerypos.v11.domain.LoadCategoriesUseCase
import com.grocerypos.v11.domain.LoadFirmNameUseCase
import com.grocerypos.v11.domain.LoadPurchaseForEditUseCase
import com.grocerypos.v11.domain.ObserveProductsUseCase
import com.grocerypos.v11.domain.ObserveSuppliersForPurchaseUseCase
import com.grocerypos.v11.domain.ObserveUnitsUseCase
import com.grocerypos.v11.domain.ProcessScannedItemsUseCase
import com.grocerypos.v11.domain.RenameUnitToEnglishUseCase
import com.grocerypos.v11.domain.SavePurchaseUseCase
import com.grocerypos.v11.domain.UpdateDefaultUnitIndexUseCase
import com.grocerypos.v11.domain.ScannedLine
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

private val DEFAULT_UNITS = listOf("pcs", "kg", "box", "dozen", "carton", "ctn", "outer", "dabbi")

/** Everything the Purchase screen needs that comes from the database — the
 * Activity only reads this, it never queries Room or SyncQueueHelper itself.
 * Item-line building (unit toggling, live totals, the in-progress bill) stays
 * Activity-side UI state, same as before — that's pure UI concern specific to
 * building the current bill. */
data class PurchaseUiState(
    val suppliers: List<Supplier> = emptyList(),
    val products: List<Product> = emptyList(),
    val units: List<String> = DEFAULT_UNITS,
    val firmName: String? = null
)

/** One-shot outcomes (toast text, navigating to the bill preview) that
 * shouldn't re-fire just because the Activity re-collects state (e.g. after a
 * rotation). */
sealed class PurchaseEvent {
    data class Saved(
        val billNo: String,
        val isUpdate: Boolean,
        val party: String,
        val grandTotal: Double,
        val discount: Double,
        val amountPaid: Double,
        val paymentMethod: String
    ) : PurchaseEvent()
    object Deleted : PurchaseEvent()
    data class Error(val message: String) : PurchaseEvent()
}

class PurchaseViewModel(
    private val observeSuppliersUseCase: ObserveSuppliersForPurchaseUseCase,
    private val observeProductsUseCase: ObserveProductsUseCase,
    private val observeUnitsUseCase: ObserveUnitsUseCase,
    private val loadFirmNameUseCase: LoadFirmNameUseCase,
    private val loadCategoriesUseCase: LoadCategoriesUseCase,
    private val loadPurchaseForEditUseCase: LoadPurchaseForEditUseCase,
    private val findLastPurchaseRateUseCase: FindLastPurchaseRateUseCase,
    private val addSupplierUseCase: AddSupplierUseCase,
    private val addProductUseCase: AddProductUseCase,
    private val addUnitUseCase: AddUnitUseCase,
    private val addCategoryUseCase: AddCategoryUseCase,
    private val renameUnitToEnglishUseCase: RenameUnitToEnglishUseCase,
    private val updateDefaultUnitIndexUseCase: UpdateDefaultUnitIndexUseCase,
    private val processScannedItemsUseCase: ProcessScannedItemsUseCase,
    private val savePurchaseUseCase: SavePurchaseUseCase,
    private val deletePurchaseUseCase: DeletePurchaseUseCase
) : ViewModel() {

    private val _uiState = MutableStateFlow(PurchaseUiState())
    val uiState: StateFlow<PurchaseUiState> = _uiState.asStateFlow()

    private val _events = MutableSharedFlow<PurchaseEvent>(extraBufferCapacity = 1)
    val events: SharedFlow<PurchaseEvent> = _events

    init {
        viewModelScope.launch {
            observeSuppliersUseCase().collect { list ->
                _uiState.value = _uiState.value.copy(suppliers = list)
            }
        }
        viewModelScope.launch {
            observeProductsUseCase().collect { list ->
                _uiState.value = _uiState.value.copy(products = list)
            }
        }
        viewModelScope.launch {
            observeUnitsUseCase().collect { list ->
                _uiState.value = _uiState.value.copy(units = (DEFAULT_UNITS + list.map { it.name }).distinct())
            }
        }
        viewModelScope.launch {
            val name = loadFirmNameUseCase()
            if (!name.isNullOrBlank()) _uiState.value = _uiState.value.copy(firmName = name)
        }
    }

    /** Fetched on demand for edit mode / dialogs — not part of continuous UI
     * state since each is only needed while its screen/dialog is open. */
    suspend fun loadForEdit(billNo: String): PurchaseEditData? = loadPurchaseForEditUseCase(billNo)

    suspend fun categories(): List<String> = loadCategoriesUseCase()

    suspend fun lastPurchaseRate(barcode: String, excludeBillNo: String?): Pair<Double, String>? =
        findLastPurchaseRateUseCase(barcode, excludeBillNo)

    suspend fun addSupplier(name: String, phone: String = "", openingBalance: Double = 0.0): Supplier =
        addSupplierUseCase(name, phone, openingBalance)

    suspend fun addProduct(product: Product) = addProductUseCase(product)

    suspend fun addUnit(name: String) = addUnitUseCase(name)

    suspend fun addCategory(name: String) = addCategoryUseCase(name)

    suspend fun renameUnitToEnglish(oldValue: String, newValue: String) =
        renameUnitToEnglishUseCase(oldValue, newValue)

    suspend fun updateDefaultUnitIndex(barcode: String, index: Int) =
        updateDefaultUnitIndexUseCase(barcode, index)

    suspend fun processScannedItems(scanned: List<ScannedLine>): List<PurchaseLine> =
        processScannedItemsUseCase(scanned, _uiState.value.products)

    fun save(
        editBillNo: String?,
        party: String,
        grandTotal: Double,
        amountPaid: Double,
        discount: Double,
        paymentMethod: String,
        purchaseDateMillis: Long,
        lines: List<PurchaseLine>,
        original: Purchase?,
        originalItems: List<PurchaseItem>,
        supplierInvoiceNo: String = "",
        payments: List<Pair<String, Double>> = emptyList()
    ) {
        viewModelScope.launch {
            val result = savePurchaseUseCase(
                editBillNo, party, grandTotal, amountPaid, discount, paymentMethod,
                purchaseDateMillis, lines, original, originalItems, _uiState.value.suppliers, supplierInvoiceNo, payments
            )
            when (result) {
                is SavePurchaseResult.Success -> _events.emit(
                    PurchaseEvent.Saved(result.billNo, result.isUpdate, party, grandTotal, discount, amountPaid, paymentMethod)
                )
                is SavePurchaseResult.Error -> _events.emit(PurchaseEvent.Error(result.message))
            }
        }
    }

    fun delete(billNo: String, original: Purchase?, originalItems: List<PurchaseItem>) {
        viewModelScope.launch {
            try {
                deletePurchaseUseCase(billNo, original, originalItems)
                _events.emit(PurchaseEvent.Deleted)
            } catch (e: Exception) {
                _events.emit(PurchaseEvent.Error(e.message ?: "Delete failed"))
            }
        }
    }
}
