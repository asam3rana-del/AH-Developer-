import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../db/party_reports_repository.dart';
import '../services/session.dart';
import '../theme/theme_manager.dart';
import '../utils/loc.dart';
import '../utils/sale_cart.dart' show formatQty;
import '../widgets/role_guard.dart';

/// Mirrors PartyReportsActivity.kt.
///
/// Customers / Suppliers tabs -> party par tap -> 6 reports (Item, Ledger, Payment History,
/// Statement, Sale/Purchase by Party, Profit&Loss / Purchase Summary), har ek dialog mein.
///
/// Role: admin + manager (Kotlin mein ye Reports ke andar hai; P&L mein cost hai). Screen ke
/// andar bhi RoleGuard hai, repository bhi `allowCost` check karta hai.
///
/// Farq (Kotlin se): Kotlin ke ic_* drawable icons ki jagah Material icons.
class PartyReportsScreen extends StatelessWidget {
  const PartyReportsScreen({super.key});

  @override
  Widget build(BuildContext context) =>
      const RoleGuard(allowed: {'admin', 'manager'}, child: _PartyReportsBody());
}

class _PartyReportsBody extends StatefulWidget {
  const _PartyReportsBody();

  @override
  State<_PartyReportsBody> createState() => _PartyReportsBodyState();
}

class _PartyReportsBodyState extends State<_PartyReportsBody> {
  bool _customers = true;
  bool _loading = true;
  List<ReportPartyRow> _rows = const [];
  final _search = TextEditingController();
  String _query = '';
  bool _onlyDue = false; // sirf wo party jin ka hisaab baqi hai
  bool _byAmount = false; // true = zyada baqi pehle, false = naam

  final _dateFmt = DateFormat('dd MMM yyyy');
  final _dateTimeFmt = DateFormat('dd MMM yyyy, hh:mm a');

  AppPalette get _p => ThemeManager.palette;
  Color get _primary => _p.flatBlueFg;
  Color get _amber => _p.flatAmberFg;
  Color get _teal => _p.flatTealFg;
  Color get _red => _p.red;

  String _rs(double v) => 'Rs ${v.round()}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Search (naam / phone) + "sirf baqi" + sort lagakar dikhane wali list.
  List<ReportPartyRow> get _visible {
    final q = _query.trim().toLowerCase();
    final list = _rows.where((r) {
      if (_onlyDue && r.closing.abs() < 0.5) return false;
      if (q.isEmpty) return true;
      return r.name.toLowerCase().contains(q) || r.phone.contains(q);
    }).toList();
    if (_byAmount) {
      list.sort((a, b) => b.closing.abs().compareTo(a.closing.abs()));
    } else {
      list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    }
    return list;
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final rows = await PartyReportsRepository.instance.loadParties(customers: _customers);
    if (!mounted) return;
    setState(() {
      _rows = rows;
      _loading = false;
    });
  }

  void _setTab(bool customers) {
    if (_customers == customers) return;
    _customers = customers;
    _load();
  }

  // ---- build -------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final rows = _visible;
    return Scaffold(
      backgroundColor: _p.bg,
      appBar: AppBar(
        backgroundColor: _p.navy,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(Loc.t('Party Reports', 'پارٹی رپورٹس'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          Text(Loc.t('Customer & supplier balances', 'کسٹمر اور سپلائر کا بیلنس'),
              style: TextStyle(fontSize: 11.5, color: _p.headerSubtitleColor)),
        ]),
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 30),
            children: [
              _tabs(),
              if (!_loading) _summaryCards(),
              _searchBox(),
              _filterChips(),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 2, 0, 10),
                child: Text(
                  '${rows.length} ${_customers ? Loc.t('customers', 'کسٹمرز') : Loc.t('suppliers', 'سپلائرز')} · '
                  '${Loc.t('Tap a party to select a report', 'رپورٹ منتخب کرنے کے لیے پارٹی پر ٹیپ کریں')}',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: _p.textMuted),
                ),
              ),
              if (_loading)
                const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator()))
              else if (rows.isEmpty)
                _empty(_rows.isEmpty
                    ? (_customers ? Loc.t('No customers yet', 'کوئی کسٹمر نہیں ہے') : Loc.t('No suppliers yet', 'کوئی سپلائر نہیں ہے'))
                    : Loc.t('No party matches', 'کوئی پارٹی نہیں ملی'))
              else
                for (final r in rows) _partyRow(r),
            ],
          ),
        ),
      ),
    );
  }

  /// Kul Lena (hara) / Kul Dena (laal). Customer tab mein Lena pehle, Supplier tab mein Dena pehle.
  Widget _summaryCards() {
    var lena = 0.0, dena = 0.0;
    for (final r in _rows) {
      if (r.closing.abs() < 0.5) continue;
      if (r.isGive) {
        dena += r.closing.abs();
      } else {
        lena += r.closing.abs();
      }
    }
    Widget card(String arrow, String label, double v, Color c) => Expanded(
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            decoration: BoxDecoration(color: _p.cardWhite, borderRadius: BorderRadius.circular(16), border: Border.all(color: _p.border)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text(arrow, style: TextStyle(color: c, fontWeight: FontWeight.bold, fontSize: 14)),
                const SizedBox(width: 6),
                Flexible(child: Text(label, style: TextStyle(color: _p.textMuted, fontSize: 12.5))),
              ]),
              const SizedBox(height: 6),
              Text(_rs(v), style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold, color: c)),
            ]),
          ),
        );
    final lenaCard = card('↓', Loc.t('Total to Receive', 'کل لینا'), lena, _teal);
    final denaCard = card('↑', Loc.t('Total to Pay', 'کل دینا'), dena, _red);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(children: [
        if (_customers) ...[lenaCard, const SizedBox(width: 10), denaCard] else ...[denaCard, const SizedBox(width: 10), lenaCard],
      ]),
    );
  }

  Widget _searchBox() => Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(color: _p.cardWhite, borderRadius: BorderRadius.circular(24), border: Border.all(color: _p.border)),
        child: Row(children: [
          Icon(Icons.search, size: 18, color: _primary),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _search,
              onChanged: (v) => setState(() => _query = v),
              style: TextStyle(fontSize: 14, color: _p.textDark),
              decoration: InputDecoration(
                hintText: Loc.t('Search name or phone', 'نام یا فون سے تلاش کریں'),
                hintStyle: TextStyle(color: _p.textMuted),
                border: InputBorder.none,
              ),
            ),
          ),
          if (_query.isNotEmpty)
            GestureDetector(
              onTap: () => setState(() {
                _search.clear();
                _query = '';
              }),
              child: Icon(Icons.close, size: 18, color: _p.textMuted),
            ),
        ]),
      );

  Widget _filterChips() {
    Widget chip(String label, bool on, VoidCallback tap) => Padding(
          padding: const EdgeInsets.only(right: 8),
          child: ChoiceChip(
            label: Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: on ? Colors.white : _p.textDark)),
            selected: on,
            selectedColor: _primary,
            backgroundColor: _p.cardWhite,
            side: BorderSide(color: on ? _primary : _p.border),
            showCheckmark: false,
            visualDensity: VisualDensity.compact,
            onSelected: (_) => tap(),
          ),
        );
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          chip(Loc.t('Only balance', 'صرف باقی'), _onlyDue, () => setState(() => _onlyDue = !_onlyDue)),
          chip(Loc.t('Highest first', 'زیادہ باقی پہلے'), _byAmount, () => setState(() => _byAmount = true)),
          chip(Loc.t('Name A-Z', 'نام'), !_byAmount, () => setState(() => _byAmount = false)),
        ]),
      ),
    );
  }

  Widget _tabs() {
    Widget pill(String label, bool selected, Color color, VoidCallback onTap) => Expanded(
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 12),
              alignment: Alignment.center,
              decoration: BoxDecoration(color: selected ? color : Colors.transparent, borderRadius: BorderRadius.circular(10)),
              child: Text(label,
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: selected ? Colors.white : _p.textMuted)),
            ),
          ),
        );
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: _p.cardWhite,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _p.border),
      ),
      child: Row(children: [
        pill(Loc.t('CUSTOMERS', 'کسٹمرز'), _customers, _primary, () => _setTab(true)),
        pill(Loc.t('SUPPLIERS', 'سپلائرز'), !_customers, _amber, () => _setTab(false)),
      ]),
    );
  }

  Widget _partyRow(ReportPartyRow r) {
    final accent = r.isCustomer ? _primary : _amber;
    final clear = r.closing.abs() < 0.5;
    final color = clear ? _p.textMuted : (r.isGive ? _red : _teal);
    final tag = clear
        ? Loc.t('Clear', 'صاف')
        : r.isGive
            ? Loc.t('To pay', 'دینا ہے')
            : Loc.t('To receive', 'لینا ہے');
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: _p.cardWhite,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _p.border),
        boxShadow: const [BoxShadow(color: Color(0x0F000000), blurRadius: 4, offset: Offset(0, 1))],
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => _showReportMenu(r),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(children: [
            _iconCircle(r.isCustomer ? Icons.person_outline : Icons.inventory_2_outlined, accent, 40),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(r.name, style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold, color: _p.textDark)),
                if (r.phone.trim().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(r.phone, style: TextStyle(fontSize: 11.5, color: _p.textMuted)),
                  ),
              ]),
            ),
            const SizedBox(width: 8),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(_rs(r.closing.abs()), style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: color)),
              Text(tag, style: TextStyle(fontSize: 10.5, color: _p.textMuted)),
            ]),
          ]),
        ),
      ),
    );
  }

  // ---- report menu -------------------------------------------------------

  Future<void> _showReportMenu(ReportPartyRow r) async {
    final isC = r.isCustomer;
    final entries = <(IconData, String, VoidCallback)>[
      (Icons.inventory_2_outlined, Loc.t('Party Report by Item', 'آئٹم کے لحاظ سے پارٹی رپورٹ'), () => _showItemReport(r)),
      (Icons.menu_book_outlined, Loc.t('Customer Ledger', 'کسٹمر لیجر'), () => _showLedger(r)),
      (Icons.account_balance_wallet_outlined, Loc.t('Payment History', 'ادائیگی کی تاریخ'), () => _showPaymentHistory(r)),
      (
        Icons.description_outlined,
        isC ? Loc.t('Customer Statement', 'کسٹمر اسٹیٹمنٹ') : Loc.t('Supplier Statement', 'سپلائر اسٹیٹمنٹ'),
        () => _showStatement(r)
      ),
      (Icons.receipt_long_outlined, Loc.t('Sale/Purchase by Party', 'پارٹی کے لحاظ سے سیل/خریداری'), () => _showTransactions(r)),
      (
        Icons.bar_chart_outlined,
        isC ? Loc.t('Customer-wise Profit', 'کسٹمر کے لحاظ سے منافع') : Loc.t('Purchase Summary', 'خریداری کا خلاصہ'),
        () => _showPartyPL(r)
      ),
    ];
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(r.name),
        contentPadding: const EdgeInsets.fromLTRB(6, 12, 6, 6),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (var i = 0; i < entries.length; i++) ...[
              ListTile(
                leading: _iconCircle(entries[i].$1, _primary, 42),
                title: Text(entries[i].$2, style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold, color: _p.textDark)),
                trailing: Text('\u203A', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: _primary)),
                onTap: () {
                  Navigator.pop(ctx);
                  entries[i].$3();
                },
              ),
              if (i != entries.length - 1) Divider(height: 1, color: _p.border),
            ],
          ]),
        ),
      ),
    );
  }

  // ---- 1) Item report ----------------------------------------------------

  Future<void> _showItemReport(ReportPartyRow r) async {
    final items = await PartyReportsRepository.instance.itemReport(isCustomer: r.isCustomer, id: r.id);
    if (!mounted) return;
    await _reportDialog(
      icon: Icons.inventory_2_outlined,
      accent: _primary,
      title: Loc.t('Item Report', 'آئٹم رپورٹ'),
      party: r.name,
      body: items.isEmpty
          ? [_empty(Loc.t('No items found', 'کوئی آئٹم نہیں ملا'))]
          : [for (final i in items) _rowText(i.product, '${formatQty(i.qty)} × — ${_rs(i.amount)}')],
    );
  }

  // ---- 2) Ledger (Dr / Cr) ----------------------------------------------

  Future<void> _showLedger(ReportPartyRow r) async {
    final lines = await PartyReportsRepository.instance.ledgerLines(isCustomer: r.isCustomer, id: r.id);
    if (!mounted) return;
    final res = runLedger(r.opening, lines);
    final opening = r.opening;
    final closingLabel = r.stuck != 0.0
        ? Loc.t('Daily Payable', 'روزانہ واجب الادا')
        : Loc.t('Closing Balance', 'اختتامی بیلنس');

    await _reportDialog(
      icon: Icons.menu_book_outlined,
      accent: _primary,
      title: Loc.t('Ledger', 'لیجر'),
      party: r.name,
      body: [
        _ledgerHeader(),
        _divider(),
        _ledgerRow(Loc.t('Opening Balance', 'ابتدائی بیلنس'),
            dr: opening > 0 ? opening : 0.0, cr: opening < 0 ? -opening : 0.0, balance: opening, bold: true),
        if (lines.isEmpty) _empty(Loc.t('No transactions yet', 'کوئی لین دین نہیں ہے')),
        for (final e in res.rows) _ledgerRow(_dateFmt.format(DateTime.fromMillisecondsSinceEpoch(e.line.time)),
            dr: e.line.dr, cr: e.line.cr, balance: e.balance),
        _divider(),
        _rowText(closingLabel, _rs(res.closing), boldLeft: true, rightColor: res.closing > 0 ? _red : _teal),
        ..._stuckSummary(res.closing, r.stuck, res.closing + r.stuck > 0 ? _red : _teal),
      ],
    );
  }

  // ---- 3) Payment history ------------------------------------------------

  Future<void> _showPaymentHistory(ReportPartyRow r) async {
    final bills = await PartyReportsRepository.instance.bills(isCustomer: r.isCustomer, id: r.id);
    final pays = await PartyReportsRepository.instance.payments(isCustomer: r.isCustomer, id: r.id);
    if (!mounted) return;
    final entries = paymentEntries(bills, isCustomer: r.isCustomer, separate: separatePayments(bills, pays));
    final total = entries.fold<double>(0, (a, e) => a + e.amount);
    await _reportDialog(
      icon: Icons.account_balance_wallet_outlined,
      accent: _teal,
      title: Loc.t('Payment History', 'ادائیگی کی تاریخ'),
      party: r.name,
      body: entries.isEmpty
          ? [_empty(Loc.t('No payments recorded yet', 'ابھی تک کوئی ادائیگی درج نہیں ہوئی'))]
          : [
              for (final e in entries)
                _paymentRow(
                  _dateTimeFmt.format(DateTime.fromMillisecondsSinceEpoch(e.date)),
                  e.general
                      ? (e.isSale ? Loc.t('Payment received', 'ادائیگی وصول ہوئی') : Loc.t('Payment made', 'ادائیگی کی گئی'))
                      : e.isSale
                          ? Loc.t('Against Sale', 'سیل کے مقابلے میں')
                          : Loc.t('Against Purchase', 'خریداری کے مقابلے میں'),
                  e.amount,
                ),
              _divider(),
              _rowText(
                r.isCustomer ? Loc.t('Total Received', 'کل موصول شدہ') : Loc.t('Total Paid', 'کل ادا شدہ'),
                _rs(total),
                boldLeft: true,
                rightColor: _teal,
              ),
            ],
    );
  }

  // ---- 4) Statement ------------------------------------------------------

  Future<void> _showStatement(ReportPartyRow r) async {
    final lines = await PartyReportsRepository.instance.ledgerLines(isCustomer: r.isCustomer, id: r.id);
    if (!mounted) return;
    final res = runLedger(r.opening, lines);
    final paymentLabel = r.isCustomer ? Loc.t('Payment received', 'ادائیگی وصول ہوئی') : Loc.t('Payment made', 'ادائیگی کی گئی');
    final closingLabel = r.stuck != 0.0
        ? Loc.t('Daily Payable', 'روزانہ واجب الادا')
        : Loc.t('Closing Balance', 'اختتامی بیلنس');
    final closingIsGive = reportIsGive(isCustomer: r.isCustomer, closing: res.closing);
    final totalIsGive = reportIsGive(isCustomer: r.isCustomer, closing: res.closing + r.stuck);

    await _reportDialog(
      icon: Icons.description_outlined,
      accent: _primary,
      title: Loc.t('Statement', 'اسٹیٹمنٹ'),
      party: r.name,
      body: [
        _rowText(Loc.t('Opening Balance', 'ابتدائی بیلنس'), _rs(r.opening), boldLeft: true),
        _divider(),
        if (lines.isEmpty) _empty(Loc.t('No transactions yet', 'کوئی لین دین نہیں ہے')),
        for (final e in res.rows)
          _statementRow(
            _dateFmt.format(DateTime.fromMillisecondsSinceEpoch(e.line.time)),
            // Kotlin: bill ke liye `total`, general payment ke liye payment amount (dr/cr mein se jo bhara ho).
            e.line.isPayment ? e.line.cr : e.line.dr,
            e.balance,
            isCustomer: r.isCustomer,
            label: e.line.isPayment ? paymentLabel : '',
          ),
        _divider(),
        _rowText(closingLabel, _rs(res.closing), boldLeft: true, rightColor: closingIsGive ? _red : _teal),
        ..._stuckSummary(res.closing, r.stuck, totalIsGive ? _red : _teal),
      ],
    );
  }

  // ---- 5) Sale / Purchase by party ---------------------------------------

  Future<void> _showTransactions(ReportPartyRow r) async {
    final bills = (await PartyReportsRepository.instance.bills(isCustomer: r.isCustomer, id: r.id))
        .where((b) => !b.isReturned)
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    if (!mounted) return;
    final total = bills.fold<double>(0, (a, b) => a + b.total);
    await _reportDialog(
      icon: Icons.receipt_long_outlined,
      accent: r.isCustomer ? _primary : _amber,
      title: r.isCustomer ? Loc.t('Sales', 'سیلز') : Loc.t('Purchases', 'خریداریاں'),
      party: r.name,
      body: [
        if (bills.isEmpty)
          _empty(r.isCustomer ? Loc.t('No sales yet', 'کوئی سیل نہیں ہوئی') : Loc.t('No purchases yet', 'کوئی خریداری نہیں ہوئی')),
        // Kotlin: invoice/bill number nahi dikhata — date hi pehchan hai.
        for (final b in bills) _rowText(_dateTimeFmt.format(DateTime.fromMillisecondsSinceEpoch(b.createdAt)), _rs(b.total)),
        _divider(),
        _rowText(Loc.t('Total', 'کل'), _rs(total)),
      ],
    );
  }

  // ---- 6) Profit & Loss / Purchase Summary --------------------------------

  Future<void> _showPartyPL(ReportPartyRow r) async {
    if (r.isCustomer) {
      final pl = await PartyReportsRepository.instance.customerProfit(r.id, allowCost: Session.isAdminOrManager);
      if (!mounted) return;
      final profitColor = pl.profit >= 0 ? _teal : _red;
      await _reportDialog(
        icon: Icons.bar_chart_outlined,
        accent: _teal,
        title: Loc.t('Profit & Loss', 'منافع اور نقصان'),
        party: r.name,
        body: pl.bills == 0
            ? [_empty(Loc.t('No sales yet', 'کوئی سیل نہیں ہوئی'))]
            : [
                _rowText(Loc.t('Total Sales (bills)', 'کل سیلز (بلز)'), '${pl.bills}'),
                _rowText(Loc.t('Revenue', 'آمدنی'), _rs(pl.revenue)),
                _rowText(Loc.t('Cost of Goods', 'سامان کی لاگت'), _rs(pl.cost)),
                _divider(),
                _rowText(pl.profit >= 0 ? Loc.t('Net Profit', 'خالص منافع') : Loc.t('Net Loss', 'خالص نقصان'), _rs(pl.profit),
                    boldLeft: true, boldRight: true, rightColor: profitColor),
              ],
      );
      return;
    }
    final bills = await PartyReportsRepository.instance.bills(isCustomer: false, id: r.id);
    final pays = await PartyReportsRepository.instance.payments(isCustomer: false, id: r.id);
    if (!mounted) return;
    final extra = separatePayments(bills, pays).fold<double>(0, (a, p) => a + p.amount);
    final s = supplierSummary(bills, separatePaid: extra, opening: r.opening);
    await _reportDialog(
      icon: Icons.bar_chart_outlined,
      accent: _teal,
      title: Loc.t('Purchase Summary', 'خریداری کا خلاصہ'),
      party: r.name,
      body: s.bills == 0
          ? [_empty(Loc.t('No purchases yet', 'کوئی خریداری نہیں ہوئی'))]
          : [
              _rowText(Loc.t('Total Bills', 'کل بلز'), '${s.bills}'),
              if (s.opening != 0.0) _rowText(Loc.t('Opening Balance', 'ابتدائی بیلنس'), _rs(s.opening)),
              _rowText(Loc.t('Total Purchased', 'کل خریداری'), _rs(s.purchased)),
              _rowText(Loc.t('Total Paid', 'کل ادائیگی'), _rs(s.paid)),
              _divider(),
              _rowText(Loc.t('Outstanding Due', 'باقی واجب الادا'), _rs(s.due),
                  boldLeft: true, rightColor: s.due > 0 ? _red : _teal),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  Loc.t("Note: Suppliers don't have their own 'profit' — this is a purchase summary.",
                      'نوٹ: سپلائرز کا اپنا منافع نہیں ہوتا — یہ خریداری کا خلاصہ ہے۔'),
                  style: TextStyle(fontSize: 11.5, color: _p.textMuted),
                ),
              ),
            ],
    );
  }

  // ---- shared widgets ----------------------------------------------------

  Future<void> _reportDialog({
    required IconData icon,
    required Color accent,
    required String title,
    required String party,
    required List<Widget> body,
  }) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        contentPadding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
              child: Row(children: [
                _iconCircle(icon, accent, 38),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(title, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: _p.textDark)),
                    const SizedBox(height: 2),
                    Text(party, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: accent)),
                  ]),
                ),
              ]),
            ),
            Container(
              margin: const EdgeInsets.fromLTRB(12, 0, 12, 4),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              constraints: const BoxConstraints(maxHeight: 350),
              decoration: BoxDecoration(
                color: _p.cardWhite,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: _p.border),
              ),
              child: SingleChildScrollView(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: body),
              ),
            ),
          ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(Loc.t('Close', 'بند کریں')))],
      ),
    );
  }

  Widget _iconCircle(IconData icon, Color accent, double size) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: accent.withOpacity(0.12), shape: BoxShape.circle),
        child: Icon(icon, size: size * 0.5, color: accent),
      );

  Widget _divider() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Divider(height: 2, thickness: 1, color: _p.border),
      );

  Widget _empty(String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(text, style: TextStyle(fontSize: 13, color: _p.textMuted)),
      );

  Widget _rowText(String left, String right,
      {bool boldLeft = false, bool boldRight = true, Color? rightColor}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      child: Row(children: [
        Expanded(
          child: Text(left,
              style: TextStyle(fontSize: 13.5, color: _p.textDark, fontWeight: boldLeft ? FontWeight.bold : FontWeight.normal)),
        ),
        Text(right,
            style: TextStyle(
                fontSize: 13.5, color: rightColor ?? _primary, fontWeight: boldRight ? FontWeight.bold : FontWeight.normal)),
      ]),
    );
  }

  /// Kotlin addStuckSummary(): stuck == 0 => kuch nahi.
  List<Widget> _stuckSummary(double dailyClosing, double stuck, Color totalColor) {
    if (stuck == 0.0) return const [];
    return [
      _rowText(Loc.t('Stuck (Purana)', 'اسٹک (پرانا)'), _rs(stuck)),
      _divider(),
      _rowText(Loc.t('Total Payable', 'کل واجب الادا'), _rs(dailyClosing + stuck),
          boldLeft: true, rightColor: totalColor),
    ];
  }

  Widget _ledgerHeader() {
    TextStyle s(Color c) => TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: c);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 2, 4, 8),
      child: Row(children: [
        Expanded(flex: 14, child: Text(Loc.t('Date', 'تاریخ'), style: s(_p.textMuted))),
        Expanded(flex: 10, child: Text(Loc.t('Debit', 'ڈیبٹ'), textAlign: TextAlign.end, style: s(_red))),
        Expanded(
            flex: 10,
            child: Padding(
              padding: const EdgeInsets.only(left: 12),
              child: Text(Loc.t('Credit', 'کریڈٹ'), textAlign: TextAlign.end, style: s(_teal)),
            )),
      ]),
    );
  }

  Widget _ledgerRow(String date, {required double dr, required double cr, required double balance, bool bold = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            flex: 14,
            child: Text(date,
                style: TextStyle(
                    fontSize: bold ? 13.5 : 13, color: _p.textDark, fontWeight: bold ? FontWeight.bold : FontWeight.normal)),
          ),
          Expanded(
            flex: 10,
            child: Text(dr > 0 ? _rs(dr) : '—',
                textAlign: TextAlign.end, style: TextStyle(fontSize: 13, color: dr > 0 ? _red : _p.textMuted)),
          ),
          Expanded(
            flex: 10,
            child: Padding(
              padding: const EdgeInsets.only(left: 12),
              child: Text(cr > 0 ? _rs(cr) : '—',
                  textAlign: TextAlign.end, style: TextStyle(fontSize: 13, color: cr > 0 ? _teal : _p.textMuted)),
            ),
          ),
        ]),
        Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Text('${Loc.t('Balance', 'بیلنس')}: ${_rs(balance)}',
              style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: balance > 0 ? _red : _teal)),
        ),
      ]),
    );
  }

  Widget _paymentRow(String date, String against, double amount) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
      child: Row(children: [
        _iconCircle(Icons.account_balance_wallet_outlined, _teal, 32),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(date, style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: _p.textDark)),
            Text(against, style: TextStyle(fontSize: 11, color: _p.textMuted)),
          ]),
        ),
        Text(_rs(amount), style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: _teal)),
      ]),
    );
  }

  Widget _statementRow(String date, double amount, double balanceAfter, {required bool isCustomer, String label = ''}) {
    final isGive = reportIsGive(isCustomer: isCustomer, closing: balanceAfter);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(date, style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: _p.textDark))),
          Text(_rs(amount), style: TextStyle(fontSize: 13, color: _p.textMuted)),
        ]),
        if (label.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 1),
            child: Text(label, style: TextStyle(fontSize: 11, color: _p.textMuted)),
          ),
        Text('${Loc.t('Balance', 'بیلنس')}: ${_rs(balanceAfter)}',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: isGive ? _red : _teal)),
      ]),
    );
  }
}
