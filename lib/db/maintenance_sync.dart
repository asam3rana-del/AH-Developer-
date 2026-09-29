import 'package:sqflite/sqflite.dart';

import '../sync/sync_queue_helper.dart';

/// Phase 13 (maintenance tools) ke liye sync_queue helpers — Kotlin `SyncQueueHelper.enqueue*` jaisa.
/// Hamesha usi transaction ke [DatabaseExecutor] par chalayein jis mein data badla ho.
Future<void> enqueueSync(
  DatabaseExecutor db,
  String type,
  String id,
  String op,
  Map<String, Object?> payload,
) =>
    SyncQueueHelper.enqueueLegacy(db, type, id, op, payload);

/// Har barcode ki (rename/update ke BAAD wali) taaza row dobara sync_queue mein.
/// Kotlin: `touchedBarcodes.forEach { dao.find(it)?.let { p -> enqueueProduct(db, p) } }`.
Future<void> enqueueProductUpdates(DatabaseExecutor db, Iterable<String> barcodes) async {
  for (final b in barcodes) {
    await SyncQueueHelper.enqueueProduct(db, b);
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
