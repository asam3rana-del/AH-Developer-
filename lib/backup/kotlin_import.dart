import 'package:sqflite/sqflite.dart';

import '../db/stock_ledger.dart';

/// Kotlin (Room, `grocery_pos_v11.db`, user_version 48) ke backup ka data Flutter DB mein copy karta hai.
///
/// Kyun zaroori: Kotlin ki DB file seedha Flutter ki file par rakh dene se kaam nahi chalta —
///  * Room ka `user_version` 48 hai, Flutter ka 13 (restore "naye version ka hai" keh kar rok deta tha),
///  * Kotlin mein extra columns hain (`saleUid`, `lineUid`, `purchaseUid`) jo Flutter mein nahi (payments.partyServerId DB v14 se Flutter mein bhi hai, common column ki tarah copy hota hai).
/// Is liye file badalne ki jagah har table ke SIRF wahi columns copy hote hain jo dono mein hain
/// (naam se), baaqi Flutter ke defaults par.
///
/// Rules:
///  * Sab kuch ek transaction mein: koi bhi table / total mismatch => poora rollback, live data waisa hi.
///  * id (customers / suppliers / payments ...) jyon ke tyon copy hoti hain, isliye customerId / partyId /
///    supplierId ke rishte nahi tootte.
///  * Balances, stock, dirty aur serverId JAISE HAIN waise copy — koi "Recalculate Balances" nahi chalta.
///  * `sync_queue` copy NAHI hoti (aur Flutter ki purani queue saaf ho jati hai) taake purana data cloud par
///    dobara push na ho. Behtar hai ke Kotlin app mein backup se pehle ek baar sync kar liya jaye.
///  * `held_bills` (adhoora bill) aur device-specific settings (printer, login method) copy nahi hote.
class KotlinBackupImporter {
  KotlinBackupImporter._();

  /// Parents pehle. Sirf yehi tables copy hote hain.
  static const List<String> tables = [
    'units',
    'categories',
    'products',
    'customers',
    'suppliers',
    'users',
    'sales',
    'sale_items',
    'purchases',
    'purchase_items',
    'payments',
    'returns',
    'expenses',
    'cash_transactions',
    'cash_register',
    'app_settings',
    'zakat_years',
    'zakat_payments',
    'zakat_month_plans',
    'shell_customers',
    'shell_transactions',
    'shop_empty_shell_log',
    'stock_movements',
    'audit',
  ];

  /// Device-specific settings — dusre phone par copy karna nuqsan-deh hai.
  static const Set<String> _skipSettingKeys = {
    'printer_name',
    'printer_mac',
    'printer_width',
    'printer_dots',
    'login_method',
    'last_username',
  };

  /// (table, column) — copy ke baad source aur destination ka jama barabar hona chahiye.
  static const List<List<String>> _sumChecks = [
    ['customers', 'balance'],
    ['customers', 'openingBalance'],
    ['customers', 'stuckBalance'],
    ['suppliers', 'balance'],
    ['suppliers', 'openingBalance'],
    ['products', 'stock'],
    ['sales', 'total'],
    ['sales', 'paid'],
    ['purchases', 'total'],
    ['purchases', 'paid'],
    ['payments', 'amount'],
    ['cash_transactions', 'amount'],
    ['expenses', 'amount'],
  ];

  /// Kotlin/Room ka DB hai? Teen nishaniyan (koi ek kafi): `room_master_table`, ya Kotlin-only column
  /// (`sales.saleUid` / `purchases.purchaseUid`), ya `user_version` > 13 (Flutter ka apna max 13 hai).
  static Future<bool> isRoomDatabase(String path) async {
    Database? db;
    try {
      db = await openDatabase(path, readOnly: true, singleInstance: false);
      final t = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='room_master_table'");
      if (t.isNotEmpty) return true;
      for (final c in const [
        ['sales', 'saleUid'],
        ['purchases', 'purchaseUid'],
      ]) {
        final info = await db.rawQuery('PRAGMA table_info(${c[0]})');
        if (info.any((r) => r['name'] == c[1])) return true;
      }
      final ver = Sqflite.firstIntValue(await db.rawQuery('PRAGMA user_version')) ?? 0;
      return ver > 13;
    } catch (_) {
      return false;
    } finally {
      try {
        await db?.close();
      } catch (_) {}
    }
  }

  /// [sourcePath] (decrypt ho chuka Kotlin .db) ka data [live] mein copy karta hai. Purana data replace hota hai.
  static Future<KotlinImportReport> importInto(Database live, String sourcePath) async {
    Database? src;
    try {
      src = await openDatabase(sourcePath, readOnly: true, singleInstance: false);
      final source = src;
      return await live.transaction<KotlinImportReport>((txn) async {
        return _run(txn, source);
      });
    } finally {
      try {
        await src?.close();
      } catch (_) {}
    }
  }

  static Future<KotlinImportReport> _run(Transaction txn, Database src) async {
    // 1) Purana data saaf (children pehle), queue bhi.
    for (final t in tables.reversed) {
      await txn.execute('DELETE FROM $t');
    }
    await txn.execute('DELETE FROM sync_queue');
    await txn.execute(
        "DELETE FROM sqlite_sequence WHERE name IN (${tables.map((_) => '?').join(',')}, 'sync_queue')",
        tables);

    final copied = <String, int>{};
    var srcHasMovements = false;

    // 2) Har table: common columns copy.
    for (final t in tables) {
      final srcInfo = await src.rawQuery('PRAGMA table_info($t)');
      if (srcInfo.isEmpty) continue; // purane Kotlin version mein table nahi
      final srcCols = srcInfo.map((r) => r['name'] as String).toSet();
      final dstInfo = await txn.rawQuery('PRAGMA table_info($t)');

      // (column, notnull, default hai?, numeric type?)
      final plan = <_Col>[];
      for (final r in dstInfo) {
        final type = (r['type'] as String? ?? '').toUpperCase();
        plan.add(_Col(
          name: r['name'] as String,
          fromSource: srcCols.contains(r['name']),
          notNull: (r['notnull'] as int? ?? 0) == 1,
          hasDefault: r['dflt_value'] != null,
          numeric: type.contains('INT') || type.contains('REAL'),
        ));
      }

      const page = 500;
      var offset = 0;
      var n = 0;
      while (true) {
        final rows = await src.rawQuery('SELECT * FROM $t ORDER BY rowid LIMIT $page OFFSET $offset');
        if (rows.isEmpty) break;
        final batch = txn.batch();
        for (final row in rows) {
          if (t == 'app_settings' && _skipSettingKeys.contains(row['key'])) continue;
          final out = <String, Object?>{};
          for (final c in plan) {
            Object? v = c.fromSource ? row[c.name] : null;
            if (v == null && c.notNull) {
              if (c.hasDefault) continue; // Flutter ka default lagega
              // NOT NULL, default nahi, source mein bhi nahi/NULL — type ka khali maan.
              out[c.name] = c.numeric ? 0 : '';
              continue;
            }
            if (v == null && !c.fromSource) continue;
            out[c.name] = v;
          }
          batch.insert(t, out, conflictAlgorithm: ConflictAlgorithm.abort);
          n++;
        }
        await batch.commit(noResult: true);
        offset += rows.length;
        if (rows.length < page) break;
      }
      copied[t] = n;
      if (t == 'stock_movements' && n > 0) srcHasMovements = true;
    }

    // 3) Defaults hamesha maujood (Flutter onCreate jaisa).
    await txn.execute("INSERT OR IGNORE INTO categories (name) VALUES ('General')");
    await txn.execute("INSERT OR IGNORE INTO units (name) VALUES ('pcs')");

    // 4) Purane Kotlin (stock_movements se pehle) — ledger shuru karo taake ledger == stock.
    if (!srcHasMovements) {
      await StockLedger.backfillOpening(txn);
    }

    // 5) Tasdeeq: row counts + jama. Zara sa bhi farq => exception => rollback.
    for (final t in tables) {
      final srcInfo = await src.rawQuery('PRAGMA table_info($t)');
      if (srcInfo.isEmpty) continue;
      if (t == 'app_settings') continue; // device keys skip hoti hain, count barabar nahi hota
      final a = Sqflite.firstIntValue(await src.rawQuery('SELECT COUNT(*) FROM $t')) ?? 0;
      final b = Sqflite.firstIntValue(await txn.rawQuery('SELECT COUNT(*) FROM $t')) ?? 0;
      if (t == 'stock_movements' && !srcHasMovements) continue; // backfill ne rows banayi hain
      if (t == 'categories' || t == 'units') {
        if (b < a) throw KotlinImportException('$t: $a rows thi, sirf $b copy hui');
        continue;
      }
      if (a != b) throw KotlinImportException('$t: $a rows thi, sirf $b copy hui');
    }
    for (final s in _sumChecks) {
      final t = s[0], c = s[1];
      final srcCols = (await src.rawQuery('PRAGMA table_info($t)')).map((r) => r['name']).toSet();
      if (!srcCols.contains(c)) continue;
      final a = _num((await src.rawQuery('SELECT COALESCE(SUM($c),0) AS s FROM $t')).first['s']);
      final b = _num((await txn.rawQuery('SELECT COALESCE(SUM($c),0) AS s FROM $t')).first['s']);
      if ((a - b).abs() > 0.005) {
        throw KotlinImportException('$t.$c ka jama match nahi hua (Kotlin: $a, Flutter: $b)');
      }
    }

    // 6) Kitni rows abhi cloud par nahi gayi thi (dirty=1)?
    var dirty = 0;
    for (final t in tables) {
      final info = await txn.rawQuery('PRAGMA table_info($t)');
      if (!info.any((r) => r['name'] == 'dirty')) continue;
      dirty += Sqflite.firstIntValue(await txn.rawQuery('SELECT COUNT(*) FROM $t WHERE dirty = 1')) ?? 0;
    }

    return KotlinImportReport(copied: copied, dirtyRows: dirty);
  }

  static double _num(Object? v) => v is num ? v.toDouble() : double.tryParse('$v') ?? 0;
}

class _Col {
  _Col({
    required this.name,
    required this.fromSource,
    required this.notNull,
    required this.hasDefault,
    required this.numeric,
  });
  final String name;
  final bool fromSource;
  final bool notNull;
  final bool hasDefault;
  final bool numeric;
}

class KotlinImportException implements Exception {
  KotlinImportException(this.message);
  final String message;
  @override
  String toString() => 'Kotlin data import ruk gaya: $message';
}

class KotlinImportReport {
  KotlinImportReport({required this.copied, required this.dirtyRows});

  /// table -> copy hui rows.
  final Map<String, int> copied;

  /// Copy hui wo rows jin par dirty=1 hai (Kotlin ne unhe cloud par push nahi kiya tha).
  final int dirtyRows;

  static const _labels = {
    'products': 'items',
    'customers': 'customers',
    'suppliers': 'suppliers',
    'sales': 'sales',
    'purchases': 'purchases',
    'payments': 'payments',
    'expenses': 'expenses',
    'cash_transactions': 'cash entries',
  };

  String summary() {
    final parts = <String>[];
    _labels.forEach((t, label) {
      final n = copied[t];
      if (n != null) parts.add('$n $label');
    });
    final s = 'Kotlin app se copy hua: ${parts.join(', ')}.';
    if (dirtyRows > 0) {
      return '$s\n$dirtyRows records Kotlin app se cloud par sync nahi hue the — unhein pehle Kotlin app se sync kar lein.';
    }
    return s;
  }
}
