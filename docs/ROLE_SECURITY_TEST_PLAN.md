# Role security test plan

Use Firebase Emulator Suite and test accounts with server-issued custom claims. These are acceptance tests, not claims that tests have already run.

1. Anonymous/no-claim/inactive/unknown-role tokens must be denied for every synced collection.
2. Admin and Manager can access only documents whose `branchId` equals their token claim.
3. Manager cannot delete; Admin can delete only in own branch.
4. Cashier cannot read purchases, suppliers, expenses, cash register, worker/payroll, rents, utilities, zakat, or app settings.
5. Cashier direct writes are denied until callable transaction endpoints are implemented.
6. All client writes to `users` and `branch_members` are denied.
7. Attempt branchId mutation on create/update and verify denial.
8. Verify each legitimate business operation through its trusted endpoint: duplicate idempotency key, stale request, negative/invalid quantity, unauthorized price override, wrong branch, inactive staff, and simultaneous devices.
9. Verify role downgrade/deactivation takes effect after token refresh/revocation strategy.
10. Run end-to-end sync and accounting reconciliation before enabling production traffic.
