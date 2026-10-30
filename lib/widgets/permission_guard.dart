import 'package:flutter/material.dart';

import '../services/permissions.dart';
import '../theme/theme_manager.dart';
import '../utils/loc.dart';

/// Screen ke andar access check (RoleGuard ki jagah jahan admin per-user access de sakta hai).
/// `PermissionGuard(permission: 'stock_audit', child: ...)` ya `PermissionGuard(anyOf: [...], child: ...)`.
class PermissionGuard extends StatelessWidget {
  final String? permission;
  final List<String>? anyOf;
  final Widget child;

  const PermissionGuard({super.key, this.permission, this.anyOf, required this.child})
      : assert(permission != null || anyOf != null);

  bool get _allowed => permission != null ? Permissions.can(permission!) : Permissions.canAny(anyOf!);

  @override
  Widget build(BuildContext context) {
    if (_allowed) return child;
    return Scaffold(
      appBar: AppBar(backgroundColor: ThemeManager.palette.navy, foregroundColor: Colors.white),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.lock_outline, size: 56, color: ThemeManager.palette.textMuted),
            const SizedBox(height: 14),
            Text(
              Loc.t('Admin has not given you access to this screen', 'ایڈمن نے آپ کو اس اسکرین کی رسائی نہیں دی'),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16, color: ThemeManager.palette.textDark),
            ),
          ]),
        ),
      ),
    );
  }
}
