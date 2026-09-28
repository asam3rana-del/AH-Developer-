import 'package:flutter/material.dart';

import '../services/session.dart';
import '../theme/app_colors.dart';
import '../utils/loc.dart';

/// Screen ke andar role check (sirf UI hide karna kaafi nahi).
/// `RoleGuard(allowed: {'admin'}, child: ProductScreen())`
class RoleGuard extends StatelessWidget {
  final Set<String> allowed;
  final Widget child;

  const RoleGuard({super.key, required this.allowed, required this.child});

  @override
  Widget build(BuildContext context) {
    if (allowed.contains(Session.role)) return child;
    final adminOnly = allowed.length == 1 && allowed.contains('admin');
    final msg = adminOnly
        ? Loc.t('Only Admin can access this screen', 'صرف ایڈمن اس اسکرین کو استعمال کر سکتا ہے')
        : Loc.t('Only Admin/Manager can access this screen', 'صرف ایڈمن/منیجر اس اسکرین کو استعمال کر سکتا ہے');
    return Scaffold(
      appBar: AppBar(backgroundColor: AppColors.navy, foregroundColor: Colors.white),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.lock_outline, size: 56, color: AppColors.textMuted),
            const SizedBox(height: 14),
            Text(msg, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16, color: AppColors.textDark)),
          ]),
        ),
      ),
    );
  }
}
