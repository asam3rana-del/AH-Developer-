import 'package:flutter_test/flutter_test.dart';
import 'package:ah_developer_kiryana_store/db/daily_bills_repository.dart';
import 'package:ah_developer_kiryana_store/utils/slip_pdf_data.dart';

void main() {
  test('slipMoney / slipRate / slipQty formatting', () {
    expect(slipMoney(1234.4), 'Rs 1,234');
    expect(slipMoney(-1234.6), '-Rs 1,235');
    expect(slipRate(50), '50');
    expect(slipRate(12.5), '12.50');
    expect(slipQty(2), '2');
    expect(slipQty(1.25), '1.25');
    expect(slipQty(0.5), '0.5');
  });

  test('slipFileName keeps safe chars and appends timestamp', () {
    final n = slipFileName('Ali / Sons', DateTime(2026, 11, 4, 9, 5));
    expect(n, 'Ali_Sons_20261104_0905.pdf');
    expect(slipFileName('   ', DateTime(2026, 11, 4, 9, 5)), 'Slip_20261104_0905.pdf');
  });

  test('dailyBillSlipData: bills, payments and totals', () {
    final p = DailyParty(
      id: 1,
      name: 'Ali',
      previousBalance: 100,
      bills: const [
        DayBill(
          invoice: 'S1',
          time: 0,
          total: 200,
          paid: 50,
          items: [DayBillItem(product: 'Rice', qty: 2, unit: 'kg', unitPrice: 100, amount: 200)],
        ),
      ],
      payments: const [DayPayment(0, 30)],
      closingBalance: 220,
    );
    final d = dailyBillSlipData(p, DateTime(2026, 11, 4));
    expect(d.title, 'DAILY BILL');
    expect(d.partyName, 'Ali');
    expect(d.meta.first.value, '04-11-2026');
    expect(d.blocks.first.rows.first.sublist(1), ['2 kg', '100', 'Rs 200']);
    expect(d.blocks.first.lines.map((l) => l.label), ['Bill total', 'Paid']);
    expect(d.blocks[1].heading, 'Payments received');
    final last = d.blocks.last.lines;
    expect(last.last.label, "Today's balance");
    expect(last.last.value, 'Rs 220');
  });

  test('paymentSlipData: balance labels', () {
    String label(bool received, double bal) => paymentSlipData(
          received: received,
          partyName: 'A',
          amount: 10,
          date: DateTime(2026, 1, 1),
          balanceNow: bal,
        ).blocks.last.lines.first.label;
    expect(label(true, 50), 'Balance due');
    expect(label(true, -50), 'Advance with us');
    expect(label(false, 50), 'Balance payable');
    expect(label(false, -50), 'Advance with you');
    expect(label(true, 0.2), 'Balance now');
  });

  test('statementSlipData sorts entries by time', () {
    final d = statementSlipData(
      isCustomer: true,
      partyName: 'A',
      closing: -500,
      youGive: true,
      entries: const [SlipStatementEntry(2000, 'b'), SlipStatementEntry(1000, 'a')],
      now: DateTime(2026, 1, 1),
    );
    expect(d.blocks.first.rows.map((r) => r[1]), ['a', 'b']);
    expect(d.meta[1].value, 'Rs 500');
    expect(d.meta[2].value, "You'll Give");
  });
}
