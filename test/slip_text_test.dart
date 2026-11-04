import 'package:flutter_test/flutter_test.dart';
import 'package:ah_developer_kiryana_store/utils/slip_text.dart';

void main() {
  group('slip header', () {
    test('centerText pads to the middle of 32 columns', () {
      expect(centerText('ABCD'), '${' ' * 14}ABCD');
      expect(centerText('x' * 40), 'x' * 40);
    });

    test('slipHeaderBlock: name and phone centered inside a monospace block', () {
      final h = slipHeaderBlock(shopName: 'AH Store', shopPhone: '03001234567');
      expect(h.startsWith('```\n'), isTrue);
      expect(h.endsWith('\n```\n'), isTrue);
      expect(h.contains('${' ' * 12}AH Store'), isTrue);
      expect(h.contains('03001234567'), isTrue);
    });

    test('slipHeaderBlock: both empty gives empty string, phone alone still works', () {
      expect(slipHeaderBlock(shopName: '', shopPhone: ''), '');
      expect(slipHeaderBlock(shopName: '', shopPhone: '0300').contains('0300'), isTrue);
    });

    test('wrapBillHeaderForWhatsApp wraps only the lines before the first rule', () {
      const bill = '    Shop\n   0300\n--------------------------------\nInvoice: 1\n';
      final out = wrapBillHeaderForWhatsApp(bill);
      expect(out, '```\n    Shop\n   0300\n```\n--------------------------------\nInvoice: 1\n');
    });

    test('wrapBillHeaderForWhatsApp leaves text without a header untouched', () {
      expect(wrapBillHeaderForWhatsApp('--------\nabc'), '--------\nabc');
      expect(wrapBillHeaderForWhatsApp('no rule here'), 'no rule here');
    });
  });

  group('buildPaymentSlipText', () {
    final date = DateTime(2026, 11, 4, 15, 30);

    test('Payment Received: header, customer, amount, balance due', () {
      final t = buildPaymentSlipText(
        received: true,
        shopName: 'AH Store',
        shopPhone: '0300',
        partyName: 'Ali',
        amount: 5000,
        date: date,
        method: 'cash',
        billRef: 'INV-7',
        slipNo: 'PAY-1',
        balanceNow: 12000,
      );
      expect(t.startsWith('```\n'), isTrue);
      expect(t.contains('PAYMENT RECEIVED'), isTrue);
      expect(t.contains('Customer: Ali'), isTrue);
      expect(t.contains('Amount: Rs 5000'), isTrue);
      expect(t.contains('Method: CASH'), isTrue);
      expect(t.contains('Against Bill: INV-7'), isTrue);
      expect(t.contains('Slip: PAY-1'), isTrue);
      expect(t.contains('Balance due: Rs 12000'), isTrue);
    });

    test('Payment Made: supplier wording, payable and advance', () {
      final due = buildPaymentSlipText(
          received: false, shopName: 'S', partyName: 'Sup', amount: 100, date: date, balanceNow: 900);
      expect(due.contains('PAYMENT MADE'), isTrue);
      expect(due.contains('Supplier: Sup'), isTrue);
      expect(due.contains('Balance payable: Rs 900'), isTrue);
      final adv = buildPaymentSlipText(
          received: false, shopName: 'S', partyName: 'Sup', amount: 100, date: date, balanceNow: -250);
      expect(adv.contains('Advance with you: Rs 250'), isTrue);
    });

    test('no balance line when balanceNow is null; zero balance says Rs 0', () {
      final none = buildPaymentSlipText(received: true, shopName: 'S', partyName: 'A', amount: 1, date: date);
      expect(none.contains('Balance'), isFalse);
      final zero = buildPaymentSlipText(
          received: true, shopName: 'S', partyName: 'A', amount: 1, date: date, balanceNow: 0.2);
      expect(zero.contains('Balance now: Rs 0'), isTrue);
    });
  });
}
