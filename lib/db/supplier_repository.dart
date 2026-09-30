import 'dart:async';

import '../models/party.dart';
import 'app_database.dart';

class SupplierRepository {
  SupplierRepository._();
  static final SupplierRepository instance = SupplierRepository._();

  final _controller = StreamController<List<Supplier>>.broadcast();

  /// Har naya subscriber ko PEHLE current list milti hai, phir live updates.
  /// (Pehle sirf pehli dafa emit hota tha — screen dobara khulti to list khali rehti
  /// aur supplier ka naam search mein nahi aata tha.)
  Stream<List<Supplier>> watchAll() async* {
    yield await listAll();
    yield* _controller.stream;
  }

  Future<void> _notify() async {
    final rows = await listAll();
    if (!_controller.isClosed) _controller.add(rows);
  }

  /// Call after a direct SQL write to `suppliers` outside this class (e.g.
  /// a purchase transaction updating balance) so listeners refresh.
  Future<void> refresh() => _notify();

  Future<List<Supplier>> listAll() async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query('suppliers', orderBy: 'name COLLATE NOCASE ASC');
    return rows.map(Supplier.fromMap).toList();
  }

  /// Mirrors `insert(s: Supplier): Long` — returns the new row id.
  Future<int> insert(Supplier supplier) async {
    final db = await AppDatabase.instance.database;
    final id = await db.insert('suppliers', supplier.toMap()..remove('id'));
    await _notify();
    return id;
  }

  /// Mirrors `addBalance(id, delta)` — positive delta increases what the
  /// business owes the supplier (credit purchase), negative reduces it
  /// (payment made / reversal on edit).
  Future<void> addBalance(int id, double delta) async {
    final db = await AppDatabase.instance.database;
    await db.rawUpdate(
      'UPDATE suppliers SET balance = balance + ?, dirty = 1 WHERE id = ?',
      [delta, id],
    );
    await _notify();
  }
}
