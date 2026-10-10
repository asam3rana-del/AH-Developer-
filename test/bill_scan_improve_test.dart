import 'package:flutter_test/flutter_test.dart';
import 'package:ah_developer_kiryana_store/models/product.dart';
import 'package:ah_developer_kiryana_store/utils/bill_scan_match.dart';
import 'package:ah_developer_kiryana_store/utils/bill_scan_parser.dart';

void main() {
  group('rebuildRowsText', () {
    test('pieces on the same row are joined left to right, rows top to bottom', () {
      final t = rebuildRowsText(const [
        OcrBox('300', 400, 101, 440, 121),
        OcrBox('Sugar', 10, 100, 60, 120),
        OcrBox('150', 300, 99, 340, 119),
        OcrBox('2', 200, 102, 210, 122),
        OcrBox('Rice', 10, 150, 50, 170),
        OcrBox('5', 200, 152, 210, 172),
      ]);
      final rows = t.split('\n');
      expect(rows.length, 2);
      expect(rows[0].startsWith('Sugar'), isTrue);
      expect(rows[0].endsWith('300'), isTrue);
      expect(rows[1].startsWith('Rice'), isTrue);
    });
  });

  group('parseBillText (improved)', () {
    test('serial number and pack size stay out of qty/rate', () {
      final l = parseBillText('1. Sugar 50kg 2 300 600');
      expect(l.single.name, 'Sugar 50kg');
      expect(l.single.qty, '2');
      expect(l.single.rate, '300');
    });

    test('column header line is skipped', () {
      final l = parseBillText('Item Description Qty Rate Amount\nSoap 3 85 255');
      expect(l.length, 1);
      expect(l.single.name, 'Soap');
    });

    test('letter O inside a number is read as zero', () {
      final l = parseBillText('Oil 1 5OO');
      expect(l.single.name, 'Oil');
      expect(l.single.rate, '500');
    });

    test('name on one line, numbers on the next', () {
      final l = parseBillText('Sugar 50kg\n2 300 600');
      expect(l.single.name, 'Sugar 50kg');
      expect(l.single.qty, '2');
      expect(l.single.rate, '300');
    });

    test('quantity first: 2 x Sugar 300', () {
      final l = parseBillText('2 x Sugar 300');
      expect(l.single.name, 'Sugar');
      expect(l.single.qty, '2');
      expect(l.single.rate, '300');
    });

    test('names ending in x keep the x', () {
      final l = parseBillText('Max 2 100 200');
      expect(l.single.name, 'Max');
    });

    test('phone number line is not an item', () {
      expect(parseBillText('Shop 03001234567'), isEmpty);
    });
  });

  test('detectBillTotal picks the biggest total-line number', () {
    expect(detectBillTotal('Sugar 2 150 300\nSub Total 1,300\nGrand Total 1,250'), 1300);
    expect(detectBillTotal('Sugar 2 150 300'), isNull);
  });

  group('matchScannedProduct', () {
    const products = [
      Product(barcode: '1', name: 'Sugar 50kg'),
      Product(barcode: '2', name: 'Rice Basmati'),
      Product(barcode: '3', name: 'Cooking Oil'),
    ];
    test('exact and near names match', () {
      expect(matchScannedProduct('sugar 50kg', products)?.barcode, '1');
      expect(matchScannedProduct('Rice Basmatl', products)?.barcode, '2'); // OCR: i -> l
    });
    test('unrelated name does not match', () {
      expect(matchScannedProduct('Detergent', products), isNull);
    });
  });
}
