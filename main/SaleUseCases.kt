package com.grocerypos.v11.domain

import com.grocerypos.v11.Customer
import com.grocerypos.v11.DeviceTag
import com.grocerypos.v11.HeldBill
import com.grocerypos.v11.Product
import com.grocerypos.v11.Sale
import com.grocerypos.v11.SaleItem
import com.grocerypos.v11.data.DuplicateInvoiceException
import com.grocerypos.v11.data.InvalidQuantityException
import com.grocerypos.v11.data.SaleRepository
import com.grocerypos.v11.data.StockUnavailableException
import com.grocerypos.v11.pricing.DiscountCalculator
import kotlinx.coroutines.flow.Flow
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * UseCases for the Sale screen (SaleActivity / SaleViewModel).
 *
 * Each one is a single, named operation rather than exposing SaleRepository's
 * raw reads/writes to the ViewModel — validation and calculation that belongs
 * to "saving a sale" (line items required, due needs a customer, invoice
 * numbering, applying the discount/paid clamps) lives here, not in the
 * Activity and not in the Repository. This is also the layer a unit test
 * would target: no Android framework classes are involved above
 * SaleRepository.
 */

/** One line item on a bill — the domain shape both the live editing screen
 * (SaleActivity's `lines` list) and an edit-reload (LoadSaleForEditUseCase)
 * use. */
data class SaleLine(
    val barcode: String,
    val itemName: String,
    val qty: Double,
    val unit: String,
    val unitPrice: Double,
    val cost: Double,
    val amount: Double,
    val mainUnit: String,
    val secondaryUnit: String,
    val secondaryUnitQty: Double,
    val tertiaryUnit: String = "",
    val tertiaryUnitQty: Double = 0.0
)

/** Everything needed to repopulate the Sale screen for editing an existing invoice. */
data class SaleForEdit(
    val sale: Sale,
    val items: List<SaleItem>,
    val customerName: String,
    val lines: List<SaleLine>,
    // NEW (Split Payment): non-empty only when this bill was originally saved
    // with more than one payment method — lets the Sale screen re-open the
    // Split Payment dialog pre-filled instead of just showing the combined total.
    val payments: List<Pair<String, Double>> = emptyList()
)

/** Result of validating + saving a sale (new or edit). */
sealed class SaveSaleResult {
    data class Success(
        val invoice: String,
        val customer: Customer?,
        val customerNameEntered: String,
        val subtotal: Double,
        val discount: Double,
        val total: Double,
        val paid: Double,
        val paymentMethod: String,
        val isUpdate: Boolean,
        val stockWarnings: List<String> = emptyList(),
        // NEW (Split Payment): the (method, amount) breakdown actually saved —
        // empty for a normal single-method sale, 2+ entries for a split-tender
        // one. Lets the Activity/Bill Preview show "Cash Rs300 + Bank Rs200"
        // instead of just the combined paymentMethod label.
        val payments: List<Pair<String, Double>> = emptyList()
    ) : SaveSaleResult()
    object EmptyItems : SaveSaleResult()
    object CustomerRequiredForDue : SaveSaleResult()
    data class StockIssue(val message: String) : SaveSaleResult()
    // NEW (Improvement Pack P6): mirrors StockIssue — same shape, distinct case
    // so the Activity/ViewModel can tell a stock problem apart from a duplicate
    // invoice if it ever wants to react differently (e.g. regenerate + retry).
    data class DuplicateInvoice(val message: String) : SaveSaleResult()
    // NEW (Improvement Pack P6): a line with qty <= 0 or a negative rate —
    // checked before the bill is even sent to the repository, since a bad
    // qty/rate corrupts subtotal/stock math no matter how it got into `lines`.
    data class InvalidLine(val message: String) : SaveSaleResult()
    // NEW (10/10 Priority #7 — Credit Limit + Due Management): this credit sale
    // would push the customer's outstanding balance past their configured
    // Customer.creditLimit. Not auto-rejected — the Activity shows this as a
    // confirm dialog ("Aage bhi save karen?") and, if the cashier confirms,
    // re-calls with allowOverride=true so the same bill saves normally (and
    // the override itself gets audit-logged — see SaveSaleUseCase below).
    data class CreditLimitExceeded(
        val customerName: String,
        val creditLimit: Double,
        val projectedBalance: Double
    ) : SaveSaleResult()
}

/** Result of a Quick Sale (single-item, no draft workflow). */
sealed class QuickSaleResult {
    data class Success(val invoice: String, val isCredit: Boolean) : QuickSaleResult()
    data class StockIssue(val message: String) : QuickSaleResult()
    data class InvalidQty(val message: String) : QuickSaleResult()
    // NEW (Improvement Pack P6): see SaveSaleResult.DuplicateInvoice.
    data class DuplicateInvoice(val message: String) : QuickSaleResult()
    // NEW (10/10 Priority #7): see SaveSaleResult.CreditLimitExceeded.
    data class CreditLimitExceeded(
        val customerName: String,
        val creditLimit: Double,
        val projectedBalance: Double
    ) : QuickSaleResult()
}

class ObserveCustomersForSaleUseCase(private val repository: SaleRepository) {
    operator fun invoke(): Flow<List<Customer>> = repository.observeCustomers()
}

class ObserveProductsForSaleUseCase(private val repository: SaleRepository) {
    operator fun invoke(): Flow<List<Product>> = repository.observeProducts()
}

class LoadFirmNameForSaleUseCase(private val repository: SaleRepository) {
    suspend operator fun invoke(): String? = repository.firmName()
}

class LoadSaleForEditUseCase(private val repository: SaleRepository) {
    suspend operator fun invoke(invoice: String): SaleForEdit? {
        val sale = repository.findSale(invoice) ?: return null
        val items = repository.itemsForInvoice(invoice)
        val customers = repository.customersSnapshot()
        val customerName = sale.customerId?.let { id -> customers.find { it.id == id }?.name } ?: ""
        val products = repository.productsSnapshot()
        val lines = items.map { si ->
            val product = products.find { it.barcode == si.barcode }
            SaleLine(
                barcode = si.barcode,
                itemName = si.product,
                qty = si.qty.toDouble(),
                unit = si.unit.ifBlank { product?.unit ?: "" },
                unitPrice = si.unitPrice,
                cost = si.cost,
                amount = si.amount,
                mainUnit = product?.unit ?: "",
                secondaryUnit = product?.secondaryUnit ?: "",
                secondaryUnitQty = product?.secondaryUnitQty ?: 0.0,
                tertiaryUnit = product?.tertiaryUnit ?: "",
                tertiaryUnitQty = product?.tertiaryUnitQty ?: 0.0
            )
        }
        // NEW (Split Payment): only worth showing as a "split" when there were
        // actually 2+ methods used — a single-entry list is exactly the normal
        // single-method case and the screen already handles that via
        // sale.paymentMethod/sale.paid, so no need to pre-open the dialog for it.
        val payments = repository.paymentsForInvoice(invoice)
        return SaleForEdit(
            sale = sale,
            items = items,
            customerName = customerName,
            lines = lines,
            payments = if (payments.size >= 2) payments else emptyList()
        )
    }
}

/** Validates + saves a new or edited sale — the discount/total/paid/due math
 * comes from the same [DiscountCalculator] used by the live on-screen preview
 * (recomputeAmounts/refreshDue in SaleActivity), so the preview and the saved
 * bill can never disagree. */
class SaveSaleUseCase(private val repository: SaleRepository) {
    suspend operator fun invoke(
        editInvoice: String?,
        enteredCustomerName: String,
        knownCustomers: List<Customer>,
        saleTypeLabel: String,
        lines: List<SaleLine>,
        discountInput: Double,
        paidInput: Double,
        paymentMethodLabel: String,
        saleDateMillis: Long,
        original: Sale?,
        originalItems: List<SaleItem>,
        // NEW (10/10 Priority #7): false on the first attempt — if the bill would
        // push the customer over their credit limit, this call returns
        // CreditLimitExceeded instead of saving. The Activity shows a confirm
        // dialog and, only if the cashier explicitly confirms, calls again with
        // allowOverride=true to actually save it.
        allowOverride: Boolean = false,
        // NEW (Split Payment / multiple payment methods): (method, amount) pairs
        // when the cashier split the bill across more than one payment method at
        // checkout. Empty (the default) means "single method" — paidInput +
        // paymentMethodLabel are used exactly as before this feature existed.
        // When non-empty, this list is the source of truth for how much was
        // actually paid (its sum), overriding paidInput — the Sale screen keeps
        // paidInput in sync with the split total, but computing it here too means
        // a stale paidInput can never silently disagree with the real split.
        payments: List<Pair<String, Double>> = emptyList()
    ): SaveSaleResult {
        if (lines.isEmpty()) return SaveSaleResult.EmptyItems

        // FIX (Improvement Pack P6): reject qty <= 0 or a negative rate on any
        // line before it can reach the subtotal/stock-decrement math below —
        // neither the repository nor the on-screen cart checked this before.
        for (line in lines) {
            if (line.qty <= 0.0) {
                return SaveSaleResult.InvalidLine("\"${line.itemName}\" ki qty 0 se zyada honi chahiye")
            }
            if (line.unitPrice < 0.0) {
                return SaveSaleResult.InvalidLine("\"${line.itemName}\" ka rate negative nahi ho sakta")
            }
        }

        val cleanPayments = payments.filter { it.second > 0.009 }
        // NEW (Split Payment): the split rows' sum is the real paid amount
        // whenever a split is in play — paidInput is trusted only when there's
        // no split (cleanPayments empty), matching the pre-split-payment behavior.
        val effectivePaidInput = if (cleanPayments.isNotEmpty()) cleanPayments.sumOf { it.second } else paidInput
        val subtotal = lines.sumOf { it.amount }
        val totals = DiscountCalculator.compute(subtotal, discountInput, effectivePaidInput)
        val enteredCustomer = enteredCustomerName.trim()

        if (totals.due > 0.009 && enteredCustomer.isEmpty()) return SaveSaleResult.CustomerRequiredForDue

        val method = when {
            totals.paid <= 0.009 -> "credit"
            // NEW (Split Payment): a combined label like "Cash + Bank" for the
            // Sale row's paymentMethod column — distinct methods only (paying
            // Cash twice in two rows still shows as plain "Cash"), same order
            // the cashier entered them in.
            cleanPayments.size >= 2 -> cleanPayments.map { it.first }.distinct().joinToString(" + ")
            cleanPayments.size == 1 -> cleanPayments[0].first
            else -> paymentMethodLabel
        }
        val existingCustomer = knownCustomers.find { it.name.equals(enteredCustomer, ignoreCase = true) }

        // NEW (10/10 Priority #7 — Credit Limit + Due Management): only meaningful
        // for a KNOWN customer with a limit actually configured (0 = "no limit
        // set", the Customer.creditLimit default, so it never blocks the common
        // case of a customer nobody has bothered to set a limit for). On an edit,
        // this bill's OWN previous outstanding amount is subtracted back out
        // first, so re-saving an unchanged (or reduced) credit bill for the same
        // customer never trips the check on its own — only a bill that GROWS
        // their outstanding balance past the limit does.
        if (existingCustomer != null && existingCustomer.creditLimit > 0.0 && !allowOverride) {
            val originalOutstanding =
                if (original != null && original.customerId == existingCustomer.id) original.total - original.paid else 0.0
            val projectedBalance = existingCustomer.balance - originalOutstanding + totals.due
            if (projectedBalance > existingCustomer.creditLimit + 0.009) {
                return SaveSaleResult.CreditLimitExceeded(
                    customerName = existingCustomer.name,
                    creditLimit = existingCustomer.creditLimit,
                    projectedBalance = projectedBalance
                )
            }
        }
        val saleType = if (saleTypeLabel == "Wholesale") "wholesale" else "retail"
        val invoice = editInvoice ?: run {
            // FIX (Improvement Pack P2): was mmYY + timestamp-tail alone — two devices
            // saving a sale in the same millisecond (or with any clock skew between
            // them) could generate the exact identical invoice string, and since
            // `invoice` is the sales table's primary key with REPLACE-on-conflict sync
            // semantics, one sale would silently overwrite the other. Suffixing the
            // same per-install DeviceTag already used by PurchaseRepository.genBillNo()
            // makes it impossible for two devices to collide, matching that
            // already-established, already-proven-safe pattern.
            val mmYY = SimpleDateFormat("MMyy", Locale.getDefault()).format(Date(saleDateMillis))
            mmYY + System.currentTimeMillis().toString().takeLast(8) + "-" + DeviceTag.current
        }

        return try {
            val result = repository.saveSale(
                invoice = invoice,
                enteredCustomerName = enteredCustomer,
                existingCustomer = existingCustomer,
                saleType = saleType,
                method = method,
                saleDateMillis = saleDateMillis,
                subtotal = totals.subtotal,
                discount = totals.discount,
                total = totals.total,
                paid = totals.paid,
                lines = lines,
                original = original,
                originalItems = originalItems,
                payments = cleanPayments
            )
            SaveSaleResult.Success(
                invoice = invoice,
                customer = result.customer,
                customerNameEntered = enteredCustomer,
                subtotal = totals.subtotal,
                discount = totals.discount,
                total = totals.total,
                paid = totals.paid,
                paymentMethod = method,
                isUpdate = original != null,
                stockWarnings = result.stockWarnings,
                payments = cleanPayments
            )
        } catch (e: StockUnavailableException) {
            SaveSaleResult.StockIssue(e.message ?: "")
        } catch (e: DuplicateInvoiceException) {
            SaveSaleResult.DuplicateInvoice(e.message ?: "")
        }
    }
}

class SaveQuickSaleUseCase(private val repository: SaleRepository) {
    suspend operator fun invoke(
        product: Product,
        qty: Double,
        price: Double,
        unit: String,
        customerName: String,
        // NEW (10/10 Priority #7): see SaveSaleUseCase.allowOverride's comment —
        // identical role for the Quick Sale dialog.
        allowOverride: Boolean = false
    ): QuickSaleResult {
        // FIX (Improvement Pack P6): same qty>0/rate>=0 guard as SaveSaleUseCase
        // — reuses InvalidQty since the Activity/ViewModel already Toast its
        // message for this screen.
        if (qty <= 0.0) return QuickSaleResult.InvalidQty("Qty 0 se zyada honi chahiye")
        if (price < 0.0) return QuickSaleResult.InvalidQty("Rate negative nahi ho sakta")

        // NEW (10/10 Priority #7 — Credit Limit + Due Management): a Quick Sale
        // is 100% credit whenever a customer name is entered (see
        // RoomSaleRepository.saveQuickSale's `isCredit` flag) — the whole amount
        // becomes their outstanding balance, so check it the same way
        // SaveSaleUseCase does for the main flow.
        val trimmedName = customerName.trim()
        if (trimmedName.isNotEmpty() && !allowOverride) {
            val existingCustomer = repository.customersSnapshot()
                .find { it.name.equals(trimmedName, ignoreCase = true) }
            if (existingCustomer != null && existingCustomer.creditLimit > 0.0) {
                val projectedBalance = existingCustomer.balance + (qty * price)
                if (projectedBalance > existingCustomer.creditLimit + 0.009) {
                    return QuickSaleResult.CreditLimitExceeded(
                        customerName = existingCustomer.name,
                        creditLimit = existingCustomer.creditLimit,
                        projectedBalance = projectedBalance
                    )
                }
            }
        }

        return try {
            val result = repository.saveQuickSale(product, qty, price, unit, customerName.trim())
            QuickSaleResult.Success(result.invoice, result.isCredit)
        } catch (e: StockUnavailableException) {
            QuickSaleResult.StockIssue(e.message ?: "")
        } catch (e: InvalidQuantityException) {
            QuickSaleResult.InvalidQty(e.message ?: "")
        } catch (e: DuplicateInvoiceException) {
            QuickSaleResult.DuplicateInvoice(e.message ?: "")
        }
    }
}

class DeleteSaleUseCase(private val repository: SaleRepository) {
    suspend operator fun invoke(invoice: String, original: Sale?, originalItems: List<SaleItem>) {
        repository.deleteSale(invoice, original, originalItems)
    }
}

class CreateCustomerUseCase(private val repository: SaleRepository) {
    suspend operator fun invoke(name: String, phone: String = "", creditLimit: Double = 0.0, openingBalance: Double = 0.0): Customer? {
        val trimmed = name.trim()
        if (trimmed.isEmpty()) return null
        return repository.createCustomer(trimmed, phone.trim(), creditLimit, openingBalance)
    }
}

/** Names of the best-selling products over the trailing 30 days, used to
 * pre-populate the Quick Sale dialog's shortcut row. */
class TopSellingProductNamesUseCase(private val repository: SaleRepository) {
    suspend operator fun invoke(): List<String> {
        val now = System.currentTimeMillis()
        val since = now - 30L * 24 * 60 * 60 * 1000
        return repository.topProductNames(since, now)
    }
}

class HoldBillUseCase(private val repository: SaleRepository) {
    suspend operator fun invoke(payload: String) {
        val holdId = "HOLD" + System.currentTimeMillis().toString()
        repository.holdBill(holdId, payload)
    }
}

class HeldBillsUseCase(private val repository: SaleRepository) {
    suspend operator fun invoke(): List<HeldBill> = repository.heldBills()
}

class DeleteHeldBillUseCase(private val repository: SaleRepository) {
    suspend operator fun invoke(bill: HeldBill) = repository.deleteHeldBill(bill)
}
