package com.grocerypos.v11.ui

import android.content.Context
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import com.grocerypos.v11.PosDatabase
import com.grocerypos.v11.data.PartyRepository
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
import com.grocerypos.v11.domain.SaveSupplierUseCase
import com.grocerypos.v11.domain.UpdateCustomerUseCase
import com.grocerypos.v11.domain.UpdateSupplierUseCase

/**
 * Wires PartyRepository + its UseCases and hands them to PartyViewModel.
 * There's no Hilt/Dagger in this project yet, so this manual factory is the
 * DI boundary for this screen — [context] should be `applicationContext` so
 * the repository doesn't hold a reference to the Activity.
 */
class PartyViewModelFactory(context: Context) : ViewModelProvider.Factory {

    private val repository = PartyRepository(PosDatabase.get(context), context.applicationContext)

    @Suppress("UNCHECKED_CAST")
    override fun <T : ViewModel> create(modelClass: Class<T>): T {
        return PartyViewModel(
            observeCustomers = ObserveCustomersUseCase(repository),
            observeSuppliers = ObserveSuppliersUseCase(repository),
            getLiveBalances = GetLiveBalancesUseCase(repository),
            saveCustomer = SaveCustomerUseCase(repository),
            saveSupplier = SaveSupplierUseCase(repository),
            updateCustomer = UpdateCustomerUseCase(repository),
            updateSupplier = UpdateSupplierUseCase(repository),
            deleteCustomer = DeleteCustomerUseCase(repository),
            deleteSupplier = DeleteSupplierUseCase(repository),
            getCustomerHistory = GetCustomerHistoryUseCase(repository),
            getSupplierHistory = GetSupplierHistoryUseCase(repository),
            recalculateBalancesUseCase = RecalculateBalancesUseCase(repository),
            mergeDuplicatePartiesUseCase = MergeDuplicatePartiesUseCase(repository),
            findDuplicatePaymentsUseCase = FindDuplicatePaymentsUseCase(repository),
            cleanupDuplicatePaymentsUseCase = CleanupDuplicatePaymentsUseCase(repository),
            findOrphanedPaymentsUseCase = FindOrphanedPaymentsUseCase(repository),
            cleanupOrphanedPaymentsUseCase = CleanupOrphanedPaymentsUseCase(repository)
        ) as T
    }
}
