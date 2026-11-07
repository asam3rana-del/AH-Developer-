import 'package:flutter/material.dart';

import '../models/due_followup.dart';
import '../theme/theme_manager.dart';
import '../utils/loc.dart';
import '../widgets/permission_guard.dart';
import 'due_reminders_screen.dart';
import 'wasooli_queue_screen.dart';

/// Ek screen mein poori wasooli: tab 1 = "Aaj ki Wasooli" (Autopilot: aaj kis ko yaad dilana hai, ek tap mein),
/// tab 2 = "Sab Bills" (Due Reminders: saari late / pending parties, filters, search).
/// Dashboard ke Collect today / Late / Promise broken tiles `initialFilter` ke sath tab 2 kholte hain.
class CollectionHubScreen extends StatelessWidget {
  final FollowUpFilter initialFilter;

  /// 0 = Aaj ki Wasooli (Autopilot), 1 = Sab Bills. null => filter laga ho to 1, warna 0.
  final int? initialTab;
  const CollectionHubScreen({super.key, this.initialFilter = FollowUpFilter.all, this.initialTab});

  @override
  Widget build(BuildContext context) {
    final p = ThemeManager.palette;
    final tab = initialTab ?? (initialFilter == FollowUpFilter.all ? 0 : 1);
    return PermissionGuard(
      permission: 'due_reminders',
      child: DefaultTabController(
        length: 2,
        initialIndex: tab,
        child: Scaffold(
          backgroundColor: p.bg,
          appBar: AppBar(
            backgroundColor: p.navy,
            foregroundColor: Colors.white,
            elevation: 0,
            title: Text(Loc.t('Collection', 'وصولی'), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            bottom: TabBar(
              indicatorColor: Colors.white,
              labelColor: Colors.white,
              unselectedLabelColor: Colors.white70,
              labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
              tabs: [
                Tab(text: Loc.t('Today (Autopilot)', 'آج (آٹو پائلٹ)')),
                Tab(text: Loc.t('All dues', 'تمام بقایا')),
              ],
            ),
          ),
          body: TabBarView(
            children: [
              const WasooliQueueScreen(embedded: true),
              DueRemindersScreen(initialFilter: initialFilter, embedded: true),
            ],
          ),
        ),
      ),
    );
  }
}
