import 'dart:convert';

import 'package:sqflite/sqflite.dart';

/// Phase 13 (maintenance tools) ke liye sync_queue helpers — Kotlin `SyncQueueHelper.enqueue*` jaisa.
/// Hamesha usi transaction ke [DatabaseExecutor] par chalayein jis mein data badla ho.
Future<void> enqueueSync(
  DatabaseExecutor db,
  String type,
  String id,
  String op,
  Map<String, Object?> payload,
) =>
    db.insert('sync_queue', {
      'entityType': type,
      'entityId': id,
      'operation': op,
      'payloadJson': jsonEncode(payload),
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'retryCount': 0,
    });

/// Har barcode ki (rename/update ke BAAD wali) taaza row dobara sync_queue mein.
/// Kotlin: `touchedBarcodes.forEach { dao.find(it)?.let { p -> enqueueProduct(db, p) } }`.
Future<void> enqueueProductUpdates(DatabaseExecutor db, Iterable<String> barcodes) async {
  for (final b in barcodes) {
    final rows = await db.query('products', where: 'barcode=?', whereArgs: [b], limit: 1);
    if (rows.isNotEmpty) {
      await enqueueSync(db, 'product', b, 'update', Map<String, Object?>.from(rows.first));
    }
  }
}

/// Audit row — fail ho to save nahi rukta (baqi repositories jaisa).
Future<void> logMaintenanceAudit(
  DatabaseExecutor db, {
  required String username,
  required String action,
  required String reference,
  required String details,
}) async {
  try {
    await db.insert('audit', {
      'username': username,
      'action': action,
      'reference': reference,
      'details': details,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
    });
  } catch (_) {
    // Audit ki wajah se maintenance kaam fail nahi hona chahiye.
  }
}
