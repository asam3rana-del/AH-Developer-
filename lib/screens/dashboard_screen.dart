import 'package:flutter/material.dart';

import '../db/dashboard_repository.dart';
import '../models/misc_entities.dart';
import '../models/product.dart';
import '../services/biometric.dart';
import '../services/session.dart';
import '../theme/theme_manager.dart';
import '../utils/loc.dart';
import '../widgets/menu_row.dart' show IconBadge;
import '../widgets/role_guard.dart';
import 'balance_sheet_screen.dart';
import 'cash_register_screen.dart';
import 'cash_screen.dart';
import 'day_book_screen.dart';
import 'due_reminders_screen.dart';
import 'expense_screen.dart';
import 'item_search_screen.dart';
import 'items_screen.dart';
import 'login_screen.dart';
import 'party_dashboard_screen.dart';
import 'party_reports_screen.dart';
import 'product_screen.dart';
import 'purchase_history_screen.dart';
import 'purchase_screen.dart';
import 'rate_comparison_screen.dart';
import 'reports_screen.dart';
import 'sale_history_screen.dart';
import 'sale_screen.dart';
import 'settings_screen.dart';
import 'shell_ledger_screen.dart';
import 'stock_report_screen.dart';
import 'zakat_screen.dart';

/// Ek dashboard card. [open] aur [onTap] dono null => abhi port nahi hua ("Coming soon").
class _Action {
  final String en, ur, subEn, subUr;
  final IconData icon;
  final Color bg, fg;
  final Widget Function()? open;
  final VoidCallback? onTap;
  final Set<String>? roles; // null => sab roles
  const _Action(this.en, this.ur, this.subEn, this.subUr, this.icon, this.bg, this.fg, {this.open, this.onTap, this.roles});
}

/// Mirrors MainActivity.kt — header (Settings / dark toggle / Quick Switch), live item-rate search,
/// Today's sale/profit (tap = hide), QUICK ACTIONS grid, DUES SUMMARY (You'll get / give).
///
/// Data + faislay `lib/db/dashboard_repository.dart` mein hain (pure functions, test/dashboard_test.dart).
/// Kotlin Dashboard par sirf quick actions hain; baqi screens (Reports, Products, Zakat ...) Kotlin mein
/// Settings/Reports ke andar hain. Flutter Settings/Reports mein woh links abhi nahi, is liye woh neeche
/// "MORE SCREENS" mein hain — links aane par yeh section hata dein.
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  static const _am = {'admin', 'manager'};
  static const _admin = {'admin'};

  // Kotlin: get/give green & red semantic hain — theme badalne par bhi wahi rehte hain.
  static const _partyGreen = Color(0xFF1B8A4A);
  static const _partyGreenBg = Color(0xFFEAF3DE);
  static const _partyRed = Color(0xFFD32F4A);
  static const _partyRedBg = Color(0xFFFCEBEB);

  static const _defaultShopName = 'IBTISAAM Kiryana Store';

  AppPalette get _p => ThemeManager.palette;

  final _searchCtrl = TextEditingController();
  List<Product>? _products; // cache; doosri screen se wapas aane par reset
  List<Product> _matches = const [];
  String _query = '';

  double _sale = 0;
  double _profit = 0;
  bool _saleHidden = false;
  bool _profitHidden = false;
  double _toGet = 0;
  double _toGive = 0;
  int _pending = 0;
  String _shopName = '';
  bool _showMore = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ data

  /// Kotlin onResume: loadDashboard + loadShopName + loadPartySummary + sync pending.
  /// Har hissa alag try mein — ek fail ho to baqi numbers phir bhi dikhen.
  Future<void> _refresh() async {
    final repo = DashboardRepository.instance;
    String? error;

    DashboardTotals? totals;
    ({double toGet, double toGive})? party;
    int? pending;
    String? shop;
    try {
      totals = await repo.todayTotals();
    } catch (e) {
      error ??= e.toString();
    }
    try {
      party = await repo.partyTotalsNow();
    } catch (e) {
      error ??= e.toString();
    }
    try {
      pending = await repo.pendingSyncCount();
    } catch (e) {
      error ??= e.toString();
    }
    try {
      shop = await repo.shopName();
    } catch (e) {
      error ??= e.toString();
    }
    if (!mounted) return;
    setState(() {
      if (totals != null) {
        _sale = totals.sale;
        _profit = totals.profit ?? 0;
      }
      if (party != null) {
        _toGet = party.toGet;
        _toGive = party.toGive;
      }
      if (pending != null) _pending = pending;
      if (shop != null) _shopName = shop;
    });
    if (error != null) _toast(error);
  }

  Future<void> _onSearch(String q) async {
    final t = q.trim();
    setState(() => _query = t);
    if (t.isEmpty) {
      setState(() => _matches = const []);
      return;
    }
    try {
      _products ??= await DashboardRepository.instance.loadProducts();
    } catch (e) {
      _toast(e.toString());
      return;
    }
    // Is dauran user ne aur type kar diya ho to purana jawab na dikhayen.
    if (!mounted || _searchCtrl.text.trim() != t) return;
    setState(() => _matches = dashboardSearch(_products!, t));
  }

  // ------------------------------------------------------------ navigation

  Future<void> _push(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    if (!mounted) return;
    _products = null; // products doosri screen par badal sakte hain
    _refresh();
    if (_query.isNotEmpty) _onSearch(_searchCtrl.text);
  }

  void _run(_Action a) {
    if (a.onTap != null) {
      a.onTap!();
    } else if (a.open != null) {
      _push(a.open!());
    } else {
      _toast(Loc.t('Coming soon', 'جلد آ رہا ہے'));
    }
  }

  Future<void> _logout() async {
    await Session.clear();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const LoginScreen()), (_) => false);
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  // ------------------------------------------------------------ quick switch

  Future<void> _openQuickSwitch() async {
    final List<User> users;
    try {
      users = await DashboardRepository.instance.activeUsers();
    } catch (e) {
      _toast(e.toString());
      return;
    }
    if (!mounted || users.isEmpty) return;
    final picked = await showDialog<User>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(Loc.t('Switch User', 'یوزر تبدیل کریں')),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: [for (final u in users) _switchRow(ctx, u)],
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(Loc.t('Cancel', 'منسوخ کریں')))],
      ),
    );
    if (picked == null || !mounted) return;
    await _attemptSwitch(picked);
  }

  Widget _switchRow(BuildContext ctx, User u) {
    final p = _p;
    final isCurrent = u.username == Session.username;
    final roleColor = Color(roleColorValue(u.role));
    final roleLabel = u.role.isEmpty ? '' : u.role[0].toUpperCase() + u.role.substring(1);
    return Opacity(
      opacity: isCurrent ? 0.55 : 1,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        decoration: BoxDecoration(
          color: p.cardWhite,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: p.border),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: isCurrent ? null : () => Navigator.pop(ctx, u),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(children: [
              CircleAvatar(
                radius: 19,
                backgroundColor: roleColor,
                child: Text(
                  u.displayName.isEmpty ? '?' : u.displayName.substring(0, 1).toUpperCase(),
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(
                    isCurrent ? '${u.displayName} (${Loc.t('Current', 'موجودہ')})' : u.displayName,
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: p.textDark),
                  ),
                  const SizedBox(height: 2),
                  Text(roleLabel, style: TextStyle(fontSize: 11.5, color: roleColor)),
                ]),
              ),
              if (!isCurrent) Icon(Icons.chevron_right, color: p.textMuted),
            ]),
          ),
        ),
      ),
    );
  }

  /// Kotlin attemptQuickSwitch(): pehle fingerprint; na ho / cancel ho / fail ho to us user ka password.
  Future<void> _attemptSwitch(User user) async {
    if (await Biometric.isAvailable()) {
      final ok = await Biometric.authenticate(
        reason: Loc.t('Verify fingerprint to switch to ${user.displayName}',
            '${user.displayName} کے اکاؤنٹ پر جانے کے لیے فنگر پرنٹ سے تصدیق کریں'),
      );
      if (!mounted) return;
      if (ok) {
        await _completeSwitch(user);
        return;
      }
    }
    await _askPassword(user);
  }

  Future<void> _askPassword(User user) async {
    final typed = await showDialog<String>(context: context, builder: (_) => _PasswordDialog(name: user.displayName));
    if (typed == null || !mounted) return;
    final bool ok;
    try {
      ok = await DashboardRepository.instance.verifySwitchPassword(user, typed);
    } catch (e) {
      _toast(e.toString());
      return;
    }
    if (!mounted) return;
    if (ok) {
      await _completeSwitch(user);
    } else {
      _toast(Loc.t('Wrong password', 'غلط پاس ورڈ'));
    }
  }

  /// Kotlin completeQuickSwitch(): session badlo aur dashboard naye role ke hisaab se dobara banao (recreate()).
  Future<void> _completeSwitch(User user) async {
    await DashboardRepository.instance.completeSwitch(user);
    if (!mounted) return;
    _toast(Loc.t('Switched to ${user.displayName}', '${user.displayName} پر سوئچ ہو گیا'));
    Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const DashboardScreen()), (_) => false);
  }

  // ---------------------------------------------------------------- actions

  /// Kotlin `quickActions` list, usi tarteeb mein.
  List<_Action> _quickActions(AppPalette p) {
    final role = Session.role;
    return [
      _Action('Sale', 'سیل', 'Start a new sale', 'نئی سیل شروع کریں', Icons.shopping_cart_outlined, p.flatPurpleBg, p.flatPurpleFg,
          open: () => const SaleScreen()),
      _Action('Quick Sale', 'کوئیک سیل', 'Fast single-item sale', 'ایک آئٹم کی تیز سیل', Icons.timer_outlined, p.flatPurpleBg,
          p.flatPurpleFg,
          open: () => const SaleScreen(openQuickSale: true)),
      if (role == 'admin')
        _Action('Purchase', 'خریداری', 'Record a purchase', 'خریداری درج کریں', Icons.inventory_2_outlined, p.flatCoralBg, p.flatCoralFg,
            open: () => const RoleGuard(allowed: _admin, child: PurchaseScreen())),
      _Action('Cash', 'کیش', 'Cash in / cash out', 'کیش اِن / آؤٹ', Icons.account_balance_wallet_outlined, p.flatAmberBg, p.flatAmberFg,
          open: () => const CashScreen()),
      _Action('Payments', 'ادائیگیاں', 'Receive or make a payment', 'رقم وصول یا ادا کریں', Icons.account_balance, p.flatTealBg,
          p.flatTealFg,
          open: () => const PartyDashboardScreen(quickPayment: true)),
      _Action('Customers &\nSuppliers', 'گاہک اور\nسپلائر', 'Manage ledgers & dues', 'کھاتے اور بقایا', Icons.people_outline, p.flatPinkBg,
          p.flatPinkFg,
          open: () => const PartyDashboardScreen()),
      _Action('Low Stock', 'کم اسٹاک', 'Items needing restock', 'دوبارہ منگوانے والی اشیاء', Icons.warning_amber_rounded, _partyRedBg,
          _partyRed,
          open: () => const StockReportScreen(lowStockOnly: true)),
      // Items abhi Flutter mein admin tak (Kotlin ka tile sab ko dikhta hai) — ItemsScreen ka RoleGuard barqarar.
      if (role == 'admin')
        _Action('Items', 'آئٹمز', 'Products, categories & units', 'پروڈکٹس، کیٹیگریز اور یونٹس', Icons.list_alt, p.flatBlueBg, p.flatBlueFg,
            open: () => const RoleGuard(allowed: _admin, child: ItemsScreen())),
      if (_am.contains(role))
        _Action('Backup', 'بیک اپ', 'Export data (CSV + PDF)', 'ڈیٹا ایکسپورٹ', Icons.save_outlined, p.flatBlueBg, p.flatBlueFg),
      _Action('Day book', 'روزنامچہ', 'View daily ledger', 'روزانہ کھاتہ', Icons.menu_book_outlined, p.flatTealBg, p.flatTealFg,
          open: () => const DayBookScreen()),
      if (showsLogoutTile(role))
        _Action('Logout', 'لاگ آؤٹ', 'Sign out of this session', 'اس سیشن سے سائن آؤٹ کریں', Icons.logout, _partyRedBg, _partyRed,
            onTap: _logout),
    ];
  }

  /// Kotlin dashboard par nahi — Settings/Reports ke andar hain (wahan link aane tak yahan).
  List<_Action> _moreActions(AppPalette p) {
    final role = Session.role;
    final all = <_Action>[
      _Action('Rate Search', 'ریٹ سرچ', 'Item rates in seconds', 'آئٹم کے ریٹ فوراً', Icons.price_check, p.flatTealBg, p.flatTealFg,
          open: () => const ItemSearchScreen()),
      _Action('Rate Comparison', 'ریٹ کا موازنہ', 'Best supplier rate per item', 'فی آئٹم بہترین سپلائر ریٹ', Icons.balance, p.flatTealBg,
          p.flatTealFg,
          roles: _am, open: () => const RoleGuard(allowed: _am, child: RateComparisonScreen())),
      _Action('Cash Register', 'کیش رجسٹر', 'Daily till open & close', 'روزانہ رجسٹر کھولیں / بند کریں', Icons.point_of_sale, p.flatAmberBg,
          p.flatAmberFg,
          open: () => const CashRegisterScreen()),
      _Action('Expenses', 'اخراجات', 'Track business spending', 'کاروباری اخراجات', Icons.receipt_long, p.flatCoralBg, p.flatCoralFg,
          open: () => const ExpenseScreen()),
      _Action('Sale History', 'سیل ہسٹری', 'Past sales by customer', 'پرانی سیلز، گاہک کے حساب سے', Icons.receipt, p.flatTealBg, p.flatTealFg,
          open: () => const SaleHistoryScreen()),
      _Action('Purchase History', 'خریداری کی تاریخ', 'Supplier bills, return & delete', 'سپلائر بلز، واپسی اور حذف', Icons.history,
          p.flatCoralBg, p.flatCoralFg,
          roles: _admin, open: () => const PurchaseHistoryScreen()),
      _Action('Products', 'پروڈکٹس', 'Products, categories & units', 'پروڈکٹس، کیٹیگریز اور یونٹس', Icons.category_outlined, p.flatBlueBg,
          p.flatBlueFg,
          roles: _admin, open: () => const RoleGuard(allowed: _admin, child: ProductScreen())),
      _Action('Reports', 'رپورٹس', 'Sales, stock & financial overview', 'سیل، اسٹاک اور مالیاتی جائزہ', Icons.bar_chart, p.flatPurpleBg,
          p.flatPurpleFg,
          roles: _am, open: () => const ReportsScreen()),
      _Action('Party Reports', 'پارٹی رپورٹس', 'Ledger, statement & item reports', 'لیجر، اسٹیٹمنٹ اور آئٹم رپورٹس', Icons.people_alt,
          p.flatPurpleBg, p.flatPurpleFg,
          roles: _am, open: () => const PartyReportsScreen()),
      _Action('Balance Sheet', 'بیلنس شیٹ', 'Assets, liabilities & capital', 'اثاثے، واجبات اور سرمایہ', Icons.assessment, p.flatBlueBg,
          p.flatBlueFg,
          roles: _am, open: () => const RoleGuard(allowed: _am, child: BalanceSheetScreen())),
      _Action('Due Reminders', 'ادائیگی یاد دہانی', 'Credit still owed, by due date', 'ادھار جو باقی ہے، تاریخ کے ساتھ', Icons.alarm,
          p.flatAmberBg, p.flatAmberFg,
          roles: _am, open: () => const DueRemindersScreen()),
      _Action('Zakat', 'زکوٰۃ', 'Ramadan-to-Ramadan tracker', 'رمضان تا رمضان حساب', Icons.volunteer_activism, p.flatTealBg, p.flatTealFg,
          roles: _am, open: () => const RoleGuard(allowed: _am, child: ZakatScreen())),
      _Action('Shell Ledger', 'شیل لیجر', 'Bottles given & shells back', 'بھری بوتلیں اور واپس شیل', Icons.repeat, p.flatAmberBg,
          p.flatAmberFg,
          open: () => const ShellLedgerScreen()),
    ];
    return all.where((a) => a.roles == null || a.roles!.contains(role)).toList();
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final p = _p;
    final mq = MediaQuery.of(context);
    final cols = dashboardColumns(mq.size.width);
    final more = _moreActions(p);
    return Scaffold(
      backgroundColor: p.bg,
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            _header(p, mq.padding.top),
            Padding(
              padding: EdgeInsets.fromLTRB(16, 20, 16, 28 + mq.padding.bottom),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _searchBar(p),
                if (_query.isNotEmpty) _searchResults(p),
                const SizedBox(height: 22),
                _statRow(p),
                const SizedBox(height: 26),
                _sectionLabel(p, Loc.t('QUICK ACTIONS', 'فوری کام')),
                _grid(_quickActions(p), cols, p),
                const SizedBox(height: 22),
                _sectionLabel(p, Loc.t('DUES SUMMARY', 'بقایا کا خلاصہ')),
                _duesRow(),
                if (_pending > 0) _syncPendingLabel(),
                if (more.isNotEmpty) ...[
                  const SizedBox(height: 22),
                  _moreToggle(p),
                  if (_showMore) ...[const SizedBox(height: 12), _grid(more, cols, p)],
                ],
              ]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(AppPalette p, double topInset) {
    final role = Session.role;
    final roleLabel = role.isEmpty ? '' : role[0].toUpperCase() + role.substring(1);
    return Container(
      padding: EdgeInsets.fromLTRB(16, topInset + 14, 16, 16),
      decoration: BoxDecoration(
        color: p.cardWhite,
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(28)),
        border: Border(bottom: BorderSide(color: p.border)),
      ),
      child: Column(children: [
        Row(children: [
          // Products & Reports Kotlin mein Settings ke andar hain — gear yahin le jata hai.
          _circleButton(Icons.settings_outlined, p.flatPurpleBg, p.flatPurpleFg, Loc.t('Settings', 'سیٹنگز'),
              () => _push(const SettingsScreen())),
          const SizedBox(width: 10),
          // Us mode ka icon jis par switch hoga.
          _circleButton(ThemeManager.isDark.value ? Icons.light_mode_outlined : Icons.dark_mode_outlined, p.flatAmberBg, p.flatAmberFg,
              Loc.t('Dark mode', 'ڈارک موڈ'), () => ThemeManager.toggleDarkMode()),
          const SizedBox(width: 10),
          _circleButton(Icons.swap_horiz, p.flatTealBg, p.flatTealFg, Loc.t('Switch user', 'یوزر تبدیل کریں'), _openQuickSwitch),
          const Spacer(),
          Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(shape: BoxShape.circle, color: p.flatPurpleBg),
              child: Text('IK', style: TextStyle(color: p.flatPurpleFg, fontWeight: FontWeight.bold, fontSize: 13)),
            ),
            const SizedBox(height: 5),
            Text('$roleLabel ${Loc.t('Panel', 'پینل')}',
                style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: p.textMuted)),
          ]),
        ]),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 16, 8, 0),
          child: Text(
            _shopName.isEmpty ? _defaultShopName : _shopName,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 19.5, fontWeight: FontWeight.bold, color: p.textDark),
          ),
        ),
      ]),
    );
  }

  Widget _circleButton(IconData icon, Color bg, Color fg, String tooltip, VoidCallback onTap) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: bg,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(width: 40, height: 40, child: Icon(icon, size: 18, color: fg)),
        ),
      ),
    );
  }

  Widget _searchBar(AppPalette p) {
    return Container(
      padding: const EdgeInsetsDirectional.fromSTEB(10, 6, 8, 6),
      decoration: BoxDecoration(
        color: p.cardWhite,
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: p.border),
      ),
      child: Row(children: [
        IconBadge(icon: Icons.search, color: p.flatTealFg, bg: p.flatTealBg, size: 36, iconSize: 16),
        const SizedBox(width: 12),
        Expanded(
          child: TextField(
            controller: _searchCtrl,
            onChanged: _onSearch,
            textInputAction: TextInputAction.search,
            style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold, color: p.textDark),
            decoration: InputDecoration(
              isDense: true,
              border: InputBorder.none,
              hintText: Loc.t('Search Item Rate…', 'آئٹم ریٹ سرچ کریں…'),
              hintStyle: TextStyle(color: p.textMuted, fontWeight: FontWeight.bold),
            ),
          ),
        ),
        if (_query.isNotEmpty)
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.close, size: 18, color: p.textMuted),
            onPressed: () {
              _searchCtrl.clear();
              _onSearch('');
            },
          ),
      ]),
    );
  }

  /// Kotlin runItemSearch(): pehle 6 match; tap => ItemSearchScreen usi item par khuli hui.
  Widget _searchResults(AppPalette p) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(
        color: p.cardWhite,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: p.border),
      ),
      child: _matches.isEmpty
          ? Padding(
              padding: const EdgeInsets.all(18),
              child: Text(Loc.t('No matching items', 'کوئی آئٹم نہیں ملا'), style: TextStyle(fontSize: 13, color: p.textMuted)),
            )
          : Column(children: [
              for (var i = 0; i < _matches.length; i++) ...[
                InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: () => _push(ItemSearchScreen(preselectBarcode: _matches[i].barcode)),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                    child: Row(children: [
                      Expanded(
                        child: Text(_matches[i].name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: p.textDark)),
                      ),
                      const SizedBox(width: 10),
                      Text(dashboardAmount(_matches[i].salePrice),
                          style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: p.flatBlueFg)),
                    ]),
                  ),
                ),
                if (i != _matches.length - 1)
                  Divider(height: 1, thickness: 1, indent: 18, endIndent: 18, color: p.border),
              ],
            ]),
    );
  }

  Widget _sectionLabel(AppPalette p, String text) => Padding(
        padding: const EdgeInsetsDirectional.only(start: 4, bottom: 14),
        child: Text(text, style: TextStyle(fontSize: 12.5, letterSpacing: 0.8, fontWeight: FontWeight.bold, color: p.textMuted)),
      );

  Widget _statCard({
    required String label,
    required String value,
    required Color bg,
    required Color fg,
    VoidCallback? onTap,
  }) {
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(26),
      child: InkWell(
        borderRadius: BorderRadius.circular(26),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: TextStyle(fontSize: 12.5, color: fg)),
            const SizedBox(height: 6),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: AlignmentDirectional.centerStart,
              child: Text(value, style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: fg)),
            ),
          ]),
        ),
      ),
    );
  }

  /// Today's sale (sab roles) + Today's profit (sirf admin). Tap = amount chhupao / dikhao.
  Widget _statRow(AppPalette p) {
    final sale = _statCard(
      label: Loc.t("Today's sale", 'آج کی سیل'),
      value: dashboardAmount(_sale, hidden: _saleHidden),
      bg: p.flatTealBg,
      fg: p.flatTealFg,
      onTap: () => setState(() => _saleHidden = !_saleHidden),
    );
    if (!showsProfitCard(Session.role)) return sale;
    final profit = _statCard(
      label: Loc.t("Today's profit", 'آج کا منافع'),
      value: dashboardAmount(_profit, hidden: _profitHidden),
      bg: p.flatBlueBg,
      fg: p.flatBlueFg,
      onTap: () => setState(() => _profitHidden = !_profitHidden),
    );
    return Row(children: [Expanded(child: sale), const SizedBox(width: 18), Expanded(child: profit)]);
  }

  /// Kotlin: dono card tap => Party Dashboard.
  Widget _duesRow() {
    return Row(children: [
      Expanded(
        child: _statCard(
          label: Loc.t("You'll get", 'آپ کو ملنا ہے'),
          value: dashboardAmount(_toGet),
          bg: _partyGreenBg,
          fg: _partyGreen,
          onTap: () => _push(const PartyDashboardScreen()),
        ),
      ),
      const SizedBox(width: 18),
      Expanded(
        child: _statCard(
          label: Loc.t("You'll give", 'آپ کو دینا ہے'),
          value: dashboardAmount(_toGive),
          bg: _partyRedBg,
          fg: _partyRed,
          onTap: () => _push(const PartyDashboardScreen()),
        ),
      ),
    ]);
  }

  /// sync_queue mein na bheji hui rows — tap => Settings (Kotlin: Sync History wahin hai).
  Widget _syncPendingLabel() {
    final msg = syncPendingMessage(_pending, urdu: Loc.isUrdu);
    if (msg == null) return const SizedBox.shrink();
    return InkWell(
      onTap: () => _push(const SettingsScreen()),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
        child: Text(msg, style: const TextStyle(fontSize: 12, color: _partyRed)),
      ),
    );
  }

  Widget _moreToggle(AppPalette p) {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => setState(() => _showMore = !_showMore),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        decoration: BoxDecoration(
          color: p.cardWhite,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: p.border),
        ),
        child: Row(children: [
          Expanded(
            child: Text(Loc.t('MORE SCREENS', 'مزید اسکرینز'),
                style: TextStyle(fontSize: 12.5, letterSpacing: 0.8, fontWeight: FontWeight.bold, color: p.textMuted)),
          ),
          Icon(_showMore ? Icons.expand_less : Icons.expand_more, color: p.textMuted),
        ]),
      ),
    );
  }

  /// Kotlin buildQuickActionRows(): har row mein [cols] card (2 / 3 / 4).
  Widget _grid(List<_Action> actions, int cols, AppPalette p) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: cols,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        mainAxisExtent: 146,
      ),
      itemCount: actions.length,
      itemBuilder: (_, i) => _actionCard(actions[i], p),
    );
  }

  Widget _actionCard(_Action a, AppPalette p) {
    final comingSoon = a.open == null && a.onTap == null;
    return Material(
      color: p.cardWhite,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: BorderSide(color: p.border)),
      child: InkWell(
        customBorder: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        onTap: () => _run(a),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            IconBadge(icon: a.icon, color: a.fg, bg: a.bg, size: 36, iconSize: 18),
            const SizedBox(height: 12),
            Text(
              Loc.t(a.en, a.ur),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold, color: comingSoon ? p.textMuted : p.textDark),
            ),
            const SizedBox(height: 3),
            Text(
              Loc.t(a.subEn, a.subUr),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: p.textMuted),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Kotlin askPasswordForSwitch() ka dialog. Apna controller khud sambhalta hai (dialog band hone par dispose).
class _PasswordDialog extends StatefulWidget {
  final String name;
  const _PasswordDialog({required this.name});

  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final _ctrl = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(Loc.t('Verify Password', 'پاس ورڈ کی تصدیق')),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        obscureText: _obscure,
        onSubmitted: (v) => Navigator.pop(context, v),
        decoration: InputDecoration(
          hintText: Loc.t("${widget.name}'s password", '${widget.name} کا پاس ورڈ'),
          suffixIcon: IconButton(
            icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility),
            onPressed: () => setState(() => _obscure = !_obscure),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(Loc.t('Cancel', 'منسوخ کریں'))),
        FilledButton(onPressed: () => Navigator.pop(context, _ctrl.text), child: Text(Loc.t('Switch', 'سوئچ کریں'))),
      ],
    );
  }
}
