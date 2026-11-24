import 'dart:async' show unawaited;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import 'backup/backup_scheduler.dart';
import 'backup/offsite_backup.dart';
import 'db/user_repository.dart';
import 'db/desktop_db_init.dart';
import 'desktop/desktop_prefs.dart';
import 'desktop/desktop_shell.dart';
import 'license/license_gate.dart';
import 'license/license_service.dart';
import 'screens/dashboard_screen.dart';
import 'screens/login_screen.dart';
import 'services/app_lock.dart';
import 'services/crash_handler.dart';
import 'services/demo_mode.dart';
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
import 'theme/app_theme.dart';
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
    // Demo / training dukaan ka flag DB khulne se PEHLE (kaunsi DB file khulegi, is par munhasir).
    await DemoMode.init();
    // PosApplication.onCreate() ka pehla kaam: DeviceTag / BranchConfigStore (IDs mein zaroorat).
    await DeviceTag.init();
    await BranchConfigStore.init();
    await Loc.load();
    await ThemeManager.load();
    await DesktopPrefs.load(); // PC: text size + sidebar (phone par kuch nahi)
    await LicenseService.instance.init(); // Hanna POS license (offline key + trial + online band)
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
    unawaited(OffsiteBackup.checkAndNotify());
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
      listenable: Listenable.merge([Loc.language, ThemeManager.isDark, DemoMode.notifier]),
      builder: (context, _) {
        final lang = Loc.language.value;
        final dark = ThemeManager.isDark.value;
        final p = ThemeManager.palette;
        final demo = DemoMode.enabled;
        return MaterialApp(
          navigatorKey: AppLock.navigatorKey,
          // PC sidebar ko pata rahe kaunsi screen / dialog upar hai.
          navigatorObservers: [DesktopShell.observerFor('$lang-$dark-$demo')],
          // zabaan / theme badalne par saari screens dobara ban jayein
          // Demo on/off par bhi poora tree naya (kisi screen mein doosri dukaan ka purana data na reh jaye).
          key: ValueKey('$lang-$dark-$demo'),
          title: demo ? 'Hanna POS (DEMO)' : 'Hanna POS',
          debugShowCheckedModeBanner: false,
          theme: _buildTheme(p, dark),
          // Desktop: mouse se bhi drag-scroll (touch-screen POS jaisa).
          scrollBehavior: const _DesktopScrollBehavior(),
          builder: (context, child) => Directionality(
            textDirection: lang == 'ur' ? TextDirection.rtl : TextDirection.ltr,
            child: _BottomSystemBarGuard(
              background: p.bg,
              // PC: sidebar + poori screen (phone / tablet par seedha child).
              child: DesktopShell(
                // License band => sirf License screen (login ke baad); qareeb => upar patti.
                child: LicenseGate(
                  // Demo dukaan har screen par saaf nazar aaye, taake asal hisaab samajh kar entry na ho.
                  child: demo
                      ? Banner(
                          message: 'DEMO',
                          location: BannerLocation.topEnd,
                          color: const Color(0xFFD97706),
                          child: child!,
                        )
                      : child!,
                ),
              ),
            ),
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
/// Poori app ka premium theme: lib/theme/app_theme.dart (Hanna navy + gold).
ThemeData _buildTheme(AppPalette p, bool dark) => AppTheme.build(p, dark);

/// Android 15+ (targetSdk 35/36) edge-to-edge zabardasti karta hai: neeche wali system bar (back/home)
/// screen ke upar aa jaati hai, aur jin ListView par apni padding di hui hai unka aakhri button
/// (maslan Settings ka Logout) us ke neeche chhup jata hai. Poori app ko bar ke upar khatam karo,
/// bar ke peeche app ka background rang. Keyboard khula ho to Flutter `padding.bottom` khud 0 kar
/// deta hai, is liye keyboard ke saath faltu khali jagah nahi banti.
class _BottomSystemBarGuard extends StatelessWidget {
  const _BottomSystemBarGuard({required this.child, required this.background});
  final Widget child;
  final Color background;

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    if (bottom <= 0) return child;
    return ColoredBox(
      color: background,
      child: Padding(
        padding: EdgeInsets.only(bottom: bottom),
        child: MediaQuery.removePadding(context: context, removeBottom: true, child: child),
      ),
    );
  }
}

class _DesktopScrollBehavior extends MaterialScrollBehavior {
  const _DesktopScrollBehavior();

  /// Phone / tablet: pehle jaisa (mouse / trackpad se bhi kheench kar scroll).
  /// PC: Windows ka aam tareeqa — mouse wheel, touchpad ki do ungliyan, scrollbar. Mouse se "kheench kar
  /// scroll" band, kyun ke wo click / text select se takrata tha aur scroll mushkil lagta tha.
  @override
  Set<PointerDeviceKind> get dragDevices => DesktopPrefs.isDesktop
      ? const {PointerDeviceKind.touch, PointerDeviceKind.stylus, PointerDeviceKind.invertedStylus}
      : const {
          PointerDeviceKind.touch,
          PointerDeviceKind.mouse,
          PointerDeviceKind.stylus,
          PointerDeviceKind.trackpad,
        };

  /// PC: lambi screens (Dashboard, Settings…) par scrollbar hamesha nazar aaye aur mouse se pakad kar
  /// kheencha ja sake.
  @override
  Widget buildScrollbar(BuildContext context, Widget child, ScrollableDetails details) {
    if (!DesktopPrefs.isDesktop || axisDirectionToAxis(details.direction) != Axis.vertical) {
      return super.buildScrollbar(context, child, details);
    }
    return Scrollbar(
      controller: details.controller,
      thumbVisibility: true,
      interactive: true,
      thickness: 10,
      radius: const Radius.circular(8),
      child: child,
    );
  }
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
