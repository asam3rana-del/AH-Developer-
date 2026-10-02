import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/db/balance_sheet_repository.dart';
import 'package:ah_developer_kiryana_store/db/party_reports_repository.dart';
import 'package:ah_developer_kiryana_store/db/party_transaction_repository.dart';

void main() {
  test('splitClosings: positive and negative totals', () {
    final r = splitClosings([100, -40, 0, 25.5, -10]);
    expect(r.positive, 125.5);
    expect(r.negative, 50);
  });

  test('ledger: payment linked to a MISSING bill still counts (same rule as trueBalance)', () {
    final lines = buildLedgerLines(
      bills: [ReportBill(id: 'S1', total: 100, paid: 0, createdAt: 1)],
      payments: [
        const ReportPayment(reference: 'manual-1', billReference: 'GONE', amount: 30, createdAt: 2),
        const ReportPayment(reference: 'manual-2', billReference: 'S1', amount: 20, createdAt: 3),
      ],
    );
    expect(lines.length, 2); // S1 bill + GONE payment; S1-linked payment skipped
    expect(runLedger(0, lines).closing, 70);
  });

  test('party stats: knownBillIds makes orphan-linked payment count', () {
    final st = computePartyTxStats(
      bills: [(total: 100.0, paid: 0.0, status: 'active', createdAt: 1, dueDate: 0)],
      standalone: [
        (amount: 30.0, billReference: 'GONE'),
        (amount: 20.0, billReference: 'S1'),
      ],
      opening: 0,
      knownBillIds: {'S1'},
    );
    expect(st.running, 70);
  });
}
