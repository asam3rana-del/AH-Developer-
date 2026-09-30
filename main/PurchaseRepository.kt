package com.grocerypos.v11.data

import com.grocerypos.v11.Product
import com.grocerypos.v11.Purchase
import com.grocerypos.v11.PurchaseItem
import com.grocerypos.v11.Supplier
import com.grocerypos.v11.UnitType
import kotlinx.coroutines.flow.Flow

/**
 * One line item on a purchase bill being built/edited — carries enough unit-
 * conversion context (mainUnit/secondaryUnit/tertiaryUnit + their quantities)
 * for PurchaseActivity to redo its live unit-toggle math on an edit/scan/draft
 * reload without re-querying the product.
 *
 * [itemName] is what gets snapshotted onto the saved PurchaseItem row (see
 * PurchaseItem.itemName's comment in Database.kt) so History/Edit/Return
 * don't need a live product lookup to show the right name later.
 *
 * [retailRate]/[wholesaleRate]: 0.0 means "leave that product price
 * unchanged" — a nonzero value here updates the product's salePrice /
 * wholesalePrice at purchase time (see RoomPurchaseRepository.savePurchase).
 */
data class PurchaseLine(
    val itemName: String,
    val barcode: String?,
    val qty: Double,
    val unit: String,
    val rate: Double,
    val amount: Double,
    val mainUnit: String,
    val secondaryUnit: String,
    val secondaryUnitQty: Double,
    val tertiaryUnit: String = "",
    val tertiaryUnitQty: Double = 0.0,
    val retailRate: Double = 0.0,
    val wholesaleRate: Double = 0.0
)

/** Snapshot loaded for editing an existing purchase bill.
 *
 * [payments]: the (method, amount) split-payment breakdown for this bill —
 * populated by LoadPurchaseForEditUseCase (via a separate
 * [PurchaseRepository.paymentsForBill] call) only when the bill actually had
 * 2+ payment methods, so PurchaseActivity.loadForEdit() knows to re-open the
 * Split Payment dialog. Empty for a normal single-method bill. */
data class PurchaseEditData(
    val purchase: Purchase,
    val items: List<PurchaseItem>,
    val supplierName: String,
    val lines: List<PurchaseLine>,
    val payments: List<Pair<String, Double>> = emptyList()
)

/** Result of [PurchaseRepository.savePurchase]. */
sealed class SavePurchaseResult {
    data class Success(val billNo: String, val isUpdate: Boolean) : SavePurchaseResult()
    data class Error(val message: String) : SavePurchaseResult()
}

/**
 * Repository contract for the Purchase screen (PurchaseActivity /
 * PurchaseViewModel). UseCases and the ViewModel go through this interface
 * instead of touching PosDatabase directly — [RoomPurchaseRepository] is the
 * one (and only) real implementation; see that file for the actual DAO
 * calls, transaction boundaries, and the reasoning behind each FIX.
 *
 * FIX ("cannot inherit from final PurchaseRepository" — kaptGenerateStubsDebugKotlin
 * build failure): this used to be a concrete `class PurchaseRepository` with its
 * own (older, incomplete) DAO logic directly inside it — a leftover from before
 * this was split into an interface + RoomPurchaseRepository implementation.
 * Kotlin classes are final by default, so `class RoomPurchaseRepository(...) :
 * PurchaseRepository` failed to compile ("cannot inherit from final
 * PurchaseRepository"). That old class body also predated several features
 * RoomPurchaseRepository already implements (addCategory, renameUnitToEnglish,
 * updateDefaultUnitIndex, paymentsForBill, split payments, supplierInvoiceNo,
 * per-line retail/wholesale rate), so this interface is written to match
 * RoomPurchaseRepository's actual `override` members exactly, not the old
 * class's narrower set.
 */
interface PurchaseRepository {

    fun observeSuppliers(): Flow<List<Supplier>>

    fun observeProducts(): Flow<List<Product>>

    fun observeUnits(): Flow<List<UnitType>>

    suspend fun getFirmName(): String?

    suspend fun categories(): List<String>

    suspend fun addUnit(name: String)

    /** Inline "Add New Category" from the Purchase screen's Add Product dialog. */
    suspend fun addCategory(name: String)

    /** Renames a unit (typically Urdu -> English) from the Purchase screen's
     * unit picker, cascading into every product that uses it. */
    suspend fun renameUnitToEnglish(oldValue: String, newValue: String)

    /** Sets/changes a product's default unit index from the Purchase screen. */
    suspend fun updateDefaultUnitIndex(barcode: String, index: Int)

    suspend fun addSupplier(name: String, phone: String = "", openingBalance: Double = 0.0): Supplier

    suspend fun addProduct(product: Product)

    /** Auto-creates a Product for a scanned bill item that doesn't match any
     * existing product. [seed] disambiguates the generated barcode across a batch. */
    suspend fun createProductForScan(name: String, cost: Double, seed: Int): Product

    suspend fun loadForEdit(billNo: String): PurchaseEditData?

    /** Rebuilds the (method, amount) split-payment breakdown for a bill, so
     * the Split Payment dialog can repopulate correctly when editing. */
    suspend fun paymentsForBill(billNo: String): List<Pair<String, Double>>

    /** Finds the most recent PAST purchase of [barcode] (excluding
     * [excludeBillNo], the bill currently being edited if any) and returns its
     * rate + the unit it was recorded in. */
    suspend fun findLastPurchaseRate(barcode: String, excludeBillNo: String?): Pair<Double, String>?

    suspend fun deletePurchase(billNo: String, original: Purchase?, originalItems: List<PurchaseItem>)

    suspend fun savePurchase(
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
        suppliers: List<Supplier>,
        supplierInvoiceNo: String = "",
        payments: List<Pair<String, Double>> = emptyList()
    ): SavePurchaseResult
}
