import 'package:flutter/material.dart';

import 'backup/backup_scheduler.dart';
import 'screens/dashboard_screen.dart';
import 'screens/login_screen.dart';
import 'services/app_lock.dart';
import 'services/session.dart';
import 'sync/branch_config_store.dart';
import 'sync/device_tag.dart';
import 'sync/network_monitor.dart';
import 'sync/settings_sync.dart';
import 'sync/sync_worker.dart';
import 'theme/app_colors.dart';
import 'theme/theme_manager.dart';
import 'utils/loc.dart';

// TODO: once you run `flutterfire configure` (see README), uncomment these
// and call Firebase.initializeApp() in main() before runApp() — mirrors the
// Firebase.initializeApp() call in the Kotlin app's Application class.
// import 'package:firebase_core/firebase_core.dart';
// import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // PosApplication.onCreate() ka pehla kaam: DeviceTag / BranchConfigStore (IDs mein zaroorat).
  await DeviceTag.init();
  await BranchConfigStore.init();
  // await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await Loc.load();
  await ThemeManager.load();
  await Session.load();
  // PosApplication.onCreate() mein AppLock.register(this) ke barabar.
  await AppLock.instance.register(loginBuilder: (_) => const LoginScreen());
  // PosApplication.onCreate() mein BackupScheduler.register(this) ke barabar (12 PM / 9 PM / app-close backup).
  BackupScheduler.instance.register();
  // NetworkMonitor.register(this): internet wapas aane par sync (SyncWorker aane par onOnline jurega).
  // NetworkMonitor.onAvailable -> SyncWorker.triggerNow (20 s debounce + KEEP: retry-storm FIX).
  // Phase 10 ka aakhri jor: SyncRepository.backend = SyncApi, afterApply = mergeOwnDuplicateExpenses,
  // SyncQueueHelper.onQueued = SyncWorker.triggerNow (Kotlin `SyncQueueHelper.trigger`).
  installSyncWiring();
  NetworkMonitor.onOnline = () => SyncWorker.instance.triggerNow();
  await NetworkMonitor.register();
  // PosApplication.onCreate() mein SyncWorker.schedulePeriodic(this) (har 15 min, app zinda ho tab).
  SyncWorker.instance.schedulePeriodic();
  runApp(const AhDeveloperApp());
}

class AhDeveloperApp extends StatelessWidget {
  const AhDeveloperApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([Loc.language, ThemeManager.isDark]),
      builder: (context, _) {
        final lang = Loc.language.value;
        final dark = ThemeManager.isDark.value;
        final p = ThemeManager.palette;
        return MaterialApp(
          navigatorKey: AppLock.navigatorKey,
          // zabaan / theme badalne par saari screens dobara ban jayein
          key: ValueKey('$lang-$dark'),
          title: 'AH Developer — Kiryana Store',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            useMaterial3: true,
            brightness: dark ? Brightness.dark : Brightness.light,
            scaffoldBackgroundColor: dark ? p.bg : AppColors.bg,
            colorSchemeSeed: AppColors.navy,
            fontFamily: 'Roboto',
          ),
          builder: (context, child) => Directionality(
            textDirection: lang == 'ur' ? TextDirection.rtl : TextDirection.ltr,
            child: child!,
          ),
          // Session hai to seedha dashboard, warna login/setup.
          home: Session.isLoggedIn ? const DashboardScreen() : const LoginScreen(),
        );
      },
    );
  }
}
