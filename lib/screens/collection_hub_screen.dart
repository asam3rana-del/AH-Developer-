import 'package:flutter/material.dart';

import '../models/due_followup.dart';
import '../models/wasooli_plan.dart';
import '../theme/theme_manager.dart';
import '../utils/loc.dart';
import '../widgets/permission_guard.dart';
import 'collection_ticker_screen.dart';
import 'due_reminders_screen.dart';
import 'receivables_screen.dart';
import 'wasooli_queue_screen.dart';
import 'wasooli_screen.dart';

/// Wasooli — ab EK page ([WasooliScreen]): "Aaj kis se lena hai", har party ki ek tareekh, 3 rang, 3 button.
/// Purani screens (Autopilot list, Sab bills, Kab se / Aging) upar ke menu mein.
///
/// Dashboard / notification wale purane rastay chalte rahen: [initialFilter] ko naye filter mein badla jata hai;
/// [initialTab] 2 = seedha "Kab se" (Aging).
class CollectionHubScreen extends StatelessWidget {
  final FollowUpFilter initialFilter;
  final int? initialTab;
  const CollectionHubScreen({super.key, this.initialFilter = FollowUpFilter.all, this.initialTab});

  static WasooliFilter _map(FollowUpFilter f) => switch (f) {
        FollowUpFilter.late || FollowUpFilter.brokenPromise => WasooliFilter.late,
        FollowUpFilter.collectToday || FollowUpFilter.today => WasooliFilter.today,
        _ => WasooliFilter.all,
      };

  @override
  Widget build(BuildContext context) {
    if (initialTab == 2) {
      return const PermissionGuard(permission: 'due_reminders', child: ReceivablesScreen());
    }
    final p = ThemeManager.palette;
    return PermissionGuard(
      permission: 'due_reminders',
      child: Scaffold(
        backgroundColor: p.bg,
        appBar: AppBar(
          backgroundColor: p.navy,
          foregroundColor: Colors.white,
          elevation: 0,
          title: Text(Loc.t('Collections', 'آج کس سے لینا ہے'),
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
          actions: [
            IconButton(
              tooltip: Loc.t('Display board', 'ڈسپلے بورڈ'),
              icon: const Icon(Icons.tv_rounded),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CollectionTickerScreen())),
            ),
            PopupMenuButton<int>(
              tooltip: Loc.t('More', 'مزید'),
              onSelected: (v) {
                final Widget page = switch (v) {
                  0 => const WasooliQueueScreen(),
                  1 => const DueRemindersScreen(),
                  _ => const ReceivablesScreen(),
                };
                Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
              },
              itemBuilder: (_) => [
                PopupMenuItem(value: 0, child: Text(Loc.t('Autopilot (old list)', 'آٹو پائلٹ (پرانی فہرست)'))),
                PopupMenuItem(value: 1, child: Text(Loc.t('All bills (filters)', 'تمام بل (فلٹر)'))),
                PopupMenuItem(value: 2, child: Text(Loc.t('Aging', 'کب سے باقی'))),
              ],
            ),
          ],
        ),
        body: WasooliScreen(initialFilter: _map(initialFilter)),
      ),
    );
  }
}
