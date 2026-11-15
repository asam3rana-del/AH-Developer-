import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/db/sale_repository.dart';
import 'package:ah_developer_kiryana_store/models/product.dart';

// Kotlin `SaveSaleUseCaseTest` + `SaveQuickSaleUseCaseTest` ke validation cases.
// Ye sab checks SaleRepository mein DB kholne se PEHLE hote hain, is liye yahan
// database ki zaroorat nahi — galat input par ArgumentError aati hai aur kuch nahi likha jata.

SaleLine _line(String name, double qty, double price) => SaleLine(
      itemName: name,
      barcode: 'b-$name',
      qty: qty,
      unit: 'kg',
      unitPrice: price,
      cost: 0,
      amount: qty * price,
    );

Matcher _argError([String? contains]) {
  final m = isA<ArgumentError>();
  return contains == null ? throwsA(m) : throwsA(m.having((e) => e.message.toString(), 'message', _contains(contains)));
}

Matcher _contains(String s) => predicate<String>((v) => v.contains(s), 'contains "$s"');

Future<String> _save(
  List<SaleLine> lines, {
  String customer = '',
  double discount = 0,
  double paid = 0,
}) =>
    SaleRepository.instance.saveSale(
      lines: lines,
      customerName: customer,
      discountInput: discount,
      paidInput: paid,
      saleType: 'retail',
      saleDateMillis: DateTime(2026, 10, 1).millisecondsSinceEpoch,
    );

void main() {
  final repo = SaleRepository.instance;

  group('saveSale validation', () {
    test('empty lines -> error, nothing saved', () async {
      await expectLater(_save([]), _argError('at least one item'));
    });

    test('due balance without a customer name -> customer required', () async {
      await expectLater(_save([_line('Rice', 2, 100)], paid: 50), _argError('Customer zaroori'));
    });

    test('nothing paid and no customer -> customer required', () async {
      await expectLater(_save([_line('Rice', 2, 100)]), _argError('Customer zaroori'));
    });

    test('whitespace-only customer counts as blank', () async {
      await expectLater(_save([_line('Rice', 1, 100)], customer: '   ', paid: 10), _argError('Customer zaroori'));
    });

    test('zero qty line is rejected', () async {
      await expectLater(_save([_line('Rice', 0, 100)], paid: 0), _argError('Rice'));
    });

    test('negative qty line is rejected', () async {
      await expectLater(_save([_line('Rice', -1, 100)]), _argError('Rice'));
    });

    test('negative rate line is rejected', () async {
      await expectLater(_save([_line('Rice', 1, -5)]), _argError('Rice'));
    });

    test('one bad line among several blocks the whole sale (and is named)', () async {
      await expectLater(
        _save([_line('Rice', 1, 100), _line('Sugar', 0, 90), _line('Tea', 1, 50)], customer: 'Ali'),
        _argError('Sugar'),
      );
    });
  });

  group('saveQuickSale validation', () {
    const rice = Product(barcode: 'b1', name: 'Rice', unit: 'kg');

    test('zero qty -> error', () async {
      await expectLater(
        repo.saveQuickSale(product: rice, qty: 0, price: 100, unit: 'kg', customerName: ''),
        _argError('Qty'),
      );
    });

    test('negative qty -> error', () async {
      await expectLater(
        repo.saveQuickSale(product: rice, qty: -2, price: 100, unit: 'kg', customerName: ''),
        _argError('Qty'),
      );
    });

    test('negative price -> error', () async {
      await expectLater(
        repo.saveQuickSale(product: rice, qty: 1, price: -1, unit: 'kg', customerName: 'Ali'),
        _argError('Rate'),
      );
    });
  });
}
