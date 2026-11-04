import 'package:flutter_test/flutter_test.dart';
import 'package:ah_developer_kiryana_store/sync/sync_queue_helper.dart';
import 'package:ah_developer_kiryana_store/utils/bill_doc.dart';
import 'package:ah_developer_kiryana_store/utils/receipt_lines.dart';

BillDoc _doc({String owner = '', bool purchase = false}) => BillDoc(
      isPurchase: purchase,
      ref: 'INV1',
      date: DateTime(2026, 11, 4, 10, 0),
      items: const [BillItem(name: 'Rice', qty: 1, unit: 'kg', rate: 100, amount: 100)],
      subtotal: 100,
      discount: 0,
      total: 100,
      paid: 100,
      shopName: 'Test Store',
      shopOwner: owner,
      shopPhone: '0300-1234567',
    );

void main() {
  const owner = 'محمد عاصم';

  test('sale text: shop name, owner name, phone in that order', () {
    final lines = _doc(owner: owner).toText().split('\n');
    final n = lines.indexWhere((l) => l.contains('Test Store'));
    expect(lines[n + 1].trim(), owner);
    expect(lines[n + 2].trim(), '0300-1234567');
  });

  test('purchase text also shows the owner name', () {
    final t = _doc(owner: owner, purchase: true).toText();
    expect(t, contains(owner));
  });

  test('no owner name = no extra line (old bills unchanged)', () {
    final lines = _doc().toText().split('\n');
    final n = lines.indexWhere((l) => l.contains('Test Store'));
    expect(lines[n + 1].trim(), '0300-1234567');
  });

  test('receipt header (printer / PDF): name, owner, phone', () {
    final h = receiptHeader(_doc(owner: owner)).whereType<RlCenter>().map((e) => e.text).toList();
    expect(h.sublist(0, 3), ['Test Store', owner, '0300-1234567']);
    final none = receiptHeader(_doc()).whereType<RlCenter>().map((e) => e.text).toList();
    expect(none.sublist(0, 2), ['Test Store', '0300-1234567']);
  });

  test('copyWith carries the owner name', () {
    expect(_doc().copyWith(shopOwner: owner).shopOwner, owner);
    expect(_doc(owner: owner).copyWith(shopPhone: '1').shopOwner, owner);
  });

  test('shop_owner is a synced setting', () {
    expect(SyncQueueHelper.isSyncedAppSettingKey('shop_owner'), isTrue);
  });
}
