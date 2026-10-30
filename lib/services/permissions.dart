import 'dart:convert';

import '../db/user_repository.dart';
import 'session.dart';

/// Ek access (report ya tool) ki tareef: kaun si group, naam, aur kin roles ko default mein milta hai.
class PermDef {
  final String key;
  final String group;
  final String en;
  final String ur;
  final Set<String> roles;
  const PermDef(this.key, this.group, this.en, this.ur, this.roles);
}

/// Per-user access rules. Admin hamesha sab kuch kar sakta hai (lock-out se bachne ke liye).
/// Baaqi users ko role ke default mil jate hain; admin kisi bhi user ke liye koi bhi item
/// alag se ON / OFF kar sakta hai ("Manage Users" -> Access). Sirf wo items save hote hain jo
/// role ke default se alag hon (users.permissions, JSON), aur sync ke zariye har device par jate hain.
class Permissions {
  Permissions._();

  static const groupReports = 'reports';
  static const groupTools = 'tools';

  static const _am = {'admin', 'manager'};
  static const _a = {'admin'};
  static const _all = {'admin', 'manager', 'cashier'};

  static const List<PermDef> all = [
    PermDef('reports_summary', groupReports, 'Sales & Profit summary (Reports page)', 'سیل اور منافع کا خلاصہ (رپورٹس پیج)', _am),
    PermDef('sale_history', groupReports, 'Sale History', 'سیل کی تاریخ', _am),
    PermDef('purchase_history', groupReports, 'Purchase History', 'خریداری کی تاریخ', _a),
    PermDef('daily_bills', groupReports, 'Daily Bills', 'روزانہ بلز', _am),
    PermDef('monthly', groupReports, 'Sale vs Purchase — Month/Year', 'سیل بمقابلہ خریداری — مہینہ/سال', _am),
    PermDef('rate_comparison', groupReports, 'Rate Comparison', 'ریٹ کا موازنہ', _am),
    PermDef('party_reports', groupReports, 'Party Reports', 'پارٹی رپورٹس', _am),
    PermDef('payments_report', groupReports, 'Payments Report', 'ادائیگیوں کی رپورٹ', _am),
    PermDef('due_reminders', groupReports, 'Due Date Reminders', 'ادائیگی کی یاد دہانی', _am),
    PermDef('stock_report', groupReports, 'Stock Report', 'اسٹاک رپورٹ', _am),
    PermDef('stock_history', groupReports, 'Stock History', 'اسٹاک کی تاریخ', _am),
    PermDef('cost_history', groupReports, 'Cost History', 'لاگت کی تاریخ', _am),
    PermDef('stock_audit', groupReports, 'Stock Audit', 'اسٹاک آڈٹ', _am),
    PermDef('inventory_insights', groupReports, 'Inventory Insights', 'انوینٹری تجزیہ', _am),
    PermDef('balance_sheet', groupReports, 'Balance Sheet', 'بیلنس شیٹ', _am),
    PermDef('stock_adjustment', groupTools, 'Stock Adjustment', 'اسٹاک ایڈجسٹمنٹ', _am),
    PermDef('stock_taking', groupTools, 'Stock Taking', 'اسٹاک گنتی', _am),
    PermDef('fix_bill_cost', groupTools, 'Fix Bill Cost', 'بل کی لاگت درست کریں', _a),
    PermDef('cash_register', groupTools, 'Cash Register', 'کیش رجسٹر', _all),
    PermDef('zakat', groupTools, 'Zakat', 'زکوٰۃ', _am),
  ];

  /// Reports hub ki rows (Reports page khulne ke liye inmein se koi ek chahiye).
  static const List<String> reportKeys = [
    'reports_summary', 'sale_history', 'purchase_history', 'daily_bills', 'monthly', 'rate_comparison',
    'party_reports', 'payments_report', 'due_reminders', 'stock_report', 'stock_history', 'cost_history',
    'stock_audit', 'inventory_insights', 'balance_sheet',
  ];

  static final Map<String, PermDef> _byKey = {for (final p in all) p.key: p};

  /// `{"key": true/false}` -> map. Kharab / khali text = koi override nahi.
  static Map<String, bool> parse(String raw) {
    if (raw.trim().isEmpty) return const {};
    try {
      final d = jsonDecode(raw);
      if (d is! Map) return const {};
      return {
        for (final e in d.entries)
          if (e.value is bool) e.key.toString(): e.value as bool,
      };
    } catch (_) {
      return const {};
    }
  }

  static String encode(Map<String, bool> overrides) => overrides.isEmpty ? '' : jsonEncode(overrides);

  /// Role ka default (admin hamesha true).
  static bool defaultFor(String role, String key) =>
      role == 'admin' || (_byKey[key]?.roles.contains(role) ?? false);

  /// Role + overrides se final jawab. Admin par overrides ka asar nahi.
  static bool resolve(String role, Map<String, bool> overrides, String key) {
    if (role == 'admin') return true;
    return overrides[key] ?? defaultFor(role, key);
  }

  static String? _cacheRaw;
  static Map<String, bool> _cache = const {};

  static Map<String, bool> _current() {
    final raw = Session.permissions;
    if (_cacheRaw != raw) {
      _cache = parse(raw);
      _cacheRaw = raw;
    }
    return _cache;
  }

  /// Maujooda logged-in user is item ko use kar sakta hai?
  static bool can(String key) => resolve(Session.role, _current(), key);

  static bool canAny(Iterable<String> keys) => keys.any(can);

  /// Reports page / hub kholne ke liye.
  static bool canAnyReport() => canAny(reportKeys);

  /// Database se taaza rules utha leta hai (admin ne dusre device par badle hon to sync ke baad yahan aa jate hain).
  static Future<void> refresh() async {
    final name = Session.username;
    if (name == null) return;
    try {
      final u = await UserRepository.instance.find(name);
      if (u == null) return;
      await Session.setPermissions(u.permissions);
    } catch (_) {
      // DB tayyar nahi / error: purane rules chalte rahen.
    }
  }
}
