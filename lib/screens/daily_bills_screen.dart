import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../db/customer_repository.dart';
import '../db/daily_bills_repository.dart';
import '../db/rent_repository.dart';
import '../models/party.dart';
import '../theme/theme_manager.dart';
import '../utils/loc.dart';
import '../utils/sale_cart.dart' show formatQty;
import '../widgets/premium_header.dart';
import '../widgets/role_guard.dart';

/// "Aaj ke Bills" — ek din ki saari alag alag (Quick Sale) sales har customer ke ek bill ki tarah,
/// saath mein pichla balance aur aaj ka balance. Sales/stock/balance ko koi tabdeeli nahi: sirf dikhana,
/// share aur print.
class DailyBillsScreen extends StatelessWidget {
  const DailyBillsScreen({super.key});

  @override
  Widget build(BuildContext context) =>
      const RoleGuard(allowed: {'admin', 'manager'}, child: _DailyBillsBody());
}

class _DailyBillsBody extends StatefulWidget {
  const _DailyBillsBody();

  @override
  State<_DailyBillsBody> createState() => _DailyBillsBodyState();
}

class _DailyBillsBodyState extends State<_DailyBillsBody> {
  DateTime _day = DateTime.now();
  bool _loading = true;
  List<DailyParty> _rows = const [];

  final _dateFmt = DateFormat('dd MMM yyyy');
  final _timeFmt = DateFormat('hh:mm a');

  AppPalette get _p => ThemeManager.palette;
  String _rs(double v) => 'Rs ${v.toStringAsFixed(v == v.roundToDouble() ? 0 : 2)}';
  Color _balColor(double v) => v < 0 ? _p.red : _p.flatTealFg;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    List<DailyParty> rows;
    try {
      rows = await DailyBillsRepository.instance.loadDay(_day);
    } catch (_) {
      rows = const [];
    }
    if (!mounted) return;
    final rentErr = RentRepository.lastError;
    if (rentErr != null) _toast('Rent bills nahi ban sake: $rentErr');
    setState(() {
      _rows = rows;
      _loading = false;
    });
  }

  void _shift(int days) {
    setState(() => _day = DateTime(_day.year, _day.month, _day.day + days));
    _load();
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (d == null) return;
    setState(() => _day = d);
    _load();
  }

  bool get _isToday {
    final n = DateTime.now();
    return n.year == _day.year && n.month == _day.month && n.day == _day.day;
  }

  @override
  Widget build(BuildContext context) {
    final totalSales = _rows.fold<double>(0, (a, r) => a + r.salesTotal);
    final totalReceived = _rows.fold<double>(0, (a, r) => a + r.receivedTotal);
    return Scaffold(
      backgroundColor: _p.bg,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 30),
          children: [
            PremiumHeader(
              title: Loc.t('Daily Bills', 'روزانہ بلز'),
              subtitle: Loc.t('One bill per customer per day + balance', 'ہر کسٹمر کا دن کا ایک بل اور بیلنس'),
              actionLabel: Loc.t('Daily Rent', 'روزانہ کرایہ'),
              actionEmoji: '🔁',
              onActionTap: _openRentSheet,
              // Back arrow aur 3-dot menu bhi isi line mein (app bar hata diya).
              leading: IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                onPressed: () => Navigator.maybePop(context),
              ),
              trailing: PopupMenuButton<String>(
                iconColor: Colors.white,
                onSelected: (v) => _dayOff(v == 'off'),
                itemBuilder: (_) => [
                  PopupMenuItem(value: 'off', child: Text(Loc.t('Remove rent for this day (holiday)', 'اس دن کا کرایہ ہٹائیں (چھٹی)'))),
                  PopupMenuItem(value: 'on', child: Text(Loc.t('Restore rent for this day', 'اس دن کا کرایہ واپس لگائیں'))),
                ],
              ),
            ),
            _dateBar(),
            if (!_loading && _rows.isNotEmpty) _summary(totalSales, totalReceived),
            if (_loading)
              const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator()))
            else if (_rows.isEmpty)
              Padding(
                padding: const EdgeInsets.all(30),
                child: Center(
                  child: Text(Loc.t('No sales on this day', 'اس دن کوئی سیل نہیں'),
                      style: TextStyle(color: _p.textMuted, fontWeight: FontWeight.bold)),
                ),
              )
            else
              for (final r in _rows) _partyCard(r),
          ],
        ),
      ),
    );
  }

  Widget _dateBar() => Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: _p.cardWhite,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _p.border),
        ),
        child: Row(children: [
          IconButton(icon: const Icon(Icons.chevron_left), onPressed: () => _shift(-1)),
          Expanded(
            child: InkWell(
              onTap: _pickDate,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  '${_isToday ? '${Loc.t('Today', 'آج')} • ' : ''}${_dateFmt.format(_day)}',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: _p.textDark),
                ),
              ),
            ),
          ),
          IconButton(icon: const Icon(Icons.chevron_right), onPressed: _isToday ? null : () => _shift(1)),
        ]),
      );

  Widget _summary(double sales, double received) => Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: _p.cardWhite,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _p.border),
        ),
        child: Row(children: [
          _stat(Loc.t('Customers', 'کسٹمرز'), '${_rows.length}', _p.textDark),
          _stat(Loc.t('Total sales', 'کل سیل'), _rs(sales), _p.flatBlueFg),
          _stat(Loc.t('Total received', 'کل وصول'), _rs(received), _p.flatTealFg),
        ]),
      );

  Widget _stat(String label, String value, Color color) => Expanded(
        child: Column(children: [
          Text(label, style: TextStyle(fontSize: 11.5, color: _p.textMuted)),
          const SizedBox(height: 3),
          Text(value, style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold, color: color)),
        ]),
      );

  Widget _kv(String k, String v, {Color? color, bool bold = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2.5),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(k, style: TextStyle(fontSize: 13, color: _p.textMuted, fontWeight: bold ? FontWeight.bold : FontWeight.normal)),
          Text(v, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: color ?? _p.textDark)),
        ]),
      );

  Widget _partyCard(DailyParty r) => Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: _p.cardWhite,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: _p.border),
          boxShadow: const [BoxShadow(color: Color(0x0F000000), blurRadius: 4, offset: Offset(0, 1))],
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => _showDetail(r),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Expanded(
                  child: Text(r.name, style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: _p.textDark)),
                ),
                Text('${r.billCount} ${Loc.t('bills', 'بلز')}', style: TextStyle(fontSize: 12, color: _p.textMuted)),
              ]),
              const SizedBox(height: 8),
              _kv(Loc.t('Previous balance', 'پچھلا بیلنس'), _rs(r.previousBalance), color: _balColor(r.previousBalance)),
              _kv(Loc.t('Today\'s sale', 'آج کی سیل'), '+ ${_rs(r.salesTotal)}', color: _p.flatBlueFg),
              if (r.receivedTotal > 0)
                _kv(Loc.t('Received today', 'آج وصول'), '- ${_rs(r.receivedTotal)}', color: _p.flatTealFg),
              Divider(height: 14, color: _p.border),
              _kv(Loc.t('Today\'s balance', 'آج کا بیلنس'), _rs(r.closingBalance), color: _balColor(r.closingBalance), bold: true),
            ]),
          ),
        ),
      );

  // ---- Daily Rent ------------------------------------------------------------------------

  void _toast(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _billOff(String invoice) async {
    try {
      await RentRepository.instance.setRentBillOff(invoice, off: true);
      _toast(Loc.t('Rent removed', 'کرایہ ہٹا دیا گیا'));
    } catch (e) {
      _toast('$e');
    }
    await _load();
  }

  Future<void> _dayOff(bool off) async {
    try {
      final n = await RentRepository.instance.setDayOff(_day, off: off);
      _toast(n == 0
          ? Loc.t('No rent bill found for this day', 'اس دن کوئی کرایہ بل نہیں ملا')
          : (off
              ? Loc.t('Rent removed for $n customers (holiday)', '$n کسٹمرز کا کرایہ ہٹا دیا (چھٹی)')
              : Loc.t('Rent restored for $n customers', '$n کسٹمرز کا کرایہ واپس لگا دیا')));
    } catch (e) {
      _toast('$e');
    }
    await _load();
  }

  Future<void> _openRentSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _p.cardWhite,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (ctx) => _RentSheet(palette: _p),
    );
    await _load();
  }

  // ---- detail: ek customer ka poora din ka bill -------------------------------------------

  Future<void> _showDetail(DailyParty r) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _p.cardWhite,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.85,
        maxChildSize: 0.95,
        builder: (_, scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: [
            Text(r.name, style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold, color: _p.textDark)),
            Text(_dateFmt.format(_day), style: TextStyle(color: _p.textMuted)),
            const SizedBox(height: 10),
            _kv(Loc.t('Previous balance', 'پچھلا بیلنس'), _rs(r.previousBalance), color: _balColor(r.previousBalance), bold: true),
            Divider(color: _p.border),
            for (final b in r.bills) ...[
              Row(children: [
                Expanded(
                  child: Text('${b.invoice}  •  ${_timeFmt.format(DateTime.fromMillisecondsSinceEpoch(b.time))}',
                      style: TextStyle(fontWeight: FontWeight.bold, color: _p.textDark)),
                ),
                Text(_rs(b.total), style: TextStyle(fontWeight: FontWeight.bold, color: _p.flatBlueFg)),
              ]),
              for (final i in b.items)
                Padding(
                  padding: const EdgeInsets.only(left: 8, top: 2),
                  child: Row(children: [
                    Expanded(
                      child: Text(
                        '${i.product}  ${formatQty(i.qty)}${i.unit.isEmpty ? '' : ' ${i.unit}'} × ${i.unitPrice.toStringAsFixed(i.unitPrice == i.unitPrice.roundToDouble() ? 0 : 2)}',
                        style: TextStyle(fontSize: 12.5, color: _p.textMuted),
                      ),
                    ),
                    Text(i.amount.toStringAsFixed(i.amount == i.amount.roundToDouble() ? 0 : 2),
                        style: TextStyle(fontSize: 12.5, color: _p.textDark)),
                  ]),
                ),
              if (b.paid > 0)
                Padding(
                  padding: const EdgeInsets.only(left: 8, top: 2),
                  child: Text('${Loc.t('Paid', 'ادا')}: ${_rs(b.paid)}',
                      style: TextStyle(fontSize: 12.5, color: _p.flatTealFg)),
                ),
              Divider(color: _p.border),
            ],
            for (final pm in r.payments)
              _kv('${Loc.t('Payment received', 'ادائیگی ملی')} • ${_timeFmt.format(DateTime.fromMillisecondsSinceEpoch(pm.time))}',
                  '- ${_rs(pm.amount)}', color: _p.flatTealFg),
            _kv(Loc.t('Today\'s sale', 'آج کی سیل'), '+ ${_rs(r.salesTotal)}', color: _p.flatBlueFg),
            if (r.receivedTotal > 0) _kv(Loc.t('Received today', 'آج وصول'), '- ${_rs(r.receivedTotal)}', color: _p.flatTealFg),
            Divider(color: _p.border),
            _kv(Loc.t('Today\'s balance', 'آج کا بیلنس'), _rs(r.closingBalance), color: _balColor(r.closingBalance), bold: true),
            const SizedBox(height: 14),
            for (final b in r.bills)
              if (isRentInvoice(b.invoice))
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      Navigator.pop(ctx);
                      await _billOff(b.invoice);
                    },
                    icon: const Icon(Icons.beach_access),
                    label: Text(Loc.t('Remove today\'s rent for this customer (holiday)', 'اس کسٹمر کا آج کا کرایہ ہٹائیں (چھٹی)')),
                  ),
                ),
            Row(children: [
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: _p.flatTealFg, padding: const EdgeInsets.symmetric(vertical: 13)),
                  onPressed: () => Share.share(dailyBillText(r, _day)),
                  icon: const Icon(Icons.share),
                  label: Text(Loc.t('Share bill', 'بل شیئر کریں')),
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}


/// Daily Rent setting: kin customers se roz rent aata hai, kitna, kis din se.
class _RentSheet extends StatefulWidget {
  final AppPalette palette;
  const _RentSheet({required this.palette});

  @override
  State<_RentSheet> createState() => _RentSheetState();
}

class _RentSheetState extends State<_RentSheet> {
  List<RentConfig> _configs = const [];
  bool _loading = true;
  final _dateFmt = DateFormat('dd MMM yyyy');

  AppPalette get _p => widget.palette;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final c = await RentRepository.instance.listConfigs();
    if (!mounted) return;
    setState(() {
      _configs = c;
      _loading = false;
    });
  }

  void _toast(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _edit({RentConfig? existing}) async {
    final customers = await CustomerRepository.instance.listAll();
    if (!mounted) return;
    int? customerId = existing?.customerId;
    final amountCtl = TextEditingController(
        text: existing == null ? '' : existing.dailyRent.toStringAsFixed(existing.dailyRent == existing.dailyRent.roundToDouble() ? 0 : 2));
    var start = existing == null ? DateTime.now() : DateTime.fromMillisecondsSinceEpoch(existing.startDay);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(Loc.t('Daily Rent', 'روزانہ کرایہ')),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            DropdownButtonFormField<int>(
              value: customerId,
              isExpanded: true,
              decoration: InputDecoration(labelText: Loc.t('Customer', 'کسٹمر')),
              items: [
                for (final Customer c in customers)
                  if (c.id != null) DropdownMenuItem<int>(value: c.id, child: Text(c.name, overflow: TextOverflow.ellipsis)),
              ],
              onChanged: existing != null ? null : (v) => setD(() => customerId = v),
            ),
            TextField(
              controller: amountCtl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(labelText: Loc.t('Daily rent (Rs)', 'روز کا کرایہ (روپے)')),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              icon: const Icon(Icons.calendar_today, size: 18),
              label: Text('${Loc.t('Starting from', 'کس دن سے')}: ${_dateFmt.format(start)}'),
              onPressed: () async {
                final d = await showDatePicker(
                  context: ctx,
                  initialDate: start,
                  firstDate: DateTime.now().subtract(const Duration(days: 366)),
                  lastDate: DateTime.now(),
                );
                if (d != null) setD(() => start = d);
              },
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(Loc.t('Cancel', 'منسوخ'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(Loc.t('Save', 'محفوظ'))),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final rent = double.tryParse(amountCtl.text.trim());
    if (customerId == null || rent == null || rent <= 0) {
      _toast(Loc.t('Customer and rent (more than 0) are required', 'کسٹمر اور کرایہ (0 سے زیادہ) ضروری ہے'));
      return;
    }
    try {
      await RentRepository.instance.setConfig(customerId: customerId!, dailyRent: rent, startDay: start);
      // Aaj tak ke bills foran bana do.
      final n = await RentRepository.instance.ensureRentUpTo(DateTime.now());
      _toast(Loc.t('Rent set. $n days of rent bills created', 'کرایہ سیٹ ہو گیا۔ $n دن کے کرایہ بل بن گئے'));
    } catch (e) {
      _toast('$e');
    }
    await _reload();
  }

  Future<void> _stop(RentConfig c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(Loc.t('Stop rent?', 'کرایہ بند کریں؟')),
        content: Text(Loc.t('Rent for ${c.name} will not be charged from now on. Old bills and balance stay as they are.',
            '${c.name} کا کرایہ آگے سے نہیں لگے گا۔ پرانے بل اور بیلنس جیسے ہیں ویسے رہیں گے۔')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(Loc.t('No', 'نہیں'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(Loc.t('Stop', 'بند کریں'))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await RentRepository.instance.removeConfig(c.customerId);
    } catch (e) {
      _toast('$e');
    }
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(Loc.t('Daily Rent', 'روزانہ کرایہ'),
            style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold, color: _p.textDark)),
        const SizedBox(height: 4),
        Text(
          Loc.t('Daily rent is added automatically to the customer\'s Daily Bill and balance every day. For a holiday, remove that day\'s rent from the Daily Bills menu. Set rent on one device only.',
              'روز کا کرایہ ہر دن کسٹمر کے ڈیلی بل اور بیلنس میں خود جڑتا ہے۔ چھٹی والے دن کا کرایہ ڈیلی بلز کے مینو سے ہٹا دیں۔ کرایہ صرف ایک ڈیوائس پر سیٹ کریں۔'),
          style: TextStyle(fontSize: 12.5, color: _p.textMuted),
        ),
        const SizedBox(height: 10),
        if (_loading)
          const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator()))
        else if (_configs.isEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Center(child: Text(Loc.t('No rent customers yet', 'ابھی کوئی کرایہ کسٹمر نہیں'), style: TextStyle(color: _p.textMuted))),
          )
        else
          Flexible(
            child: ListView(shrinkWrap: true, children: [
              for (final c in _configs)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(c.name, style: TextStyle(fontWeight: FontWeight.bold, color: _p.textDark)),
                  subtitle: Text(
                      'Rs ${c.dailyRent.toStringAsFixed(c.dailyRent == c.dailyRent.roundToDouble() ? 0 : 2)} / ${Loc.t('day', 'دن')} • ${_dateFmt.format(DateTime.fromMillisecondsSinceEpoch(c.startDay))}'),
                  onTap: () => _edit(existing: c),
                  trailing: IconButton(icon: const Icon(Icons.stop_circle_outlined), onPressed: () => _stop(c)),
                ),
            ]),
          ),
        const SizedBox(height: 10),
        FilledButton.icon(
          onPressed: () => _edit(),
          icon: const Icon(Icons.add),
          label: Text(Loc.t('New rent customer', 'نیا کرایہ کسٹمر')),
        ),
      ]),
    );
  }
}
