import 'dart:convert';

/// SyncApi.push ka SAAF (Firestore ke baghair) hissa — Kotlin `SyncApi.push()` ke faisle, taake unhein
/// bina Firebase ke test kiya ja sake. Firestore se asli baat `sync_api.dart` mein hoti hai.

/// Kotlin `Long.MIN_VALUE` — server doc par `updatedAt` na ho to.
const int kLongMin = -0x7fffffffffffffff - 1;

/// `entityType` -> Firestore collection (Kotlin `when (entry.entityType)`). Anjaan type => null
/// (push false lauta deta hai, audit ke baghair).
const Map<String, String> pushCollections = {
  'customer': 'customers',
  'supplier': 'suppliers',
  'product': 'products',
  'user': 'users',
  'sale': 'sales',
  'purchase': 'purchases',
  'payment': 'payments',
  'expense': 'expenses',
  'cash_transaction': 'cash_transactions',
  'unit': 'units',
  'category': 'categories',
  'zakat_year': 'zakat_years',
  'zakat_payment': 'zakat_payments',
  'return': 'returns',
  'stock_movement': 'stock_movements',
  'app_setting': 'app_settings',
  'cash_register': 'cash_register',
  'shell_customer': 'shell_customers',
  'shell_transaction': 'shell_transactions',
  'shop_empty_shell_log': 'shop_empty_shell_log',
};

String? collectionFor(String entityType) => pushCollections[entityType];

/// increment ops jinhein transaction + appliedOps (idempotent) se guzarna hai.
bool isIncrementOp(String operation) =>
    operation == 'increment_stock' || operation == 'increment_balance';

/// `increment_stock` => 'stock', warna 'balance'.
String incrementFieldFor(String operation) => operation == 'increment_stock' ? 'stock' : 'balance';

/// Firestore ka number (int/double) -> int; warna null.
int? asMillis(Object? v) => v is num ? v.toInt() : null;

/// payloadJson -> Map (Kotlin `gson.fromJson(json, Map::class.java)`).
Map<String, Object?> decodePayload(String json) {
  final v = jsonDecode(json);
  if (v is! Map) throw FormatException('payloadJson object nahi hai');
  return Map<String, Object?>.from(v);
}

/// Har increment entry ka yaktaa id: "<deviceTag>-<queueId>-<createdAt>" (retry par dobara na lage).
String buildOpId(String deviceTag, int? entryId, int createdAt) => '$deviceTag-$entryId-$createdAt';

/// Kotlin FIX (upsert/create_if_absent): payload par HAMESHA maujooda branch code aur `updatedAt`
/// (payload ka, warna `nowMs`) — purani/ghalat branch wali stuck entries khud theek ho jati hain.
class StampedPayload {
  final Map<String, Object?> map;
  final int incomingUpdatedAt;
  const StampedPayload(this.map, this.incomingUpdatedAt);
}

StampedPayload stampPayload(Map<String, Object?> raw, String branchId, int nowMs) {
  final incoming = asMillis(raw['updatedAt']) ?? nowMs;
  return StampedPayload({...raw, 'branchId': branchId, 'updatedAt': incoming}, incoming);
}

/// Last-write-wins: der se aane wali (offline) entry naye cloud edit ko overwrite nahi karti.
bool shouldApplyUpsert(int incomingUpdatedAt, int? serverUpdatedAt) =>
    incomingUpdatedAt >= (serverUpdatedAt ?? kLongMin);

/// Delete bhi wohi: purana delete naye cloud record ko nahi mitata.
bool shouldApplyDelete(int deleteAt, int? serverUpdatedAt) =>
    deleteAt >= (serverUpdatedAt ?? kLongMin);

/// Hard delete nahi — timestamped tombstone (doosre devices pull mein dekh saken).
Map<String, Object?> tombstone(String entityId, int deleteAt, String branchId) => {
      'serverId': entityId,
      '_deleted': true,
      'updatedAt': deleteAt,
      'branchId': branchId,
    };

/// create_if_absent (cash register): sirf tab likho jab doc na ho ya tombstone ho.
bool canCreateIfAbsent({required bool exists, required Map<String, Object?>? data}) =>
    !(exists && data?['_deleted'] != true);

/// appliedOps ki safai: 30 din se purani hataen, zyada se zyada 999 rakhen (naya milakar 1000),
/// purani pehle nikalti hain; phir `opId` ko `nowTs` ke saath jodein.
Map<String, Object?> pruneAppliedOps(Map<String, Object?> applied, String opId, int nowTs) {
  final cutoff = nowTs - 30 * 24 * 60 * 60 * 1000;
  final entries = applied.entries.where((e) {
    final t = asMillis(e.value);
    return t != null && t >= cutoff;
  }).toList()
    ..sort((a, b) {
      final c = asMillis(a.value)!.compareTo(asMillis(b.value)!);
      return c != 0 ? c : a.key.compareTo(b.key);
    });
  final tail = entries.length > 999 ? entries.sublist(entries.length - 999) : entries;
  final kept = <String, Object?>{for (final e in tail) e.key: e.value};
  kept[opId] = nowTs;
  return kept;
}

/// Transaction ke andar increment ka faisla.
class IncrementPlan {
  /// opId pehle se laga hua => dobara nahi lagana (retry).
  final bool skip;

  /// Jis field par `FieldValue.increment(delta)` lagega ('stock' / 'balance').
  final String incrementField;
  final double delta;

  /// Baqi likhne wali fields (updatedAt, branchId, appliedOps, aur naye doc par serverId/_deleted/seed).
  final Map<String, Object?> otherFields;

  /// `SetOptions(mergeFields: ...)` — incrementField samet.
  final List<String> mergeFields;

  const IncrementPlan({
    required this.skip,
    required this.incrementField,
    required this.delta,
    required this.otherFields,
    required this.mergeFields,
  });
}

/// Kotlin `increment_stock` / `increment_balance` ka transaction body.
///  * `exists`/`data`: transaction mein padha hua server doc.
///  * Naya doc (na ho, ya tombstone) => serverId + (tombstone ho to `_deleted:false`) + seed fields bhi
///    (warna balance/stock wala bina naam ka "ghost" doc ban jata hai).
IncrementPlan planIncrement({
  required bool exists,
  required Map<String, Object?>? data,
  required String operation,
  required double delta,
  required Object updatedAtValue,
  required String branchId,
  required String opId,
  required int nowTs,
  required String entityId,
  required Map<String, Object?> seedFields,
}) {
  final field = incrementFieldFor(operation);
  final rawApplied = data?['appliedOps'];
  final applied = rawApplied is Map ? Map<String, Object?>.from(rawApplied) : <String, Object?>{};
  if (applied.containsKey(opId)) {
    return IncrementPlan(
        skip: true, incrementField: field, delta: delta, otherFields: const {}, mergeFields: const []);
  }
  final kept = pruneAppliedOps(applied, opId, nowTs);
  final wasDeleted = exists && data?['_deleted'] == true;
  final isNew = !exists || wasDeleted;

  final other = <String, Object?>{
    'updatedAt': updatedAtValue,
    'branchId': branchId,
    'appliedOps': kept,
  };
  final merge = <String>[field, 'updatedAt', 'branchId', 'appliedOps'];
  if (isNew) {
    other['serverId'] = entityId;
    merge.add('serverId');
    if (wasDeleted) {
      other['_deleted'] = false;
      merge.add('_deleted');
    }
    seedFields.forEach((k, v) {
      other[k] = v;
      merge.add(k);
    });
  }
  return IncrementPlan(
      skip: false, incrementField: field, delta: delta, otherFields: other, mergeFields: merge);
}

/// Kotlin `localIdFromOwnEntityId`: entityId "<prefix><thisDeviceTag>-<localId>" ho to localId nikalo.
int? localIdFromOwnEntityId(String entityId, String prefix, String deviceTag) {
  final own = '$prefix$deviceTag-';
  if (!entityId.startsWith(own)) return null;
  return int.tryParse(entityId.substring(own.length));
}
