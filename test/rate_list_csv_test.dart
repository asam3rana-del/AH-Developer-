import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/utils/rate_list_csv.dart';

void main() {
  // Kotlin ItemsActivity.parseCsvLine / importRateListCsv.
  group('parseCsvLine', () {
    test('plain fields', () => expect(parseCsvLine('a,b,c'), ['a', 'b', 'c']));
    test('quoted comma stays inside field', () => expect(parseCsvLine('"a,b",c'), ['a,b', 'c']));
    test('escaped "" quote', () => expect(parseCsvLine('"say ""hi""",x'), ['say "hi"', 'x']));
    test('trailing empty field kept', () => expect(parseCsvLine('a,,'), ['a', '', '']));
  });

  group('parseRateListCsv', () {
    const header =
        "Code (don't edit),Name,Category,Unit,Wholesale Rate,Retail Rate,2nd Unit,1 Unit = Qty (2nd Unit),3rd Unit,1 (2nd Unit) = Qty (3rd Unit)";

    test('header skipped, BOM + CRLF handled, full row parsed', () {
      final rows = parseRateListCsv('\uFEFF$header\r\n"B1","Rice","Grain","kg",190,200,"gram",1000,"",\r\n');
      expect(rows.length, 1);
      final r = rows.first;
      expect(r.barcode, 'B1');
      expect(r.unit, 'kg');
      expect(r.wholesale, 190);
      expect(r.retail, 200);
      expect(r.secondaryUnit, 'gram');
      expect(r.secondaryUnitQty, 1000);
      expect(r.tertiaryUnit, '');
      expect(r.tertiaryUnitQty, 0);
    });

    test('blank lines, short rows and blank Code are skipped', () {
      final rows = parseRateListCsv('$header\n\n"B1","a","c"\n"","n","c","kg",1,2\n"B2","n","c","kg",1,2\n');
      expect(rows.map((r) => r.barcode), ['B2']);
    });

    test('bad numbers become null (keep existing), blank unit becomes null', () {
      final r = parseRateListCsv('$header\n"B1","n","c","",abc,,,,,\n').single;
      expect(r.unit, isNull);
      expect(r.wholesale, isNull);
      expect(r.retail, isNull);
      expect(r.secondaryUnitQty, 0);
    });

    test('header only -> no rows', () => expect(parseRateListCsv(header), isEmpty));
  });

  test('rateListImportMessage', () {
    expect(rateListImportMessage(3, 0), 'Updated 3 product(s)');
    expect(rateListImportMessage(3, 2), 'Updated 3 product(s), 2 not found (Code column changed?)');
  });
}
