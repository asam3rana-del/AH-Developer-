import 'package:sqflite/sqflite.dart' show DatabaseExecutor;

import '../db/user_repository.dart';

/// Stock kam hone par sale allow hogi ya nahi.
///
/// Setting `allow_short_stock_sale`: '1' (default) = sale ho jaye, stock minus
/// mein chala jaye aur warning dikhe; '0' = purana rule (sale block).
/// UI ke sync checks ke liye [allowShortStock] cache hai; repository hamesha
/// DB se taaza value parhta hai ([readFrom]).
class StockPolicy {
  static const settingKey = 'allow_short_stock_sale';

  /// Cache for synchronous UI checks. Default ON.
  static bool allowShortStock = true;

  static Future<bool> load() async {
    final v = await UserRepository.instance.getSetting(settingKey);
    allowShortStock = v == null || v.trim() != '0';
    return allowShortStock;
  }

  static Future<void> save(bool on) async {
    await UserRepository.instance.setSetting(settingKey, on ? '1' : '0');
    allowShortStock = on;
  }

  /// Reads the live value inside an open transaction.
  static Future<bool> readFrom(DatabaseExecutor ex) async {
    final rows = await ex.query('app_settings', where: 'key = ?', whereArgs: [settingKey], limit: 1);
    if (rows.isEmpty) return true;
    return (rows.first['value'] as String?)?.trim() != '0';
  }

  static String shortWarning(String name, double availableBefore, double needed, String smallestUnit) {
    final after = availableBefore - needed;
    return 'Warning: "$name" ka stock kam tha — sale ho gayi, stock ab ${_n(after)} $smallestUnit (minus) hai. '
        'Purchase entry karke theek karen.';
  }

  static String _n(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);
}
