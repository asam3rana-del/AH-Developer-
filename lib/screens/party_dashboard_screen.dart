import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../db/party_dashboard_repository.dart';
import '../models/product.dart';
import '../services/session.dart';
import '../theme/theme_manager.dart';
import '../utils/loc.dart';
import '../widgets/role_guard.dart';
import 'cash_screen.dart';
import 'item_search_screen.dart';
import 'login_screen.dart';
import 'party_screen.dart';
import 'payments_screen.dart';
import 'product_screen.dart';
import 'purchase_screen.dart';
import 'sale_screen.dart';
import 'settings_screen.dart';

/// Mirrors PartyDashboardActivity.kt (+ PartyQuickAddMenu.kt ka "+" menu, chhota hissa).
///
/// "You'll Get / You'll Give" summary cards + Parties / Transactions / Items tabs + search +
/// neeche Add Purchase / "+" / Add Sale bar. Sab roles (Kotlin jaisa); andar ke role checks:
///  * cost / purchase data (Purchase Rate, Purchased totals) sirf admin/manager ko — cashier ke
///    liye repository load hi nahi karta (PORTING_PLAN §1).
///  * Edit Rates, Add Item, Add Purchase sirf admin.
///  * Sale row tap (edit) sirf admin — Day Book jaisa.
///
/// Abhi baaki (Phase 6 ke agle screens / Phase 7 / Phase 10):
///  * Party row tap => PartyTransactionScreen (port hone par `_openParty` mein jorein).
///  * Purchase row tap => edit-saved-purchase (Phase 7).
///  * "+" menu: Sale/Purchase Return (History, Phase 7); Payment Received/Made abhi Payments
///    screen kholta hai (party picker + openPayment PartyQuickAddMenu.kt ke saath aayega).
///  * Overdue / Due Today badge (sales mein dueDate column nahi — Due Reminders ke saath).
///  * Reports (Phase 9). Share summary: share plugin nahi, is liye clipboard mein copy.
class PartyDashboardScreen extends StatefulWidget {
  const PartyDashboardScreen({super.key});

  @override
  State<PartyDashboardScreen> createState() => _PartyDashboardScreenState();
}

enum _Tab { parties, transactions, items }

class _SheetItem {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  const _SheetItem(this.icon, this.color, this.title, this.subtitle, this.onTap);
}

class _PartyDashboardScreenState extends State<PartyDashboardScreen> {
  _Tab _tab = _Tab.parties;
  PartyFilter _filter = PartyFilter.all;

  List<PartyRow> _parties = const [];
  DashboardTransactions _tx = const DashboardTransactions([], {});
  List<ItemAgg> _items = const [];
  bool _loadingTab = false;

  final _partyQ = TextEditingController();
  final _txQ = TextEditingController();
  final _itemQ = TextEditingController();

  final _dateFmt = DateFormat('dd MMM yyyy');
  final _dateTimeFmt = DateFormat('dd MMM, hh:mm a');

  AppPalette get _p => ThemeManager.palette;
  Color get _green => _p.flatTealFg;
  Color get _orange => _p.flatCoralFg;
  Color get _blue => _p.flatBlueFg;
  Color get _purple => _p.flatPurpleFg;
  Color get _gold => _p.flatAmberFg;
  Color get _red => _p.red;

  bool get _canSeeCost => Session.isAdminOrManager;

  @override
  void initState() {
    super.initState();
    _loadParties();
  }

  @override
  void dispose() {
    _partyQ.dispose();
    _txQ.dispose();
    _itemQ.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ data

  Future<void> _loadParties() async {
    try {
      final rows = await PartyDashboardRepository.instance.loadParties();
      if (!mounted) return;
      setState(() => _parties = rows);
    } catch (e) {
      _toast(e.toString());
    }
  }

  Future<void> _loadTx() async {
    setState(() => _loadingTab = true);
    try {
      final data = await PartyDashboardRepository.instance.loadTransactions();
      if (!mounted) return;
      setState(() => _tx = data);
    } catch (e) {
      _toast(e.toString());
    } finally {
      if (mounted) setState(() => _loadingTab = false);
    }
  }

  Future<void> _loadItems() async {
    setState(() => _loadingTab = true);
    try {
      final data = await PartyDashboardRepository.instance.loadItems();
      if (!mounted) return;
      setState(() => _items = data);
    } catch (e) {
      _toast(e.toString());
    } finally {
      if (mounted) setState(() => _loadingTab = false);
    }
  }

  /// Kotlin onResume() + tab kholna: party balances hamesha; baaki tabs jab khule hon.
  Future<void> _reloadActive() async {
    await _loadParties();
    if (!mounted) return;
    if (_tab == _Tab.transactions) await _loadTx();
    if (_tab == _Tab.items) await _loadItems();
  }

  void _setTab(_Tab t) {
    if (_tab == t) return;
    setState(() => _tab = t);
    _reloadActive();
  }

  // ------------------------------------------------------------------ helpers

  String _rs(double v) => 'Rs ${v.toStringAsFixed(2)}';

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  void _comingSoon() => _toast(Loc.t('Coming soon', 'جلد آ رہا ہے'));

  /// Screen kholo, wapas aane par data taza (Kotlin onResume).
  Future<void> _push(Widget page) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
    if (mounted) _reloadActive();
  }

  BoxDecoration _cardDeco(AppPalette p) => BoxDecoration(
        color: p.cardWhite,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 6, offset: const Offset(0, 2))],
      );

  // ------------------------------------------------------------------ actions

  void _openParty(PartyRow r) {
    // TODO(Phase 6): PartyTransactionScreen(partyId: r.id, partyName: r.name, isCustomer: r.isCustomer)
    _comingSoon();
  }

  void _openTx(TxRow row) {
    if (row.isSale) {
      if (!Session.isAdmin) {
        _toast(Loc.t('Only Admin can edit a sale', 'صرف ایڈمن سیل ایڈٹ کر سکتا ہے'));
        return;
      }
      _push(SaleScreen(editInvoice: row.reference));
    } else {
      // Edit-saved-purchase Phase 7 mein.
      _comingSoon();
    }
  }

  Future<void> _logout() async {
    await Session.clear();
    if (!mounted) return;
    Navigator.of(context)
        .pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const LoginScreen()), (_) => false);
  }

  Future<void> _copySummary() async {
    final t = partyTotals(_parties);
    final text = Loc.t(
      "You'll Get: Rs ${t.toGet.toStringAsFixed(2)}\nYou'll Give: Rs ${t.toGive.toStringAsFixed(2)}",
      'آپ کو ملیں گے: روپے ${t.toGet.toStringAsFixed(2)}\nآپ کو دینے ہیں: روپے ${t.toGive.toStringAsFixed(2)}',
    );
    await Clipboard.setData(ClipboardData(text: text));
    _toast(Loc.t('Summary copied', 'خلاصہ کاپی ہو گیا'));
  }

  void _toggleSummaryFilter(PartyFilter target) {
    setState(() {
      _filter = _filter == target ? PartyFilter.all : target;
      _tab = _Tab.parties;
    });
    _loadParties();
  }

  // ------------------------------------------------------------------ sheets / dialogs

  Future<void> _showSheet({
    required IconData icon,
    required String title,
    required String subtitle,
    required List<_SheetItem> items,
  }) {
    final p = _p;
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: p.cardWhite,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.8),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
              child: Row(children: [
                CircleAvatar(radius: 22, backgroundColor: p.navy.withOpacity(0.12), child: Icon(icon, color: p.navy)),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(title, style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: p.textDark)),
                    Text(subtitle, style: TextStyle(fontSize: 12, color: p.textMuted)),
                  ]),
                ),
              ]),
            ),
            Divider(height: 1, color: p.border),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: items.length,
                separatorBuilder: (_, __) => Divider(height: 1, color: p.border),
                itemBuilder: (_, i) {
                  final it = items[i];
                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
                    leading: CircleAvatar(
                        radius: 20, backgroundColor: it.color.withOpacity(0.14), child: Icon(it.icon, color: it.color, size: 20)),
                    title: Text(it.title, style: TextStyle(fontWeight: FontWeight.bold, color: p.textDark)),
                    subtitle: Text(it.subtitle, style: TextStyle(fontSize: 12, color: p.textMuted)),
                    trailing: Icon(Icons.chevron_right, color: p.textMuted),
                    onTap: () {
                      Navigator.pop(ctx);
                      it.onTap();
                    },
                  );
                },
              ),
            ),
          ]),
        ),
      ),
    );
  }

  void _showMainMenu() {
    _showSheet(
      icon: Icons.menu,
      title: Loc.t('Menu', 'مینو'),
      subtitle: Loc.t('Jump to any section', 'کسی بھی سیکشن پر جائیں'),
      items: [
        if (Session.isAdmin)
          _SheetItem(Icons.inventory_2_outlined, _blue, Loc.t('Products', 'پروڈکٹس'),
              Loc.t('Manage your inventory items', 'اپنے انوینٹری آئٹمز کا انتظام کریں'),
              () => _push(const RoleGuard(allowed: {'admin'}, child: ProductScreen()))),
        if (Session.isAdminOrManager)
          _SheetItem(Icons.trending_up, _purple, Loc.t('Reports', 'رپورٹس'),
              Loc.t('Sales, stock & financial overview', 'سیل، اسٹاک اور مالیاتی جائزہ'), _comingSoon),
        _SheetItem(Icons.account_balance_wallet_outlined, _green, Loc.t('Cash In/Out', 'کیش ان/آؤٹ'),
            Loc.t('Record cash movements', 'کیش کی آمد و رفت درج کریں'), () => _push(const CashScreen())),
        _SheetItem(Icons.search, _green, Loc.t('Item Rate Search', 'آئٹم ریٹ سرچ'),
            Loc.t("Look up any item's price", 'کسی بھی آئٹم کی قیمت دیکھیں'), () => _push(const ItemSearchScreen())),
        _SheetItem(Icons.settings_outlined, _orange, Loc.t('Settings', 'سیٹنگز'),
            Loc.t('App preferences & account', 'ایپ کی ترتیبات اور اکاؤنٹ'), () => _push(const SettingsScreen())),
        _SheetItem(Icons.logout, _red, Loc.t('Logout', 'لاگ آؤٹ'),
            Loc.t('Sign out of this session', 'اس سیشن سے سائن آؤٹ کریں'), _logout),
      ],
    );
  }

  void _showQuickAdd() {
    _showSheet(
      icon: Icons.add,
      title: Loc.t('Quick Add', 'فوری اندراج'),
      subtitle: Loc.t('Choose an action', 'ایک عمل منتخب کریں'),
      items: [
        _SheetItem(Icons.receipt_long, _red, Loc.t('Add Sale', 'سیل شامل کریں'),
            Loc.t('Create a new sale invoice', 'نیا سیل انوائس بنائیں'), () => _push(const SaleScreen())),
        if (Session.isAdmin)
          _SheetItem(Icons.shopping_cart_outlined, _blue, Loc.t('Add Purchase', 'خریداری شامل کریں'),
              Loc.t('Create a new purchase bill', 'نیا خریداری بل بنائیں'),
              () => _push(const RoleGuard(allowed: {'admin'}, child: PurchaseScreen()))),
        // Returns History screens (Phase 7) se hoti hain.
        _SheetItem(Icons.undo, _orange, Loc.t('Sale Return', 'سیل واپسی'),
            Loc.t('Return items from a past sale', 'پچھلی سیل سے آئٹمز واپس کریں'), _comingSoon),
        if (Session.isAdmin)
          _SheetItem(Icons.undo, _green, Loc.t('Purchase Return', 'خریداری واپسی'),
              Loc.t('Return items from a past purchase', 'پچھلی خریداری سے آئٹمز واپس کریں'), _comingSoon),
        _SheetItem(Icons.person_add_alt, _purple, Loc.t('New Party', 'نئی پارٹی'),
            Loc.t('Add a customer or supplier', 'کسٹمر یا سپلائر شامل کریں'), () => _push(const PartyScreen())),
        _SheetItem(Icons.account_balance_wallet_outlined, _green, Loc.t('Payment Received', 'ادائیگی وصول ہوئی'),
            Loc.t('Record money received', 'موصول ہونے والی رقم درج کریں'), () => _push(const PaymentsScreen())),
        _SheetItem(Icons.account_balance, _gold, Loc.t('Payment Made', 'ادائیگی ہوئی'),
            Loc.t('Record money paid out', 'ادا کی گئی رقم درج کریں'), () => _push(const PaymentsScreen())),
      ],
    );
  }

  Future<void> _showFilterDialog() async {
    final p = _p;
    final options = <(PartyFilter, String)>[
      (PartyFilter.all, Loc.t('All Parties', 'تمام پارٹیز')),
      (PartyFilter.customers, Loc.t('Customers Only', 'صرف کسٹمرز')),
      (PartyFilter.suppliers, Loc.t('Suppliers Only', 'صرف سپلائرز')),
      (PartyFilter.receivable, Loc.t("Receivable Only (You'll Get)", 'صرف وصولی باقی (آپ کو ملیں گے)')),
      (PartyFilter.payable, Loc.t("Payable Only (You'll Give)", 'صرف ادائیگی باقی (آپ کو دینے ہیں)')),
    ];
    final picked = await showDialog<PartyFilter>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(Loc.t('Filter', 'فلٹر')),
        children: [
          for (final o in options)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, o.$1),
              child: Row(children: [
                Expanded(child: Text(o.$2, style: TextStyle(color: p.textDark))),
                if (_filter == o.$1) Icon(Icons.check, color: p.flatTealFg),
              ]),
            ),
        ],
      ),
    );
    if (picked != null && mounted) setState(() => _filter = picked);
  }

  Future<void> _showItemDetail(ItemAgg c) async {
    final p = _p;
    final pr = c.product;
    Widget line(String label, String value, [Color? color]) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(children: [
            Expanded(child: Text(label, style: TextStyle(fontSize: 13.5, color: p.textMuted))),
            Text(value, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: color ?? p.textDark)),
          ]),
        );

    final edit = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(pr.name),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            line(Loc.t('Category', 'کیٹگری'), pr.category.isEmpty ? '-' : pr.category),
            line(Loc.t('Unit', 'یونٹ'), pr.unit),
            line(Loc.t('Current Stock', 'موجودہ اسٹاک'), pr.formatStockBreakdown()),
            if (_canSeeCost) line(Loc.t('Purchase Rate', 'خرید ریٹ'), _rs(pr.cost), _orange),
            line(Loc.t('Retail Sale Rate', 'ریٹیل ریٹ'), _rs(pr.salePrice), _blue),
            line(Loc.t('Wholesale Rate', 'ہول سیل ریٹ'), _rs(pr.wholesalePrice), _purple),
            Divider(color: p.border),
            line(Loc.t('Total Sold (all-time)', 'کل فروخت'), '${c.soldQty} · ${_rs(c.soldAmt)}', _green),
            if (_canSeeCost)
              line(Loc.t('Total Purchased (all-time)', 'کل خریداری'), '${c.purQty} · ${_rs(c.purAmt)}', _orange),
          ]),
        ),
        actions: [
          if (Session.isAdmin) TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(Loc.t('Edit', 'ایڈٹ'))),
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(Loc.t('Close', 'بند کریں'))),
        ],
      ),
    );
    if (edit == true && mounted) _showEditRates(c);
  }

  Future<void> _showEditRates(ItemAgg c) async {
    final result = await showDialog<({double cost, double sale, double wholesale})>(
      context: context,
      builder: (_) => _EditRatesDialog(product: c.product),
    );
    if (result == null || !mounted) return;
    try {
      await PartyDashboardRepository.instance.saveRates(
        c.product.barcode,
        cost: result.cost,
        salePrice: result.sale,
        wholesalePrice: result.wholesale,
      );
      _toast(Loc.t('Rates updated', 'ریٹ اپڈیٹ ہو گئی'));
      await _loadItems();
    } catch (e) {
      _toast(e.toString());
    }
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final p = _p;
    return Scaffold(
      backgroundColor: p.bg,
      body: Column(children: [
        _header(p),
        Expanded(
          child: Stack(children: [
            CustomScrollView(slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(14, 18, 14, 0),
                sliver: SliverToBoxAdapter(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    _summaryCards(p),
                    const SizedBox(height: 16),
                    _tabs(p),
                    const SizedBox(height: 14),
                    _searchRow(p),
                    const SizedBox(height: 14),
                  ]),
                ),
              ),
              SliverPadding(padding: const EdgeInsets.symmetric(horizontal: 14), sliver: _listSliver(p)),
              const SliverToBoxAdapter(child: SizedBox(height: 110)), // neeche wali bar se door
            ]),
            Positioned(left: 0, right: 0, bottom: 0, child: _bottomBar(p)),
          ]),
        ),
      ]),
    );
  }

  Widget _header(AppPalette p) {
    return Container(
      color: p.navy,
      padding: EdgeInsets.fromLTRB(8, MediaQuery.of(context).padding.top + 8, 8, 16),
      child: Row(children: [
        IconButton(icon: const Icon(Icons.menu, color: Colors.white), onPressed: _showMainMenu),
        Expanded(
          child: Text(Loc.t('Dashboard', 'ڈیش بورڈ'),
              style: const TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.bold)),
        ),
        IconButton(
          icon: const Icon(Icons.notifications_none, color: Colors.white),
          onPressed: () => _toast(Loc.t('No new notifications', 'کوئی نئی اطلاع نہیں')),
        ),
        IconButton(icon: const Icon(Icons.share, color: Color(0xFFFF5252)), onPressed: _copySummary),
      ]),
    );
  }

  // ---- summary cards

  Widget _summaryCards(AppPalette p) {
    final t = partyTotals(_parties);
    return Row(children: [
      Expanded(
        child: _summaryCard(p,
            arrow: '↓',
            label: Loc.t("You'll Get", 'آپ کو ملیں گے'),
            accent: _green,
            value: t.toGet,
            active: _filter == PartyFilter.receivable,
            onTap: () => _toggleSummaryFilter(PartyFilter.receivable)),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: _summaryCard(p,
            arrow: '↑',
            label: Loc.t("You'll Give", 'آپ کو دینے ہیں'),
            accent: _red,
            value: t.toGive,
            active: _filter == PartyFilter.payable,
            onTap: () => _toggleSummaryFilter(PartyFilter.payable)),
      ),
    ]);
  }

  Widget _summaryCard(
    AppPalette p, {
    required String arrow,
    required String label,
    required Color accent,
    required double value,
    required bool active,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        decoration: _cardDeco(p).copyWith(
          color: active ? accent.withOpacity(0.10) : p.cardWhite,
          border: active ? Border.all(color: accent, width: 1.5) : null,
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              width: 26,
              height: 26,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
              child: Text(arrow, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(label, style: TextStyle(fontSize: 12.5, color: p.textMuted))),
          ]),
          const SizedBox(height: 10),
          Text(_rs(value), style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: p.textDark)),
        ]),
      ),
    );
  }

  // ---- tabs + search row

  Widget _tabs(AppPalette p) {
    final entries = <(_Tab, String)>[
      (_Tab.parties, Loc.t('Parties', 'پارٹیز')),
      (_Tab.transactions, Loc.t('Transactions', 'لین دین')),
      (_Tab.items, Loc.t('Items', 'آئٹمز')),
    ];
    return Row(children: [
      for (var i = 0; i < entries.length; i++) ...[
        if (i > 0) const SizedBox(width: 8),
        Expanded(
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: () => _setTab(entries[i].$1),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 13),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: p.cardWhite,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: _tab == entries[i].$1 ? _red : p.border),
              ),
              child: Text(
                entries[i].$2,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: _tab == entries[i].$1 ? FontWeight.bold : FontWeight.normal,
                  color: _tab == entries[i].$1 ? _red : p.textMuted,
                ),
              ),
            ),
          ),
        ),
      ],
    ]);
  }

  Widget _searchField(AppPalette p, TextEditingController c, String hint) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: p.cardWhite,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: p.border),
        ),
        child: Row(children: [
          Icon(Icons.search, size: 18, color: p.textMuted),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: c,
              onChanged: (_) => setState(() {}),
              style: TextStyle(fontSize: 13.5, color: p.textDark),
              decoration: InputDecoration(
                hintText: hint,
                hintStyle: TextStyle(color: p.textMuted, fontSize: 13.5),
                border: InputBorder.none,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _accentButton(String label, Color color, VoidCallback onTap) {
    return Material(
      color: color,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
        ),
      ),
    );
  }

  Widget _searchRow(AppPalette p) {
    switch (_tab) {
      case _Tab.parties:
        return Row(children: [
          _searchField(p, _partyQ, Loc.t('Search party', 'پارٹی تلاش کریں')),
          const SizedBox(width: 10),
          InkWell(
            customBorder: const CircleBorder(),
            onTap: _showFilterDialog,
            child: Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: _filter == PartyFilter.all ? p.cardWhite : _red.withOpacity(0.12),
                shape: BoxShape.circle,
                border: Border.all(color: _filter == PartyFilter.all ? p.border : _red),
              ),
              child: Icon(Icons.filter_list, size: 20, color: _filter == PartyFilter.all ? p.textMuted : _red),
            ),
          ),
          const SizedBox(width: 10),
          _accentButton('+ ${Loc.t('New Party', 'نئی پارٹی')}', _blue, () => _push(const PartyScreen())),
        ]);
      case _Tab.transactions:
        return Row(children: [
          _searchField(p, _txQ,
              Loc.t('Search transaction (party or item name)', 'پارٹی یا آئٹم کا نام سے تلاش کریں')),
        ]);
      case _Tab.items:
        return Row(children: [
          _searchField(p, _itemQ, Loc.t('Search item', 'آئٹم تلاش کریں')),
          if (Session.isAdmin) ...[
            const SizedBox(width: 10),
            _accentButton('+ ${Loc.t('Add Item', 'آئٹم شامل کریں')}', _blue,
                () => _push(const RoleGuard(allowed: {'admin'}, child: ProductScreen()))),
          ],
        ]);
    }
  }

  // ---- list

  Widget _emptySliver(AppPalette p, String msg) => SliverToBoxAdapter(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 30),
          decoration: _cardDeco(p),
          alignment: Alignment.center,
          child: Text(msg, textAlign: TextAlign.center, style: TextStyle(color: p.textMuted, fontSize: 13)),
        ),
      );

  Widget _listSliver(AppPalette p) {
    switch (_tab) {
      case _Tab.parties:
        final partyRows = filterPartyRows(_parties, _filter, _partyQ.text);
        if (partyRows.isEmpty) {
          final msg = switch (_filter) {
            PartyFilter.receivable => Loc.t('No one owes you right now', 'ابھی کوئی آپ کا مقروض نہیں'),
            PartyFilter.payable => Loc.t("You don't owe anyone right now", 'ابھی آپ کسی کے مقروض نہیں'),
            _ => Loc.t('No parties found', 'کوئی پارٹی نہیں ملی'),
          };
          return _emptySliver(p, msg);
        }
        return SliverList(
            delegate: SliverChildBuilderDelegate((_, i) => _partyCard(p, partyRows[i]), childCount: partyRows.length));

      case _Tab.transactions:
        if (_loadingTab && _tx.rows.isEmpty) return _loadingSliver();
        final txRows = filterTxRows(_tx.rows, _txQ.text, _tx.itemNamesByKey);
        if (txRows.isEmpty) {
          return _emptySliver(p, Loc.t('No transactions yet', 'ابھی تک کوئی لین دین نہیں ہے'));
        }
        return SliverList(
            delegate: SliverChildBuilderDelegate((_, i) => _txCard(p, txRows[i]), childCount: txRows.length));

      case _Tab.items:
        if (_loadingTab && _items.isEmpty) return _loadingSliver();
        final itemRows = filterItemAggs(_items, _itemQ.text);
        if (itemRows.isEmpty) return _emptySliver(p, Loc.t('No items found', 'کوئی آئٹم نہیں ملا'));
        return SliverList(
            delegate: SliverChildBuilderDelegate((_, i) => _itemCard(p, itemRows[i]), childCount: itemRows.length));
    }
  }

  Widget _loadingSliver() => const SliverToBoxAdapter(
        child: Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator())),
      );

  Widget _partyCard(AppPalette p, PartyRow r) {
    final amountColor = r.isSettled ? p.textDark : (r.isGive ? _red : _green);
    final caption = r.isSettled
        ? ''
        : (r.isGive ? Loc.t("You'll Give", 'آپ کو دینے ہیں') : Loc.t("You'll Get", 'آپ کو ملیں گے'));
    final subtitle = r.lastActivityAt != null
        ? _dateFmt.format(DateTime.fromMillisecondsSinceEpoch(r.lastActivityAt!))
        : (r.isCustomer ? Loc.t('Customer', 'کسٹمر') : Loc.t('Supplier', 'سپلائر'));

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: _cardDeco(p),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => _openParty(r),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
          child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(r.name, style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: p.textDark)),
                const SizedBox(height: 4),
                Text(subtitle, style: TextStyle(fontSize: 11.5, color: p.textMuted)),
                // Stuck Balance: badi figure TOTAL hai, ye line use Daily + Stuck mein todti hai.
                if (r.stuck != 0.0)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      '${Loc.t('Daily', 'روزانہ')} Rs ${(r.closing - r.stuck).toStringAsFixed(0)}  •  '
                      '${Loc.t('Stuck', 'اسٹک')} Rs ${r.stuck.toStringAsFixed(0)}',
                      style: TextStyle(fontSize: 11, color: p.textMuted),
                    ),
                  ),
              ]),
            ),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(
                r.isSettled ? 'Rs 0' : _rs(r.closing.abs()),
                style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold, color: amountColor),
              ),
              if (caption.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(caption, style: TextStyle(fontSize: 11, color: amountColor)),
                ),
            ]),
          ]),
        ),
      ),
    );
  }

  Widget _txCard(AppPalette p, TxRow row) {
    final accent = row.isSale ? _green : _orange;
    final typeLabel = row.isSale ? Loc.t('Sale', 'سیل') : Loc.t('Purchase', 'خریداری');
    final date = _dateTimeFmt.format(DateTime.fromMillisecondsSinceEpoch(row.createdAt));

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: _cardDeco(p),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => _openTx(row),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(row.partyName, style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold, color: p.textDark)),
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                  decoration: BoxDecoration(color: accent.withOpacity(0.12), borderRadius: BorderRadius.circular(20)),
                  child: Text(typeLabel, style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: accent)),
                ),
                const SizedBox(height: 4),
                Text(
                  row.isReturned ? '$date  •  ${Loc.t('Returned', 'واپس')}' : date,
                  style: TextStyle(fontSize: 11, color: row.isReturned ? _red : p.textMuted),
                ),
              ]),
            ),
            Text(_rs(row.amount), style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: accent)),
          ]),
        ),
      ),
    );
  }

  Widget _itemCard(AppPalette p, ItemAgg c) {
    final pr = c.product;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: _cardDeco(p),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => _showItemDetail(c),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Text(pr.name, style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold, color: p.textDark)),
              ),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                if (pr.category.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                    decoration:
                        BoxDecoration(color: p.textMuted.withOpacity(0.14), borderRadius: BorderRadius.circular(20)),
                    child: Text(pr.category,
                        style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: p.textMuted)),
                  ),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  // Stock SMALLEST unit mein hota hai — hamesha formatStockBreakdown se dikhayen.
                  child: Text('${Loc.t('Stock', 'اسٹاک')}: ${pr.formatStockBreakdown()}',
                      style: TextStyle(fontSize: 11.5, color: p.textMuted)),
                ),
              ]),
            ]),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '${Loc.t('Category', 'کیٹگری')}: ${pr.category.isEmpty ? '-' : pr.category}  ·  '
                '${Loc.t('Unit', 'یونٹ')}: ${pr.unit}',
                style: TextStyle(fontSize: 11.5, color: p.textMuted),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(children: [
                if (_canSeeCost)
                  Expanded(
                    child: Text('${Loc.t('Purchase Rate', 'خرید ریٹ')}: ${_rs(pr.cost)}',
                        style: TextStyle(fontSize: 11.5, color: _orange)),
                  ),
                Expanded(
                  child: Text('${Loc.t('Retail Rate', 'ریٹیل ریٹ')}: ${_rs(pr.salePrice)}',
                      style: TextStyle(fontSize: 11.5, color: _blue)),
                ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('${Loc.t('Wholesale Rate', 'ہول سیل ریٹ')}: ${_rs(pr.wholesalePrice)}',
                  style: TextStyle(fontSize: 11.5, color: _purple)),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(children: [
                Expanded(
                  child: Text('${Loc.t('Sold', 'فروخت')}: ${c.soldQty} · ${_rs(c.soldAmt)}',
                      style: TextStyle(fontSize: 12, color: _green)),
                ),
                if (_canSeeCost)
                  Text('${Loc.t('Purchased', 'خریدا')}: ${c.purQty} · ${_rs(c.purAmt)}',
                      style: TextStyle(fontSize: 12, color: _orange)),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  // ---- bottom bar

  Widget _bottomBar(AppPalette p) {
    Widget pill(String label, Color color, VoidCallback onTap) => Expanded(
          child: Material(
            color: color,
            borderRadius: BorderRadius.circular(26),
            child: InkWell(
              borderRadius: BorderRadius.circular(26),
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 17),
                child: Center(
                  child: Text(label,
                      style: const TextStyle(color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.bold)),
                ),
              ),
            ),
          ),
        );

    return Container(
      padding: EdgeInsets.fromLTRB(20, 14, 20, 14 + MediaQuery.of(context).padding.bottom),
      decoration: BoxDecoration(
        color: p.cardWhite,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.10), blurRadius: 14, offset: const Offset(0, -2))],
      ),
      child: Row(children: [
        if (Session.isAdmin) ...[
          pill(Loc.t('Add Purchase', 'خریداری شامل کریں'), _blue,
              () => _push(const RoleGuard(allowed: {'admin'}, child: PurchaseScreen()))),
          const SizedBox(width: 10),
        ],
        Material(
          color: _blue,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: _showQuickAdd,
            child: const SizedBox(width: 52, height: 52, child: Icon(Icons.add, color: Colors.white)),
          ),
        ),
        const SizedBox(width: 10),
        pill(Loc.t('Add Sale', 'سیل شامل کریں'), _red, () => _push(const SaleScreen())),
      ]),
    );
  }
}

/// "Edit Rates" dialog (Kotlin showEditRatesDialog): Purchase / Retail / Wholesale, PRIMARY unit par.
/// Apne controllers khud dispose karta hai (dialog band hone ke animation ke baad bhi safe).
class _EditRatesDialog extends StatefulWidget {
  final Product product;
  const _EditRatesDialog({required this.product});

  @override
  State<_EditRatesDialog> createState() => _EditRatesDialogState();
}

class _EditRatesDialogState extends State<_EditRatesDialog> {
  late final TextEditingController _cost;
  late final TextEditingController _sale;
  late final TextEditingController _wholesale;
  String? _error;

  static String _initial(double v) => v == 0.0 ? '' : v.toStringAsFixed(2);

  @override
  void initState() {
    super.initState();
    _cost = TextEditingController(text: _initial(widget.product.cost));
    _sale = TextEditingController(text: _initial(widget.product.salePrice));
    _wholesale = TextEditingController(text: _initial(widget.product.wholesalePrice));
  }

  @override
  void dispose() {
    _cost.dispose();
    _sale.dispose();
    _wholesale.dispose();
    super.dispose();
  }

  void _save() {
    final cost = double.tryParse(_cost.text.trim());
    final sale = double.tryParse(_sale.text.trim());
    final wholesale = double.tryParse(_wholesale.text.trim());
    if (cost == null || sale == null || wholesale == null || cost < 0 || sale < 0 || wholesale < 0) {
      setState(() => _error = Loc.t('Enter valid rates', 'صحیح ریٹ لکھیں'));
      return;
    }
    Navigator.pop(context, (cost: cost, sale: sale, wholesale: wholesale));
  }

  Widget _field(String label, TextEditingController c) => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: TextField(
          controller: c,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: label, hintText: '0.00'),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('${Loc.t('Edit Rates', 'ریٹ ایڈٹ کریں')} — ${widget.product.name}'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          _field(Loc.t('Purchase Rate', 'خرید ریٹ'), _cost),
          _field(Loc.t('Retail Sale Rate', 'ریٹیل ریٹ'), _sale),
          _field(Loc.t('Wholesale Rate', 'ہول سیل ریٹ'), _wholesale),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(_error!, style: TextStyle(color: ThemeManager.palette.red, fontSize: 12.5)),
            ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(Loc.t('Cancel', 'منسوخ کریں'))),
        TextButton(onPressed: _save, child: Text(Loc.t('Save', 'محفوظ کریں'))),
      ],
    );
  }
}
