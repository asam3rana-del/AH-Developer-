import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' show Database;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ah_developer_kiryana_store/db/app_database.dart';
import 'package:ah_developer_kiryana_store/db/shop_rent_repository.dart';
import 'package:ah_developer_kiryana_store/services/session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  // ------------------------------------------------------------ pure maths

  group('mahine aur rent ki maths', () {
    test('ymOf / addMonths / monthsBetween / monthsRange', () {
      expect(ymOf(DateTime(2026, 3, 9)), '2026-03');
      expect(addMonths('2026-11', 2), '2027-01');
      expect(addMonths('2026-01', -1), '2025-12');
      expect(monthsBetween('2025-10', '2026-10'), 12);
      expect(monthsRange('2026-11', '2027-02'), ['2026-11', '2026-12', '2027-01', '2027-02']);
      expect(monthsRange('2026-11', '2026-10'), isEmpty);
    });

    test('rentForMonth: saal baad naya rent sirf aage lagta hai', () {
      final terms = {'2025-10': 15000.0, '2026-10': 16500.0};
      expect(rentForMonth(terms, '2025-10'), 15000);
      expect(rentForMonth(terms, '2026-09'), 15000);
      expect(rentForMonth(terms, '2026-10'), 16500);
      expect(rentForMonth(terms, '2027-03'), 16500);
      expect(rentForMonth(terms, '2020-01'), 15000); // koi term itna purana nahi => pehla term
      expect(rentForMonth(const {}, '2026-10'), 0);
    });

    test('dueDateFor: 31 tareekh chhote mahine mein aakhri din', () {
      expect(dueDateFor('2026-10', 5), DateTime(2026, 10, 5));
      expect(dueDateFor('2026-02', 31), DateTime(2026, 2, 28));
      expect(dueDateFor('2028-02', 31), DateTime(2028, 2, 29));
      expect(dueDateFor('2026-10', 0), DateTime(2026, 10, 1));
    });

    test('needsRentReview: 12 mahine baad yaad dilao; increaseByPercent', () {
      expect(needsRentReview('2025-10', '2026-09'), isFalse);
      expect(needsRentReview('2025-10', '2026-10'), isTrue);
      expect(increaseByPercent(15000, 10), 16500);
      expect(increaseByPercent(12345, 5), 12962);
    });

    test('allocateFifo: sab se purana mahina pehle, baqi extra', () {
      const dues = [MonthDue('2026-09', 5000), MonthDue('2026-10', 15000)];
      final a = allocateFifo(dues, 7000);
      expect(a.allocs.map((x) => (x.ym, x.amount)).toList(), [('2026-09', 5000.0), ('2026-10', 2000.0)]);
      expect(a.extra, 0);
      final b = allocateFifo(dues, 25000);
      expect(b.allocs.length, 2);
      expect(b.extra, 5000);
      final c = allocateFifo(const [], 300);
      expect(c.allocs, isEmpty);
      expect(c.extra, 300);
      expect(allocateFifo(dues, 3000).allocs.single.amount, 3000);
    });
  });

  // ------------------------------------------------------------ database

  group('Shop Rents (asal AppDatabase)', () {
    late Directory tempDir;
    late Database db;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      tempDir = await Directory.systemTemp.createTemp('ah_shop_rent_');
      await AppDatabase.instance.close();
      await databaseFactory.setDatabasesPath(tempDir.path);
      db = await AppDatabase.instance.database;
      Session.username = 'rent-test-admin';
      Session.role = 'admin';
    });

    tearDown(() async {
      await AppDatabase.instance.close();
      Session.username = null;
      Session.role = 'cashier';
      await tempDir.delete(recursive: true);
    });

    final repo = ShopRentRepository.instance;

    Future<double> sum(String sql) async =>
        ((await db.rawQuery(sql)).first.values.first as num?)?.toDouble() ?? 0.0;
    Future<double> expenses() => sum("SELECT COALESCE(SUM(amount),0) FROM expenses WHERE category = 'Rent'");
    Future<double> cashOut() => sum("SELECT COALESCE(SUM(amount),0) FROM cash_transactions WHERE type = 'OUT'");
    Future<double> cashIn() => sum("SELECT COALESCE(SUM(amount),0) FROM cash_transactions WHERE type = 'IN'");

    final oct = DateTime(2026, 10, 10);

    Future<int> shop({bool auto = true, double openingAdvance = 0}) => repo.addShop(
          shopName: 'Shop A',
          landlord: 'Ali',
          monthlyRent: 15000,
          dueDay: 5,
          startMonth: DateTime(2026, 10, 1),
          openingAdvance: openingAdvance,
          autoApply: auto,
          now: oct,
        );

    test('naya shop: is mahine ka charge banta hai, tareekh guzar gayi to overdue', () async {
      final id = await shop();
      final s = (await repo.summaryOf(id, now: oct))!;
      expect(s.currentRent, 15000);
      expect(s.outstanding, 15000);
      expect(s.dues.single.ym, '2026-10');
      expect(s.overdue, isTrue); // due 5 Oct, aaj 10 Oct
      expect(s.advanceBalance, 0);
      // dobara ensureCharges: koi naya charge nahi (ek dukaan + ek mahina = ek hi charge)
      expect(await repo.ensureCharges(now: oct), 0);
      expect((await repo.summaryOf(id, now: oct))!.outstanding, 15000);
    });

    test('pay: Expense (Rent) + Cash OUT banti hai; poora ho to Paid; zyada ho to advance', () async {
      final id = await shop();
      final r1 = await repo.pay(id, amount: 10000, method: 'cash', now: oct);
      expect(r1.toRent, 10000);
      expect(r1.toAdvance, 0);
      expect(await expenses(), 10000);
      expect(await cashOut(), 10000);
      expect((await repo.summaryOf(id, now: oct))!.outstanding, 5000);

      final r2 = await repo.pay(id, amount: 8000, method: 'cash', now: oct);
      expect(r2.toRent, 5000);
      expect(r2.toAdvance, 3000);
      final s = (await repo.summaryOf(id, now: oct))!;
      expect(s.isClear, isTrue);
      expect(s.advanceBalance, 3000);
      expect(await expenses(), 15000); // advance expense nahi
      expect(await cashOut(), 18000); // lekin cash se nikla
    });

    test('advance: Cash OUT hai, Expense nahi; agle mahine ka rent us mein se khud katta hai', () async {
      final id = await shop(openingAdvance: 0);
      await repo.pay(id, amount: 15000, method: 'cash', now: oct);
      await repo.giveAdvance(id, amount: 20000, method: 'bank', note: 'saal ka', now: oct);
      expect(await expenses(), 15000);
      expect(await cashOut(), 35000);
      expect((await repo.summaryOf(id, now: oct))!.advanceBalance, 20000);

      // Naya mahina: charge banta hai aur advance se kat jata hai (autoApply on).
      final nov = DateTime(2026, 11, 10);
      expect(await repo.ensureCharges(now: nov), 1);
      final s = (await repo.summaryOf(id, now: nov))!;
      expect(s.isClear, isTrue);
      expect(s.advanceBalance, 5000);
      expect(await expenses(), 30000); // Nov ka rent ab expense
      // Cash mein barabar IN + OUT: balance wahi
      expect(await cashIn(), 15000);
      expect(await cashOut(), 35000 + 15000);
      expect(await cashOut() - await cashIn(), 35000);
    });

    test('autoApply band ho to advance khud nahi katta; applyAdvance se katta hai', () async {
      final id = await shop(auto: false, openingAdvance: 20000);
      expect((await repo.summaryOf(id, now: oct))!.advanceBalance, 20000);
      expect((await repo.summaryOf(id, now: oct))!.outstanding, 15000);
      expect(await repo.applyAdvance(id, now: oct), 15000);
      final s = (await repo.summaryOf(id, now: oct))!;
      expect(s.isClear, isTrue);
      expect(s.advanceBalance, 5000);
      expect(await repo.applyAdvance(id, now: oct), 0); // ab kuch baqi nahi
    });

    test('saal baad rent badalna: purane mahine nahi badalte, naye badal jate hain', () async {
      final id = await shop();
      await repo.pay(id, amount: 15000, method: 'cash', now: oct);
      final oct27 = DateTime(2027, 10, 10);
      await repo.ensureCharges(now: oct27); // Nov 2026 .. Oct 2027
      var s = (await repo.summaryOf(id, now: oct27))!;
      expect(s.reviewDue, isTrue); // 12 mahine ho gaye
      expect(s.dues.length, 12);
      expect(s.currentRent, 15000);

      await repo.changeRent(id, fromYm: '2027-10', newRent: 16500);
      s = (await repo.summaryOf(id, now: oct27))!;
      expect(s.currentRent, 16500);
      expect(s.reviewDue, isFalse);
      expect(s.dues.last.ym, '2027-10');
      expect(s.dues.last.due, 16500); // mojooda unpaid mahina naya rent
      expect(s.dues.first.due, 15000); // purana mahina waisa hi
      // Agle mahine ka charge naye rent par
      await repo.ensureCharges(now: DateTime(2027, 11, 3));
      expect((await repo.summaryOf(id, now: DateTime(2027, 11, 3)))!.dues.last.due, 16500);
    });

    test('waiveMonth: rent maaf; ada ho chuka ho to nahi', () async {
      final id = await shop();
      await repo.waiveMonth(id, '2026-10');
      expect((await repo.summaryOf(id, now: oct))!.isClear, isTrue);
      final id2 = await repo.addShop(shopName: 'B', monthlyRent: 1000, startMonth: DateTime(2026, 10, 1), now: oct);
      await repo.pay(id2, amount: 500, method: 'cash', now: oct);
      await expectLater(() => repo.waiveMonth(id2, '2026-10'), throwsA(isA<StateError>()));
    });

    test('deleteEntry: payment hatao => rent wapas baqi, Expense + Cash dono hat jati hain', () async {
      final id = await shop();
      await repo.pay(id, amount: 15000, method: 'cash', now: oct);
      final h = await repo.history(id);
      final pay = h.firstWhere((e) => e.kind == 'payment');
      await repo.deleteEntry(pay.id);
      expect(await expenses(), 0);
      expect(await cashOut(), 0);
      expect((await repo.summaryOf(id, now: oct))!.outstanding, 15000);
    });

    test('deleteEntry: jis advance mein se rent kat chuka ho wo pehle nahi hat sakta', () async {
      final id = await shop(auto: false);
      await repo.giveAdvance(id, amount: 15000, method: 'cash', now: oct);
      await repo.applyAdvance(id, now: oct);
      final h = await repo.history(id);
      final adv = h.firstWhere((e) => e.kind == 'advance');
      final applied = h.firstWhere((e) => e.kind == 'applied');
      await expectLater(() => repo.deleteEntry(adv.id), throwsA(isA<StateError>()));
      await repo.deleteEntry(applied.id); // Expense + cash IN dono gayi
      expect(await expenses(), 0);
      expect(await cashIn(), 0);
      await repo.deleteEntry(adv.id);
      expect(await cashOut(), 0);
      final s = (await repo.summaryOf(id, now: oct))!;
      expect(s.advanceBalance, 0);
      expect(s.outstanding, 15000);
    });

    test('Expense screen se rent ka expense hata diya to ledger khud theek ho jata hai', () async {
      final id = await shop();
      await repo.pay(id, amount: 15000, method: 'cash', now: oct);
      await db.delete('expenses'); // kisi ne Expense screen se hata diya
      expect((await repo.summaryOf(id, now: oct))!.outstanding, 15000); // ab paid nahi ginta
      await repo.ensureCharges(now: oct);
      final rows = await db.query('shop_rent_ledger', where: "kind = 'payment'");
      expect(rows, isEmpty);
    });

    test('monthReport: rent / ada / baqi', () async {
      final id = await shop();
      await repo.pay(id, amount: 6000, method: 'cash', now: oct);
      final rows = await repo.monthReport('2026-10');
      expect(rows.single.rent, 15000);
      expect(rows.single.paid, 6000);
      expect(rows.single.due, 9000);
      expect(await repo.monthReport('2026-09'), isEmpty);
      expect(id, greaterThan(0));
    });

    test('deleteShop: sirf jab payment/advance na ho; band shop ka rent nahi banta', () async {
      final id = await shop();
      await repo.deleteShop(id);
      expect(await repo.listShops(), isEmpty);

      final id2 = await shop();
      await repo.pay(id2, amount: 100, method: 'cash', now: oct);
      await expectLater(() => repo.deleteShop(id2), throwsA(isA<StateError>()));
      await repo.setActive(id2, false);
      expect(await repo.ensureCharges(now: DateTime(2026, 12, 1)), 0);
    });

    test('role: cashier shop rent nahi chala sakta', () async {
      Session.role = 'cashier';
      await expectLater(() => repo.addShop(shopName: 'X', monthlyRent: 1), throwsA(isA<StateError>()));
    });
  });
}
