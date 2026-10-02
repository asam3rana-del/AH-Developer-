package com.grocerypos.v11.domain

import com.grocerypos.v11.Customer
import com.grocerypos.v11.Purchase
import com.grocerypos.v11.Sale
import com.grocerypos.v11.Supplier
import com.grocerypos.v11.data.CleanupPaymentsResult
import com.grocerypos.v11.data.DuplicatePaymentGroup
import com.grocerypos.v11.data.MergeResult
import com.grocerypos.v11.data.PartyRepository
import com.grocerypos.v11.data.RecalcResult
import kotlinx.coroutines.flow.Flow

/**
 * UseCases for the Customers & Suppliers screen (PartyActivity / PartyViewModel).
 *
 * Each one is a single, named operation rather than exposing PartyRepository's
 * raw CRUD to the ViewModel — the validation that belongs to "adding a party"
 * (e.g. name is required), not to "writing a row to the database", lives here.
 * This is also the layer a unit test would target: no Android framework
 * classes are involved above PartyRepository.
 */

/** Result of validating + saving/updating a customer or supplier. */
sealed class SavePartyResult {
    object Success : SavePartyResult()
    object NameRequired : SavePartyResult()
}

class ObserveCustomersUseCase(private val repository: PartyRepository) {
    operator fun invoke(): Flow<List<Customer>> = repository.observeCustomers()
}

class ObserveSuppliersUseCase(private val repository: PartyRepository) {
    operator fun invoke(): Flow<List<Supplier>> = repository.observeSuppliers()
}

/** PERMANENT FIX (balance drift): the Customers & Suppliers list's closing
 * ("You'll Get/Give") figures come from here — PartyRepository's live,
 * recomputed-from-the-ledger balances — instead of each Customer/Supplier's
 * stored, driftable `.balance` field. See PartyRepository.liveCustomerBalances(). */
class GetLiveBalancesUseCase(private val repository: PartyRepository) {
    suspend operator fun invoke(): Pair<Map<Long, Double>, Map<Long, Double>> =
        Pair(repository.liveCustomerBalances(), repository.liveSupplierBalances())
}

class SaveCustomerUseCase(private val repository: PartyRepository) {
    suspend operator fun invoke(
        name: String,
        phone: String,
        creditLimit: Double,
        openingBalance: Double,
        // NEW (Stuck Balance): optional; 0.0 for the vast majority of customers.
        stuckBalance: Double = 0.0
    ): SavePartyResult {
        val trimmedName = name.trim()
        if (trimmedName.isEmpty()) return SavePartyResult.NameRequired
        repository.saveCustomer(
            Customer(
                name = trimmedName,
                phone = phone.trim(),
                creditLimit = creditLimit,
                openingBalance = openingBalance,
                balance = 0.0,
                stuckBalance = stuckBalance
            )
        )
        return SavePartyResult.Success
    }
}

class SaveSupplierUseCase(private val repository: PartyRepository) {
    suspend operator fun invoke(
        name: String,
        phone: String,
        openingBalance: Double
    ): SavePartyResult {
        val trimmedName = name.trim()
        if (trimmedName.isEmpty()) return SavePartyResult.NameRequired
        repository.saveSupplier(
            Supplier(
                name = trimmedName,
                phone = phone.trim(),
                openingBalance = openingBalance,
                balance = 0.0
            )
        )
        return SavePartyResult.Success
    }
}

class UpdateCustomerUseCase(private val repository: PartyRepository) {
    suspend operator fun invoke(
        existing: Customer,
        name: String,
        phone: String,
        creditLimit: Double,
        openingBalance: Double,
        // NEW (Stuck Balance): null = "caller doesn't touch it" (e.g. a non-admin edit
        // where the field isn't even shown) — keeps the existing stuck amount instead of
        // silently zeroing it. A real value (including 0.0 to clear it) overwrites.
        stuckBalance: Double? = null
    ): SavePartyResult {
        val trimmedName = name.trim()
        if (trimmedName.isEmpty()) return SavePartyResult.NameRequired
        repository.updateCustomer(
            existing.copy(
                name = trimmedName,
                phone = phone.trim(),
                creditLimit = creditLimit,
                openingBalance = openingBalance,
                stuckBalance = stuckBalance ?: existing.stuckBalance
            )
        )
        return SavePartyResult.Success
    }
}

class UpdateSupplierUseCase(private val repository: PartyRepository) {
    suspend operator fun invoke(
        existing: Supplier,
        name: String,
        phone: String,
        openingBalance: Double
    ): SavePartyResult {
        val trimmedName = name.trim()
        if (trimmedName.isEmpty()) return SavePartyResult.NameRequired
        repository.updateSupplier(
            existing.copy(
                name = trimmedName,
                phone = phone.trim(),
                openingBalance = openingBalance
            )
        )
        return SavePartyResult.Success
    }
}

class DeleteCustomerUseCase(private val repository: PartyRepository) {
    suspend operator fun invoke(customer: Customer) = repository.deleteCustomer(customer)
}

class DeleteSupplierUseCase(private val repository: PartyRepository) {
    suspend operator fun invoke(supplier: Supplier) = repository.deleteSupplier(supplier)
}

class GetCustomerHistoryUseCase(private val repository: PartyRepository) {
    suspend operator fun invoke(customer: Customer): List<Sale> =
        repository.salesByCustomer(customer.id)
}

class GetSupplierHistoryUseCase(private val repository: PartyRepository) {
    suspend operator fun invoke(supplier: Supplier): List<Purchase> =
        repository.purchasesBySupplier(supplier.id)
}

/** Recomputes every customer/supplier balance from their actual bills + payments
 * and corrects any drift — see PartyRepository.recalculateBalances(). */
class RecalculateBalancesUseCase(private val repository: PartyRepository) {
    suspend operator fun invoke(): RecalcResult = repository.recalculateBalances()
}

/** Merges same-name duplicate customers/suppliers into one record — see
 * PartyRepository.mergeDuplicateParties() for what actually happens. */
class MergeDuplicatePartiesUseCase(private val repository: PartyRepository) {
    suspend operator fun invoke(): MergeResult = repository.mergeDuplicateParties()
}

/** Preview step for "Cleanup Duplicate Payments" — finds the stray duplicate payment
 * rows without deleting anything yet, so the screen can show what it's about to remove
 * before the shop owner confirms. See PartyRepository.findDuplicatePayments(). */
class FindDuplicatePaymentsUseCase(private val repository: PartyRepository) {
    suspend operator fun invoke(): List<DuplicatePaymentGroup> = repository.findDuplicatePayments()
}

/** Deletes the duplicate payment rows found by [FindDuplicatePaymentsUseCase] and fixes
 * the balances they were throwing off — see PartyRepository.cleanupDuplicatePayments(). */
class CleanupDuplicatePaymentsUseCase(private val repository: PartyRepository) {
    suspend operator fun invoke(groups: List<DuplicatePaymentGroup>? = null): CleanupPaymentsResult =
        repository.cleanupDuplicatePayments(groups)
}

/** Preview step for "Cleanup Orphaned Payments" — finds bill-embedded payment rows
 * whose purchase/sale no longer exists (left behind by a bill deleted before
 * deletePurchase()/deleteSale() cleaned up their payment row too), without deleting
 * anything yet. See PartyRepository.findOrphanedPayments(). */
class FindOrphanedPaymentsUseCase(private val repository: PartyRepository) {
    suspend operator fun invoke(): List<com.grocerypos.v11.Payment> = repository.findOrphanedPayments()
}

/** Deletes the orphaned payment rows found by [FindOrphanedPaymentsUseCase] and fixes
 * the balances they were throwing off — see PartyRepository.cleanupOrphanedPayments(). */
class CleanupOrphanedPaymentsUseCase(private val repository: PartyRepository) {
    suspend operator fun invoke(payments: List<com.grocerypos.v11.Payment>? = null): CleanupPaymentsResult =
        repository.cleanupOrphanedPayments(payments)
}
