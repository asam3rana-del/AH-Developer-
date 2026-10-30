import 'package:shared_preferences/shared_preferences.dart';

import '../models/misc_entities.dart';

/// Mirrors the Android "session" SharedPreferences {username, role}.
class Session {
  Session._();

  static String? username;
  static String displayName = '';
  static String role = 'cashier';
  /// Per-user access overrides (JSON, users.permissions) — dekhein Permissions.
  static String permissions = '';

  static bool get isLoggedIn => username != null;
  static bool get isAdmin => role == 'admin';
  static bool get isManager => role == 'manager';
  static bool get isAdminOrManager => isAdmin || isManager;

  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    username = p.getString('session_username');
    displayName = p.getString('session_displayName') ?? '';
    role = p.getString('session_role') ?? 'cashier';
    permissions = p.getString('session_permissions') ?? '';
  }

  static Future<void> start(User u) async {
    username = u.username;
    displayName = u.displayName;
    role = u.role;
    permissions = u.permissions;
    final p = await SharedPreferences.getInstance();
    await p.setString('session_username', u.username);
    await p.setString('session_displayName', u.displayName);
    await p.setString('session_role', u.role);
    await p.setString('session_permissions', u.permissions);
  }

  static Future<void> setPermissions(String value) async {
    permissions = value;
    final p = await SharedPreferences.getInstance();
    await p.setString('session_permissions', value);
  }

  static Future<void> clear() async {
    username = null;
    displayName = '';
    role = 'cashier';
    permissions = '';
    final p = await SharedPreferences.getInstance();
    await p.remove('session_username');
    await p.remove('session_displayName');
    await p.remove('session_role');
    await p.remove('session_permissions');
  }
}
