import 'package:sqflite/sqflite.dart';

import 'device_tag.dart';
import 'sync_push_plan.dart';

/// Kotlin `push()` ke `increment_*` branch ka `seedFields`: naye server doc ko is device ke local
/// record ki pehchan (naam, phone...) ke saath banane ke liye.
///
/// FIX (Kotlin): `serverId` column purana/khali ho to lookup chook jata tha aur doc bina naam ka ban
/// jata tha. Ab pehle serverId se dhoondte hain, warna entityId "customer:<tag>-<id>" se local id nikal
/// kar (is device ki apni IDs hamesha isi shakl ki hoti hain), aur mil jaye to local row ka serverId
/// theek bhi kar dete hain.
Future<Map<String, Object?>> loadSeedFields(
  DatabaseExecutor db, {
  required String entityType,
  required String entityId,
  String? deviceTag,
}) async {
  final tag = deviceTag ?? DeviceTag.current;
  switch (entityType) {
    case 'customer':
      final row = await _findParty(db, 'customers', 'customer:', entityId, tag);
      if (row == null) return {};
      return {
        'name': row['name'],
        'phone': row['phone'],
        'creditLimit': row['creditLimit'],
        'openingBalance': row['openingBalance'],
        'stuckBalance': row['stuckBalance'],
      };
    case 'supplier':
      final row = await _findParty(db, 'suppliers', 'supplier:', entityId, tag);
      if (row == null) return {};
      return {
        'name': row['name'],
        'phone': row['phone'],
        'openingBalance': row['openingBalance'],
      };
    case 'product':
      final rows = await db.query('products', where: 'barcode = ?', whereArgs: [entityId], limit: 1);
      if (rows.isEmpty) return {};
      final p = rows.first;
      return {
        'name': p['name'],
        'category': p['category'],
        'cost': p['cost'],
        'salePrice': p['salePrice'],
        'wholesalePrice': p['wholesalePrice'],
        'shopkeeperPrice': p['shopkeeperPrice'] ?? 0,
        'reorderLevel': p['reorderLevel'],
        'expiry': p['expiry'],
        'unit': p['unit'],
        'unitSize': p['unitSize'],
        'unitNote': p['unitNote'],
        'secondaryUnit': p['secondaryUnit'],
        'secondaryUnitQty': p['secondaryUnitQty'],
        'tertiaryUnit': p['tertiaryUnit'],
        'tertiaryUnitQty': p['tertiaryUnitQty'],
        'defaultUnitIndex': p['defaultUnitIndex'],
        'quickSaleDefaultUnitIndex': p['quickSaleDefaultUnitIndex'],
        'searchTag': p['searchTag'],
      };
    default:
      return {};
  }
}

Future<Map<String, Object?>?> _findParty(
  DatabaseExecutor db,
  String table,
  String prefix,
  String entityId,
  String tag,
) async {
  var rows = await db.query(table, where: 'serverId = ?', whereArgs: [entityId], limit: 1);
  if (rows.isNotEmpty) return rows.first;
  final localId = localIdFromOwnEntityId(entityId, prefix, tag);
  if (localId == null) return null;
  rows = await db.query(table, where: 'id = ?', whereArgs: [localId], limit: 1);
  if (rows.isEmpty) return null;
  final row = rows.first;
  if (row['serverId'] != entityId) {
    await db.update(table, {'serverId': entityId}, where: 'id = ?', whereArgs: [localId]);
  }
  return row;
}
