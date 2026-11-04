import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/utils/bill_doc.dart';
import 'package:ah_developer_kiryana_store/utils/slip_pdf_data.dart';

void main() {
  final doc = BillDoc(
    isPurchase: false,
    ref: 'INV-1',
    date: DateTime(2026, 11, 4),
    items: const [BillItem(name: 'Chawal', qty: 2, unit: 'kg', rate: 150, amount: 300)],
    subtotal: 300,
    discount: 20,
    total: 280,
    paid: 100,
    partyName: 'Ali',
  );

  test('sale bill PDF data: title, rows, due and net balance', () {
    final d = billDocSlipData(doc, netBalance: 500);
    expect(d.title, 'SALE BILL');
    expect(d.partyName, 'Ali');
    final b = d.blocks.single;
    expect(b.rows.single, ['Chawal', '2 kg', '150', 'Rs 300']);
    final labels = b.lines.map((l) => l.label).toList();
    expect(labels, containsAll(['Discount', 'Balance Due', 'Prev Balance', 'Net Balance']));
    expect(b.lines.firstWhere((l) => l.label == 'Prev Balance').value, 'Rs 320');
  });

  test('walk-in sale without party and no net balance', () {
    final d = billDocSlipData(BillDoc(
      isPurchase: false, ref: 'INV-2', date: DateTime(2026, 11, 4), items: const [],
      subtotal: 0, discount: 0, total: 0, paid: 0,
    ));
    expect(d.partyName, 'Walk-in');
    expect(d.blocks.single.lines.any((l) => l.label == 'Net Balance'), isFalse);
  });
}
