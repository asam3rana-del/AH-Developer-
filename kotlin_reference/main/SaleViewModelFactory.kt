package com.grocerypos.v11.ui

import android.content.Context
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import com.grocerypos.v11.PosDatabase
import com.grocerypos.v11.data.SaleRepository
import com.grocerypos.v11.data.RoomSaleRepository
import com.grocerypos.v11.domain.CreateCustomerUseCase
import com.grocerypos.v11.domain.DeleteHeldBillUseCase
import com.grocerypos.v11.domain.DeleteSaleUseCase
import com.grocerypos.v11.domain.HeldBillsUseCase
import com.grocerypos.v11.domain.HoldBillUseCase
import com.grocerypos.v11.domain.LoadFirmNameForSaleUseCase
import com.grocerypos.v11.domain.LoadSaleForEditUseCase
import com.grocerypos.v11.domain.ObserveCustomersForSaleUseCase
import com.grocerypos.v11.domain.ObserveProductsForSaleUseCase
import com.grocerypos.v11.domain.SaveQuickSaleUseCase
import com.grocerypos.v11.domain.SaveSaleUseCase
import com.grocerypos.v11.domain.TopSellingProductNamesUseCase

/**
 * Wires SaleRepository + its UseCases and hands them to SaleViewModel.
 * There's no Hilt/Dagger in this project yet, so this manual factory is the
 * DI boundary for this screen — [context] should be `applicationContext` so
 * the repository doesn't hold a reference to the Activity.
 */
class SaleViewModelFactory(context: Context) : ViewModelProvider.Factory {

    private val repository: SaleRepository = RoomSaleRepository(PosDatabase.get(context), context.applicationContext)

    @Suppress("UNCHECKED_CAST")
    override fun <T : ViewModel> create(modelClass: Class<T>): T {
        return SaleViewModel(
            observeCustomers = ObserveCustomersForSaleUseCase(repository),
            observeProducts = ObserveProductsForSaleUseCase(repository),
            loadFirmNameUseCase = LoadFirmNameForSaleUseCase(repository),
            loadSaleForEdit = LoadSaleForEditUseCase(repository),
            saveSaleUseCase = SaveSaleUseCase(repository),
            saveQuickSaleUseCase = SaveQuickSaleUseCase(repository),
            deleteSaleUseCase = DeleteSaleUseCase(repository),
            createCustomerUseCase = CreateCustomerUseCase(repository),
            topSellingProductNamesUseCase = TopSellingProductNamesUseCase(repository),
            holdBillUseCase = HoldBillUseCase(repository),
            heldBillsUseCase = HeldBillsUseCase(repository),
            deleteHeldBillUseCase = DeleteHeldBillUseCase(repository)
        ) as T
    }
}
