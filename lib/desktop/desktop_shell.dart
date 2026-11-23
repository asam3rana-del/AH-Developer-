import 'dart:async' show scheduleMicrotask, unawaited;
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show kBackMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../screens/backup_export_screen.dart';
import '../screens/cash_screen.dart';
import '../screens/collection_hub_screen.dart';
import '../screens/daily_bills_screen.dart';
import '../screens/day_book_screen.dart';
import '../screens/expense_screen.dart';
import '../screens/items_screen.dart';
import '../screens/login_screen.dart';
import '../screens/party_dashboard_screen.dart';
import '../screens/purchase_screen.dart';
import '../screens/reports_screen.dart';
import '../screens/sale_screen.dart';
import '../screens/settings_screen.dart';
import '../screens/stock_report_screen.dart';
import '../license/license_service.dart';
import '../services/app_lock.dart';
import '../services/permissions.dart';
import '../services/session.dart';
import '../theme/theme_manager.dart';
import '../utils/loc.dart';
import '../widgets/permission_guard.dart';
import '../widgets/role_guard.dart';
import 'desktop_prefs.dart';

/// Navigator ka stack (PC sidebar ke liye): kaunsi screen upar hai, dialog khula hai ya nahi.
class ShellNavObserver extends NavigatorObserver {
  final List<Route<dynamic>> stack = [];
  final ValueNotifier<int> changes = ValueNotifier<int>(0);

  Route<dynamic>? get top => stack.isEmpty ? null : stack.last;

  /// Dialog / bottom sheet / popup menu upar khula hai.
  bool get popupOnTop => top != null && top is! PageRoute;

  void _changed({bool popped = false}) {
    changes.value++;
    if (popped && stack.length == 1) {
      // Dashboard par wapas — wo apne numbers dobara padh le (sidebar se aane par bhi).
      scheduleMicrotask(() => DesktopShell.rootShown.value++);
    }
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    stack.add(route);
    _changed();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    stack.remove(route);
    _changed(popped: true);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    stack.remove(route);
    _changed(popped: true);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final i = oldRoute == null ? -1 : stack.indexOf(oldRoute);
    if (i >= 0 && newRoute != null) {
      stack[i] = newRoute;
    } else {
      if (oldRoute != null) stack.remove(oldRoute);
      if (newRoute != null) stack.add(newRoute);
    }
    _changed();
  }
}

/// Sidebar ka ek item. [screen] null => Dashboard (stack ki jarr par wapas).
class _NavItem {
  final String id, en, ur;
  final IconData icon;
  final Widget Function()? screen;
  const _NavItem(this.id, this.en, this.ur, this.icon, [this.screen]);
}

/// PC (Windows) ka dhancha: baayen sidebar (Urdu mein daayen) + beech mein screen.
/// - Login / lock screen par sidebar nahi (menu se lock ke peeche na ja sakein).
/// - Tang window (< 1000 px) par sidebar nahi — purana mobile layout.
/// - Har screen ko content area ki asal chaurai MediaQuery mein milti hai (breakpoints sahi chalein).
/// - Text size (Ctrl + / - / 0), shortcuts (F1 list), mouse ka Back button.
class DesktopShell extends StatefulWidget {
  const DesktopShell({super.key, required this.child});
  final Widget child;

  static ShellNavObserver? _observer;
  static String? _observerKey;

  /// MaterialApp ke har naye (key badalne par) Navigator ke liye naya observer.
  static ShellNavObserver observerFor(String appKey) {
    if (_observer == null || _observerKey != appKey) {
      _observer = ShellNavObserver();
      _observerKey = appKey;
    }
    return _observer!;
  }

  /// Stack wapas Dashboard tak aaya (Dashboard ise sun kar refresh karta hai).
  static final ValueNotifier<int> rootShown = ValueNotifier<int>(0);

  @override
  State<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends State<DesktopShell> {
  ShellNavObserver? _obs;
  bool _rebuildScheduled = false;
  bool _navigating = false;

  @override
  void initState() {
    super.initState();
    _obs = DesktopShell._observer;
    _obs?.changes.addListener(_onChange);
    AppLock.instance.loginScreenShown.addListener(_onChange);
    LicenseService.instance.state.addListener(_onChange);
    DesktopPrefs.textScale.addListener(_onChange);
    DesktopPrefs.sidebarCollapsed.addListener(_onChange);
    if (DesktopPrefs.isDesktop) HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    _obs?.changes.removeListener(_onChange);
    AppLock.instance.loginScreenShown.removeListener(_onChange);
    LicenseService.instance.state.removeListener(_onChange);
    DesktopPrefs.textScale.removeListener(_onChange);
    DesktopPrefs.sidebarCollapsed.removeListener(_onChange);
    if (DesktopPrefs.isDesktop) HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  /// Route push/pop build ke beech bhi aa sakta hai — rebuild hamesha agle frame par.
  void _onChange() {
    if (_rebuildScheduled) return;
    _rebuildScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _rebuildScheduled = false;
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  NavigatorState? get _nav => AppLock.navigatorKey.currentState;

  /// Andar (logged in) hain, login/lock screen nahi, aur license chal raha hai (band ho to menu / shortcuts nahi).
  bool get _signedIn =>
      Session.isLoggedIn && !AppLock.instance.onLoginScreen && LicenseService.instance.state.value.usable;

  // ------------------------------------------------------------------ navigation

  List<_NavItem> _items() {
    const am = {'admin', 'manager'};
    final role = Session.role;
    return [
      const _NavItem('dashboard', 'Dashboard', 'ڈیش بورڈ', Icons.space_dashboard_outlined),
      _NavItem('sale', 'Sale', 'سیل', Icons.shopping_cart_outlined, () => const SaleScreen()),
      _NavItem('quick_sale', 'Quick Sale', 'کوئیک سیل', Icons.timer_outlined, () => const SaleScreen(openQuickSale: true)),
      if (role == 'admin')
        _NavItem('purchase', 'Purchase', 'خریداری', Icons.inventory_2_outlined,
            () => const RoleGuard(allowed: {'admin'}, child: PurchaseScreen())),
      if (am.contains(role))
        _NavItem('daily_bills', 'Daily Bills', 'روزانہ بلز', Icons.receipt_long_outlined, () => const DailyBillsScreen()),
      _NavItem('parties', 'Customers & Suppliers', 'گاہک اور سپلائر', Icons.people_outline,
          () => const PartyDashboardScreen()),
      if (Permissions.can('due_reminders'))
        _NavItem('collection', 'Collection', 'وصولی', Icons.bolt_rounded, () => const CollectionHubScreen()),
      _NavItem('items', 'Items', 'آئٹمز', Icons.list_alt, () => const ItemsScreen()),
      _NavItem('low_stock', 'Low Stock', 'کم اسٹاک', Icons.warning_amber_rounded,
          () => const StockReportScreen(lowStockOnly: true)),
      _NavItem('day_book', 'Day book', 'روزنامچہ', Icons.menu_book_outlined, () => const DayBookScreen()),
      if (Permissions.canAnyReport())
        _NavItem('reports', 'Reports', 'رپورٹس', Icons.trending_up, () => const ReportsScreen()),
      if (Permissions.can('expense'))
        _NavItem('expense', 'Expense', 'اخراجات', Icons.business_center_outlined,
            () => const PermissionGuard(permission: 'expense', child: ExpenseScreen())),
      if (Permissions.can('cash_register'))
        _NavItem('cash', 'Cash & Bank', 'کیش اور بینک', Icons.account_balance_outlined,
            () => const PermissionGuard(permission: 'cash_register', child: CashScreen())),
      if (am.contains(role))
        _NavItem('backup', 'Backup', 'بیک اپ', Icons.save_outlined, () => const BackupExportScreen()),
      _NavItem('settings', 'Settings', 'سیٹنگز', Icons.settings_outlined, () => const SettingsScreen()),
    ];
  }

  /// Kaunsa sidebar item roshan ho: stack mein sab se neeche wali sidebar-screen, warna Dashboard.
  String? _activeId() {
    final s = _obs?.stack ?? const [];
    if (s.length <= 1) return 'dashboard';
    for (final r in s.skip(1)) {
      final name = r.settings.name;
      if (name != null && name.startsWith('nav:')) return name.substring(4);
    }
    return null;
  }

  /// Pehle Dashboard tak wapas (har screen ka apna "unsaved changes" sawal izzat se — maybePop),
  /// phir chuni hui screen. Koi screen jaane na de to wahin ruk jao.
  Future<void> _go(_NavItem item) async {
    final nav = _nav;
    final obs = _obs;
    if (nav == null || obs == null || _navigating || obs.popupOnTop) return;
    if (_activeId() == item.id && obs.stack.length <= 2 && item.screen != null) return; // pehle se wahin
    _navigating = true;
    try {
      while (obs.stack.length > 1) {
        final top = obs.top;
        if (top is! PageRoute) return;
        await nav.maybePop();
        await Future<void>.delayed(Duration.zero);
        if (identical(obs.top, top)) return; // screen ne rok liya (unsaved bill wagaira)
      }
      final b = item.screen;
      if (b != null && mounted) {
        unawaited(nav.push(MaterialPageRoute<void>(builder: (_) => b(), settings: RouteSettings(name: 'nav:${item.id}'))));
      }
    } finally {
      _navigating = false;
    }
  }

  void _goId(String id) {
    for (final i in _items()) {
      if (i.id == id) {
        _go(i);
        return;
      }
    }
  }

  Future<void> _back() async {
    final obs = _obs;
    if (obs == null || obs.stack.length <= 1) return;
    await _nav?.maybePop();
  }

  Future<void> _logout() async {
    final ok = await _confirm(Loc.t('Logout?', 'لاگ آؤٹ کریں؟'),
        Loc.t('Unsaved work on open screens will be lost.', 'کھلی اسکرینوں کا محفوظ نہ کیا گیا کام ختم ہو جائے گا۔'));
    if (!ok) return;
    await Session.clear();
    _nav?.pushAndRemoveUntil(MaterialPageRoute<void>(builder: (_) => const LoginScreen()), (_) => false);
  }

  Future<bool> _confirm(String title, String body) async {
    final ctx = _nav?.overlay?.context;
    if (ctx == null) return false;
    final r = await showDialog<bool>(
      context: ctx,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(Loc.t('Cancel', 'منسوخ کریں'))),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(Loc.t('OK', 'ٹھیک ہے'))),
        ],
      ),
    );
    return r ?? false;
  }

  // ------------------------------------------------------------------ keyboard / mouse

  bool _onKey(KeyEvent e) {
    if (e is! KeyDownEvent) return false;
    final kb = HardwareKeyboard.instance;
    final k = e.logicalKey;
    // Text size: login screen par bhi.
    if (kb.isControlPressed && !kb.isAltPressed) {
      if (k == LogicalKeyboardKey.equal || k == LogicalKeyboardKey.numpadAdd) {
        DesktopPrefs.zoom(1);
        return true;
      }
      if (k == LogicalKeyboardKey.minus || k == LogicalKeyboardKey.numpadSubtract) {
        DesktopPrefs.zoom(-1);
        return true;
      }
      if (k == LogicalKeyboardKey.digit0 || k == LogicalKeyboardKey.numpad0) {
        DesktopPrefs.zoom(0);
        return true;
      }
    }
    if (!_signedIn || (_obs?.popupOnTop ?? true)) return false;
    if (k == LogicalKeyboardKey.f1) {
      showDesktopShortcuts();
      return true;
    }
    if (kb.isAltPressed && k == LogicalKeyboardKey.arrowLeft) {
      _back();
      return true;
    }
    if (kb.isControlPressed && !kb.isShiftPressed && !kb.isAltPressed) {
      String? id;
      if (k == LogicalKeyboardKey.keyD) {
        id = 'dashboard';
      } else if (k == LogicalKeyboardKey.keyN) {
        id = 'sale';
      } else if (k == LogicalKeyboardKey.keyI) {
        id = 'items';
      } else if (k == LogicalKeyboardKey.keyL) {
        id = 'parties';
      } else if (k == LogicalKeyboardKey.keyB) {
        id = 'day_book';
      }
      if (id != null) {
        _goId(id);
        return true;
      }
    }
    return false;
  }

  void _onPointerDown(PointerDownEvent e) {
    if ((e.buttons & kBackMouseButton) != 0 && _signedIn && !(_obs?.popupOnTop ?? true)) _back();
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final p = ThemeManager.palette;
    if (!DesktopPrefs.isDesktop) return widget.child;

    // Windows ki apni text scaling * hamari setting.
    final scaled = mq.copyWith(textScaler: TextScaler.linear(mq.textScaler.scale(1) * DesktopPrefs.textScale.value));
    final showSidebar = _signedIn && mq.size.width >= DesktopPrefs.shellMinWidth;
    final collapsed = DesktopPrefs.sidebarCollapsed.value;
    final sidebarW = showSidebar ? (collapsed ? 76.0 : 236.0) : 0.0;

    final content = LayoutBuilder(builder: (context, c) {
      final w = math.min(c.maxWidth, DesktopPrefs.maxContentWidth);
      return ColoredBox(
        color: p.bg,
        child: Center(
          child: SizedBox(
            width: w,
            height: c.maxHeight,
            child: MediaQuery(data: scaled.copyWith(size: Size(w, c.maxHeight)), child: widget.child),
          ),
        ),
      );
    });

    return MediaQuery(
      data: scaled,
      child: Listener(
        onPointerDown: _onPointerDown,
        child: Row(children: [
          if (showSidebar)
            SizedBox(
              width: sidebarW,
              child: AbsorbPointer(
                absorbing: _obs?.popupOnTop ?? false,
                child: _Sidebar(
                  items: _items(),
                  activeId: _activeId(),
                  collapsed: collapsed,
                  onTap: _go,
                  onLogout: _logout,
                  onHelp: showDesktopShortcuts,
                ),
              ),
            ),
          Expanded(key: const ValueKey('desktop-content'), child: content),
        ]),
      ),
    );
  }
}

/// F1 / Settings: saare keyboard shortcuts ki list.
Future<void> showDesktopShortcuts() async {
  final ctx = AppLock.navigatorKey.currentState?.overlay?.context;
  if (ctx == null) return;
  Widget row(String keys, String en, String ur) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(children: [
          SizedBox(
            width: 150,
            child: Text(keys, style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.bold)),
          ),
          Expanded(child: Text(Loc.t(en, ur))),
        ]),
      );
  Widget head(String en, String ur) => Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 4),
        child: Text(Loc.t(en, ur), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
      );
  await showDialog<void>(
    context: ctx,
    builder: (c) => AlertDialog(
      title: Text(Loc.t('Keyboard shortcuts', 'کی بورڈ شارٹ کٹس')),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            head('Anywhere', 'ہر جگہ'),
            row('Ctrl + D', 'Dashboard', 'ڈیش بورڈ'),
            row('Ctrl + N', 'New sale', 'نئی سیل'),
            row('Ctrl + I', 'Items', 'آئٹمز'),
            row('Ctrl + L', 'Customers & Suppliers (ledger)', 'گاہک اور سپلائر (کھاتہ)'),
            row('Ctrl + B', 'Day book', 'روزنامچہ'),
            row('Alt + ←', 'Back (mouse back button too)', 'واپس (ماؤس کا بیک بٹن بھی)'),
            row('Ctrl + +  /  Ctrl + −', 'Bigger / smaller text', 'بڑا / چھوٹا ٹیکسٹ'),
            row('Ctrl + 0', 'Normal text size', 'عام ٹیکسٹ سائز'),
            row('F1', 'This list', 'یہ فہرست'),
            head('Dashboard', 'ڈیش بورڈ'),
            row('Ctrl + F', 'Search item / customer', 'آئٹم / کسٹمر تلاش'),
            row('F5', 'Refresh', 'ریفریش'),
            head('Sale screen', 'سیل اسکرین'),
            row('F2', 'Item search', 'آئٹم تلاش'),
            row('F3', 'Customer', 'کسٹمر'),
            row('F4', 'Discount', 'ڈسکاؤنٹ'),
            row('F7', 'Retail / Wholesale', 'ریٹیل / ہول سیل'),
            row('F8', 'Amount mode', 'رقم موڈ'),
            row('F9  /  Ctrl + S', 'Save bill', 'بل محفوظ کریں'),
            row('Ctrl + P', 'Print', 'پرنٹ'),
            row('Ctrl + Q', 'Quick sale', 'کوئیک سیل'),
            row('Ctrl + H  /  Ctrl + R', 'Hold / Recall bill', 'بل ہولڈ / واپس'),
          ]),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(c), child: Text(Loc.t('Close', 'بند کریں')))],
    ),
  );
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.items,
    required this.activeId,
    required this.collapsed,
    required this.onTap,
    required this.onLogout,
    required this.onHelp,
  });

  final List<_NavItem> items;
  final String? activeId;
  final bool collapsed;
  final void Function(_NavItem) onTap;
  final VoidCallback onLogout;
  final VoidCallback onHelp;

  static const _bg = Color(0xFF0B2545); // Hanna navy (app icon jaisa)
  static const _accent = Color(0xFFF5B841); // Hanna gold

  @override
  Widget build(BuildContext context) {
    final name = Session.username ?? '';
    final role = Session.role;
    final roleLabel = role.isEmpty ? '' : role[0].toUpperCase() + role.substring(1);
    return Material(
      color: _bg,
      child: SafeArea(
        child: Column(children: [
          // Brand
          Padding(
            padding: EdgeInsets.fromLTRB(collapsed ? 0 : 18, 18, collapsed ? 0 : 12, 14),
            child: Row(
              mainAxisAlignment: collapsed ? MainAxisAlignment.center : MainAxisAlignment.start,
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(10)),
                  child: const Icon(Icons.point_of_sale, color: _accent, size: 22),
                ),
                if (!collapsed) ...[
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text('Hanna POS',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800)),
                  ),
                ],
              ],
            ),
          ),
          Divider(height: 1, color: Colors.white.withValues(alpha: 0.1)),
          // Items
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 10),
              children: [for (final i in items) _tile(i)],
            ),
          ),
          Divider(height: 1, color: Colors.white.withValues(alpha: 0.1)),
          // User + controls
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 12),
            child: collapsed
                ? Column(children: [
                    _iconBtn(Icons.keyboard_outlined, onHelp),
                    _iconBtn(Icons.logout, onLogout),
                    _iconBtn(Icons.keyboard_double_arrow_right, () => DesktopPrefs.setSidebarCollapsed(false)),
                  ])
                : Column(children: [
                    Row(children: [
                      CircleAvatar(
                        radius: 17,
                        backgroundColor: _accent,
                        child: Text(name.isEmpty ? '?' : name.substring(0, 1).toUpperCase(),
                            style: const TextStyle(color: _bg, fontWeight: FontWeight.bold)),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                          Text(roleLabel, style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 11)),
                        ]),
                      ),
                    ]),
                    const SizedBox(height: 8),
                    Row(children: [
                      _iconBtn(Icons.keyboard_outlined, onHelp),
                      _iconBtn(Icons.logout, onLogout),
                      const Spacer(),
                      _iconBtn(Icons.keyboard_double_arrow_left, () => DesktopPrefs.setSidebarCollapsed(true)),
                    ]),
                  ]),
          ),
        ]),
      ),
    );
  }

  Widget _iconBtn(IconData icon, VoidCallback onTap) => InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(9),
          child: Icon(icon, size: 20, color: Colors.white.withValues(alpha: 0.75)),
        ),
      );

  Widget _tile(_NavItem i) {
    final active = i.id == activeId;
    final fg = active ? Colors.white : Colors.white.withValues(alpha: 0.72);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: active ? Colors.white.withValues(alpha: 0.12) : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => onTap(i),
          child: Container(
            height: 44,
            padding: EdgeInsets.symmetric(horizontal: collapsed ? 0 : 12),
            decoration: active
                ? const BoxDecoration(
                    border: BorderDirectional(start: BorderSide(color: _accent, width: 3)),
                  )
                : null,
            child: Row(
              mainAxisAlignment: collapsed ? MainAxisAlignment.center : MainAxisAlignment.start,
              children: [
                Icon(i.icon, size: 21, color: active ? _accent : fg),
                if (!collapsed) ...[
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(Loc.t(i.en, i.ur),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: fg, fontSize: 14, fontWeight: active ? FontWeight.bold : FontWeight.w500)),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
