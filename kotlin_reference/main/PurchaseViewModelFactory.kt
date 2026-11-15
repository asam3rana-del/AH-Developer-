package com.grocerypos.v11.ui

import android.content.Context
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import com.grocerypos.v11.PosDatabase
import com.grocerypos.v11.data.PurchaseRepository
import com.grocerypos.v11.data.RoomPurchaseRepository
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

/**
 * Wires PurchaseRepository + its UseCases and hands them to PurchaseViewModel.
 * There's no Hilt/Dagger in this project yet, so this manual factory is the
 * DI boundary for this screen — [context] should be `applicationContext` so
 * the repository doesn't hold a reference to the Activity.
 */
class PurchaseViewModelFactory(context: Context) : ViewModelProvider.Factory {

    private val repository: PurchaseRepository = RoomPurchaseRepository(PosDatabase.get(context), context.applicationContext)

    @Suppress("UNCHECKED_CAST")
    override fun <T : ViewModel> create(modelClass: Class<T>): T {
        return PurchaseViewModel(
            observeSuppliersUseCase = ObserveSuppliersForPurchaseUseCase(repository),
            observeProductsUseCase = ObserveProductsUseCase(repository),
            observeUnitsUseCase = ObserveUnitsUseCase(repository),
            loadFirmNameUseCase = LoadFirmNameUseCase(repository),
            loadCategoriesUseCase = LoadCategoriesUseCase(repository),
            loadPurchaseForEditUseCase = LoadPurchaseForEditUseCase(repository),
            findLastPurchaseRateUseCase = FindLastPurchaseRateUseCase(repository),
            addSupplierUseCase = AddSupplierUseCase(repository),
            addProductUseCase = AddProductUseCase(repository),
            addUnitUseCase = AddUnitUseCase(repository),
            addCategoryUseCase = AddCategoryUseCase(repository),
            renameUnitToEnglishUseCase = RenameUnitToEnglishUseCase(repository),
            updateDefaultUnitIndexUseCase = UpdateDefaultUnitIndexUseCase(repository),
            processScannedItemsUseCase = ProcessScannedItemsUseCase(repository),
            savePurchaseUseCase = SavePurchaseUseCase(repository),
            deletePurchaseUseCase = DeletePurchaseUseCase(repository)
        ) as T
    }
}
