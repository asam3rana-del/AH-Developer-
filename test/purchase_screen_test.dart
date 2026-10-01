import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/db/party_transaction_repository.dart' show purchaseItemSmallestQty;
import 'package:ah_developer_kiryana_store/db/purchase_history_repository.dart' show partialSmallestQty;
import 'package:ah_developer_kiryana_store/db/purchase_repository.dart';
import 'package:ah_developer_kiryana_store/models/product.dart';
import 'package:ah_developer_kiryana_store/models/purchase.dart';
import 'package:ah_developer_kiryana_store/services/purchase_hold_recall.dart';
import 'package:ah_developer_kiryana_store/utils/purchase_calc.dart';
import 'package:ah_developer_kiryana_store/utils/split_payment.dart';
import 'package:ah_developer_kiryana_store/utils/stock_touch_policy.dart';

// 1 Carton = 4 Dozen = 48 Pcs.
const _juice = Product(
  barcode: 'b3',
  name: 'Juice',
  unit: 'Carton',
  secondaryUnit: 'Dozen',
  secondaryUnitQty: 4,
  tertiaryUnit: 'Pcs',
  tertiaryUnitQty: 12,
  cost: 480,
  salePrice: 600,
  wholesalePrice: 540,
  stock: 480,
);

PurchaseLine _line(String barcode, double qty, String unit, double rate,
        {double retail = 0, double wholesale = 0}) =>
    PurchaseLine(
      itemName: barcode,
      barcode: barcode,
      qty: qty,
      unit: unit,
      rate: rate,
      amount: qty * rate,
      retailRate: retail,
      wholesaleRate: wholesale,
    );

PurchaseItem _item(String barcode, double qty, String unit, double rate,
        {double factor = 0, double retail = 0, double wholesale = 0, int? id}) =>
    PurchaseItem(
      id: id,
      billNo: 'PUR-1',
      barcode: barcode,
      qty: qty,
      unitCost: rate,
      amount: qty * rate,
      unit: unit,
      conversionFactor: factor,
      retailRate: retail,
      wholesaleRate: wholesale,
    );

void main() {
  group('purchaseMargin', () {
    test('sale ya purchase rate 0 => koi warning nahi', () {
      expect(purchaseMargin(salePriceMain: 0, purchaseRateMain: 50).level, MarginLevel.none);
      expect(purchaseMargin(salePriceMain: 100, purchaseRateMain: 0).level, MarginLevel.none);
    });

    test('margin <= 0 => loss', () {
      expect(purchaseMargin(salePriceMain: 100, purchaseRateMain: 100).level, MarginLevel.loss);
      expect(purchaseMargin(salePriceMain: 100, purchaseRateMain: 120).level, MarginLevel.loss);
    });

    test('margin < 10% => low, warna ok', () {
      final low = purchaseMargin(salePriceMain: 100, purchaseRateMain: 95);
      expect(low.level, MarginLevel.low);
      expect(low.margin, 5);
      expect(low.marginPct, closeTo(5, 1e-9));
      expect(purchaseMargin(salePriceMain: 100, purchaseRateMain: 70).level, MarginLevel.ok);
      // theek 10% = low nahi
      expect(purchaseMargin(salePriceMain: 100, purchaseRateMain: 90).level, MarginLevel.ok);
    });
  });

  group('text helpers', () {
    test('rateText / qtyText', () {
      expect(rateText(0), '');
      expect(rateText(12), '12.00');
      expect(qtyText(3), '3');
      expect(qtyText(2.5), '2.5');
    });
  });

  group('isDuplicatePurchase', () {
    final day = DateTime(2026, 9, 29, 10, 30);
    bool dup({String s = 'Ali Traders', double t = 1000, DateTime? d}) => isDuplicatePurchase(
          candidateSupplier: 'ali traders',
          candidateTotal: 1000,
          candidateDate: day,
          wantedSupplier: s,
          wantedTotal: t,
          wantedDate: d ?? DateTime(2026, 9, 29, 23, 59),
        );

    test('same supplier (case-insensitive) + total + din => duplicate', () => expect(dup(), isTrue));
    test('doosra supplier', () => expect(dup(s: 'Bilal'), isFalse));
    test('total farq', () => expect(dup(t: 1001), isFalse));
    test('doosra din', () => expect(dup(d: DateTime(2026, 9, 30)), isFalse));
  });

  group('validatePurchaseLines', () {
    test('khali bill', () => expect(validatePurchaseLines(const []), isNotNull));
    test('qty 0', () => expect(validatePurchaseLines([_line('a', 0, 'pcs', 10)]), contains('qty')));
    test('negative rate', () => expect(validatePurchaseLines([_line('a', 1, 'pcs', -1)]), contains('negative')));
    test('sab theek', () => expect(validatePurchaseLines([_line('a', 1, 'pcs', 10)]), isNull));
    test('negative qty', () => expect(validatePurchaseLines([_line('a', -1, 'pcs', 10)]), isNotNull));
    test('ek kharab line baaki theek lines ke saath poora bill rokti hai', () {
      expect(
        validatePurchaseLines([_line('a', 1, 'pcs', 10), _line('b', 0, 'pcs', 10), _line('c', 2, 'pcs', 5)]),
        isNotNull,
      );
    });
  });

  group('planPurchaseCash', () {
    test('single method, paid total se upar nahi', () {
      final p = planPurchaseCash(grandTotal: 1000, amountPaid: 2000, singleMethod: 'Bank', payments: const []);
      expect(p.paid, 1000);
      expect(p.cashRows, [const PayEntry('Bank', 1000)]);
    });

    test('kuch paid nahi => credit, cash row nahi', () {
      final p = planPurchaseCash(grandTotal: 1000, amountPaid: 0, singleMethod: 'Cash', payments: const []);
      expect(p.paid, 0);
      expect(p.cashRows, isEmpty);
    });

    test('split rows paid ban jati hain, amountPaid ignore', () {
      final p = planPurchaseCash(
        grandTotal: 1000,
        amountPaid: 999,
        singleMethod: 'Cash',
        payments: const [PayEntry('Cash', 300), PayEntry('Bank', 200)],
      );
      expect(p.paid, 500);
      expect(p.cashRows, [const PayEntry('Cash', 300), const PayEntry('Bank', 200)]);
    });

    test('split rows total se zyada => aakhri rows se kat', () {
      final p = planPurchaseCash(
        grandTotal: 1000,
        amountPaid: 0,
        singleMethod: 'Cash',
        payments: const [PayEntry('Cash', 800), PayEntry('Bank', 500)],
      );
      expect(p.paid, 1000);
      expect(p.cashRows, [const PayEntry('Cash', 800), const PayEntry('Bank', 200)]);
    });

    test('linked payments ki cash dobara nahi ginti (pehli rows se kat)', () {
      final p = planPurchaseCash(
        grandTotal: 1000,
        amountPaid: 0,
        singleMethod: 'Cash',
        payments: const [PayEntry('Cash', 800), PayEntry('Bank', 500)],
        linkedPaid: 300,
      );
      expect(p.paid, 1000); // paid mein linked shamil
      expect(p.cashRows, [const PayEntry('Cash', 500), const PayEntry('Bank', 200)]);
    });
  });

  group('Hold / Recall encode-decode', () {
    test('round trip', () {
      final d = PurchaseDraft(
        supplier: 'Ali Traders',
        supplierInvoiceNo: 'INV-77',
        paidText: '500',
        dateMillis: 1780000000000,
        lines: [
          _line('b3', 2, 'Carton', 600, retail: 700, wholesale: 650),
          const PurchaseLine(itemName: 'Free text', barcode: null, qty: 1.5, unit: 'kg', rate: 40, amount: 60),
        ],
      );
      final back = decodePurchaseHold(encodePurchaseHold(d));
      expect(back.supplier, 'Ali Traders');
      expect(back.supplierInvoiceNo, 'INV-77');
      expect(back.paidText, '500');
      expect(back.dateMillis, 1780000000000);
      expect(back.lines.length, 2);
      expect(back.lines[0].barcode, 'b3');
      expect(back.lines[0].qty, 2);
      expect(back.lines[0].retailRate, 700);
      expect(back.lines[0].wholesaleRate, 650);
      expect(back.lines[1].barcode, isNull);
      expect(back.lines[1].itemName, 'Free text');
      expect(back.lines[1].amount, 60);
    });

    test('narm decode: chhoti rows skip, gayab numbers 0', () {
      final payload = 'S\u0001I\u0001\u0001\u0004a\u0003nm\u0003x\u0002b\u0003Name\u0003bad\u0003kg\u0003oops\u00035';
      final d = decodePurchaseHold(payload);
      // pehli row mein 3 field (< 6) => skip; doosri mein qty/rate ghalat => 0
      expect(d.lines.length, 1);
      expect(d.lines[0].qty, 0);
      expect(d.lines[0].rate, 0);
      expect(d.lines[0].amount, 5);
      expect(d.dateMillis, 0);
    });

    test('hasContent', () {
      expect(const PurchaseDraft().hasContent, isFalse);
      expect(const PurchaseDraft(supplier: 'x').hasContent, isTrue);
      expect(PurchaseDraft(lines: [_line('a', 1, 'pcs', 1)]).hasContent, isTrue);
    });
  });

  group('purchaseEditDiff', () {
    test('bilkul na-badli line => na reverse na dobara add; factor carry', () {
      final orig = [_item('b3', 2, 'Carton', 500, factor: 48), _item('b4', 1, 'Dozen', 100, factor: 12)];
      final diff = purchaseEditDiff([_line('b3', 2, 'Carton', 500), _line('b4', 3, 'Dozen', 100)], orig);
      expect(diff.changedLineIndices, {1});
      expect(diff.itemsToReverse.map((e) => e.barcode), ['b4']);
      expect(diff.unchangedOriginalByIndex[0]!.conversionFactor, 48);
      expect(diff.unchangedOriginalByIndex.containsKey(1), isFalse);
    });

    test('rate ya unit badle to changed', () {
      final orig = [_item('b3', 2, 'Carton', 500, factor: 48)];
      expect(purchaseEditDiff([_line('b3', 2, 'Carton', 510)], orig).changedLineIndices, {0});
      expect(purchaseEditDiff([_line('b3', 2, 'Dozen', 500)], orig).changedLineIndices, {0});
    });

    test('retail / wholesale rate badle to line changed', () {
      final orig = [_item('b3', 2, 'Carton', 500, factor: 48, retail: 600)];
      expect(purchaseEditDiff([_line('b3', 2, 'Carton', 500, retail: 600)], orig).changedLineIndices, isEmpty);
      expect(purchaseEditDiff([_line('b3', 2, 'Carton', 500, retail: 650)], orig).changedLineIndices, {0});
    });

    test('do bilkul same lines, original mein sirf ek => doosri changed', () {
      final orig = [_item('b3', 1, 'Carton', 500, factor: 48)];
      final diff = purchaseEditDiff([_line('b3', 1, 'Carton', 500), _line('b3', 1, 'Carton', 500)], orig);
      expect(diff.changedLineIndices, {1});
      expect(diff.itemsToReverse, isEmpty);
    });

    test('line hata di => wahi reverse hoti hai', () {
      final orig = [_item('b3', 2, 'Carton', 500, factor: 48), _item('b4', 1, 'Dozen', 100, factor: 12)];
      final diff = purchaseEditDiff([_line('b3', 2, 'Carton', 500)], orig);
      expect(diff.changedLineIndices, isEmpty);
      expect(diff.itemsToReverse.map((e) => e.barcode), ['b4']);
    });
  });

  group('frozen conversionFactor', () {
    test('factor > 0 => product ki maujuda ladder nahi', () {
      // Bill par 1 Dozen = 10 pcs likha tha (ladder tab alag thi); ab ladder 12 hai.
      final it = _item('b3', 2, 'Dozen', 100, factor: 10);
      expect(purchaseItemSmallestQty(it, _juice), 20);
    });

    test('factor 0 (purani row) => maujuda ladder; product nahi => qty', () {
      final it = _item('b3', 2, 'Dozen', 100);
      expect(purchaseItemSmallestQty(it, _juice), 24);
      expect(purchaseItemSmallestQty(it, null), 2);
    });

    test('partial return bhi frozen factor istemal karta hai', () {
      final it = _item('b3', 4, 'Dozen', 100, factor: 10);
      expect(partialSmallestQty(it, _juice, 1.5), 15);
      expect(partialSmallestQty(_item('b3', 4, 'Dozen', 100), _juice, 1.5), 18);
    });
  });

  group('models', () {
    test('PurchaseItem toMap / fromMap', () {
      final it = _item('b3', 2, 'Carton', 500, factor: 48, retail: 600, wholesale: 550, id: 7);
      final back = PurchaseItem.fromMap(it.toMap());
      expect(back.id, 7);
      expect(back.conversionFactor, 48);
      expect(back.retailRate, 600);
      expect(back.wholesaleRate, 550);
      expect(back.itemName, '');
    });

    test('purani row (naye columns nahi) => defaults', () {
      final back = PurchaseItem.fromMap({
        'id': 1,
        'billNo': 'PUR-1',
        'barcode': 'b3',
        'qty': 2,
        'unitCost': 5,
        'amount': 10,
        'unit': 'pcs',
      });
      expect(back.conversionFactor, 0);
      expect(back.itemName, '');
      expect(back.retailRate, 0);
    });

    test('Purchase supplierInvoiceNo round trip + default', () {
      const p = Purchase(billNo: 'PUR-1', total: 10, paid: 0, createdAt: 1, supplierInvoiceNo: 'INV-9');
      expect(Purchase.fromMap(p.toMap()).supplierInvoiceNo, 'INV-9');
      final old = Purchase.fromMap({'billNo': 'PUR-2', 'total': 1, 'paid': 0, 'createdAt': 1});
      expect(old.supplierInvoiceNo, '');
    });
  });
}
