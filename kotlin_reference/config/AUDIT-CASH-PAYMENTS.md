# Cash & Payment audit — changes (Sep 19, 2026)

NOTE: written without a Kotlin compiler available — run `./gradlew assembleDebug testDebugUnitTest` first.
No Room schema change (only new @Query methods) => no migration / version bump. No Firestore rules change.

## Sync / duplicates
- SyncQueueHelper: payment/expense/cashTransaction entity ids keep an existing serverId (were re-stamped with
  this device's id => duplicate documents on edit / force-resync).
- ExpenseActivity + ZakatActivity: use enqueueExpense() (stamps serverId) — expenses no longer saved twice.
- SyncRepository + SyncQueueHelper.mergeOwnDuplicateExpenses(): auto-removes the local twin of already-duplicated
  expenses after each sync (local delete only; the twin shares the same Firestore document).
- Expense cash-out reference is device-unique (was "expense:<localId>", collided across devices).
- SyncApi: increment_stock / increment_balance pushes are now idempotent (transaction + appliedOps in the same doc).
- PartyTransactionActivity.deletePayment: queues a sync-delete for every row with the real serverId.

## Balances / party screens
- PartyTransactionActivity: bill-embedded "Purchase payment" rows hidden from the party list; Total Paid no longer
  double counts; item edit/delete balance math fixed when `paid` gets capped; whole-bill delete removes only outstanding.
- PartyReportsActivity: Ledger + Statement no longer double count embedded purchase payments.
- PartyRepository.recalculateBalances: ignores bill-linked payments (already in bill.paid); new dryRun flag.
- BalanceSheetActivity: data-check warnings (balance drift, negative cash/bank).

## Cash book
- RoomSaleRepository / RoomPurchaseRepository: editing a bill that has bill-linked payments no longer re-records them;
  purchase Payment row uses the purchase date.
- Bill return / delete now voids bill-linked payments (voidLinkedPayments) — refund entry on return.
- reconcilePaidAndCashRecords: dated reversal instead of shrinking the original day's cash row.
- DayBookActivity: linked payments no longer counted twice in Cash In/Out.
- CashActivity: Cash Out under an expense category creates a real Expense (+ linked cash entry); new
  "Non-expense (Withdrawal / Transfer)" category for plain cash movements; double-tap guard.
- ZakatActivity: Zakat payment now writes the cash/bank OUT entry and uses the chosen method.
- CashRegisterActivity: opening balance carries forward from the last CLOSED register; OPEN can't overwrite a
  register another device already opened/closed.
