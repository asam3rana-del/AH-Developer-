import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ah_developer_kiryana_store/db/app_database.dart';
import 'package:ah_developer_kiryana_store/db/due_followup_repository.dart';
import 'package:ah_developer_kiryana_store/db/due_reminders_repository.dart';
import 'package:ah_developer_kiryana_store/models/collection_plan.dart';
import 'package:ah_developer_kiryana_store/models/due_followup.dart';
import 'package:ah_developer_kiryana_store/services/session.dart';

// 15 Mar 2026, 14:30 local — din ke beech ka waqt.
final now = DateTime(2026, 3, 15, 14, 30).millisecondsSinceEpoch;
int day(int d) => DateTime(2026, 3, d).millisecondsSinceEpoch;
int at(int d, int h) => DateTime(2026, 3, d, h).millisecondsSinceEpoch;

DueFollowUp fu(
  int createdAt, {
  int id = 0,
  int partyId = 1,
  String method = FollowUpMethod.call,
  String outcome = FollowUpOutcome.note,
  double amount = 0,
  int promise = 0,
  int next = 0,
}) =>
    DueFollowUp(
      id: id == 0 ? createdAt : id,
      partyId: partyId,
      partyName: 'Ali',
      method: method,
      outcome: outcome,
      amount: amount,
      promiseDate: promise,
      nextFollowUp: next,
      createdAt: createdAt,
    );

DueBill bill(String id, {int partyId = 1, String name = 'Ali', double total = 1000, double paid = 0, int dueDate = 0, String phone = '0300'}) =>
    DueBill(
      id: id,
      partyId: partyId,
      partyName: name,
      partyPhone: phone,
      total: total,
      paid: paid,
      dueDate: dueDate,
      createdAt: 1,
      isSale: true,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('followUpState', () {
    test('koi entry nahi => never, kuch tay nahi', () {
      final s = followUpState(const [], nowMillis: now);
      expect(s.never, isTrue);
      expect(s.needsActionToday, isFalse);
      expect(s.promiseBroken, isFalse);
      expect(s.daysSinceContact(now), isNull);
    });

    test('sirf "sent" entry: aakhri baat ginti hai, par wada / follow-up / dispute nahi', () {
      final s = followUpState([fu(at(14, 10), outcome: FollowUpOutcome.sent, method: FollowUpMethod.whatsapp)], nowMillis: now);
      expect(s.never, isFalse);
      expect(s.contactCount, 1);
      expect(s.promise, isNull);
      expect(s.nextFollowUp, 0);
      expect(s.daysSinceContact(now), 1);
    });

    test('wada aage ki tareekh ka => wada pe, aaj kaam nahi', () {
      final s = followUpState([fu(at(14, 10), outcome: FollowUpOutcome.promised, promise: day(18), next: day(18))], nowMillis: now);
      expect(s.onPromise, isTrue);
      expect(s.promiseBroken, isFalse);
      expect(s.needsActionToday, isFalse);
    });

    test('wada aaj ka => aaj karna hai', () {
      final s = followUpState([fu(at(12, 10), outcome: FollowUpOutcome.promised, promise: day(15))], nowMillis: now);
      expect(s.promiseToday, isTrue);
      expect(s.needsActionToday, isTrue);
      expect(s.promiseBroken, isFalse);
    });

    test('wada guzar gaya aur paisa nahi aaya => toota', () {
      final s = followUpState([fu(at(10, 10), outcome: FollowUpOutcome.promised, promise: day(13))], nowMillis: now);
      expect(s.promiseBroken, isTrue);
      expect(s.onPromise, isFalse);
      expect(s.needsActionToday, isTrue);
    });

    test('wade ke baad "paid" aa jaye to wada khatam', () {
      final s = followUpState([
        fu(at(10, 10), outcome: FollowUpOutcome.promised, promise: day(13)),
        fu(at(13, 11), outcome: FollowUpOutcome.paid),
      ], nowMillis: now);
      expect(s.promise, isNull);
      expect(s.promiseBroken, isFalse);
    });

    test('wade ke baad "sent" wada khatam nahi karta', () {
      final s = followUpState([
        fu(at(10, 10), outcome: FollowUpOutcome.promised, promise: day(13)),
        fu(at(14, 11), outcome: FollowUpOutcome.sent, method: FollowUpMethod.whatsapp),
      ], nowMillis: now);
      expect(s.promiseBroken, isTrue);
    });

    test('naya wada purane ko badal deta hai', () {
      final s = followUpState([
        fu(at(8, 10), outcome: FollowUpOutcome.promised, promise: day(10)),
        fu(at(11, 10), outcome: FollowUpOutcome.promised, promise: day(20)),
      ], nowMillis: now);
      expect(s.promise!.promiseDate, day(20));
      expect(s.onPromise, isTrue);
    });

    test('follow-up ka din (aaj ya pehle) => aaj karna hai; aage ka => nahi', () {
      expect(followUpState([fu(at(12, 10), outcome: FollowUpOutcome.noAnswer, next: day(15))], nowMillis: now).followUpDue, isTrue);
      expect(followUpState([fu(at(12, 10), outcome: FollowUpOutcome.noAnswer, next: day(12))], nowMillis: now).needsActionToday, isTrue);
      expect(followUpState([fu(at(12, 10), outcome: FollowUpOutcome.noAnswer, next: day(16))], nowMillis: now).needsActionToday, isFalse);
    });

    test('dispute: follow-up ka din bhi aaj ka kaam nahi ginta, rank sab se neeche', () {
      final s = followUpState([fu(at(12, 10), outcome: FollowUpOutcome.dispute, next: day(14))], nowMillis: now);
      expect(s.dispute, isTrue);
      expect(s.followUpDue, isFalse);
      expect(followUpRank(s), 4);
    });

    test('entries kisi bhi tarteeb mein den, nateeja wahi', () {
      final a = fu(at(10, 10), outcome: FollowUpOutcome.promised, promise: day(13));
      final b = fu(at(13, 11), outcome: FollowUpOutcome.paid);
      expect(followUpState([a, b], nowMillis: now).promise, isNull);
      expect(followUpState([b, a], nowMillis: now).promise, isNull);
    });
  });

  group('rank + filter', () {
    FollowUpState st(List<DueFollowUp> e) => followUpState(e, nowMillis: now);
    test('rank: toota 0, aaj 1, aam 2, wada pe 3, dispute 4', () {
      expect(followUpRank(st([fu(at(10, 10), outcome: FollowUpOutcome.promised, promise: day(13))])), 0);
      expect(followUpRank(st([fu(at(12, 10), outcome: FollowUpOutcome.noAnswer, next: day(15))])), 1);
      expect(followUpRank(st(const [])), 2);
      expect(followUpRank(st([fu(at(14, 10), outcome: FollowUpOutcome.promised, promise: day(20))])), 3);
      expect(followUpRank(st([fu(at(12, 10), outcome: FollowUpOutcome.dispute)])), 4);
    });

    test('filter matches', () {
      final never = st(const []);
      final broken = st([fu(at(10, 10), outcome: FollowUpOutcome.promised, promise: day(13))]);
      final onP = st([fu(at(14, 10), outcome: FollowUpOutcome.promised, promise: day(20))]);
      expect(followUpMatches(FollowUpFilter.all, never), isTrue);
      expect(followUpMatches(FollowUpFilter.neverContacted, never), isTrue);
      expect(followUpMatches(FollowUpFilter.neverContacted, broken), isFalse);
      expect(followUpMatches(FollowUpFilter.brokenPromise, broken), isTrue);
      expect(followUpMatches(FollowUpFilter.today, broken), isTrue); // toota wada aaj ka kaam bhi hai
      expect(followUpMatches(FollowUpFilter.onPromise, onP), isTrue);
      expect(followUpMatches(FollowUpFilter.today, onP), isFalse);
    });
  });

  group('promiseRecord', () {
    test('poora wada, toota wada, aur aane wala wada (nahi ginta)', () {
      final r = promiseRecord([
        fu(at(1, 10), outcome: FollowUpOutcome.promised, promise: day(3)),
        fu(at(3, 12), outcome: FollowUpOutcome.paid), // wada poora
        fu(at(4, 10), outcome: FollowUpOutcome.promised, promise: day(6)), // toota (kuch nahi aaya)
        fu(at(14, 10), outcome: FollowUpOutcome.promised, promise: day(20)), // abhi aage ka
      ], nowMillis: now);
      expect(r.made, 2);
      expect(r.kept, 1);
      expect(r.broken, 1);
    });

    test('partial (raqam ke saath) bhi wada poora ginta hai', () {
      final r = promiseRecord([
        fu(at(1, 10), outcome: FollowUpOutcome.promised, promise: day(3)),
        fu(at(3, 12), outcome: FollowUpOutcome.partial, amount: 500),
      ], nowMillis: now);
      expect(r.kept, 1);
    });
  });

  group('reminderLevel + message', () {
    test('pichle 45 din ke WhatsApp / SMS ginte hain, call nahi; zyada se zyada 2', () {
      expect(reminderLevel(const [], nowMillis: now), 0);
      expect(reminderLevel([fu(at(10, 10), method: FollowUpMethod.call)], nowMillis: now), 0);
      expect(reminderLevel([fu(at(10, 10), method: FollowUpMethod.whatsapp)], nowMillis: now), 1);
      expect(
          reminderLevel([
            fu(at(8, 10), method: FollowUpMethod.whatsapp),
            fu(at(10, 10), method: FollowUpMethod.sms),
            fu(at(12, 10), method: FollowUpMethod.whatsapp),
          ], nowMillis: now),
          2);
      // 45 din se purana nahi ginta.
      expect(reminderLevel([fu(DateTime(2026, 1, 1).millisecondsSinceEpoch, method: FollowUpMethod.whatsapp)], nowMillis: now), 0);
    });

    test('message ki shiddat badhti hai aur toota wada likha jata hai', () {
      final m0 = followUpMessage(level: 0, name: 'Ali', rs: '5000');
      final m1 = followUpMessage(level: 1, name: 'Ali', rs: '5000', oldestDays: 12);
      final m2 = followUpMessage(
          level: 2, name: 'Ali', rs: '5000', brokenPromiseDate: DateTime(2026, 3, 13), brokenPromiseAmount: 2000);
      expect(m0, contains('Rs 5000'));
      expect(m0, isNot(contains('pehle bhi')));
      expect(m1, contains('pehle bhi yaad'));
      expect(m1, contains('12 din'));
      expect(m2, contains('13/3'));
      expect(m2, contains('Rs 2000'));
      expect(m2, contains('is hafte'));
    });

    test('reminderUriFor: pehli baar purana message; wada toota to naya', () {
      final g = DueParty(partyId: 1, partyName: 'Ali', partyPhone: '0300 1234567', isSale: true, bills: [bill('INV-1', dueDate: day(10), phone: '0300 1234567')]);
      final first = reminderUriFor(g, const [], nowMillis: now);
      expect(first.toString(), startsWith('https://wa.me/923001234567?text='));
      expect(Uri.decodeComponent(first.query), contains('Invoice INV-1'));
      final broken = reminderUriFor(
          g, [fu(at(10, 10), outcome: FollowUpOutcome.promised, promise: day(13), amount: 400)],
          nowMillis: now);
      final text = Uri.decodeComponent(broken.query);
      expect(text, contains('wada kiya tha'));
      expect(text, contains('5 din')); // 10 Mar se 15 Mar
    });
  });

  group('buildCollectionFocus', () {
    DueParty party(int id, String name, double total, {int due = 0}) =>
        DueParty(partyId: id, partyName: name, partyPhone: '0300', isSale: true, bills: [bill('I$id', partyId: id, name: name, total: total, dueDate: due)]);

    test('ginti, raqam, tarteeb: toota wada > aaj karna hai > overdue; wada pe wali overdue mein nahi', () {
      final parties = [
        party(1, 'Overdue only', 1000, due: day(5)),
        party(2, 'Broken', 500, due: day(5)),
        party(3, 'On promise', 9000, due: day(5)),
        party(4, 'Follow today', 300, due: day(5)),
        party(5, 'Future bill', 700, due: day(25)),
      ];
      final fups = {
        2: [fu(at(10, 10), partyId: 2, outcome: FollowUpOutcome.promised, promise: day(13))],
        3: [fu(at(14, 10), partyId: 3, outcome: FollowUpOutcome.promised, promise: day(20))],
        4: [fu(at(12, 10), partyId: 4, outcome: FollowUpOutcome.noAnswer, next: day(15))],
      };
      final f = buildCollectionFocus(parties, fups, nowMillis: now);
      expect(f.totalParties, 5);
      expect(f.totalDue, 11500);
      expect(f.brokenCount, 1);
      expect(f.actionCount, 2); // Broken + Follow today
      expect(f.actionAmount, 800);
      expect(f.overdueCount, 3); // Overdue only, Broken, Follow today (On promise nahi)
      expect(f.overdueAmount, 1800);
      expect([for (final p in f.top) p.party.partyName], ['Broken', 'Follow today', 'Overdue only']);
      expect(f.top.first.oldestOverdueDays, 10);
    });

    test('Due screen ke filter home card ki ginti se bilkul mel khate hain', () {
      final parties = [
        party(1, 'Overdue only', 1000, due: day(5)),
        party(2, 'Broken', 500, due: day(5)),
        party(3, 'On promise', 9000, due: day(5)),
        party(4, 'Follow today', 300, due: day(5)),
        party(5, 'Future bill', 700, due: day(25)),
        party(6, 'Bill today', 250, due: day(15)),
        party(7, 'Promise today', 400, due: day(25)),
      ];
      final fups = {
        2: [fu(at(10, 10), partyId: 2, outcome: FollowUpOutcome.promised, promise: day(13))],
        3: [fu(at(14, 10), partyId: 3, outcome: FollowUpOutcome.promised, promise: day(20))],
        4: [fu(at(12, 10), partyId: 4, outcome: FollowUpOutcome.noAnswer, next: day(15))],
        7: [fu(at(14, 10), partyId: 7, outcome: FollowUpOutcome.promised, promise: day(15))],
      };
      final f = buildCollectionFocus(parties, fups, nowMillis: now, topN: 2);
      int count(FollowUpFilter flt) => parties
          .where((p) => partyMatchesFilter(flt, p, followUpState(fups[p.partyId] ?? const <DueFollowUp>[], nowMillis: now), nowMillis: now))
          .length;
      expect(count(FollowUpFilter.collectToday), f.dueTodayCount);
      expect(count(FollowUpFilter.late), f.overdueCount);
      expect(count(FollowUpFilter.brokenPromise), f.brokenCount);
      expect(count(FollowUpFilter.focus), f.candidateCount);
      expect(f.top.length, 2); // card sirf 2 dikhata hai, baqi "+N more"
      expect(f.candidateCount > f.top.length, isTrue);
    });

    test('advance rows aur khali list', () {
      final adv = DueParty(
        partyId: 9,
        partyName: 'Adv',
        partyPhone: '',
        isSale: true,
        bills: [DueBill(id: 'Advance', partyId: 9, partyName: 'Adv', partyPhone: '', total: 100, paid: 0, dueDate: 0, createdAt: 1, isSale: true, isBalance: true, isAdvance: true)],
      );
      final f = buildCollectionFocus([adv], const {}, nowMillis: now);
      expect(f.isEmpty, isTrue);
      expect(CollectionFocus.empty.isEmpty, isTrue);
    });

    test('walk-in (partyId null) overdue ginta hai par follow-up nahi', () {
      final walkIn = DueParty(
        partyId: null,
        partyName: 'Walk-in',
        partyPhone: '',
        isSale: true,
        bills: [
          DueBill(id: 'W1', partyId: null, partyName: 'Walk-in', partyPhone: '', total: 200, paid: 0, dueDate: day(1), createdAt: 1, isSale: true),
        ],
      );
      final f = buildCollectionFocus([walkIn], const {}, nowMillis: now);
      expect(f.overdueCount, 1);
      expect(f.actionCount, 0);
    });
  });

  group('followUpMonthStats', () {
    test('ginti aur raqam', () {
      final s = followUpMonthStats([
        fu(at(1, 10), method: FollowUpMethod.whatsapp, outcome: FollowUpOutcome.sent),
        fu(at(2, 10), method: FollowUpMethod.call, outcome: FollowUpOutcome.promised, promise: day(5)),
        fu(at(5, 10), method: FollowUpMethod.call, outcome: FollowUpOutcome.paid, amount: 1500),
        fu(at(6, 10), method: FollowUpMethod.visit, outcome: FollowUpOutcome.partial, amount: 500, promise: day(9)),
      ]);
      expect(s.total, 4);
      expect(s.whatsapp, 1);
      expect(s.calls, 2);
      expect(s.promises, 2);
      expect(s.paidOrPartial, 2);
      expect(s.recorded, 2000);
    });
  });

  group('DueFollowUpRepository (asal AppDatabase)', () {
    late Directory tempDir;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      tempDir = await Directory.systemTemp.createTemp('ah_followup_');
      await AppDatabase.instance.close();
      await databaseFactory.setDatabasesPath(tempDir.path);
      await AppDatabase.instance.database;
      Session.username = 'followup-tester';
      Session.role = 'admin';
    });

    tearDown(() async {
      await AppDatabase.instance.close();
      Session.username = null;
      Session.role = 'cashier';
      await tempDir.delete(recursive: true);
    });

    final repo = DueFollowUpRepository.instance;

    test('add -> forParty nayi pehle, staff khud lagta hai, tareekhen din ki shuruaat par', () async {
      final id1 = await repo.add(
          partyId: 1, partyName: 'Ali', method: FollowUpMethod.call, outcome: FollowUpOutcome.noAnswer, createdAt: 1000);
      final id2 = await repo.add(
        partyId: 1,
        partyName: 'Ali',
        method: FollowUpMethod.call,
        outcome: FollowUpOutcome.promised,
        amount: 2000,
        promiseDate: at(18, 15),
        nextFollowUp: at(18, 9),
        note: '  Jumma ko dunga ',
        createdAt: 2000,
      );
      await repo.add(partyId: 2, partyName: 'Bilal', method: FollowUpMethod.whatsapp, createdAt: 3000);

      final list = await repo.forParty(1);
      expect(list.map((e) => e.id), [id2, id1]);
      expect(list.first.promiseDate, day(18));
      expect(list.first.nextFollowUp, day(18));
      expect(list.first.note, 'Jumma ko dunga');
      expect(list.first.staff, 'followup-tester');
      expect(list.first.amount, 2000);
    });

    test('setResult "sent" entry ko nateeja deta hai; byId; delete', () async {
      final id = await repo.add(partyId: 1, partyName: 'Ali', method: FollowUpMethod.whatsapp, outcome: FollowUpOutcome.sent);
      expect((await repo.byId(id))!.outcome, FollowUpOutcome.sent);
      final ok = await repo.setResult(
          id: id, outcome: FollowUpOutcome.promised, amount: 500, promiseDate: day(20), nextFollowUp: day(20), note: 'ok');
      expect(ok, isTrue);
      final e = (await repo.byId(id))!;
      expect(e.outcome, FollowUpOutcome.promised);
      expect(e.promiseDate, day(20));
      expect(e.method, FollowUpMethod.whatsapp); // tareeqa wahi
      expect(await repo.delete(id), isTrue);
      expect(await repo.byId(id), isNull);
      expect(await repo.setResult(id: id, outcome: FollowUpOutcome.paid), isFalse);
    });

    test('allByParty party ke hisaab se; monthStats mahine ki hadd mein', () async {
      await repo.add(partyId: 1, partyName: 'Ali', method: FollowUpMethod.call, outcome: FollowUpOutcome.paid, amount: 700, createdAt: at(3, 10));
      await repo.add(partyId: 2, partyName: 'Bilal', method: FollowUpMethod.whatsapp, createdAt: at(4, 10));
      await repo.add(partyId: 1, partyName: 'Ali', method: FollowUpMethod.call, createdAt: DateTime(2026, 2, 28, 10).millisecondsSinceEpoch);
      final all = await repo.allByParty();
      expect(all.keys.toSet(), {1, 2});
      expect(all[1]!.length, 2);
      final m = await repo.monthStats(2026, 3);
      expect(m.total, 2);
      expect(m.recorded, 700);
    });

    test('naya schema: due_followups table fresh install mein hai', () async {
      final db = await AppDatabase.instance.database;
      final t = await db.rawQuery("SELECT name FROM sqlite_master WHERE type='table' AND name='due_followups'");
      expect(t, isNotEmpty);
    });
  });

  group('planCollection', () {
    DueBill b(String id, int created, double total, {double paid = 0}) => DueBill(
        id: id, partyId: 1, partyName: 'Ali', partyPhone: '0300', total: total, paid: paid,
        dueDate: 0, createdAt: created, isSale: true);

    test('purane bill se shuru, phir previous balance, phir advance', () {
      final bills = [b('B', 2, 500), b('A', 1, 1000, paid: 400)]; // A baqi 600
      final open = openBillsForCollection(bills);
      expect(open.map((x) => x.id), ['A', 'B']);
      final p = planCollection(amount: 1300, bills: open, previousBalance: 100);
      expect(p.shares.map((s) => s.billRef), ['A', 'B']);
      expect(p.shares[0].amount, 600);
      expect(p.shares[0].clearsBill, true);
      expect(p.shares[1].amount, 500);
      expect(p.toPreviousBalance, 100);
      expect(p.advance, 100);
      expect(p.remainingAfter, 0);
    });

    test('kam raqam: pehla bill adha, baqi kuch nahi', () {
      final open = [b('A', 1, 1000), b('B', 2, 500)];
      final p = planCollection(amount: 300, bills: open);
      expect(p.shares.length, 1);
      expect(p.shares.first.clearsBill, false);
      expect(p.remainingAfter, 1200);
    });
  });

  group('bina-date receivable', () {
    DueParty undated(int createdDay) => DueParty(
        partyId: 1, partyName: 'Ali', partyPhone: '0300', isSale: true,
        bills: [DueBill(id: 'INV-9', partyId: 1, partyName: 'Ali', partyPhone: '0300', total: 800, paid: 0,
            dueDate: 0, createdAt: day(createdDay), isSale: true)]);

    test('7+ din purana bina-date bill late hai, taza nahi', () {
      final st = followUpState(const [], nowMillis: now);
      expect(classifyCollection(undated(5), st, nowMillis: now).late, true); // 10 din
      expect(classifyCollection(undated(12), st, nowMillis: now).late, false); // 3 din
      expect(undated(5).oldestAgeDays(nowMillis: now), 10);
      expect(undated(12).oldestAgeDays(nowMillis: now), 0);
    });
  });
}
