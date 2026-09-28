import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/db/zakat_repository.dart';
import 'package:ah_developer_kiryana_store/models/zakat.dart';
import 'package:ah_developer_kiryana_store/utils/hijri.dart';

void main() {
  group('Hijri conversion', () {
    test('Gregorian <-> JDN known value (2000-01-01 = 2451545)', () {
      expect(gregorianToJdn(2000, 1, 1), 2451545);
      final g = jdnToGregorian(2451545);
      expect((g.year, g.month, g.day), (2000, 1, 1));
    });

    test('1 Ramadan dates (tabular calendar)', () {
      DateTime d(int y) => ramadanStart(y);
      expect(d(1445), DateTime(2024, 3, 11));
      expect(d(1446), DateTime(2025, 3, 1));
      expect(d(1447), DateTime(2026, 2, 18));
      expect(d(1448), DateTime(2027, 2, 8));
    });

    test('round trip over many days', () {
      for (var j = gregorianToJdn(1990, 1, 1); j < gregorianToJdn(2060, 1, 1); j += 7) {
        final h = jdnToIslamic(j);
        expect(h.month, inInclusiveRange(1, 12));
        expect(h.day, inInclusiveRange(1, 30));
        expect(islamicToJdn(h.year, h.month, h.day), j);
      }
    });
  });

  group('Zakat year bracket', () {
    test('mid-year date falls in the Ramadan that started before it', () {
      final b = currentRamadanBracket(DateTime(2026, 9, 29));
      expect(b.start, DateTime(2026, 2, 18));
      expect(b.end, DateTime(2027, 2, 8));
    });

    test('date before this Ramadan uses the previous Ramadan', () {
      final b = currentRamadanBracket(DateTime(2026, 1, 10));
      expect(b.start, DateTime(2025, 3, 1));
      expect(b.end, DateTime(2026, 2, 18));
    });

    test('exactly on 1 Ramadan starts the new year', () {
      final b = currentRamadanBracket(DateTime(2026, 2, 18));
      expect(b.start, DateTime(2026, 2, 18));
    });
  });

  group('Zakat maths', () {
    test('2.5% of net assets; never negative', () {
      expect(zakatPayable(100000), 2500);
      expect(zakatPayable(0), 0);
      expect(zakatPayable(-5000), 0);
    });

    test('net assets = cash + bank + stock + receivables - payables', () {
      expect(
        netZakatableAssets(cashInHand: 1000, bankBalance: 2000, stockValue: 3000, receivables: 500, payables: 1500),
        5000,
      );
    });

    test('12 month slices tile the year exactly, no gaps/overlap', () {
      const s = 1000000, e = 1000000 + 354 * 86400000;
      expect(monthStartMillis(s, e, 1), s);
      expect(monthEndMillis(s, e, 12), e);
      for (var m = 1; m < 12; m++) {
        expect(monthEndMillis(s, e, m), monthStartMillis(s, e, m + 1));
      }
    });

    test('month labels', () {
      final y = ZakatYear(
          startDate: DateTime(2026, 2, 18).millisecondsSinceEpoch,
          endDate: DateTime(2027, 2, 8).millisecondsSinceEpoch,
          assetsSnapshot: 0,
          totalPayable: 0,
          createdAt: 0);
      expect(zakatMonthLabel(y, 1, urdu: false), 'Ramadan');
      expect(zakatMonthLabel(y, 12, urdu: false), "Sha'ban");
      expect(zakatMonthLabel(y.copyWith(calendarType: 'gregorian'), 1, urdu: false), 'Feb 2026');
    });

    test('payment description', () {
      final s = DateTime(2026, 2, 18).millisecondsSinceEpoch, e = DateTime(2027, 2, 8).millisecondsSinceEpoch;
      expect(zakatPaymentDescription(startMs: s, endMs: e, note: '', urdu: false),
          'Zakat payment (18 Feb 2026 \u2014 08 Feb 2027)');
      expect(zakatPaymentDescription(startMs: s, endMs: e, note: ' for Ali ', urdu: false),
          'Zakat payment (18 Feb 2026 \u2014 08 Feb 2027) | for Ali');
    });

    test('month row: covered / remaining', () {
      expect(const ZakatMonthRow(1, 100, 100, '', null).covered, isTrue);
      expect(const ZakatMonthRow(1, 100, 99.6, '', null).covered, isTrue); // within 0.5 tolerance
      expect(const ZakatMonthRow(1, 100, 40, '', null).remaining, 60);
      expect(const ZakatMonthRow(1, 100, 150, '', null).remaining, 0);
    });
  });
}
