import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:intl/intl.dart';

import '../db/purchase_history_repository.dart';
import '../db/party_transaction_repository.dart' show InsufficientStockException;
import '../theme/theme_manager.dart';
import '../utils/bill_doc.dart';
import '../utils/bill_text.dart';
import 'bill_preview_screen.dart';
import '../models/purchase.dart';
import '../utils/loc.dart';
import '../widgets/role_guard.dart';
import 'purchase_screen.dart';

/// Mirrors PurchaseHistoryActivity.kt.
///
/// Supplier bills ki list (naya pehle): Total Purchases / Total Due cards, bill no. ya supplier search,
/// har card par DUE/PAID badge, Balance, aur Print / Share / ⋮ (Return, Delete).
/// Return = har line ki qty chun kar (partial); poori qty = poori bill return.
///
/// Role: admin-only (RoleGuard; PORTING_PLAN — Purchase admin-only). Return/Delete data layer par bhi check.
///
/// Farq (Kotlin se):
///  * Card tap = bill ki items neeche expand (Sale History jaisa); edit = pencil icon -> PurchaseScreen(editBillNo:). Returned bill edit nahi
///    hota (Kotlin bhi rokta hai) — us par tap = bill ki lines ka detail dialog.
///  * Print = Bill Preview screen (Bluetooth / WhatsApp / Copy). Share = clipboard (share plugin nahi).
///  * Line ka naam bill par jama shuda (purani rows ke liye live product).
class PurchaseHistoryScreen extends StatelessWidget {
  const PurchaseHistoryScreen({super.key});

  @override
  Widget build(BuildContext context) => const RoleGuard(allowed: {'admin'}, child: _PurchaseHistoryBody());
}

class _PurchaseHistoryBody extends StatefulWidget {
  const _PurchaseHistoryBody();

  @override
  State<_PurchaseHistoryBody> createState() => _PurchaseHistoryBodyState();
}

class _PurchaseHistoryBodyState extends State<_PurchaseHistoryBody> with WidgetsBindingObserver {
  final _repo = PurchaseHistoryRepository.instance;
  final _search = TextEditingController();
  final _dayFmt = DateFormat('dd MMM, yy');

  bool _loading = true;
  List<PurchaseHistoryRow> _rows = const [];
  PurchaseHistorySummary _summary = const PurchaseHistorySummary(0, 0);
  String _query = '';
  Map<String, String> _itemText = const {};

  // Card tap = bill neeche khulti hai (Sale History jaisa); edit alag pencil se.
  final Set<String> _expanded = {};
  final Map<String, List<PurchaseItem>> _items = {};
  final Map<String, List<ReturnableLine>> _lines = {};

  AppPalette get _p => ThemeManager.palette;
  Color get _green => const Color(0xFF1E9E6B);
  String _rs(double v) => 'Rs ${v.round()}';
  String _qty(double v) => v == v.truncateToDouble() ? v.toInt().toString() : v.toString();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _search.dispose();
    super.dispose();
  }

  // Kotlin FIX: onResume par dobara load, warna DUE/PAID badge purana rehta.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load(showSpinner: false);
  }

  Future<void> _load({bool showSpinner = true}) async {
    if (showSpinner) setState(() => _loading = true);
    final rows = await _repo.allPurchases();
    final itemText = await _repo.itemTextByBill();
    if (!mounted) return;
    setState(() {
      _rows = rows;
      _itemText = itemText;
      _summary = summarizePurchases(rows);
      _items.clear();
      _lines.clear();
      _expanded.removeWhere((b) => !rows.any((r) => r.billNo == b));
      _loading = false;
    });
    for (final b in _expanded) {
      _loadItems(b);
    }
  }

  Future<void> _loadItems(String billNo) async {
    final items = await _repo.itemsForBill(billNo);
    final lines = await _repo.linesForBill(billNo);
    if (!mounted) return;
    setState(() {
      _items[billNo] = items;
      _lines[billNo] = lines;
    });
  }

  void _toggle(String billNo) {
    setState(() {
      if (!_expanded.add(billNo)) _expanded.remove(billNo);
    });
    if (_expanded.contains(billNo) && !_items.containsKey(billNo)) _loadItems(billNo);
  }

  void _toast(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  // ------------------------------------------------------------------ actions

  /// Pencil: sirf active bill edit hota hai (returned bill Kotlin mein bhi edit nahi hota).
  Future<void> _edit(PurchaseHistoryRow r) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => PurchaseScreen(editBillNo: r.billNo)));
    if (mounted) _load(showSpinner: false);
  }

  /// Kotlin printPurchase(): DB se taza bill utha kar text preview.
  Future<void> _print(PurchaseHistoryRow r) async {
    final purchase = await _repo.findPurchase(r.billNo);
    if (purchase == null) return;
    final items = await _repo.itemsForBill(r.billNo);
    final lines = await _repo.linesForBill(r.billNo);
    if (!mounted) return;
    await BillPreviewScreen.open(
      context,
      BillDoc(
        isPurchase: true,
        ref: r.billNo,
        date: DateTime.fromMillisecondsSinceEpoch(purchase.createdAt),
        partyName: r.supplierName,
        items: [
          for (var i = 0; i < items.length; i++)
            BillItem(name: lines[i].name, qty: items[i].qty, unit: lines[i].unit, rate: items[i].unitCost, amount: items[i].amount),
        ],
        subtotal: purchase.subtotal,
        discount: purchase.discount,
        total: purchase.total,
        paid: purchase.paid,
      ),
    );
  }

  Future<void> _share(PurchaseHistoryRow r) async {
    final text = buildPurchaseShareText(
      supplier: r.supplierName,
      billNo: r.billNo,
      total: r.total,
      balance: r.due,
      date: DateTime.fromMillisecondsSinceEpoch(r.createdAt),
    );
    try {
      await Share.share(text);
    } catch (_) {
      // Share sheet na khule (jaise kuch iPad/desktop) to clipboard par wapas.
      await Clipboard.setData(ClipboardData(text: text));
      _toast(Loc.t('Purchase details copied', 'خریداری کی تفصیل کاپی ہو گئی'));
    }
  }

  Future<void> _delete(PurchaseHistoryRow r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(Loc.t('Delete purchase', 'خریداری حذف کریں')),
        content: Text(Loc.t("Delete this purchase? This will reverse its stock and cost changes. This can't be undone.",
            'یہ خریداری حذف کریں؟ اس سے اسٹاک اور لاگت واپس ہو جائے گی۔ اسے واپس نہیں لیا جا سکتا۔')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(Loc.t('Cancel', 'منسوخ کریں'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(Loc.t('Delete', 'حذف کریں'))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      try {
        await _repo.deletePurchase(r.billNo);
      } on InsufficientStockException catch (e) {
        if (!mounted) return;
        final force = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Stock kam hai'),
            content: Text('${e.message}\n\nPhir bhi delete karen? Stock 0 tak kam hoga (minus nahi), cost wahi rahegi. '
                'Baad mein Stock Movement / Adjustment se check kar len.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('DELETE ANYWAY')),
            ],
          ),
        );
        if (force != true) return;
        await _repo.deletePurchase(r.billNo, force: true);
      }
      _toast(Loc.t('Purchase deleted', 'خریداری حذف ہو گئی'));
    } catch (e) {
      _toast('$e');
    }
    if (mounted) _load(showSpinner: false);
  }

  Future<void> _return(PurchaseHistoryRow r) async {
    final lines = await _repo.linesForBill(r.billNo);
    if (lines.isEmpty) return;
    if (!mounted) return;
    final requested = await showDialog<Map<int, double>>(
      context: context,
      builder: (ctx) => _ReturnDialog(lines: lines, palette: _p),
    );
    if (requested == null) return;
    try {
      await _repo.returnItems(r.billNo, requested);
      _toast(Loc.t('Items returned', 'آئٹمز واپس ہو گئے'));
    } catch (e) {
      _toast('$e');
    }
    if (mounted) _load(showSpinner: false);
  }

  // ---------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final rows = filterPurchaseRows(_rows, _query, itemText: _itemText);
    return Scaffold(
      backgroundColor: _p.bg,
      appBar: AppBar(
        backgroundColor: _p.navy,
        foregroundColor: Colors.white,
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(Loc.t('Purchase History', 'خریداری کی تاریخ'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          Text(Loc.t('All supplier bills', 'تمام سپلائر بلز'), style: TextStyle(fontSize: 11.5, color: _p.headerSubtitleColor)),
        ]),
        actions: [
          TextButton.icon(
            onPressed: () async {
              await Navigator.push(context, MaterialPageRoute(builder: (_) => const PurchaseScreen()));
              if (mounted) _load(showSpinner: false);
            },
            icon: const Icon(Icons.add, size: 16, color: Colors.white),
            label: Text(Loc.t('New', 'نیا'), style: const TextStyle(color: Colors.white)),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 28),
                children: [
                  Row(children: [
                    Expanded(child: _summaryCard('↓', Loc.t('Total Purchases', 'کل خریداری'), _summary.totalPurchases, _p.navy)),
                    const SizedBox(width: 10),
                    Expanded(child: _summaryCard('↑', Loc.t('Total Due', 'کل باقی'), _summary.totalDue, _p.red)),
                  ]),
                  const SizedBox(height: 14),
                  _searchBox(),
                  const SizedBox(height: 12),
                  if (rows.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 50),
                      child: Center(
                        child: Text(Loc.t('No purchases yet', 'ابھی کوئی خریداری نہیں'),
                            style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: _p.textMuted)),
                      ),
                    ),
                  for (final r in rows) _card(r),
                ],
              ),
            ),
    );
  }

  Widget _summaryCard(String arrow, String label, double value, Color accent) => Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(color: _p.cardWhite, borderRadius: BorderRadius.circular(16), border: Border.all(color: _p.border)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(arrow, style: TextStyle(color: accent, fontWeight: FontWeight.bold, fontSize: 14)),
            const SizedBox(width: 6),
            Flexible(child: Text(label, style: TextStyle(color: _p.textMuted, fontSize: 12.5))),
          ]),
          const SizedBox(height: 6),
          Text(_rs(value), style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold, color: _p.textDark)),
        ]),
      );

  Widget _searchBox() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(color: _p.cardWhite, borderRadius: BorderRadius.circular(16), border: Border.all(color: _p.border)),
        child: Row(children: [
          Icon(Icons.search, size: 18, color: _p.textMuted),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _search,
              onChanged: (v) => setState(() => _query = v),
              style: TextStyle(fontSize: 14.5, color: _p.textDark),
              decoration: InputDecoration(
                hintText: Loc.t('Search supplier, item or bill no.…', 'سپلائر، آئٹم یا بل نمبر تلاش کریں…'),
                hintStyle: TextStyle(color: _p.textMuted),
                border: InputBorder.none,
              ),
            ),
          ),
        ]),
      );

  Widget _card(PurchaseHistoryRow r) {
    final due = r.due;
    final duePill = due > 0;
    final pillColor = duePill ? _p.red : _green;
    final open = _expanded.contains(r.billNo);
    final items = _items[r.billNo];
    final lines = _lines[r.billNo];
    Widget act(IconData i, Color c, VoidCallback onTap) => InkWell(
          onTap: onTap,
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8), child: Icon(i, size: 19, color: c)),
        );
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(color: _p.cardWhite, borderRadius: BorderRadius.circular(18), border: Border.all(color: _p.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => _toggle(r.billNo),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Row(children: [
                  Flexible(child: Text(r.supplierName, style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold, color: _p.textDark))),
                  if (r.isActive)
                    Container(
                      margin: const EdgeInsets.only(left: 10),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: pillColor.withOpacity(0.10),
                        borderRadius: BorderRadius.circular(30),
                        border: Border.all(color: pillColor.withOpacity(0.35)),
                      ),
                      child: Text(duePill ? Loc.t('DUE', 'باقی') : Loc.t('PAID', 'ادا شدہ'),
                          style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold, color: pillColor)),
                    ),
                  const Spacer(),
                  Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text(r.isActive ? Loc.t('Purchase', 'خریداری') : _cap(r.status), style: TextStyle(fontSize: 11.5, color: _p.textMuted)),
                    Text(_dayFmt.format(DateTime.fromMillisecondsSinceEpoch(r.createdAt)), style: TextStyle(fontSize: 11.5, color: _p.textMuted)),
                  ]),
                ]),
              ),
              const SizedBox(height: 10),
              Row(children: [
                Text(_rs(r.total), style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: r.isReturned ? _p.red : _p.textDark)),
                const Spacer(),
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Icon(open ? Icons.expand_less : Icons.expand_more, size: 22, color: _p.textMuted),
                ),
              ]),
              const SizedBox(height: 4),
              // Paid bill par "Balance: Rs 0" jagah gherta tha — ab sirf baqaya ho to "Due".
              if (r.isActive && duePill)
                Text('${Loc.t('Due', 'باقی')}: ${_rs(due)}', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: _p.red)),
              if (r.isActive)
                Align(
                  alignment: Alignment.centerRight,
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    act(Icons.print_outlined, _p.navy, () => _print(r)),
                    act(Icons.share_outlined, _p.navy, () => _share(r)),
                    act(Icons.edit_outlined, _p.teal, () => _edit(r)),
                    PopupMenuButton<int>(
                      icon: Icon(Icons.more_vert, size: 19, color: _p.textMuted),
                      onSelected: (v) => v == 1 ? _return(r) : _delete(r),
                      itemBuilder: (_) => [
                        PopupMenuItem(value: 1, child: Text(Loc.t('Return', 'واپسی'))),
                        PopupMenuItem(value: 2, child: Text(Loc.t('Delete', 'حذف کریں'))),
                      ],
                    ),
                  ]),
                )
              else
                const SizedBox(height: 10),
            ]),
          ),
        ),
        if (open)
          items == null || lines == null
              ? const Padding(padding: EdgeInsets.all(14), child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))))
              : _itemsPanel(r, items, lines),
      ]),
    );
  }

  /// Sale History jaisa saaf design: naam bold, neeche "qty unit × rate", amount daayen; neeche hisaab.
  Widget _itemsPanel(PurchaseHistoryRow r, List<PurchaseItem> items, List<ReturnableLine> lines) {
    if (items.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        child: Text(Loc.t('No items on this purchase.', 'اس خریداری میں کوئی آئٹم نہیں۔'), style: TextStyle(fontSize: 12, color: _p.textMuted)),
      );
    }
    final itemsTotal = items.fold<double>(0.0, (a, i) => a + i.amount);
    final discount = itemsTotal - r.total;
    Widget sumRow(String label, String value, {bool bold = false, Color? color}) => Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Row(children: [
            Expanded(child: Text(label, style: TextStyle(fontSize: 12.5, fontWeight: bold ? FontWeight.bold : FontWeight.normal, color: color ?? _p.textMuted))),
            Text(value, style: TextStyle(fontSize: bold ? 14 : 12.5, fontWeight: bold ? FontWeight.bold : FontWeight.w600, color: color ?? _p.textDark)),
          ]),
        );
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 0, 10, 12),
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
      decoration: BoxDecoration(color: _p.fieldFill, borderRadius: BorderRadius.circular(12), border: Border.all(color: _p.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) Divider(height: 1, thickness: 1, color: _p.border),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: 24, child: Text('${i + 1}.', style: TextStyle(fontSize: 12, color: _p.textMuted))),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(lines[i].name, style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: _p.textDark)),
                  const SizedBox(height: 2),
                  Text('${_qty(items[i].qty)} ${lines[i].unit}  ×  Rs ${_qty(items[i].unitCost)}', style: TextStyle(fontSize: 12.5, color: _p.textMuted)),
                ]),
              ),
              const SizedBox(width: 8),
              Text(_rs(items[i].amount), style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: _p.textDark)),
            ]),
          ),
        ],
        Divider(height: 8, thickness: 1.5, color: _p.border),
        sumRow('${Loc.t('Items', 'آئٹمز')}: ${items.length}', _rs(itemsTotal)),
        if (discount > 0.5) sumRow(Loc.t('Discount', 'رعایت'), '- ${_rs(discount)}'),
        sumRow(Loc.t('Total', 'کل'), _rs(r.total), bold: true, color: r.isReturned ? _p.red : _p.navy),
        if (r.isActive && r.paid > 0.009) sumRow(Loc.t('Paid', 'ادا شدہ'), _rs(r.paid)),
        if (r.isActive && r.due > 0.5) sumRow(Loc.t('Due', 'باقی'), _rs(r.due), bold: true, color: _p.red),
      ]),
    );
  }

  String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
}

/// Kotlin openReturnPurchaseDialog(): har line par "Return qty (khali = skip)". Validation pure
/// `parseReturnRequest` se.
class _ReturnDialog extends StatefulWidget {
  final List<ReturnableLine> lines;
  final AppPalette palette;
  const _ReturnDialog({required this.lines, required this.palette});

  @override
  State<_ReturnDialog> createState() => _ReturnDialogState();
}

class _ReturnDialogState extends State<_ReturnDialog> {
  late final Map<int, TextEditingController> _ctrls = {for (final l in widget.lines) l.itemId: TextEditingController()};
  String? _error;

  @override
  void dispose() {
    for (final c in _ctrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  String _qty(double v) => v == v.truncateToDouble() ? v.toInt().toString() : v.toString();

  void _submit() {
    final req = parseReturnRequest(widget.lines, {for (final e in _ctrls.entries) e.key: e.value.text});
    if (req.error != null) {
      setState(() => _error = req.error);
      return;
    }
    Navigator.pop(context, req.quantities);
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return AlertDialog(
      title: Text(Loc.t('Return items', 'آئٹمز واپس کریں')),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            Loc.t('Enter how many units of each item are being returned. Stock and supplier balance will be adjusted only for those quantities.',
                'ہر آئٹم کی کتنی مقدار واپس ہو رہی ہے درج کریں۔ صرف انہی مقداروں کے مطابق اسٹاک اور سپلائر بیلنس ایڈجسٹ ہو گا۔'),
            style: TextStyle(fontSize: 13, color: p.textMuted),
          ),
          const SizedBox(height: 8),
          Flexible(
            child: ListView(shrinkWrap: true, children: [
              for (final l in widget.lines)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(l.name, style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: p.textDark)),
                    Text(Loc.t('Purchased: ${_qty(l.qty)} ${l.unit}', 'خریدی گئی مقدار: ${_qty(l.qty)} ${l.unit}'),
                        style: TextStyle(fontSize: 12, color: p.textMuted)),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _ctrls[l.itemId],
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(
                        isDense: true,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                        hintText: Loc.t('Return qty (leave blank to skip)', 'واپسی مقدار (چھوڑنے کے لیے خالی رکھیں)'),
                      ),
                    ),
                  ]),
                ),
            ]),
          ),
          if (_error != null)
            Padding(padding: const EdgeInsets.only(top: 6), child: Text(_error!, style: TextStyle(color: p.red, fontSize: 12.5))),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(Loc.t('Cancel', 'منسوخ کریں'))),
        FilledButton(onPressed: _submit, child: Text(Loc.t('Return', 'واپسی'))),
      ],
    );
  }
}
