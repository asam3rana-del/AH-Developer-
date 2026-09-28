import 'package:shared_preferences/shared_preferences.dart';

import '../models/misc_entities.dart';

/// Mirrors the Android "session" SharedPreferences {username, role}.
class Session {
  Session._();

  static String? username;
  static String displayName = '';
  static String role = 'cashier';

  static bool get isLoggedIn => username != null;
  static bool get isAdmin => role == 'admin';
  static bool get isManager => role == 'manager';
  static bool get isAdminOrManager => isAdmin || isManager;

  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    username = p.getString('session_username');
    displayName = p.getString('session_displayName') ?? '';
    role = p.getString('session_role') ?? 'cashier';
  }

  static Future<void> start(User u) async {
    username = u.username;
    displayName = u.displayName;
    role = u.role;
    final p = await SharedPreferences.getInstance();
    await p.setString('session_username', u.username);
    await p.setString('session_displayName', u.displayName);
    await p.setString('session_role', u.role);
  }

  static Future<void> clear() async {
    username = null;
    displayName = '';
    role = 'cashier';
    final p = await SharedPreferences.getInstance();
    await p.remove('session_username');
    await p.remove('session_displayName');
    await p.remove('session_role');
  }
}
