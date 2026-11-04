import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/db/due_followup_repository.dart';
import 'package:ah_developer_kiryana_store/db/due_reminders_repository.dart';
import 'package:ah_developer_kiryana_store/models/receivable_aging.dart';
import 'package:ah_developer_kiryana_store/utils/due_days.dart';

// 15 Mar 2026, 14:30 local.
final now = DateTime(2026, 3, 15, 14, 30).millisecondsSinceEpoch;
int day(int d) => DateTime(2026, 3, d).millisecondsSinceEpoch;

DueBill bill(String id, int partyId, double total, {int due = 0, double paid = 0, bool balance = false, bool advance = false}) =>
    DueBill(
      id: id,
      partyId: partyId,
      partyName: 'P$partyId',
      partyPhone: '0300',
      total: total,
      paid: paid,
      dueDate: due,
      createdAt: 1,
      isSale: true,
      isBalance: balance,
      isAdvance: advance,
    );

DueParty party(int id, List<DueBill> bills) =>
    DueParty(partyId: id, partyName: 'P$id', partyPhone: '0300', isSale: true, bills: bills);

void main() {
  group('agingBucketForDays', () {
    test('seemayen', () {
      expect(agingBucketForDays(-3), AgingBucket.notDue);
      expect(agingBucketForDays(0), AgingBucket.notDue);
      expect(agingBucketForDays(1), AgingBucket.late1to7);
      expect(agingBucketForDays(7), AgingBucket.late1to7);
      expect(agingBucketForDays(8), AgingBucket.late8to30);
      expect(agingBucketForDays(30), AgingBucket.late8to30);
      expect(agingBucketForDays(31), AgingBucket.late31to60);
      expect(agingBucketForDays(60), AgingBucket.late31to60);
      expect(agingBucketForDays(61), AgingBucket.late60plus);
    });

    test('calendarDaysBetween', () {
      expect(calendarDaysBetween(day(10), now), 5);
      expect(calendarDaysBetween(day(15), now), 0);
      expect(calendarDaysBetween(day(20), now), -5);
    });
  });

  group('buildAging', () {
    test('har bill apne dibbe mein, party ki worst halat, kul mel khata hai', () {
      final parties = [
        party(1, [bill('A', 1, 1000, due: day(14)), bill('B', 1, 500, due: day(1))]), // 1 din + 14 din late
        party(2, [bill('C', 2, 300, due: day(20))]), // abhi waqt hai
        party(3, [bill('D', 3, 200)]), // tareekh nahi
        party(4, [bill('E', 4, 700, due: day(15))]), // aaj due => notDue
      ];
      final s = buildAging(parties, nowMillis: now);
      expect(s.totalDue, 2700);
      expect(s.totalParties, 4);
      expect(s.amountIn(AgingBucket.late1to7), 1000);
      expect(s.amountIn(AgingBucket.late8to30), 500);
      expect(s.amountIn(AgingBucket.notDue), 1000); // 300 + 700
      expect(s.amountIn(AgingBucket.noDate), 200);
      expect(s.lateAmount, 1500);
      expect(s.lateShare, closeTo(1500 / 2700, 1e-9));
      // dibbon ka jod = kul
      final sum = AgingBucket.values.fold<double>(0, (a, b) => a + s.amountIn(b));
      expect(sum, s.totalDue);
      // bari raqam pehle: P1 (1500) phir P4 (700)
      expect([for (final r in s.rows) r.party.partyName].take(2), ['P1', 'P4']);
      final r1 = s.rows.first;
      expect(r1.maxDaysLate, 14);
      expect(r1.worst, AgingBucket.late8to30);
      expect(s.rows.firstWhere((r) => r.party.partyName == 'P3').worst, AgingBucket.noDate);
      expect(s.rows.firstWhere((r) => r.party.partyName == 'P2').worst, AgingBucket.notDue);
      expect(s.partiesIn(AgingBucket.late1to7), 1);
      expect(s.partiesIn(AgingBucket.notDue), 2);
    });

    test('rowsIn: sirf us dibbe ki parties, us dibbe ki raqam se', () {
      final parties = [
        party(1, [bill('A', 1, 1000, due: day(14)), bill('B', 1, 500, due: day(1))]),
        party(2, [bill('C', 2, 4000, due: day(13))]),
      ];
      final s = buildAging(parties, nowMillis: now);
      expect([for (final r in s.rowsIn(AgingBucket.late1to7)) r.party.partyName], ['P2', 'P1']);
      expect([for (final r in s.rowsIn(AgingBucket.late8to30)) r.party.partyName], ['P1']);
      expect(s.rowsIn(AgingBucket.late60plus), isEmpty);
    });

    test('baqi paisa wala hissa hi ginta hai; advance aur poore ada bills chhodte hain', () {
      final parties = [
        party(1, [bill('A', 1, 1000, paid: 400, due: day(1)), bill('Z', 1, 500, paid: 500, due: day(1))]),
        party(2, [bill('Adv', 2, 900, balance: true, advance: true)]),
        party(3, [bill('Previous balance', 3, 250, balance: true)]), // purana hisaab => tareekh nahi
      ];
      final s = buildAging(parties, nowMillis: now);
      expect(s.totalParties, 2);
      expect(s.amountIn(AgingBucket.late8to30), 600);
      expect(s.amountIn(AgingBucket.noDate), 250);
      expect(s.totalDue, 850);
    });

    test('60+ din aur khali', () {
      final s = buildAging([party(1, [bill('A', 1, 100, due: DateTime(2025, 12, 1).millisecondsSinceEpoch)])], nowMillis: now);
      expect(s.amountIn(AgingBucket.late60plus), 100);
      expect(AgingSummary.empty.isEmpty, isTrue);
      expect(buildAging(const [], nowMillis: now).isEmpty, isTrue);
      expect(buildAging(const [], nowMillis: now).lateShare, 0);
    });
  });

  group('buildCollectionFocus: aaj lena hai', () {
    test('aaj ki tareekh wali party "aaj lena hai" mein, late / aage wali nahi', () {
      final parties = [
        party(1, [bill('A', 1, 1000, due: day(15))]), // aaj
        party(2, [bill('B', 2, 400, due: day(10))]), // late
        party(3, [bill('C', 3, 300, due: day(20))]), // aage
        party(4, [bill('D', 4, 600, due: day(15)), bill('E', 4, 100, due: day(5))]), // late bhi, aaj bhi => sirf late
      ];
      final f = buildCollectionFocus(parties, const {}, nowMillis: now);
      expect(f.dueTodayCount, 1);
      expect(f.dueTodayAmount, 1000);
      expect(f.overdueCount, 2);
      expect(f.overdueAmount, 1100);
      expect(f.totalParties, 4);
      final names = [for (final p in f.top) p.party.partyName];
      expect(names, containsAll(['P1', 'P2', 'P4']));
      expect(names.contains('P3'), isFalse);
      expect(f.top.firstWhere((p) => p.party.partyName == 'P1').dueToday, isTrue);
      expect(f.top.firstWhere((p) => p.party.partyName == 'P2').dueToday, isFalse);
    });
  });

  group('due days', () {
    test('parseShopDueDays', () {
      expect(parseShopDueDays(null), kFallbackDueDays);
      expect(parseShopDueDays(''), kFallbackDueDays);
      expect(parseShopDueDays('abc'), kFallbackDueDays);
      expect(parseShopDueDays('15'), 15);
      expect(parseShopDueDays(' 30 '), 30);
      expect(parseShopDueDays('0'), 0);
      expect(parseShopDueDays('-4'), 0);
      expect(parseShopDueDays('9999'), kMaxDueDays);
    });

    test('effectiveDueDays: customer pehle, phir dukaan', () {
      expect(effectiveDueDays(customerDays: 10, shopDays: 7), 10);
      expect(effectiveDueDays(customerDays: 0, shopDays: 7), 7);
      expect(effectiveDueDays(customerDays: 0, shopDays: 0), 0);
    });
  });
}
