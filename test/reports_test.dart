import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/db/reports_repository.dart';

void main() {
  group('reportRangeFor', () {
    // Mangal 29 Sep 2026, 15:30
    final now = DateTime(2026, 9, 29, 15, 30);

    test('today = aaj ka midnight se agle midnight - 1ms', () {
      final r = reportRangeFor(ReportPeriod.today, now);
      expect(r.start, DateTime(2026, 9, 29).millisecondsSinceEpoch);
      expect(r.end, DateTime(2026, 9, 30).millisecondsSinceEpoch - 1);
    });

    test('week = Monday midnight se ab tak', () {
      final r = reportRangeFor(ReportPeriod.week, now);
      expect(r.start, DateTime(2026, 9, 28).millisecondsSinceEpoch);
      expect(r.end, now.millisecondsSinceEpoch);
    });

    test('week Monday ko apne din se shuru hota hai', () {
      final mon = DateTime(2026, 9, 28, 9);
      expect(reportRangeFor(ReportPeriod.week, mon).start, DateTime(2026, 9, 28).millisecondsSinceEpoch);
    });

    test('week Sunday ko pichle Monday se', () {
      final sun = DateTime(2026, 10, 4, 9);
      expect(reportRangeFor(ReportPeriod.week, sun).start, DateTime(2026, 9, 28).millisecondsSinceEpoch);
    });

    test('week mahine ki hadd paar kar sakta hai', () {
      final wed = DateTime(2026, 10, 1, 9);
      expect(reportRangeFor(ReportPeriod.week, wed).start, DateTime(2026, 9, 28).millisecondsSinceEpoch);
    });

    test('month = mahine ki 1 tarikh se ab tak', () {
      final r = reportRangeFor(ReportPeriod.month, now);
      expect(r.start, DateTime(2026, 9, 1).millisecondsSinceEpoch);
      expect(r.end, now.millisecondsSinceEpoch);
    });

    test('allTime = 0 se ab tak', () {
      final r = reportRangeFor(ReportPeriod.allTime, now);
      expect(r.start, 0);
      expect(r.end, now.millisecondsSinceEpoch);
    });
  });

  group('buildProfitLoss', () {
    test('gross aur net sahi', () {
      final pl = buildProfitLoss(sales: 1000, cogs: 700, expenses: 100);
      expect(pl.grossProfit, 300);
      expect(pl.netProfit, 200);
      expect(pl.isLoss, false);
    });

    test('kharche zyada hon to Net Loss', () {
      final pl = buildProfitLoss(sales: 500, cogs: 400, expenses: 250);
      expect(pl.netProfit, -150);
      expect(pl.isLoss, true);
    });

    test('kuch nahi to sab zero', () {
      final pl = buildProfitLoss(sales: 0, cogs: 0, expenses: 0);
      expect(pl.netProfit, 0);
      expect(pl.isLoss, false);
    });
  });
}
