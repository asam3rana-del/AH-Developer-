import 'dart:async';

import '../models/party.dart';
import 'app_database.dart';

class CustomerRepository {
  CustomerRepository._();
  static final CustomerRepository instance = CustomerRepository._();

  final _controller = StreamController<List<Customer>>.broadcast();
  bool _primed = false;

  Stream<List<Customer>> watchAll() {
    if (!_primed) {
      _primed = true;
      _notify();
    }
    return _controller.stream;
  }

  Future<void> _notify() async {
    final rows = await listAll();
    if (!_controller.isClosed) _controller.add(rows);
  }

  /// Call after a direct SQL write to `customers` outside this class (e.g. a
  /// sale transaction updating balance) so listeners refresh.
  Future<void> refresh() => _notify();

  Future<List<Customer>> listAll() async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query('customers', orderBy: 'name COLLATE NOCASE ASC');
    return rows.map(Customer.fromMap).toList();
  }

  /// Mirrors `insert(c: Customer): Long` — returns the new row id.
  Future<int> insert(Customer customer) async {
    final db = await AppDatabase.instance.database;
    final id = await db.insert('customers', customer.toMap()..remove('id'));
    await _notify();
    return id;
  }

  /// Mirrors `addBalance(id, delta)` — positive delta increases what the
  /// customer owes (credit sale / due), negative reduces it (payment
  /// received / reversal on edit).
  Future<void> addBalance(int id, double delta) async {
    final db = await AppDatabase.instance.database;
    await db.rawUpdate(
      'UPDATE customers SET balance = balance + ?, dirty = 1 WHERE id = ?',
      [delta, id],
    );
    await _notify();
  }
}
