import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../db/customer_repository.dart';
import '../db/party_repository.dart';
import '../db/payment_repository.dart';
import '../db/supplier_repository.dart';
import '../models/misc_entities.dart';
import '../services/session.dart';
import '../utils/loc.dart';
import '../theme/theme_manager.dart';

/// Home-screen "Payments" tile (Kotlin: PartyDashboardActivity quickPayment +
/// PartyTransactionActivity.showPaymentDialog + PaymentsReportActivity).
///
/// Tab 1 "Record"  — all roles: pick Received (customer) / Made (supplier),
///                   search a party, tap it, fill the payment dialog.
/// Tab 2 "History" — admin/manager only (Kotlin PaymentsReportActivity):
///                   period totals + list. Edit/Delete are admin only.
class PaymentsScreen extends StatefulWidget {
  const PaymentsScreen({super.key});

  @override
  State<PaymentsScreen> createState() => _PaymentsScreenState();
}

class _PaymentsScreenState extends State<PaymentsScreen> {
  // Bumped after every save/edit/delete so the History tab reloads.
  final _reload = ValueNotifier<int>(0);

  @override
  void dispose() {
    _reload.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final showHistory = Session.isAdminOrManager;
    final tabs = <Tab>[
      Tab(text: Loc.t('Record', 'درج کریں')),
      if (showHistory) Tab(text: Loc.t('History', 'ہسٹری')),
    ];
    return DefaultTabController(
      length: tabs.length,
      child: Scaffold(
        backgroundColor: ThemeManager.palette.bg,
        appBar: AppBar(
          backgroundColor: ThemeManager.palette.navy,
          foregroundColor: Colors.white,
          title: Text(Loc.t('Payments', 'ادائیگیاں')),
          bottom: showHistory
              ? TabBar(
                  indicatorColor: ThemeManager.palette.teal,
                  labelColor: Colors.white,
                  unselectedLabelColor: ThemeManager.palette.headerSubtitleColor,
                  tabs: tabs,
                )
              : null,
        ),
        body: TabBarView(
          children: [
            _RecordTab(onChanged: () => _reload.value++),
            if (showHistory) _HistoryTab(reload: _reload),
          ],
        ),
      ),
    );
  }
}

String _rs(num v) => 'Rs ${v.toStringAsFixed(2)}';

// ---------------------------------------------------------------------------
// Payment dialog (Receive / Make / Edit)
// ---------------------------------------------------------------------------

/// Returns true if a payment was saved/updated.
Future<bool> showPaymentDialog(
  BuildContext context, {
  required bool isCustomer,
  required int partyId,
  required String partyName,
  Payment? existing,
}) async {
  final bills = await PaymentRepository.instance.billOptions(isCustomer: isCustomer, partyId: partyId);
  if (!context.mounted) return false;

  final amountCtrl = TextEditingController(
    text: existing == null
        ? ''
        : (existing.amount == existing.amount.roundToDouble()
            ? existing.amount.toStringAsFixed(0)
            : existing.amount.toString()),
  );
  final noteCtrl = TextEditingController(text: existing?.note ?? '');
  var date = existing != null ? DateTime.fromMillisecondsSinceEpoch(existing.createdAt) : DateTime.now();
  var method = (existing?.method.toLowerCase() == 'bank') ? 'bank' : 'cash';
  String billRef = existing != null && bills.any((b) => b.ref == existing.billReference) ? existing.billReference : '';
  String? error;

  final saved = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
      final title = existing != null
          ? Loc.t('Edit Payment', 'ادائیگی میں ترمیم')
          : isCustomer
              ? Loc.t('Receive Payment', 'ادائیگی وصول کریں')
              : Loc.t('Make Payment', 'ادائیگی کریں');
      return AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(partyName, style: TextStyle(fontWeight: FontWeight.bold, color: ThemeManager.palette.textDark)),
            const SizedBox(height: 10),
            TextField(
              controller: amountCtrl,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(labelText: Loc.t('Amount', 'رقم'), errorText: error),
            ),
            const SizedBox(height: 8),
            InkWell(
              onTap: () async {
                final picked = await showDatePicker(
                  context: ctx,
                  initialDate: date,
                  firstDate: DateTime(2000),
                  lastDate: DateTime.now(), // a payment can't be in the future
                );
                if (picked != null) setS(() => date = picked);
              },
              child: InputDecorator(
                decoration: InputDecoration(labelText: Loc.t('Date', 'تاریخ'), prefixIcon: const Icon(Icons.calendar_today, size: 18)),
                child: Text(DateFormat('dd MMM yyyy').format(date)),
              ),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              value: method,
              decoration: InputDecoration(labelText: Loc.t('Method', 'ذریعہ')),
              items: const [
                DropdownMenuItem(value: 'cash', child: Text('cash')),
                DropdownMenuItem(value: 'bank', child: Text('bank')),
              ],
              onChanged: (v) => setS(() => method = v ?? 'cash'),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              value: billRef,
              isExpanded: true,
              decoration: InputDecoration(labelText: Loc.t('Link to a bill', 'بل سے جوڑیں')),
              items: [
                DropdownMenuItem(value: '', child: Text(Loc.t('General (not linked to a bill)', 'عام (کسی بل سے منسلک نہیں)'))),
                for (final b in bills) DropdownMenuItem(value: b.ref, child: Text(b.label, overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (v) => setS(() => billRef = v ?? ''),
            ),
            const SizedBox(height: 8),
            TextField(controller: noteCtrl, decoration: InputDecoration(labelText: Loc.t('Note (optional)', 'نوٹ (اختیاری)'))),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(Loc.t('Cancel', 'منسوخ کریں'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: ThemeManager.palette.teal),
            onPressed: () async {
              final amt = double.tryParse(amountCtrl.text.trim());
              if (amt == null || amt <= 0) {
                setS(() => error = Loc.t('Enter a valid amount', 'صحیح رقم لکھیں'));
                return;
              }
              // Keep the picked day, but use the current time-of-day so several
              // payments on one day keep their order.
              final now = DateTime.now();
              final when = DateTime(date.year, date.month, date.day, now.hour, now.minute, now.second)
                  .millisecondsSinceEpoch;
              final note = noteCtrl.text.trim();
              if (existing != null) {
                await PaymentRepository.instance.update(
                  original: existing,
                  isCustomer: isCustomer,
                  partyName: partyName,
                  newAmount: amt,
                  newMethod: method,
                  newNote: note,
                  newDateMillis: when,
                  newBillRef: billRef,
                );
              } else {
                await PaymentRepository.instance.save(
                  isCustomer: isCustomer,
                  partyId: partyId,
                  partyName: partyName,
                  amount: amt,
                  method: method,
                  note: note,
                  dateMillis: when,
                  billRef: billRef,
                );
              }
              if (ctx.mounted) Navigator.pop(ctx, true);
            },
            child: Text(Loc.t('Save', 'محفوظ کریں')),
          ),
        ],
      );
    }),
  );

  amountCtrl.dispose();
  noteCtrl.dispose();
  if (saved == true && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(existing != null
          ? Loc.t('Payment updated', 'ادائیگی اپ ڈیٹ ہو گئی')
          : Loc.t('Payment saved', 'ادائیگی محفوظ ہو گئی')),
    ));
  }
  return saved == true;
}

// ---------------------------------------------------------------------------
// Tab 1: Record
// ---------------------------------------------------------------------------

class _PartyItem {
  final int id;
  final String name, phone;
  final double balance;
  const _PartyItem(this.id, this.name, this.phone, this.balance);
}

class _RecordTab extends StatefulWidget {
  final VoidCallback onChanged;
  const _RecordTab({required this.onChanged});

  @override
  State<_RecordTab> createState() => _RecordTabState();
}

class _RecordTabState extends State<_RecordTab> {
  bool _isCustomer = true; // Received (customer) / Made (supplier)
  String _q = '';

  // Balance LIVE ledger se (bills + payments), stored field se nahi — sync ke baad stored
  // balance drift kar sakta hai (Phase 6 screens bhi yahi karti hain). Opening/stuck shamil.
  late final Stream<List<_PartyItem>> _customerItems = _liveCustomers();
  late final Stream<List<_PartyItem>> _supplierItems = _liveSuppliers();

  Stream<List<_PartyItem>> _liveCustomers() async* {
    await for (final list in CustomerRepository.instance.watchAll()) {
      final live = await PartyRepository.instance.liveCustomerBalances();
      yield [
        for (final c in list)
          _PartyItem(c.id!, c.name, c.phone,
              partyClosing(opening: c.openingBalance, running: live[c.id] ?? 0.0, stuck: c.stuckBalance)),
      ];
    }
  }

  Stream<List<_PartyItem>> _liveSuppliers() async* {
    await for (final list in SupplierRepository.instance.watchAll()) {
      final live = await PartyRepository.instance.liveSupplierBalances();
      yield [
        for (final s in list)
          _PartyItem(s.id!, s.name, s.phone, partyClosing(opening: s.openingBalance, running: live[s.id] ?? 0.0)),
      ];
    }
  }

  @override
  Widget build(BuildContext context) {
    final accent = _isCustomer ? ThemeManager.palette.teal : ThemeManager.palette.orange;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        child: Column(children: [
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(value: true, label: Text(Loc.t('Payment Received', 'ادائیگی وصول ہوئی')), icon: const Icon(Icons.south_west, size: 16)),
                ButtonSegment(value: false, label: Text(Loc.t('Payment Made', 'ادائیگی ہوئی')), icon: const Icon(Icons.north_east, size: 16)),
              ],
              selected: {_isCustomer},
              onSelectionChanged: (s) => setState(() {
                _isCustomer = s.first;
                _q = '';
              }),
            ),
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              _isCustomer ? Loc.t('From a customer', 'کسٹمر سے') : Loc.t('To a supplier', 'سپلائر کو'),
              style: TextStyle(fontSize: 12, color: ThemeManager.palette.textMuted),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            onChanged: (v) => setState(() => _q = v),
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: Loc.t('Search party by name or phone', 'نام یا فون سے تلاش کریں'),
              filled: true,
              fillColor: ThemeManager.palette.fieldFill,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: ThemeManager.palette.border)),
              isDense: true,
            ),
          ),
        ]),
      ),
      Expanded(
        child: StreamBuilder<List<_PartyItem>>(
          // Stream ek hi baar banti hai (customer/supplier badalne par), har build par nahi.
          stream: _isCustomer ? _customerItems : _supplierItems,
          builder: (_, snap) => _list(snap.data ?? const [], accent, loading: !snap.hasData),
        ),
      ),
    ]);
  }

  Widget _list(List<_PartyItem> all, Color accent, {required bool loading}) {
    if (loading) return const Center(child: CircularProgressIndicator());
    final q = _q.trim().toLowerCase();
    final items = all.where((p) => q.isEmpty || '${p.name} ${p.phone}'.toLowerCase().contains(q)).toList();
    if (items.isEmpty) {
      return Center(
        child: Text(
          all.isEmpty
              ? (_isCustomer ? Loc.t('No customers yet', 'ابھی کوئی کسٹمر نہیں') : Loc.t('No suppliers yet', 'ابھی کوئی سپلائر نہیں'))
              : Loc.t('No matching party', 'کوئی مماثل پارٹی نہیں'),
          style: TextStyle(color: ThemeManager.palette.textMuted),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      itemCount: items.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (_, i) {
        final p = items[i];
        // customer balance > 0 => they owe us; supplier balance > 0 => we owe them.
        final owes = p.balance > 0.009;
        final label = owes
            ? (_isCustomer ? Loc.t('Owes', 'بقایا') : Loc.t('We owe', 'ہم نے دینا')) + ' ${_rs(p.balance)}'
            : p.balance < -0.009
                ? Loc.t('Advance', 'ایڈوانس') + ' ${_rs(-p.balance)}'
                : Loc.t('Settled', 'حساب صاف');
        return InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () async {
            final ok = await showPaymentDialog(context, isCustomer: _isCustomer, partyId: p.id, partyName: p.name);
            if (ok) widget.onChanged();
          },
          child: Ink(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: ThemeManager.palette.cardWhite,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: ThemeManager.palette.border),
            ),
            child: Row(children: [
              CircleAvatar(backgroundColor: accent.withOpacity(0.15), child: Icon(_isCustomer ? Icons.person : Icons.local_shipping, color: accent)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(p.name, style: TextStyle(fontWeight: FontWeight.bold, color: ThemeManager.palette.textDark)),
                  if (p.phone.isNotEmpty) Text(p.phone, style: TextStyle(fontSize: 12, color: ThemeManager.palette.textMuted)),
                ]),
              ),
              Text(label,
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: owes ? ThemeManager.palette.redDark : ThemeManager.palette.textMuted)),
            ]),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Tab 2: History / report  (Kotlin PaymentsReportActivity)
// ---------------------------------------------------------------------------

enum _Period { today, week, month, all }

enum _Filter { all, received, made }

class _HistoryTab extends StatefulWidget {
  final ValueNotifier<int> reload;
  const _HistoryTab({required this.reload});

  @override
  State<_HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends State<_HistoryTab> {
  _Period _period = _Period.month;
  _Filter _filter = _Filter.all;
  String _q = '';
  List<PaymentRow> _rows = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    widget.reload.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    widget.reload.removeListener(_load);
    super.dispose();
  }

  int? _from() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    switch (_period) {
      case _Period.today:
        return today.millisecondsSinceEpoch;
      case _Period.week:
        // Week starts on Monday.
        return today.subtract(Duration(days: today.weekday - 1)).millisecondsSinceEpoch;
      case _Period.month:
        return DateTime(now.year, now.month, 1).millisecondsSinceEpoch;
      case _Period.all:
        return null;
    }
  }

  Future<void> _load() async {
    final rows = await PaymentRepository.instance.report(fromMillis: _from());
    if (!mounted) return;
    setState(() {
      _rows = rows;
      _loading = false;
    });
  }

  Future<void> _rowActions(PaymentRow r) async {
    if (!Session.isAdmin) return; // edit/delete are admin only
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.edit),
            title: Text(Loc.t('Edit', 'ترمیم')),
            onTap: () => Navigator.pop(ctx, 'edit'),
          ),
          ListTile(
            leading: Icon(Icons.delete, color: ThemeManager.palette.red),
            title: Text(Loc.t('Delete', 'حذف کریں'), style: TextStyle(color: ThemeManager.palette.red)),
            onTap: () => Navigator.pop(ctx, 'delete'),
          ),
        ]),
      ),
    );
    if (choice == null || !mounted || r.partyId == null) return;
    if (choice == 'edit') {
      final ok = await showPaymentDialog(context,
          isCustomer: r.isCustomer, partyId: r.partyId!, partyName: r.partyName, existing: r.payment);
      if (ok) widget.reload.value++;
    } else {
      final sure = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(Loc.t('Delete Payment', 'ادائیگی حذف کریں')),
          content: Text(Loc.t(
            'Delete this ${_rs(r.payment.amount)} payment? The party\'s balance will be adjusted back.',
            'کیا یہ ${_rs(r.payment.amount)} کی ادائیگی حذف کی جائے؟ پارٹی کا بیلنس واپس ایڈجسٹ ہو جائے گا۔',
          )),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(Loc.t('Cancel', 'منسوخ کریں'))),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(Loc.t('Delete', 'حذف کریں'), style: TextStyle(color: ThemeManager.palette.red))),
          ],
        ),
      );
      if (sure == true) {
        await PaymentRepository.instance.delete(payment: r.payment, isCustomer: r.isCustomer);
        widget.reload.value++;
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(Loc.t('Payment deleted', 'ادائیگی حذف ہو گئی'))));
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());

    final received = _rows.where((r) => r.isCustomer).fold<double>(0, (s, r) => s + r.payment.amount);
    final made = _rows.where((r) => !r.isCustomer).fold<double>(0, (s, r) => s + r.payment.amount);
    final net = received - made;

    final q = _q.trim().toLowerCase();
    final shown = _rows.where((r) {
      final okFilter = switch (_filter) {
        _Filter.all => true,
        _Filter.received => r.isCustomer,
        _Filter.made => !r.isCustomer,
      };
      final text = '${r.partyName} ${r.payment.note} ${r.payment.method} ${r.payment.billReference}'.toLowerCase();
      return okFilter && (q.isEmpty || text.contains(q));
    }).toList();

    final fmt = DateFormat('dd MMM yyyy, hh:mm a');

    return ListView(padding: const EdgeInsets.all(16), children: [
      Row(children: [
        for (final e in {
          _Period.today: Loc.t('Today', 'آج'),
          _Period.week: Loc.t('Week', 'ہفتہ'),
          _Period.month: Loc.t('Month', 'مہینہ'),
          _Period.all: Loc.t('All Time', 'ہمیشہ'),
        }.entries)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ChoiceChip(
                label: SizedBox(width: double.infinity, child: Text(e.value, textAlign: TextAlign.center)),
                selected: _period == e.key,
                selectedColor: ThemeManager.palette.teal,
                labelStyle: TextStyle(color: _period == e.key ? Colors.white : ThemeManager.palette.textMuted, fontWeight: FontWeight.bold, fontSize: 12),
                showCheckmark: false,
                onSelected: (_) {
                  setState(() => _period = e.key);
                  _load();
                },
              ),
            ),
          ),
      ]),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(child: _summary(Loc.t('Received', 'وصول ہوئی'), received, ThemeManager.palette.teal)),
        const SizedBox(width: 10),
        Expanded(child: _summary(Loc.t('Made', 'ادا ہوئی'), made, ThemeManager.palette.redDark)),
      ]),
      const SizedBox(height: 10),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        decoration: BoxDecoration(color: ThemeManager.palette.cardWhite, borderRadius: BorderRadius.circular(16), border: Border.all(color: ThemeManager.palette.border)),
        child: Row(children: [
          Expanded(
              child: Text(Loc.t('Net (Received − Made)', 'خالص (وصول − ادا)'),
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: ThemeManager.palette.textMuted))),
          Text(_rs(net.abs()),
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: net >= 0 ? ThemeManager.palette.teal : ThemeManager.palette.redDark)),
        ]),
      ),
      const SizedBox(height: 14),
      TextField(
        onChanged: (v) => setState(() => _q = v),
        decoration: InputDecoration(
          prefixIcon: const Icon(Icons.search),
          hintText: Loc.t('Search by party, note, or method', 'پارٹی، نوٹ یا ذریعہ سے تلاش کریں'),
          filled: true,
          fillColor: ThemeManager.palette.fieldFill,
          isDense: true,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: ThemeManager.palette.border)),
        ),
      ),
      const SizedBox(height: 8),
      Wrap(spacing: 8, children: [
        for (final e in {
          _Filter.all: (Loc.t('All', 'سب'), ThemeManager.palette.teal),
          _Filter.received: (Loc.t('Received', 'وصول ہوئی'), ThemeManager.palette.teal),
          _Filter.made: (Loc.t('Made', 'ادا ہوئی'), ThemeManager.palette.redDark),
        }.entries)
          ChoiceChip(
            label: Text(e.value.$1),
            selected: _filter == e.key,
            selectedColor: e.value.$2,
            showCheckmark: false,
            labelStyle: TextStyle(color: _filter == e.key ? Colors.white : ThemeManager.palette.textMuted, fontWeight: FontWeight.bold, fontSize: 12),
            onSelected: (_) => setState(() => _filter = e.key),
          ),
      ]),
      const SizedBox(height: 10),
      if (shown.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 40),
          child: Center(
            child: Text(
              _rows.isEmpty
                  ? Loc.t('No payments in this period', 'اس مدت میں کوئی ادائیگی نہیں')
                  : Loc.t('No matching payments', 'کوئی مماثل ادائیگی نہیں'),
              style: TextStyle(color: ThemeManager.palette.textMuted),
            ),
          ),
        )
      else
        for (final r in shown)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () => _rowActions(r),
              child: Ink(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(color: ThemeManager.palette.cardWhite, borderRadius: BorderRadius.circular(16), border: Border.all(color: ThemeManager.palette.border)),
                child: Row(children: [
                  CircleAvatar(
                    radius: 19,
                    backgroundColor: (r.isCustomer ? ThemeManager.palette.teal : ThemeManager.palette.redDark).withOpacity(0.13),
                    child: Icon(r.isCustomer ? Icons.trending_up : Icons.trending_down, size: 18, color: r.isCustomer ? ThemeManager.palette.teal : ThemeManager.palette.redDark),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(r.partyName, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5, color: ThemeManager.palette.textDark)),
                      Text(
                        fmt.format(DateTime.fromMillisecondsSinceEpoch(r.payment.createdAt)) +
                            '  \u2022  ${r.payment.method.toUpperCase()}' +
                            (r.payment.billReference.isNotEmpty ? '  \u2022  ${r.payment.billReference}' : '') +
                            (r.payment.note.isNotEmpty ? '  \u2022  ${r.payment.note}' : ''),
                        style: TextStyle(fontSize: 11, color: ThemeManager.palette.textMuted),
                      ),
                    ]),
                  ),
                  Text(_rs(r.payment.amount),
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: r.isCustomer ? ThemeManager.palette.teal : ThemeManager.palette.redDark)),
                ]),
              ),
            ),
          ),
    ]);
  }

  Widget _summary(String label, double v, Color color) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: ThemeManager.palette.cardWhite, borderRadius: BorderRadius.circular(16), border: Border.all(color: ThemeManager.palette.border)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: TextStyle(fontSize: 11, color: ThemeManager.palette.textMuted)),
          const SizedBox(height: 6),
          Text(_rs(v), style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: color)),
        ]),
      );
}
