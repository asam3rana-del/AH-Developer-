package com.grocerypos.v11.domain

import com.grocerypos.v11.Product
import com.grocerypos.v11.Purchase
import com.grocerypos.v11.PurchaseItem
import com.grocerypos.v11.Supplier
import com.grocerypos.v11.UnitType
import com.grocerypos.v11.data.PurchaseEditData
import com.grocerypos.v11.data.PurchaseLine
import com.grocerypos.v11.data.PurchaseRepository
import com.grocerypos.v11.data.SavePurchaseResult
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flowOf

/**
 * In-memory test double for [PurchaseRepository]. Lets SavePurchaseUseCase /
 * ProcessScannedItemsUseCase (etc.) be unit tested without a real Room
 * database or Android Context — configure the `*Result` / `*Throws` fields
 * before calling a use case, then inspect the `last*Call` fields afterward to
 * assert what the use case actually asked the repository to do.
 *
 * This does NOT reimplement RoomPurchaseRepository's stock/cost/transaction
 * logic — it's a controllable stand-in, not a second copy of production
 * logic. Tests that need real stock/cost/transaction behavior belong in an
 * instrumented (Robolectric or on-device) test against RoomPurchaseRepository
 * itself. (Added in Improvement Pack P9, mirroring FakeSaleRepository.)
 */
class FakePurchaseRepository(
    private val suppliers: MutableList<Supplier> = mutableListOf(),
    private val products: MutableList<Product> = mutableListOf(),
    private val units: MutableList<UnitType> = mutableListOf()
) : PurchaseRepository {

    // ---- Configure these before invoking a use case under test ----
    var savePurchaseResult: SavePurchaseResult = SavePurchaseResult.Success(billNo = "TESTBILL", isUpdate = false)
    var savePurchaseThrows: RuntimeException? = null

    var loadForEditResult: PurchaseEditData? = null
    var findLastPurchaseRateResult: Pair<Double, String>? = null
    var firmName: String? = "Test Shop"
    var categoriesResult: List<String> = listOf("General")

    // ---- Recorded calls, for assertions ----
    var lastSavePurchaseCall: SavePurchaseCallArgs? = null
        private set
    var deletePurchaseCallCount: Int = 0
        private set

    data class SavePurchaseCallArgs(
        val editBillNo: String?,
        val party: String,
        val grandTotal: Double,
        val amountPaid: Double,
        val discount: Double,
        val paymentMethod: String,
        val lineCount: Int,
        val isUpdate: Boolean
    )

    override fun observeSuppliers(): Flow<List<Supplier>> = flowOf(suppliers.toList())

    override fun observeProducts(): Flow<List<Product>> = flowOf(products.toList())

    override fun observeUnits(): Flow<List<UnitType>> = flowOf(units.toList())

    override suspend fun getFirmName(): String? = firmName

    override suspend fun categories(): List<String> = categoriesResult

    override suspend fun addUnit(name: String) {
        units.add(UnitType(name))
    }

    // FIX (build: "FakePurchaseRepository is not abstract and does not
    // implement abstract member 'addCategory'" — PurchaseRepository already
    // declared addCategory, this test double just never added the override):
    // recorded the same way categoriesResult/addUnit are, so a test can both
    // drive AddCategoryUseCase and assert what got "saved".
    val addedCategories: MutableList<String> = mutableListOf()
    override suspend fun addCategory(name: String) {
        addedCategories.add(name)
    }

    override suspend fun renameUnitToEnglish(oldValue: String, newValue: String) {
        if (oldValue.isBlank() || newValue.isBlank() || oldValue == newValue) return
        units.removeAll { it.name == oldValue }
        units.add(UnitType(newValue))
        for (i in products.indices) {
            val p = products[i]
            products[i] = p.copy(
                unit = if (p.unit == oldValue) newValue else p.unit,
                secondaryUnit = if (p.secondaryUnit == oldValue) newValue else p.secondaryUnit,
                tertiaryUnit = if (p.tertiaryUnit == oldValue) newValue else p.tertiaryUnit
            )
        }
    }

    override suspend fun updateDefaultUnitIndex(barcode: String, index: Int) {
        val i = products.indexOfFirst { it.barcode == barcode }
        if (i >= 0) products[i] = products[i].copy(defaultUnitIndex = index)
    }

    override suspend fun addSupplier(name: String, phone: String, openingBalance: Double): Supplier {
        val newSupplier = Supplier(id = (suppliers.size + 1).toLong(), name = name, phone = phone, openingBalance = openingBalance)
        suppliers.add(newSupplier)
        return newSupplier
    }

    override suspend fun addProduct(product: Product) {
        products.add(product)
    }

    override suspend fun createProductForScan(name: String, cost: Double, seed: Int): Product {
        val newProduct = Product(
            barcode = "TESTSCAN$seed",
            name = name, category = "General", cost = cost, salePrice = 0.0, wholesalePrice = 0.0,
            stock = 0.0, openingStock = 0.0, unit = "pcs", secondaryUnit = "", secondaryUnitQty = 0.0
        )
        products.add(newProduct)
        return newProduct
    }

    override suspend fun loadForEdit(billNo: String): PurchaseEditData? = loadForEditResult

    var paymentsForBillResult: List<Pair<String, Double>> = emptyList()
    override suspend fun paymentsForBill(billNo: String): List<Pair<String, Double>> = paymentsForBillResult

    override suspend fun findLastPurchaseRate(barcode: String, excludeBillNo: String?): Pair<Double, String>? =
        findLastPurchaseRateResult

    override suspend fun deletePurchase(billNo: String, original: Purchase?, originalItems: List<PurchaseItem>) {
        deletePurchaseCallCount++
    }

    override suspend fun savePurchase(
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
        supplierInvoiceNo: String,
        payments: List<Pair<String, Double>>
    ): SavePurchaseResult {
        lastSavePurchaseCall = SavePurchaseCallArgs(
            editBillNo = editBillNo,
            party = party,
            grandTotal = grandTotal,
            amountPaid = amountPaid,
            discount = discount,
            paymentMethod = paymentMethod,
            lineCount = lines.size,
            isUpdate = original != null
        )
        savePurchaseThrows?.let { throw it }
        return savePurchaseResult
    }
}
