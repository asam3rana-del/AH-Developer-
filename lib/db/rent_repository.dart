import 'package:sqflite/sqflite.dart' show ConflictAlgorithm;

import 'app_database.dart';
import 'customer_repository.dart';
import '../models/sale.dart';
import '../services/session.dart';
import '../sync/sync_queue_helper.dart';

/// Daily Rent: kisi customer se roz ka fixed rent (jaise Rs 150) jo roz uske Daily Bill / balance mein
/// judta hai. Saal mein 1-2 din chhutti hoti hai — us din ka rent hata diya jata hai.
///
/// Tareeqa: har din ka rent ek AAM sale bill hai (invoice `RENT-yyyyMMdd-<customerId>`, items nahi,
/// paid 0) — is liye customer balance, Statement, Party Reports, Daily Bill aur sync mein khud sahi aata hai.
/// Chhutti = us bill ko 'returned' kar dena (balance wapas, report se bahar) — bill maujood rehta hai
/// to dobara ban kar rent wapas nahi judta.
///
/// Maths PURE functions mein hai ([rentInvoice], [missingRentDays]) taake bina DB ke test ho sake.

const rentInvoicePrefix = 'RENT-';

bool isRentInvoice(String invoice) => invoice.startsWith(rentInvoicePrefix);

String _two(int v) => v.toString().padLeft(2, '0');

/// `RENT-20261012-5` (din + customer id) — ek din, ek customer = ek hi bill (dobara na bane).
String rentInvoice(int customerId, DateTime day) => '$rentInvoicePrefix${day.year}${_two(day.month)}${_two(day.day)}-$customerId';

/// [start] se [today] tak (dono shamil) wo din jin ka rent bill abhi bana nahi ([existing] invoices mein nahi).
/// Returned (chhutti) bill bhi [existing] mein gina jata hai — is liye chhutti wala din dobara nahi banta.
List<DateTime> missingRentDays({
  required DateTime start,
  required DateTime today,
  required int customerId,
  required Set<String> existing,
}) {
  final out = <DateTime>[];
  var d = DateTime(start.year, start.month, start.day);
  final last = DateTime(today.year, today.month, today.day);
  while (!d.isAfter(last)) {
    if (!existing.contains(rentInvoice(customerId, d))) out.add(d);
    d = DateTime(d.year, d.month, d.day + 1);
  }
  return out;
}

class RentConfig {
  final int customerId;
  final String name;
  final double dailyRent;
  final int startDay; // millis, din ki shuruaat
  const RentConfig({required this.customerId, required this.name, required this.dailyRent, required this.startDay});
}

class RentRepository {
  RentRepository._();
  static final RentRepository instance = RentRepository._();

  void _requireStaff() {
    if (!Session.isAdminOrManager) throw StateError('Only Admin/Manager can manage daily rent');
  }

  /// Jin customers ka daily rent laga hai.
  Future<List<RentConfig>> listConfigs() async {
    final db = await AppDatabase.instance.database;
    final rows = await db.rawQuery(
      'SELECT r.customerId AS customerId, c.name AS name, r.dailyRent AS dailyRent, r.startDay AS startDay '
      'FROM customer_rent r JOIN customers c ON c.id = r.customerId ORDER BY c.name COLLATE NOCASE ASC',
    );
    return [
      for (final r in rows)
        RentConfig(
          customerId: (r['customerId'] as num).toInt(),
          name: (r['name'] as String?) ?? '',
          dailyRent: (r['dailyRent'] as num).toDouble(),
          startDay: (r['startDay'] as num).toInt(),
        ),
    ];
  }

  /// Rent lagayen / badlen. Badla hua rent sirf AAGE ke dinon par lagta hai; ban chuke bills nahi badalte.
  Future<void> setConfig({required int customerId, required double dailyRent, required DateTime startDay}) async {
    _requireStaff();
    if (!dailyRent.isFinite || dailyRent <= 0) throw ArgumentError('Rent 0 se zyada hona chahiye');
    final db = await AppDatabase.instance.database;
    final s = DateTime(startDay.year, startDay.month, startDay.day).millisecondsSinceEpoch;
    await db.insert('customer_rent', {'customerId': customerId, 'dailyRent': dailyRent, 'startDay': s},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Rent band: aage se bill nahi banenge. Purane bills / balance jaise hain waise rehte hain.
  Future<void> removeConfig(int customerId) async {
    _requireStaff();
    final db = await AppDatabase.instance.database;
    await db.delete('customer_rent', where: 'customerId = ?', whereArgs: [customerId]);
  }

  /// Har rent customer ke liye [today] tak ke jo din ke bills nahi bane, bana do (roz pehli baar kholne par
  /// ya kai din app band rehne par bhi poore din bhar jate hain). Kitne bills bane wo lautata hai.
  Future<int> ensureRentUpTo(DateTime today) async {
    final db = await AppDatabase.instance.database;
    final configs = await db.query('customer_rent');
    if (configs.isEmpty) return 0;
    var created = 0;
    await db.transaction((txn) async {
      for (final c in configs) {
        final cid = (c['customerId'] as num).toInt();
        final rent = (c['dailyRent'] as num).toDouble();
        final start = DateTime.fromMillisecondsSinceEpoch((c['startDay'] as num).toInt());
        final cust = await txn.query('customers', columns: ['id'], where: 'id = ?', whereArgs: [cid], limit: 1);
        if (cust.isEmpty) continue; // customer delete ho gaya
        final existingRows = await txn.query('sales',
            columns: ['invoice'], where: 'invoice LIKE ?', whereArgs: ['$rentInvoicePrefix%-$cid']);
        final existing = {for (final r in existingRows) r['invoice'] as String};
        final days = missingRentDays(start: start, today: today, customerId: cid, existing: existing);
        for (final d in days) {
          final now = DateTime.now().millisecondsSinceEpoch;
          final invoice = rentInvoice(cid, d);
          final sale = Sale(
            invoice: invoice,
            customerId: cid,
            subtotal: rent,
            discount: 0.0,
            tax: 0.0,
            total: rent,
            paid: 0.0,
            paymentMethod: 'credit',
            saleType: 'retail',
            createdAt: DateTime(d.year, d.month, d.day, 0, 0, 1).millisecondsSinceEpoch,
            status: 'active',
            updatedAt: now,
          );
          await txn.insert('sales', sale.toMap());
          await txn.rawUpdate(
            'UPDATE customers SET balance = balance + ?, dirty = 1, updatedAt = ? WHERE id = ?',
            [rent, now, cid],
          );
          await SyncQueueHelper.enqueueBalanceDelta(txn, customer: true, partyId: cid, delta: rent);
          await SyncQueueHelper.enqueueLegacy(txn, 'sale', invoice, 'create', {
            'invoice': invoice,
            'customerId': cid,
            'total': rent,
            'paid': 0.0,
            'itemCount': 0,
          });
          created++;
        }
      }
    });
    if (created > 0) await CustomerRepository.instance.refresh();
    return created;
  }

  /// Chhutti: [invoice] wale rent bill ko hata do ([off] true) ya wapas lagao ([off] false).
  /// Balance usi hisaab se wapas / dobara judta hai aur dusre device par sync hota hai.
  Future<void> setRentBillOff(String invoice, {required bool off}) async {
    _requireStaff();
    if (!isRentInvoice(invoice)) throw ArgumentError('Ye rent bill nahi hai');
    final db = await AppDatabase.instance.database;
    await db.transaction((txn) async {
      final rows = await txn.query('sales', where: 'invoice = ?', whereArgs: [invoice], limit: 1);
      if (rows.isEmpty) throw ArgumentError('Rent bill nahi mila');
      final sale = Sale.fromMap(rows.first);
      final isOff = sale.status == 'returned';
      if (isOff == off) return; // pehle se isi halat mein
      final now = DateTime.now().millisecondsSinceEpoch;
      final delta = off ? -sale.total : sale.total;
      if (sale.customerId != null) {
        await txn.rawUpdate(
          'UPDATE customers SET balance = balance + ?, dirty = 1, updatedAt = ? WHERE id = ?',
          [delta, now, sale.customerId],
        );
        await SyncQueueHelper.enqueueBalanceDelta(txn, customer: true, partyId: sale.customerId!, delta: delta);
      }
      final status = off ? 'returned' : 'active';
      await txn.update('sales', {'status': status, 'updatedAt': now, 'dirty': 1},
          where: 'invoice = ?', whereArgs: [invoice]);
      await SyncQueueHelper.enqueueLegacy(txn, 'sale', invoice, 'update', {
        'invoice': invoice,
        'customerId': sale.customerId,
        'total': sale.total,
        'paid': sale.paid,
        'status': status,
      });
    });
    await CustomerRepository.instance.refresh();
  }

  /// Is din (sab rent customers ka) rent chhutti: har rent bill [off] karo. Kitne bills badle wo lautata hai.
  Future<int> setDayOff(DateTime day, {required bool off}) async {
    _requireStaff();
    final db = await AppDatabase.instance.database;
    final ids = (await db.query('customer_rent', columns: ['customerId']))
        .map((r) => (r['customerId'] as num).toInt())
        .toList();
    var n = 0;
    for (final cid in ids) {
      final invoice = rentInvoice(cid, day);
      final rows = await db.query('sales', columns: ['status'], where: 'invoice = ?', whereArgs: [invoice], limit: 1);
      if (rows.isEmpty) continue;
      if ((rows.first['status'] == 'returned') == off) continue;
      await setRentBillOff(invoice, off: off);
      n++;
    }
    return n;
  }
}
