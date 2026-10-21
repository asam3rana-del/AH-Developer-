import '../models/misc_entities.dart';
import '../services/session.dart';
import '../sync/sync_queue_helper.dart';
import 'app_database.dart';
import 'expense_repository.dart';

/// Workers: hazri/chhutti, advance aur mahine ki salary.
///
/// - Salary do tarah ki: `monthly` (mahine ki fixed) aur `daily` (roz ki dihaadi).
/// - Hazri ke 4 status: P hazir, A gair-hazir, H aadhi chhutti, L paid chhutti.
/// - Advance dene par Cash/Bank se plain OUT row banti hai (expense nahi — salary mein kat'ti hai).
/// - Salary dene par ek Expense (Salaries/Wages, poori kamai) + cash OUT (sirf net raqam) banta hai,
///   dono ek hi transaction mein, aur sync queue mein. Expense delete karne se cash row bhi hat'ti hai.
///
/// Maths PURE functions mein hai ([attendanceCounts], [computeEarned]) taake bina DB ke test ho sake.

const workerStatuses = <String>['P', 'A', 'H', 'L'];
const workerMonthly = 'monthly';
const workerDaily = 'daily';

String _two(int v) => v.toString().padLeft(2, '0');

/// `2026-10-05`
String workerDayKey(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';

/// `2026-10`
String workerMonthKey(int year, int month) => '$year-${_two(month)}';

int daysInMonth(int year, int month) => DateTime(year, month + 1, 0).day;

class AttendanceCounts {
  final double present;
  final double absent;
  final double half;
  final double paidLeave;
  final int unmarked;
  const AttendanceCounts({
    this.present = 0,
    this.absent = 0,
    this.half = 0,
    this.paidLeave = 0,
    this.unmarked = 0,
  });
}

/// [marks]: din (1..31) -> status. Jo din likha nahi wo `unmarked`.
AttendanceCounts attendanceCounts(Map<int, String> marks, int year, int month) {
  double p = 0, a = 0, h = 0, l = 0;
  var unmarked = 0;
  final n = daysInMonth(year, month);
  for (var d = 1; d <= n; d++) {
    switch (marks[d]) {
      case 'P':
        p++;
      case 'A':
        a++;
      case 'H':
        h++;
      case 'L':
        l++;
      default:
        unmarked++;
    }
  }
  return AttendanceCounts(present: p, absent: a, half: h, paidLeave: l, unmarked: unmarked);
}

class EarnedResult {
  /// Is mahine ki kamai (katauti ke baad).
  final double earned;

  /// Gair-hazri/aadhi chhutti ki katauti (sirf monthly mein).
  final double deduction;

  /// Kitne din ki kamai bani (daily mein) ya kitne din kat'te (monthly mein).
  final double days;
  const EarnedResult({required this.earned, required this.deduction, required this.days});
}

/// Monthly: poori salary − (rate / mahine ke din) × (gair-hazir + aadhe din × 0.5). Jo din likha nahi wo hazir.
/// Daily: rate × (hazir + paid chhutti + aadhe din × 0.5). Jo din likha nahi wo gina nahi jata.
EarnedResult computeEarned({
  required String payType,
  required double rate,
  required int year,
  required int month,
  required AttendanceCounts counts,
}) {
  double round2(double v) => (v * 100).round() / 100;
  if (payType == workerDaily) {
    final days = counts.present + counts.paidLeave + counts.half * 0.5;
    return EarnedResult(earned: round2(rate * days), deduction: 0, days: days);
  }
  final perDay = rate / daysInMonth(year, month);
  final cutDays = counts.absent + counts.half * 0.5;
  var deduction = round2(perDay * cutDays);
  if (deduction > rate) deduction = rate;
  return EarnedResult(earned: round2(rate - deduction), deduction: deduction, days: cutDays);
}

class Worker {
  final int? id;
  final String name;
  final String phone;
  final String payType;
  final double rate;
  final bool active;
  final int createdAt;
  const Worker({
    this.id,
    required this.name,
    this.phone = '',
    this.payType = workerMonthly,
    required this.rate,
    this.active = true,
    this.createdAt = 0,
  });

  bool get isDaily => payType == workerDaily;

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'name': name,
        'phone': phone,
        'payType': payType,
        'rate': rate,
        'active': active ? 1 : 0,
        'createdAt': createdAt,
      };

  factory Worker.fromMap(Map<String, Object?> m) => Worker(
        id: (m['id'] as num?)?.toInt(),
        name: (m['name'] as String?) ?? '',
        phone: (m['phone'] as String?) ?? '',
        payType: (m['payType'] as String?) ?? workerMonthly,
        rate: ((m['rate'] as num?) ?? 0).toDouble(),
        active: ((m['active'] as num?) ?? 1) != 0,
        createdAt: ((m['createdAt'] as num?) ?? 0).toInt(),
      );
}

class WorkerAdvance {
  final int id;
  final int workerId;
  final double amount;
  final String method;
  final String note;
  final int createdAt;
  const WorkerAdvance({
    required this.id,
    required this.workerId,
    required this.amount,
    required this.method,
    required this.note,
    required this.createdAt,
  });

  factory WorkerAdvance.fromMap(Map<String, Object?> m) => WorkerAdvance(
        id: (m['id'] as num).toInt(),
        workerId: (m['workerId'] as num).toInt(),
        amount: (m['amount'] as num).toDouble(),
        method: (m['method'] as String?) ?? 'cash',
        note: (m['note'] as String?) ?? '',
        createdAt: (m['createdAt'] as num).toInt(),
      );
}

class WorkerSalaryPayment {
  final int id;
  final int workerId;
  final String month;
  final double earned;
  final double advanceCut;
  final double net;
  final String method;
  final int? expenseId;
  final int createdAt;
  const WorkerSalaryPayment({
    required this.id,
    required this.workerId,
    required this.month,
    required this.earned,
    required this.advanceCut,
    required this.net,
    required this.method,
    required this.expenseId,
    required this.createdAt,
  });

  factory WorkerSalaryPayment.fromMap(Map<String, Object?> m) => WorkerSalaryPayment(
        id: (m['id'] as num).toInt(),
        workerId: (m['workerId'] as num).toInt(),
        month: (m['month'] as String?) ?? '',
        earned: (m['earned'] as num).toDouble(),
        advanceCut: (m['advanceCut'] as num).toDouble(),
        net: (m['net'] as num).toDouble(),
        method: (m['method'] as String?) ?? 'cash',
        expenseId: (m['expenseId'] as num?)?.toInt(),
        createdAt: (m['createdAt'] as num).toInt(),
      );
}

/// Advance cash row ka reference (delete isi se dhoondta hai). Device-unique (`worker_advance:<tag>-<id>`),
/// bilkul advance ki sync entity id jaisa, taake do devices ke advance #5 aapas mein na takrayen.
String workerAdvanceCashReference(int advanceId, {String? serverId}) =>
    SyncQueueHelper.workerAdvanceEntityId({'id': advanceId, 'serverId': serverId});

/// v23 mein bani purani advance rows ka reference (sync se pehle).
String legacyWorkerAdvanceCashReference(int advanceId) => 'wadv:$advanceId';

class WorkerRepository {
  WorkerRepository._();
  static final WorkerRepository instance = WorkerRepository._();

  void _requireStaff() {
    if (!Session.isAdminOrManager) throw StateError('Only Admin/Manager can manage workers');
  }

  Future<List<Worker>> list({bool activeOnly = false}) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query(
      'workers',
      where: activeOnly ? 'active = 1' : null,
      orderBy: 'active DESC, name COLLATE NOCASE ASC',
    );
    return rows.map(Worker.fromMap).toList();
  }

  /// Naya worker (id null) ya purane ki tabdeeli. Naya id wapas deta hai.
  Future<int> save(Worker w) async {
    _requireStaff();
    final name = w.name.trim();
    if (name.isEmpty) throw ArgumentError('Name is required');
    if (!w.rate.isFinite || w.rate <= 0) throw ArgumentError('Salary/rate must be greater than 0');
    if (w.payType != workerMonthly && w.payType != workerDaily) throw ArgumentError('Invalid pay type');
    final db = await AppDatabase.instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final map = Worker(
      id: w.id,
      name: name,
      phone: w.phone.trim(),
      payType: w.payType,
      rate: w.rate,
      active: w.active,
      createdAt: w.createdAt == 0 ? now : w.createdAt,
    ).toMap()
      ..['updatedAt'] = now;
    return db.transaction((txn) async {
      final int id;
      if (w.id == null) {
        id = await txn.insert('workers', map);
      } else {
        await txn.update('workers', map, where: 'id = ?', whereArgs: [w.id]);
        id = w.id!;
      }
      await SyncQueueHelper.enqueueWorker(txn, id);
      return id;
    });
  }

  // ------------------------------------------------------------ hazri

  /// Is mahine ki hazri: din (1..31) -> status.
  Future<Map<int, String>> monthAttendance(int workerId, int year, int month) async {
    final db = await AppDatabase.instance.database;
    final from = workerDayKey(DateTime(year, month, 1));
    final to = workerDayKey(DateTime(year, month, daysInMonth(year, month)));
    final rows = await db.query(
      'worker_attendance',
      where: 'workerId = ? AND day >= ? AND day <= ?',
      whereArgs: [workerId, from, to],
    );
    final out = <int, String>{};
    for (final r in rows) {
      final day = int.tryParse((r['day'] as String).substring(8, 10));
      if (day != null) out[day] = r['status'] as String;
    }
    return out;
  }

  /// [status] null = nishan hata do. Jis mahine ki salary de di gayi, uski hazri badli nahi ja sakti.
  Future<void> setAttendance(int workerId, DateTime day, String? status) async {
    _requireStaff();
    if (status != null && !workerStatuses.contains(status)) throw ArgumentError('Invalid status');
    final db = await AppDatabase.instance.database;
    if (await isMonthPaid(workerId, day.year, day.month)) {
      throw StateError('Salary for this month is already paid');
    }
    final key = workerDayKey(day);
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      if (status == null) {
        await txn.delete('worker_attendance', where: 'workerId = ? AND day = ?', whereArgs: [workerId, key]);
        await SyncQueueHelper.enqueueWorkerAttendanceDelete(txn, workerId, key);
      } else {
        await txn.rawInsert(
          'INSERT OR REPLACE INTO worker_attendance (workerId, day, status, updatedAt) VALUES (?, ?, ?, ?)',
          [workerId, key, status, now],
        );
        await SyncQueueHelper.enqueueWorkerAttendance(txn, workerId, key);
      }
    });
  }

  /// Mahine ke un dinon ko jo likhe nahi, [upTo] tak (dono shamil) hazir (P) likh do.
  Future<void> markUnmarkedPresent(int workerId, int year, int month, {required DateTime upTo}) async {
    _requireStaff();
    if (await isMonthPaid(workerId, year, month)) throw StateError('Salary for this month is already paid');
    final marks = await monthAttendance(workerId, year, month);
    final db = await AppDatabase.instance.database;
    final last = daysInMonth(year, month);
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      for (var d = 1; d <= last; d++) {
        final date = DateTime(year, month, d);
        if (date.isAfter(upTo)) break;
        if (marks.containsKey(d)) continue;
        final key = workerDayKey(date);
        await txn.rawInsert(
          'INSERT OR REPLACE INTO worker_attendance (workerId, day, status, updatedAt) VALUES (?, ?, ?, ?)',
          [workerId, key, 'P', now],
        );
        await SyncQueueHelper.enqueueWorkerAttendance(txn, workerId, key);
      }
    });
  }

  // ---------------------------------------------------------- advance

  Future<double> advanceBalance(int workerId) async {
    final db = await AppDatabase.instance.database;
    final a = await db.rawQuery('SELECT COALESCE(SUM(amount),0) AS t FROM worker_advances WHERE workerId = ?', [workerId]);
    final c = await db.rawQuery(
        'SELECT COALESCE(SUM(advanceCut),0) AS t FROM worker_salary_payments WHERE workerId = ?', [workerId]);
    final bal = (a.first['t'] as num).toDouble() - (c.first['t'] as num).toDouble();
    return bal < 0 ? 0 : (bal * 100).round() / 100;
  }

  /// Sab workers ka baqi advance: workerId -> raqam.
  Future<Map<int, double>> allAdvanceBalances() async {
    final db = await AppDatabase.instance.database;
    final out = <int, double>{};
    for (final r in await db.rawQuery('SELECT workerId, SUM(amount) AS t FROM worker_advances GROUP BY workerId')) {
      out[(r['workerId'] as num).toInt()] = (r['t'] as num).toDouble();
    }
    for (final r in await db.rawQuery('SELECT workerId, SUM(advanceCut) AS t FROM worker_salary_payments GROUP BY workerId')) {
      final id = (r['workerId'] as num).toInt();
      out[id] = (out[id] ?? 0) - (r['t'] as num).toDouble();
    }
    out.updateAll((_, v) => v < 0 ? 0 : v);
    return out;
  }

  Future<List<WorkerAdvance>> advances(int workerId) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query('worker_advances',
        where: 'workerId = ?', whereArgs: [workerId], orderBy: 'createdAt DESC, id DESC');
    return rows.map(WorkerAdvance.fromMap).toList();
  }

  /// Advance do: worker ke naam par advance + Cash/Bank se OUT row (expense nahi), ek transaction mein.
  Future<void> addAdvance({
    required int workerId,
    required String workerName,
    required double amount,
    required String method,
    String note = '',
  }) async {
    _requireStaff();
    if (method != 'cash' && method != 'bank') throw ArgumentError('method must be cash or bank');
    if (!amount.isFinite || amount <= 0) throw ArgumentError('Amount must be greater than 0');
    final db = await AppDatabase.instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      final id = await txn.insert('worker_advances', {
        'workerId': workerId,
        'amount': amount,
        'method': method,
        'note': note.trim(),
        'createdAt': now,
        'updatedAt': now,
      });
      final cash = CashTransaction(
        type: 'OUT',
        method: method,
        amount: amount,
        reason: 'Worker Advance: $workerName',
        reference: workerAdvanceCashReference(id),
        createdAt: now,
        updatedAt: now,
      );
      final cashId = await txn.insert('cash_transactions', cash.toMap());
      await SyncQueueHelper.enqueueLegacy(txn, 'cash_transaction', '$cashId', 'create', {...cash.toMap(), 'id': cashId});
      await SyncQueueHelper.enqueueWorkerAdvance(txn, id);
    });
  }

  /// Advance hatao (galti se likha gaya). Agar wo pehle hi salary mein kat chuka ho to nahi hatega.
  Future<void> deleteAdvance(WorkerAdvance a) async {
    _requireStaff();
    final balance = await advanceBalance(a.workerId);
    if (balance + 0.005 < a.amount) {
      throw StateError('This advance is already deducted from a salary');
    }
    final db = await AppDatabase.instance.database;
    await db.transaction((txn) async {
      // Entity id row delete se PEHLE (doosre device se aayi advance ki asal serverId na khoye).
      final eid = await SyncQueueHelper.entityIdFor(txn, 'worker_advance', '${a.id}');
      await txn.delete('worker_advances', where: 'id = ?', whereArgs: [a.id]);
      await SyncQueueHelper.enqueueDelete(txn, 'worker_advance', eid);
      await SyncQueueHelper.deleteCashTransactionsByReference(txn, eid);
      await SyncQueueHelper.deleteCashTransactionsByReference(txn, legacyWorkerAdvanceCashReference(a.id));
    });
  }

  // ----------------------------------------------------------- salary

  Future<bool> isMonthPaid(int workerId, int year, int month) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query('worker_salary_payments',
        where: 'workerId = ? AND month = ?', whereArgs: [workerId, workerMonthKey(year, month)], limit: 1);
    return rows.isNotEmpty;
  }

  Future<List<WorkerSalaryPayment>> payments(int workerId) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query('worker_salary_payments',
        where: 'workerId = ?', whereArgs: [workerId], orderBy: 'month DESC');
    return rows.map(WorkerSalaryPayment.fromMap).toList();
  }

  /// Mahine ki salary do. [earned] screen ka hisaab hai; yahan dobara [computeEarned] se jaancha jata hai
  /// taake purani/ghalat raqam na likhi jaye. [advanceCut] baqi advance se zyada ya kamai se zyada nahi ho sakta.
  Future<void> paySalary({
    required Worker worker,
    required int year,
    required int month,
    required double advanceCut,
    required String method,
  }) async {
    _requireStaff();
    final id = worker.id;
    if (id == null) throw ArgumentError('Worker not saved');
    if (method != 'cash' && method != 'bank') throw ArgumentError('method must be cash or bank');
    if (!advanceCut.isFinite || advanceCut < 0) throw ArgumentError('Invalid advance deduction');
    if (await isMonthPaid(id, year, month)) throw StateError('Salary for this month is already paid');

    final marks = await monthAttendance(id, year, month);
    final calc = computeEarned(
      payType: worker.payType,
      rate: worker.rate,
      year: year,
      month: month,
      counts: attendanceCounts(marks, year, month),
    );
    final earned = calc.earned;
    if (earned <= 0) throw StateError('Nothing earned for this month');
    final balance = await advanceBalance(id);
    if (advanceCut > balance + 0.005) throw ArgumentError('Advance deduction is more than the balance');
    if (advanceCut > earned + 0.005) throw ArgumentError('Advance deduction is more than the earned salary');
    final net = ((earned - advanceCut) * 100).round() / 100;

    final monthKey = workerMonthKey(year, month);
    final category = worker.isDaily ? 'Wages' : 'Salaries';
    final description = '${worker.name} | $monthKey';
    final db = await AppDatabase.instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      final expense = Expense(
        category: category,
        description: description,
        amount: earned,
        method: method,
        createdAt: now,
        updatedAt: now,
      );
      final expenseId = await txn.insert('expenses', expense.toMap());
      await SyncQueueHelper.enqueueLegacy(txn, 'expense', '$expenseId', 'create', {...expense.toMap(), 'id': expenseId});

      if (net > 0) {
        final cash = CashTransaction(
          type: 'OUT',
          method: method,
          amount: net,
          reason: expenseCashReason(category),
          reference: expenseCashReference(expenseId),
          createdAt: now,
          updatedAt: now,
        );
        final cashId = await txn.insert('cash_transactions', cash.toMap());
        await SyncQueueHelper.enqueueLegacy(txn, 'cash_transaction', '$cashId', 'create', {...cash.toMap(), 'id': cashId});
      }

      final paymentId = await txn.insert('worker_salary_payments', {
        'workerId': id,
        'month': monthKey,
        'earned': earned,
        'advanceCut': advanceCut,
        'net': net,
        'method': method,
        'expenseId': expenseId,
        'expenseServerId': expenseCashReference(expenseId),
        'createdAt': now,
        'updatedAt': now,
      });
      await SyncQueueHelper.enqueueWorkerSalaryPayment(txn, paymentId);
    });
  }

  /// Salary wapas: expense + uska cash OUT hat'te hain, advance wapas baqi mein aa jata hai, hazri dobara badli ja sakti hai.
  Future<void> deletePayment(WorkerSalaryPayment p) async {
    _requireStaff();
    final db = await AppDatabase.instance.database;
    // Expense dhoondo: local id se, warna (doosre device se aayi salary) serverId se.
    List<Map<String, Object?>> rows = const [];
    if (p.expenseId != null) {
      rows = await db.query('expenses', where: 'id = ?', whereArgs: [p.expenseId], limit: 1);
    }
    if (rows.isEmpty) {
      final pr = await db.query('worker_salary_payments',
          columns: ['expenseServerId'], where: 'id = ?', whereArgs: [p.id], limit: 1);
      final sid = pr.isEmpty ? null : pr.first['expenseServerId'];
      if (sid is String && sid.isNotEmpty) {
        rows = await db.query('expenses', where: 'serverId = ?', whereArgs: [sid], limit: 1);
      }
    }
    if (rows.isNotEmpty) await ExpenseRepository.instance.delete(Expense.fromMap(rows.first));
    await db.transaction((txn) async {
      final eid = await SyncQueueHelper.entityIdFor(txn, 'worker_salary_payment', '${p.id}');
      await txn.delete('worker_salary_payments', where: 'id = ?', whereArgs: [p.id]);
      await SyncQueueHelper.enqueueDelete(txn, 'worker_salary_payment', eid);
    });
  }
}
