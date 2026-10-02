import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:intl/intl.dart';

import '../db/party_transaction_repository.dart';
import '../db/payment_repository.dart';
import '../models/misc_entities.dart';
import '../models/purchase.dart';
import '../models/sale.dart';
import '../services/session.dart';
import '../theme/theme_manager.dart';
import '../utils/loc.dart';
import '../utils/sale_cart.dart' show formatQty;
import 'payments_screen.dart' show showPaymentDialog;

/// Mirrors PartyTransactionActivity.kt.
///
/// Ek party (customer / supplier) ki APNI transactions: balance card (Opening + You'll Get/Give),
/// Stuck split card, stat grid (Total / Paid / Overdue / Credit Limit / Last activity), Share
/// Statement, search + All/Bills/Payments chips, aur bills + standalone payments ki merged list.
///
///  * Bill row tap => "Billed Items" dialog: har line Edit (qty/rate) / Delete — sirf admin.
///  * Payment row: Edit / Delete (admin) aur Share. Header: Edit Name, Receive/Make Payment.
///  * Balance HAMESHA live ledger se (opening + running + stuck), stored field se nahi.
///
/// Farq (Flutter):
///  * Share Statement / Share receipt: share plugin nahi, clipboard mein copy hota hai
///    (Party Dashboard ke Share summary jaisa).
///  * Payment save ke baad "Share receipt?" offer nahi — har payment row par Share chip hai.
///  * Overdue ab asli hai: bill ki `dueDate` (DB v10, Due Reminders screen se set hoti hai) guzar chuki ho
///    aur paisa baqi ho to.
///  * Supplier ki screen sirf admin/manager ke liye (cashier ko purchase data nahi milta).
class PartyTransactionScreen extends StatefulWidget {
  final int partyId;
  final String partyName;
  final bool isCustomer;

  /// Dashboard "+" menu ke Payment Received/Made ke liye: screen khulte hi payment dialog.
  final bool openPayment;

  const PartyTransactionScreen({
    super.key,
    required this.partyId,
    required this.partyName,
    required this.isCustomer,
    this.openPayment = false,
  });

  @override
  State<PartyTransactionScreen> createState() => _PartyTransactionScreenState();
}

class _PartyTransactionScreenState extends State<PartyTransactionScreen> {
  final _repo = PartyTransactionRepository.instance;
  final _dateTimeFmt = DateFormat('dd MMM yyyy, hh:mm a');
  final _dateFmt = DateFormat('dd MMM yyyy');
  final _searchCtrl = TextEditingController();

  late String _name = widget.partyName;
  PartyTxStats? _stats;
  List<TxEntry> _entries = const [];
  TxFilter _filter = TxFilter.all;
  bool _loading = true;
  int _loadSeq = 0; // Kotlin loadJob.cancel(): purani load ka late natija naya na bigaade.

  AppPalette get _p => ThemeManager.palette;
  bool get _blocked => !widget.isCustomer && !Session.isAdminOrManager;
  Color get _accent => widget.isCustomer ? _p.flatTealFg : _p.flatCoralFg;

  @override
  void initState() {
    super.initState();
    if (_blocked) return;
    _load();
    if (widget.openPayment) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _payment());
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- helpers

  String _rs(double v) => 'Rs ${v.toStringAsFixed(2)}';

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  bool _requireAdmin() {
    if (Session.isAdmin) return true;
    _toast(Loc.t('Only Admin can do this action', 'صرف ایڈمن یہ عمل کر سکتا ہے'));
    return false;
  }

  String _payLabel(Payment pay) {
    final base = widget.isCustomer
        ? Loc.t('Payment Received', 'ادائیگی وصول ہوئی')
        : Loc.t('Payment Made', 'ادائیگی ہوئی');
    return '$base  \u2022  ${pay.method.toUpperCase()}'
        '${pay.note.isNotEmpty ? '  \u2022  ${pay.note}' : ''}'
        '${pay.billReference.isNotEmpty ? '  \u2022  ${Loc.t('Against', 'برائے راست')} ${pay.billReference}' : ''}';
  }

  // ------------------------------------------------------------------- load

  Future<void> _load() async {
    final seq = ++_loadSeq;
    try {
      final d = await _repo.load(isCustomer: widget.isCustomer, partyId: widget.partyId);
      if (!mounted || seq != _loadSeq) return;

      final bills = <TxBill>[
        for (final s in d.sales) (total: s.total, paid: s.paid, status: s.status, createdAt: s.createdAt, dueDate: s.dueDate),
        for (final b in d.purchases) (total: b.total, paid: b.paid, status: b.status, createdAt: b.createdAt, dueDate: b.dueDate),
      ];
      final stats = computePartyTxStats(
        bills: bills,
        standalone: [for (final pay in d.payments) (amount: pay.amount, billReference: pay.billReference)],
        opening: d.opening,
        stuck: d.stuck,
        creditLimit: d.creditLimit,
        knownBillIds: {for (final s in d.sales) s.invoice, for (final b in d.purchases) b.billNo},
      );

      final saleLabel = Loc.t('Sale', 'سیل');
      final purchaseLabel = Loc.t('Purchase', 'خریداری');
      final entries = <TxEntry>[
        for (final s in d.sales)
          TxEntry(
            createdAt: s.createdAt,
            isPayment: false,
            sale: s,
            searchText: '${_dateTimeFmt.format(DateTime.fromMillisecondsSinceEpoch(s.createdAt))} $saleLabel ${s.total}'
                .toLowerCase(),
          ),
        for (final b in d.purchases)
          TxEntry(
            createdAt: b.createdAt,
            isPayment: false,
            purchase: b,
            searchText:
                '${_dateTimeFmt.format(DateTime.fromMillisecondsSinceEpoch(b.createdAt))} $purchaseLabel ${b.total}'
                    .toLowerCase(),
          ),
        for (final pay in d.payments)
          TxEntry(
            createdAt: pay.createdAt,
            isPayment: true,
            payment: pay,
            searchText:
                '${_dateTimeFmt.format(DateTime.fromMillisecondsSinceEpoch(pay.createdAt))} ${_payLabel(pay)} ${pay.amount} ${pay.method} ${pay.note} ${pay.billReference}'
                    .toLowerCase(),
          ),
      ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));

      setState(() {
        _stats = stats;
        _entries = entries;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || seq != _loadSeq) return;
      setState(() => _loading = false);
      _toast(e.toString());
    }
  }

  // ---------------------------------------------------------------- actions

  Future<void> _editName() async {
    final ctrl = TextEditingController(text: _name);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(Loc.t('Edit Name', 'نام ترمیم کریں')),
        content: TextField(controller: ctrl, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(Loc.t('Cancel', 'منسوخ کریں'))),
          TextButton(
            onPressed: () {
              final v = ctrl.text.trim();
              if (v.isEmpty) {
                _toast(Loc.t('Name cannot be empty', 'نام خالی نہیں ہو سکتا'));
                return;
              }
              Navigator.pop(ctx, v);
            },
            child: Text(Loc.t('Save', 'محفوظ کریں')),
          ),
        ],
      ),
    );
    if (newName == null) return;
    try {
      final ok = await _repo.renameParty(isCustomer: widget.isCustomer, partyId: widget.partyId, newName: newName);
      if (!mounted) return;
      if (ok) {
        setState(() => _name = newName);
        _toast(Loc.t('Name updated', 'نام اپ ڈیٹ ہو گیا'));
      } else {
        _toast(Loc.t('Party not found', 'پارٹی نہیں ملی'));
      }
    } catch (e) {
      _toast('Could not update name: $e');
    }
  }

  Future<void> _payment({Payment? existing}) async {
    if (existing != null && !_requireAdmin()) return;
    final saved = await showPaymentDialog(context,
        isCustomer: widget.isCustomer, partyId: widget.partyId, partyName: _name, existing: existing);
    if (saved) {
      _toast(existing != null
          ? Loc.t('Payment updated', 'ادائیگی اپ ڈیٹ ہو گئی')
          : Loc.t('Payment saved', 'ادائیگی محفوظ ہو گئی'));
      _load();
    }
  }

  Future<void> _deletePayment(Payment pay) async {
    if (!_requireAdmin()) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(Loc.t('Delete Payment', 'ادائیگی ڈیلیٹ کریں')),
        content: Text(Loc.t("Delete this ${_rs(pay.amount)} payment? The party's balance will be adjusted back.",
            'کیا یہ ${_rs(pay.amount)} کی ادائیگی حذف کی جائے؟ پارٹی کا بیلنس واپس ایڈجسٹ ہو جائے گا۔')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(Loc.t('Cancel', 'منسوخ کریں'))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(Loc.t('Delete', 'حذف کریں'))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await PaymentRepository.instance.delete(payment: pay, isCustomer: widget.isCustomer);
      _toast(Loc.t('Payment deleted', 'ادائیگی حذف ہو گئی'));
      _load();
    } catch (e) {
      _toast(e.toString());
    }
  }

  Future<void> _copyReceipt(Payment pay) async {
    final verb = widget.isCustomer ? Loc.t('Payment Received', 'ادائیگی وصول ہوئی') : Loc.t('Payment Made', 'ادائیگی ہوئی');
    final lines = <String>[
      verb,
      '${Loc.t('Party', 'پارٹی')}: $_name',
      '${Loc.t('Amount', 'رقم')}: ${_rs(pay.amount)}',
      '${Loc.t('Date', 'تاریخ')}: ${_dateFmt.format(DateTime.fromMillisecondsSinceEpoch(pay.createdAt))}',
      '${Loc.t('Method', 'ذریعہ')}: ${pay.method.toUpperCase()}',
      if (pay.billReference.isNotEmpty) '${Loc.t('Against Bill', 'بل نمبر')}: ${pay.billReference}',
      if (pay.note.isNotEmpty) '${Loc.t('Note', 'نوٹ')}: ${pay.note}',
    ];
    try {
      await Share.share(lines.join('\n'));
    } catch (_) {
      // Share sheet na khule (jaise kuch iPad/desktop) to clipboard par wapas.
      await Clipboard.setData(ClipboardData(text: lines.join('\n')));
      _toast(Loc.t('Receipt copied — paste it in WhatsApp/SMS', 'رسید کاپی ہو گئی — واٹس ایپ/ایس ایم ایس میں پیسٹ کریں'));
    }
  }

  Future<void> _copyStatement() async {
    final st = _stats;
    if (st == null) return;
    final give = partyGive(st.closing);
    final sb = StringBuffer()
      ..writeln(_name)
      ..writeln(widget.isCustomer ? Loc.t('Customer Statement', 'کسٹمر سٹیٹمنٹ') : Loc.t('Supplier Statement', 'سپلائر سٹیٹمنٹ'))
      ..writeln('${Loc.t('Outstanding', 'بقایا')}: ${_rs(st.closing.abs())}'
          ' (${give ? Loc.t("You'll Give", 'آپ کو دینے ہیں') : Loc.t("You'll Get", 'آپ کو ملیں گے')})');
    if (st.stuck != 0) {
      sb
        ..writeln('${Loc.t('Daily Payable', 'روزانہ واجب الادا')}: ${_rs(st.daily)}')
        ..writeln('${Loc.t('Stuck (Purana)', 'اسٹک (پرانا)')}: ${_rs(st.stuck)}');
    }
    sb.writeln('----------------------------');
    final oldestFirst = [..._entries]..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    for (final e in oldestFirst) {
      sb.writeln('${_dateTimeFmt.format(DateTime.fromMillisecondsSinceEpoch(e.createdAt))}  \u2014  ${e.searchText}');
    }
    try {
      await Share.share(sb.toString());
    } catch (_) {
      // Share sheet na khule (jaise kuch iPad/desktop) to clipboard par wapas.
      await Clipboard.setData(ClipboardData(text: sb.toString()));
      _toast(Loc.t('Statement copied — paste it in WhatsApp/SMS', 'سٹیٹمنٹ کاپی ہو گئی — واٹس ایپ/ایس ایم ایس میں پیسٹ کریں'));
    }
  }

  /// closing > 0 customer = unhone dena hai; supplier closing > 0 = humein dena hai.
  bool partyGive(double closing) => widget.isCustomer ? closing < 0 : closing > 0;

  Future<void> _openBill(TxEntry e) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _BilledItemsDialog(
        isSale: e.sale != null,
        reference: e.sale?.invoice ?? e.purchase!.billNo,
        accent: _accent,
      ),
    );
    _load(); // Kotlin: dialog band hone par list dobara.
  }

  // ------------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final p = _p;
    if (_blocked) {
      return Scaffold(
        backgroundColor: p.bg,
        appBar: AppBar(backgroundColor: p.navy, foregroundColor: Colors.white),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Text(
              Loc.t('Only Admin/Manager can access this screen', 'صرف ایڈمن/منیجر اس اسکرین کو استعمال کر سکتا ہے'),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16, color: p.textDark),
            ),
          ),
        ),
      );
    }

    final visible = filterTxEntries(_entries, _filter, _searchCtrl.text);
    return Scaffold(
      backgroundColor: p.bg,
      appBar: AppBar(
        backgroundColor: p.navy,
        foregroundColor: Colors.white,
        titleSpacing: 0,
        title: Text(_name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          IconButton(tooltip: Loc.t('Edit', 'ترمیم'), icon: const Icon(Icons.edit_outlined), onPressed: _editName),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextButton.icon(
              style: TextButton.styleFrom(
                foregroundColor: Colors.white,
                backgroundColor: _accent,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
              ),
              icon: const Icon(Icons.account_balance_wallet_outlined, size: 16),
              label: Text(
                widget.isCustomer ? Loc.t('Receive Payment', 'ادائیگی وصول کریں') : Loc.t('Make Payment', 'ادائیگی کریں'),
                style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold),
              ),
              onPressed: () => _payment(),
            ),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 24),
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: 6, bottom: 12),
                    child: Text(
                      widget.isCustomer
                          ? Loc.t('Customer transactions', 'کسٹمر لین دین')
                          : Loc.t('Supplier transactions', 'سپلائر لین دین'),
                      style: TextStyle(fontSize: 12.5, color: p.textMuted),
                    ),
                  ),
                  if (_stats != null) ...[
                    _balanceCard(p, _stats!),
                    if (_stats!.stuck != 0) _stuckCard(p, _stats!),
                    _statsCard(p, _stats!),
                  ],
                  _shareButton(),
                  const SizedBox(height: 14),
                  _searchBox(p),
                  const SizedBox(height: 10),
                  _chips(p),
                  const SizedBox(height: 12),
                  if (visible.isEmpty)
                    _placeholder(
                      p,
                      _entries.isEmpty
                          ? Loc.t('No transactions yet', 'ابھی تک کوئی لین دین نہیں ہے')
                          : Loc.t('No matching transactions', 'کوئی مماثل لین دین نہیں'),
                    )
                  else
                    for (final e in visible) e.isPayment ? _paymentRow(p, e) : _billRow(p, e),
                ],
              ),
            ),
    );
  }

  BoxDecoration _cardDeco(AppPalette p) => BoxDecoration(
        color: p.cardWhite,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: p.border),
      );

  Widget _balanceCard(AppPalette p, PartyTxStats st) {
    final give = partyGive(st.closing);
    final color = give ? p.red : p.flatTealFg;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
      decoration: _cardDeco(p),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(Loc.t('Opening', 'ابتدائی'), style: TextStyle(fontSize: 11, color: p.textMuted)),
            const SizedBox(height: 4),
            Text(_rs(st.opening), style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: p.textDark)),
          ]),
        ),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(give ? Loc.t("You'll Give", 'آپ کو دینے ہیں') : Loc.t("You'll Get", 'آپ کو ملیں گے'),
              style: TextStyle(fontSize: 11, color: color)),
          const SizedBox(height: 4),
          Text(_rs(st.closing.abs()), style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: color)),
        ]),
      ]),
    );
  }

  Widget _stuckCard(AppPalette p, PartyTxStats st) {
    Widget line(String label, double v, {bool bold = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(children: [
            Expanded(
                child: Text(label,
                    style: TextStyle(
                        fontSize: bold ? 13 : 12,
                        fontWeight: bold ? FontWeight.bold : FontWeight.normal,
                        color: bold ? p.textDark : p.textMuted))),
            Text(_rs(v),
                style: TextStyle(
                    fontSize: bold ? 13 : 12, fontWeight: bold ? FontWeight.bold : FontWeight.normal, color: p.textDark)),
          ]),
        );
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
      decoration: _cardDeco(p),
      child: Column(children: [
        line(Loc.t('Daily Payable', 'روزانہ واجب الادا'), st.daily),
        line(Loc.t('Stuck (Purana)', 'اسٹک (پرانا)'), st.stuck),
        Divider(color: p.border, height: 10),
        line(Loc.t('Total Payable', 'کل واجب الادا'), st.daily + st.stuck, bold: true),
      ]),
    );
  }

  Widget _statsCard(AppPalette p, PartyTxStats st) {
    Widget tile(String label, String value, Color valueColor) => Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: TextStyle(fontSize: 11, color: p.textMuted)),
              const SizedBox(height: 3),
              Text(value, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: valueColor)),
            ]),
          ),
        );
    final credit = widget.isCustomer
        ? (st.creditLimit > 0 ? _rs(st.creditLimit) : Loc.t('No Limit', 'کوئی حد نہیں'))
        : '-';
    final last = (st.lastActivityAt != null && st.lastActivityAt! > 0)
        ? _dateFmt.format(DateTime.fromMillisecondsSinceEpoch(st.lastActivityAt!))
        : Loc.t('No activity yet', 'ابھی تک کوئی سرگرمی نہیں');
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 10),
      decoration: _cardDeco(p),
      child: Column(children: [
        Row(children: [
          tile(widget.isCustomer ? Loc.t('Total Sales', 'کل سیلز') : Loc.t('Total Purchases', 'کل خریداری'),
              _rs(st.totalAmount), _accent),
          tile(Loc.t('Total Paid', 'کل ادا شدہ'), _rs(st.totalPaid), p.flatTealFg),
        ]),
        Row(children: [
          tile(Loc.t('Overdue', 'واجب الادا'), _rs(st.overdue), st.overdue > 0 ? p.red : p.textDark),
          tile(Loc.t('Credit Limit', 'کریڈٹ حد'), credit, p.textDark),
        ]),
        Row(children: [
          tile(widget.isCustomer ? Loc.t('Last Sale', 'آخری سیل') : Loc.t('Last Purchase', 'آخری خریداری'), last,
              p.textDark),
        ]),
      ]),
    );
  }

  Widget _shareButton() => SizedBox(
        height: 46,
        child: ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            backgroundColor: _accent,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          icon: const Icon(Icons.share_outlined, size: 18),
          label: Text(Loc.t('Share Statement', 'سٹیٹمنٹ شیئر کریں'), style: const TextStyle(fontWeight: FontWeight.bold)),
          onPressed: _copyStatement,
        ),
      );

  Widget _searchBox(AppPalette p) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: p.fieldFill,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: p.border),
        ),
        child: TextField(
          controller: _searchCtrl,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            border: InputBorder.none,
            hintText: Loc.t('Search this history (date, note, amount)', 'اس تاریخ میں تلاش کریں'),
          ),
        ),
      );

  Widget _chips(AppPalette p) {
    Widget chip(String label, TxFilter mode) {
      final active = _filter == mode;
      return Padding(
        padding: const EdgeInsets.only(right: 10),
        child: InkWell(
          borderRadius: BorderRadius.circular(24),
          onTap: () => setState(() => _filter = mode),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            decoration: BoxDecoration(
              color: active ? _accent : p.border.withOpacity(0.5),
              borderRadius: BorderRadius.circular(24),
            ),
            child: Text(label,
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: active ? Colors.white : p.textMuted)),
          ),
        ),
      );
    }

    return Row(children: [
      chip(Loc.t('All', 'سب'), TxFilter.all),
      chip(Loc.t('Bills', 'بل'), TxFilter.bills),
      chip(Loc.t('Payments', 'ادائیگیاں'), TxFilter.payments),
    ]);
  }

  Widget _placeholder(AppPalette p, String text) => Container(
        padding: const EdgeInsets.all(28),
        decoration: _cardDeco(p),
        child: Center(child: Text(text, style: TextStyle(color: p.textMuted, fontSize: 13.5))),
      );

  Widget _billRow(AppPalette p, TxEntry e) {
    final isSale = e.sale != null;
    final returned = e.status == 'returned';
    final label = (isSale ? Loc.t('Sale', 'سیل') : Loc.t('Purchase', 'خریداری')) +
        (returned ? '  \u2022  ${Loc.t('Returned', 'واپس')}' : '');
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      elevation: 0,
      color: p.cardWhite,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: p.border)),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _openBill(e),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(children: [
            Icon(isSale ? Icons.shopping_cart_outlined : Icons.receipt_long_outlined, color: _accent),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(_dateTimeFmt.format(DateTime.fromMillisecondsSinceEpoch(e.createdAt)),
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: p.textDark)),
                const SizedBox(height: 3),
                Text(label, style: TextStyle(fontSize: 12, color: returned ? p.red : p.textMuted)),
              ]),
            ),
            Text(_rs(e.amount), style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: _accent)),
          ]),
        ),
      ),
    );
  }

  Widget _paymentRow(AppPalette p, TxEntry e) {
    final pay = e.payment!;
    Widget chip(IconData icon, String label, Color color, VoidCallback onTap) => Padding(
          padding: const EdgeInsets.only(right: 8),
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: color,
              side: BorderSide(color: color.withOpacity(0.6)),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
              minimumSize: const Size(0, 32),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            ),
            icon: Icon(icon, size: 14),
            label: Text(label, style: const TextStyle(fontSize: 12)),
            onPressed: onTap,
          ),
        );
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      elevation: 0,
      color: p.cardWhite,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: p.border)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.account_balance_wallet_outlined, color: widget.isCustomer ? p.flatTealFg : p.flatCoralFg),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(_dateTimeFmt.format(DateTime.fromMillisecondsSinceEpoch(pay.createdAt)),
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: p.textDark)),
                const SizedBox(height: 3),
                Text(_payLabel(pay), style: TextStyle(fontSize: 12, color: p.textMuted)),
              ]),
            ),
            Text(_rs(pay.amount),
                style: TextStyle(
                    fontSize: 14, fontWeight: FontWeight.bold, color: widget.isCustomer ? p.flatTealFg : p.flatCoralFg)),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            if (Session.isAdmin) chip(Icons.edit_outlined, Loc.t('Edit', 'ترمیم'), p.textDark, () => _payment(existing: pay)),
            chip(Icons.send_outlined, Loc.t('Share', 'شیئر'), p.flatTealFg, () => _copyReceipt(pay)),
            if (Session.isAdmin) chip(Icons.delete_outline, Loc.t('Delete', 'حذف'), p.red, () => _deletePayment(pay)),
          ]),
        ]),
      ),
    );
  }
}

// ===========================================================================
// Billed Items dialog (Kotlin showBilledItemsDialog)
// ===========================================================================

class _BilledItemsDialog extends StatefulWidget {
  final bool isSale;
  final String reference; // invoice / billNo
  final Color accent;
  const _BilledItemsDialog({required this.isSale, required this.reference, required this.accent});

  @override
  State<_BilledItemsDialog> createState() => _BilledItemsDialogState();
}

class _BilledItemsDialogState extends State<_BilledItemsDialog> {
  final _repo = PartyTransactionRepository.instance;
  bool _loading = true;
  Sale? _sale;
  Purchase? _purchase;
  List<SaleItem> _saleItems = const [];
  List<PurchaseItem> _purchaseItems = const [];
  Map<String, String> _names = const {};

  AppPalette get _p => ThemeManager.palette;
  String _rs(double v) => 'Rs ${v.toStringAsFixed(2)}';

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  /// Bill khud delete ho gayi (aakhri line gayi) => dialog band.
  Future<void> _reload() async {
    if (widget.isSale) {
      final s = await _repo.findSale(widget.reference);
      if (s == null) {
        _close();
        return;
      }
      final items = await _repo.saleItems(widget.reference);
      if (!mounted) return;
      setState(() {
        _sale = s;
        _saleItems = items;
        _loading = false;
      });
    } else {
      final b = await _repo.findPurchase(widget.reference);
      if (b == null) {
        _close();
        return;
      }
      final items = await _repo.purchaseItems(widget.reference);
      final names = await _repo.productNames(items.map((i) => i.barcode));
      if (!mounted) return;
      setState(() {
        _purchase = b;
        _purchaseItems = items;
        _names = names;
        _loading = false;
      });
    }
  }

  void _close() {
    if (mounted) Navigator.of(context).pop();
  }

  Future<(double, double)?> _qtyRateDialog(String title, double qty, double rate) async {
    final qCtrl = TextEditingController(text: formatQty(qty));
    final rCtrl = TextEditingController(text: formatQty(rate));
    return showDialog<(double, double)>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: qCtrl,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(labelText: Loc.t('Quantity', 'مقدار')),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: rCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(labelText: Loc.t('Rate', 'ریٹ')),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(Loc.t('Cancel', 'منسوخ کریں'))),
          TextButton(
            onPressed: () {
              final q = double.tryParse(qCtrl.text.trim());
              final r = double.tryParse(rCtrl.text.trim());
              if (q == null || q <= 0 || r == null || r < 0) {
                _toast(Loc.t('Enter a valid qty and rate', 'درست مقدار اور ریٹ درج کریں'));
                return;
              }
              Navigator.pop(ctx, (q, r));
            },
            child: Text(Loc.t('Save', 'محفوظ کریں')),
          ),
        ],
      ),
    );
  }

  Future<bool> _confirmDelete(String name) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(Loc.t('Delete Item', 'آئٹم ڈیلیٹ کریں')),
          content: Text(name),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(Loc.t('Cancel', 'منسوخ کریں'))),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(Loc.t('Delete', 'ڈیلیٹ کریں'))),
          ],
        ),
      ) ==
      true;

  /// Har write ke baad dobara load; error par Kotlin jaisa toast.
  Future<void> _run(Future<void> Function() action, {required String failPrefix}) async {
    try {
      await action();
      await _reload();
    } on InsufficientStockException catch (e) {
      _toast(e.message);
    } catch (e) {
      _toast('$failPrefix: $e');
    }
  }

  Future<void> _editSale(SaleItem it) async {
    if (!Session.isAdmin) return _toast(Loc.t('Only Admin can do this action', 'صرف ایڈمن یہ عمل کر سکتا ہے'));
    final r = await _qtyRateDialog(it.product, it.qty, it.unitPrice);
    if (r == null) return;
    await _run(() => _repo.editSaleItem(item: it, newQty: r.$1, newRate: r.$2), failPrefix: 'Could not update item');
  }

  Future<void> _deleteSale(SaleItem it) async {
    if (!Session.isAdmin) return _toast(Loc.t('Only Admin can do this action', 'صرف ایڈمن یہ عمل کر سکتا ہے'));
    if (!await _confirmDelete(it.product)) return;
    await _run(() async {
      final whole = await _repo.deleteSaleItem(it);
      if (whole) _toast(Loc.t('Sale deleted', 'سیل ڈیلیٹ ہو گئی'));
    }, failPrefix: 'Could not delete item');
  }

  Future<void> _editPurchase(PurchaseItem it) async {
    if (!Session.isAdmin) return _toast(Loc.t('Only Admin can do this action', 'صرف ایڈمن یہ عمل کر سکتا ہے'));
    final r = await _qtyRateDialog(_names[it.barcode] ?? it.barcode, it.qty, it.unitCost);
    if (r == null) return;
    await _run(() => _repo.editPurchaseItem(item: it, newQty: r.$1, newRate: r.$2), failPrefix: 'Could not update item');
  }

  Future<void> _deletePurchase(PurchaseItem it) async {
    if (!Session.isAdmin) return _toast(Loc.t('Only Admin can do this action', 'صرف ایڈمن یہ عمل کر سکتا ہے'));
    if (!await _confirmDelete(_names[it.barcode] ?? it.barcode)) return;
    await _run(() async {
      final whole = await _repo.deletePurchaseItem(it);
      if (whole) _toast(Loc.t('Purchase deleted', 'خریداری ڈیلیٹ ہو گئی'));
    }, failPrefix: 'Could not delete item');
  }

  Widget _itemRow(String name, double qty, double amount, VoidCallback? onEdit, VoidCallback? onDelete) {
    final p = _p;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: p.textDark)),
            Text('${Loc.t('Qty', 'مقدار')}: ${formatQty(qty)}', style: TextStyle(fontSize: 12, color: p.textMuted)),
          ]),
        ),
        Text(_rs(amount), style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: widget.accent)),
        if (onEdit != null)
          IconButton(visualDensity: VisualDensity.compact, icon: Icon(Icons.edit_outlined, size: 18, color: p.textDark), onPressed: onEdit),
        if (onDelete != null)
          IconButton(visualDensity: VisualDensity.compact, icon: Icon(Icons.delete_outline, size: 18, color: p.red), onPressed: onDelete),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = _p;
    final fmt = DateFormat('dd MMM yyyy, hh:mm a');
    final createdAt = _sale?.createdAt ?? _purchase?.createdAt ?? DateTime.now().millisecondsSinceEpoch;
    final status = _sale?.status ?? _purchase?.status ?? 'active';
    final total = _sale?.total ?? _purchase?.total ?? 0.0;
    final count = widget.isSale ? _saleItems.length : _purchaseItems.length;
    final admin = Session.isAdmin;

    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(24, 20, 24, 4),
      title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(
          widget.isSale
              ? Loc.t('Billed Items \u2014 Sale', 'بل شدہ آئٹمز \u2014 سیل')
              : Loc.t('Billed Items \u2014 Purchase', 'بل شدہ آئٹمز \u2014 خریداری'),
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: p.textDark),
        ),
        const SizedBox(height: 4),
        Text(
          fmt.format(DateTime.fromMillisecondsSinceEpoch(createdAt)) +
              (status == 'returned' ? '  \u2022  ${Loc.t('Returned', 'واپس')}' : ''),
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.normal, color: status == 'returned' ? p.red : p.textMuted),
        ),
      ]),
      content: SizedBox(
        width: double.maxFinite,
        child: _loading
            ? const SizedBox(height: 80, child: Center(child: CircularProgressIndicator()))
            : count == 0
                ? Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(Loc.t('No items found', 'کوئی آئٹم نہیں ملا'), style: TextStyle(color: p.textMuted)),
                  )
                : SingleChildScrollView(
                    child: Column(children: [
                      if (widget.isSale)
                        for (final it in _saleItems)
                          _itemRow(it.product, it.qty, it.amount, admin ? () => _editSale(it) : null,
                              admin ? () => _deleteSale(it) : null)
                      else
                        for (final it in _purchaseItems)
                          _itemRow(_names[it.barcode] ?? it.barcode, it.qty, it.amount,
                              admin ? () => _editPurchase(it) : null, admin ? () => _deletePurchase(it) : null),
                      Divider(color: p.border, height: 18),
                      Row(children: [
                        Expanded(
                            child: Text(Loc.t('Total', 'کل'),
                                style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: p.textDark))),
                        Text(_rs(total), style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: widget.accent)),
                      ]),
                    ]),
                  ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(Loc.t('Close', 'بند کریں')))],
    );
  }
}
