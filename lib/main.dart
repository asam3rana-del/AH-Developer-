import 'dart:async' show unawaited;
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import 'backup/backup_scheduler.dart';
import 'db/user_repository.dart';
import 'db/desktop_db_init.dart';
import 'screens/dashboard_screen.dart';
import 'screens/login_screen.dart';
import 'services/app_lock.dart';
import 'services/crash_handler.dart';
import 'services/bill_reminder_service.dart';
import 'services/due_alert_service.dart';
import 'services/return_alert_service.dart';
import 'services/session.dart';
import 'sync/branch_config_store.dart';
import 'sync/device_tag.dart';
import 'sync/network_monitor.dart';
import 'sync/settings_sync.dart';
import 'sync/sync_keepalive.dart';
import 'sync/sync_worker.dart';
import 'theme/theme_manager.dart';
import 'utils/loc.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // MainActivity.onCreate: CrashHandler.install — sab se pehle, taake baad ki har crash pakri jaye.
  CrashHandler.install();
  // FIX: in mein se koi bhi fail ho (kharab prefs / DB nahi khulti) to pehle `runApp` kabhi nahi chalta tha —
  // dukaandar ko sirf safed screen. Ab saaf error screen + Retry + error copy (support ke liye).
  try {
    // Windows: DB factory sab se pehle (DeviceTag/BranchConfigStore ke liye nahi, lekin koi bhi DB call se pehle).
    await initDesktopDatabase();
    // PosApplication.onCreate() ka pehla kaam: DeviceTag / BranchConfigStore (IDs mein zaroorat).
    await DeviceTag.init();
    await BranchConfigStore.init();
    await Loc.load();
    await ThemeManager.load();
    await Session.load();
    await _revalidateSession();
    // PosApplication.onCreate() mein AppLock.register(this) ke barabar.
    await AppLock.instance.register(loginBuilder: (_) => const LoginScreen());
  } catch (e, st) {
    CrashHandler.record('Startup', e, st);
    runApp(_StartupErrorApp(error: '$e', stack: '$st'));
    return;
  }
  // PosApplication.onCreate() mein BackupScheduler.register(this) ke barabar (12 PM / 9 PM / app-close backup).
  try {
    BackupScheduler.instance.register();
  } catch (_) {} // plugin fail ho to bhi app khule
  // NetworkMonitor.register(this): internet wapas aane par sync (SyncWorker aane par onOnline jurega).
  // NetworkMonitor.onAvailable -> SyncWorker.triggerNow (20 s debounce + KEEP: retry-storm FIX).
  // Phase 10 ka aakhri jor: SyncRepository.backend = SyncApi, afterApply = mergeOwnDuplicateExpenses,
  // SyncQueueHelper.onQueued = SyncWorker.triggerNow (Kotlin `SyncQueueHelper.trigger`).
  installSyncWiring();
  NetworkMonitor.onOnline = () => SyncWorker.instance.triggerNow();
  try {
    await NetworkMonitor.register();
  } catch (_) {} // internet-monitor fail ho to bhi app khule (periodic sync chalta rahega)
  // PosApplication.onCreate() mein SyncWorker.schedulePeriodic(this) (har 15 min, app zinda ho tab — screen par ya background mein).
  SyncWorker.instance.schedulePeriodic();
  // Android: minimize / back ke baad bhi sync na ruke (foreground service). Fail ho to app chalti rahe.
  unawaited(SyncKeepAlive.start());
  // Roz ki due-reminder notification: app khulte hi check; tap par Due Reminders screen.
  try {
    await DueAlertService.init(withTap: true);
    unawaited(DueAlertService.checkAndNotify());
    unawaited(BillReminderService.checkAndNotify());
    unawaited(ReturnAlertService.checkAndNotify());
  } catch (_) {}
  runApp(const AhDeveloperApp());
  unawaited(DueAlertService.handleLaunch());
}

/// FIX: Session (username/role) SharedPreferences se aata hai — Windows par wo saada JSON file hai jise cashier
/// khud badal kar `admin` likh sakta tha, aur jis user ko Admin ne deactivate kiya / role badla wo restart ke
/// baad bhi purane role ke saath andar rehta. Har launch par DB ke `users` se dobara milao.
/// DB khul hi na sake to kuch na chhero (lockout na ho).
Future<void> _revalidateSession() async {
  final name = Session.username;
  if (name == null) return;
  try {
    final u = await UserRepository.instance.find(name);
    if (u == null || !u.active) {
      await Session.clear();
      return;
    }
    if (u.role != Session.role || u.permissions != Session.permissions || u.displayName != Session.displayName) {
      await Session.start(u);
    }
  } catch (_) {}
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
          title: 'Hanna Solutions',
          debugShowCheckedModeBanner: false,
          theme: _buildTheme(p, dark),
          // Desktop: mouse se bhi drag-scroll (touch-screen POS jaisa).
          scrollBehavior: const _DesktopScrollBehavior(),
          builder: (context, child) => Directionality(
            textDirection: lang == 'ur' ? TextDirection.rtl : TextDirection.ltr,
            child: _DesktopFrame(background: p.bg, child: child!),
          ),
          // Session hai to seedha dashboard, warna login/setup.
          home: Session.isLoggedIn ? const DashboardScreen() : const LoginScreen(),
        );
      },
    );
  }
}

/// Poori app ka ThemeData ThemeManager ke palette se: dialog, bottom sheet, popup menu, card, text-field
/// aur unstyled Text bhi dark/light mein palette ke rang lete hain (pehle Material ke apne seeded rang the).
/// Sirf stable ColorScheme/ThemeData fields — component themes (DialogTheme wagaira) jaan boojh kar nahi,
/// kyunke naye Flutter versions mein unke class naam badal gaye hain.
ThemeData _buildTheme(AppPalette p, bool dark) {
  final brightness = dark ? Brightness.dark : Brightness.light;
  final scheme = ColorScheme.fromSeed(seedColor: p.navy, brightness: brightness).copyWith(
    surface: p.cardWhite,
    onSurface: p.textDark,
    onSurfaceVariant: p.textMuted,
    surfaceContainerLowest: p.cardWhite,
    surfaceContainerLow: p.cardWhite,
    surfaceContainer: p.cardWhite,
    surfaceContainerHigh: p.cardWhite,
    surfaceContainerHighest: p.fieldFill,
    outline: p.textMuted,
    outlineVariant: p.border,
    error: p.red,
  );
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: p.bg,
    canvasColor: p.cardWhite,
    dividerColor: p.border,
    fontFamily: 'Roboto',
  );
  return base.copyWith(textTheme: base.textTheme.apply(bodyColor: p.textDark, displayColor: p.textDark));
}

bool get _isDesktop => !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

/// Screens mobile ke liye bani hain. Bari (desktop) window mein unhein khinchne ke bajaye beech mein
/// aik hadd (900 px) tak chaura rakhte hain; phone / tablet par kuch nahi badalta.
class _DesktopFrame extends StatelessWidget {
  const _DesktopFrame({required this.child, required this.background});
  final Widget child;
  final Color background;

  static const double maxWidth = 900;

  @override
  Widget build(BuildContext context) {
    if (!_isDesktop) return child;
    return ColoredBox(
      color: background,
      child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: maxWidth), child: child)),
    );
  }
}

class _DesktopScrollBehavior extends MaterialScrollBehavior {
  const _DesktopScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.stylus,
        PointerDeviceKind.trackpad,
      };
}


/// App start na ho sake to ye screen (theme / zabaan / DB par bharosa nahi — sab saada).
class _StartupErrorApp extends StatelessWidget {
  const _StartupErrorApp({required this.error, required this.stack});
  final String error;
  final String stack;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Builder(
        builder: (context) => Scaffold(
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const Icon(Icons.error_outline, size: 56, color: Colors.red),
                const SizedBox(height: 12),
                const Text('App start nahi ho saki',
                    textAlign: TextAlign.center, style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                const Text(
                  'Aap ka data phone mein mehfooz hai. Pehle "Dobara koshish" dabayein. Phir bhi na chale to '
                  '"Error copy" kar ke support ko bhejein — app uninstall NA karein.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: SingleChildScrollView(
                    child: SelectableText(error, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: main,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Dobara koshish (Retry)'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: 'Startup error\n$error\n\n$stack'));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context)
                          .showSnackBar(const SnackBar(content: Text('Error copy ho gaya')));
                    }
                  },
                  icon: const Icon(Icons.copy),
                  label: const Text('Error copy'),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
