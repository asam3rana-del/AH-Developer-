import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../db/shop_rent_repository.dart';
import '../theme/theme_manager.dart';
import '../utils/loc.dart';

/// Shop Rents — jo dukaneen hum kiraye par lete hain: har dukaan ka malik, mahana rent, advance, advance se rent
/// katna, saal baad rent badalna, history aur mahine ki report. Admin/Manager (RoleGuard se kholein).
/// Maths + DB: lib/db/shop_rent_repository.dart.
class ShopRentScreen extends StatefulWidget {
  const ShopRentScreen({super.key});

  @override
  State<ShopRentScreen> createState() => _ShopRentScreenState();
}

class _ShopRentScreenState extends State<ShopRentScreen> {
  List<ShopRentSummary> _items = const [];
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      await ShopRentRepository.instance.ensureCharges();
      final items = [...await ShopRentRepository.instance.summaries()];
      // Zaroori pehle: chalti dukaneen, un mein late wali, phir zyada baqi wali, phir naam se.
      items.sort((a, b) {
        if (a.shop.active != b.shop.active) return a.shop.active ? -1 : 1;
        if (a.overdue != b.overdue) return a.overdue ? -1 : 1;
        final byDue = b.outstanding.compareTo(a.outstanding);
        if (byDue != 0) return byDue;
        return a.shop.shopName.toLowerCase().compareTo(b.shop.shopName.toLowerCase());
      });
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _toast(e.toString());
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  String _rs(double v) => 'Rs ${NumberFormat('#,##0').format(v.round())}';

  /// Koi bhi kaam chalao: double-tap se bachao, ghalti dikhao, phir list taaza karo.
  Future<void> _run(Future<void> Function() job, {String? ok}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await job();
      if (ok != null && mounted) _toast(ok);
    } catch (e) {
      if (mounted) _toast(e is StateError ? e.message : (e is ArgumentError ? '${e.message}' : e.toString()));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await _load();
  }

  // ------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final p = ThemeManager.palette;
    final active = _items.where((s) => s.shop.active).toList();
    final monthRent = active.fold<double>(0, (a, s) => a + s.currentRent);
    final due = active.fold<double>(0, (a, s) => a + s.outstanding);
    final adv = _items.fold<double>(0, (a, s) => a + s.advanceBalance);
    return Scaffold(
      backgroundColor: p.bg,
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: p.teal,
        foregroundColor: Colors.white,
        onPressed: _busy ? null : _addShopDialog,
        icon: const Icon(Icons.add),
        label: Text(Loc.t('Add Shop', 'دکان شامل کریں')),
      ),
      body: Column(children: [
        _header(p),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                    children: [
                      Row(children: [
                        _stat(p, Loc.t('Monthly Rent', 'ماہانہ کرایہ'), _rs(monthRent), p.navyInk),
                        const SizedBox(width: 10),
                        _stat(p, Loc.t('Due', 'باقی'), _rs(due), due > 0 ? p.red : p.teal),
                        const SizedBox(width: 10),
                        _stat(p, Loc.t('Advance', 'ایڈوانس'), _rs(adv), p.teal),
                      ]),
                      const SizedBox(height: 16),
                      if (_items.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            Loc.t('No shops yet. Tap "Add Shop" to add a rented shop.',
                                'ابھی کوئی دکان نہیں۔ کرائے کی دکان شامل کرنے کے لیے "دکان شامل کریں" دبائیں۔'),
                            textAlign: TextAlign.center,
                            style: TextStyle(color: p.textMuted),
                          ),
                        )
                      else
                        for (final s in _items) _shopCard(p, s),
                    ],
                  ),
                ),
        ),
      ]),
    );
  }

  Widget _header(AppPalette p) {
    return Container(
      color: p.navy,
      padding: EdgeInsets.fromLTRB(8, MediaQuery.of(context).padding.top + 10, 8, 16),
      child: Row(children: [
        IconButton(icon: const Icon(Icons.arrow_back, color: Colors.white), onPressed: () => Navigator.of(context).maybePop()),
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(color: p.headerBadgeOverlay, shape: BoxShape.circle),
          child: const Icon(Icons.storefront_outlined, color: Colors.white, size: 18),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(Loc.t('Shop Rents', 'دکانوں کا کرایہ'),
                style: const TextStyle(color: Colors.white, fontSize: 18.5, fontWeight: FontWeight.bold)),
            Text(Loc.t('Monthly rent, advance & landlords', 'ماہانہ کرایہ، ایڈوانس اور مالک'),
                style: TextStyle(color: p.headerSubtitleColor, fontSize: 11)),
          ]),
        ),
        IconButton(
          tooltip: Loc.t('Monthly report', 'ماہانہ رپورٹ'),
          icon: const Icon(Icons.bar_chart, color: Colors.white),
          onPressed: _reportSheet,
        ),
      ]),
    );
  }

  BoxDecoration _card(AppPalette p, double r) => BoxDecoration(
        color: p.cardWhite,
        borderRadius: BorderRadius.circular(r),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 8, offset: const Offset(0, 3))],
      );

  Widget _stat(AppPalette p, String label, String value, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: _card(p, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: p.textMuted)),
          const SizedBox(height: 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(value, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: color)),
          ),
        ]),
      ),
    );
  }

  Widget _chip(AppPalette p, String text, Color fg, Color bg) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
        child: Text(text, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: fg)),
      );

  Widget _shopCard(AppPalette p, ShopRentSummary s) {
    final shop = s.shop;
    final df = DateFormat('dd MMM yyyy');
    Widget status;
    if (!shop.active) {
      status = _chip(p, Loc.t('Closed', 'بند'), p.textMuted, p.fieldFill);
    } else if (s.isClear) {
      status = _chip(p, Loc.t('Paid', 'ادا'), p.flatTealFg, p.flatTealBg);
    } else if (s.overdue) {
      status = _chip(p, '${Loc.t('Overdue', 'تاخیر')} ${_rs(s.outstanding)}', p.flatCoralFg, p.flatCoralBg);
    } else {
      status = _chip(p, '${Loc.t('Due', 'باقی')} ${_rs(s.outstanding)}', p.flatAmberFg, p.flatAmberBg);
    }
    return Opacity(
      opacity: shop.active ? 1 : 0.6,
      child: Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.all(16),
        decoration: _card(p, 20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(shop.shopName, style: TextStyle(fontSize: 16.5, fontWeight: FontWeight.bold, color: p.textDark)),
                const SizedBox(height: 2),
                Text(
                  [
                    if (shop.landlord.isNotEmpty) shop.landlord,
                    if (shop.phone.isNotEmpty) shop.phone,
                  ].join('  •  '),
                  style: TextStyle(fontSize: 12.5, color: p.textMuted),
                ),
              ]),
            ),
            status,
            _menu(p, s),
          ]),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 6, children: [
            _chip(p, '${_rs(s.currentRent)} / ${Loc.t('month', 'ماہ')}', p.navyInk, p.fieldFill),
            _chip(p, '${Loc.t('Due on', 'تاریخ')} ${shop.dueDay}', p.navyInk, p.fieldFill),
            if (s.advanceBalance > 0)
              _chip(p, '${Loc.t('Advance', 'ایڈوانس')} ${_rs(s.advanceBalance)}', p.flatTealFg, p.flatTealBg),
          ]),
          if (s.dues.isNotEmpty) ...[
            const SizedBox(height: 10),
            for (final d in s.dues)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Row(children: [
                  Expanded(
                    child: Text(
                      '${DateFormat('MMMM yyyy').format(ymToDate(d.ym))}  •  ${Loc.t('due', 'تاریخ')} ${df.format(dueDateFor(d.ym, shop.dueDay))}',
                      style: TextStyle(fontSize: 12.5, color: p.textDark),
                    ),
                  ),
                  Text(_rs(d.due), style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: p.red)),
                ]),
              ),
          ],
          if (shop.active && s.reviewDue) ...[
            const SizedBox(height: 10),
            InkWell(
              onTap: () => _changeRentDialog(s),
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: p.flatAmberBg, borderRadius: BorderRadius.circular(12)),
                child: Row(children: [
                  Icon(Icons.update, size: 16, color: p.flatAmberFg),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      Loc.t('Rent has not changed for a year — time to review it. Tap to change.',
                          'کرایہ ایک سال سے وہی ہے — اب بدلنے کا وقت ہے۔ بدلنے کے لیے دبائیں۔'),
                      style: TextStyle(fontSize: 12, color: p.flatAmberFg, fontWeight: FontWeight.w600),
                    ),
                  ),
                ]),
              ),
            ),
          ],
          if (shop.active) ...[
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: [
              _action(p, Icons.payments_outlined, Loc.t('Pay Rent', 'کرایہ دیں'), p.teal, () => _payDialog(s)),
              _action(p, Icons.savings_outlined, Loc.t('Give Advance', 'ایڈوانس دیں'), p.blue, () => _advanceDialog(s)),
              if (s.advanceBalance > 0 && s.outstanding > 0)
                _action(p, Icons.content_cut, Loc.t('Deduct from Advance', 'ایڈوانس سے کاٹیں'), p.amber, () => _applyAdvance(s)),
            ]),
          ],
        ]),
      ),
    );
  }

  Widget _action(AppPalette p, IconData icon, String label, Color color, VoidCallback onTap) {
    return OutlinedButton.icon(
      onPressed: _busy ? null : onTap,
      icon: Icon(icon, size: 16, color: color),
      label: Text(label, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 12.5)),
      style: OutlinedButton.styleFrom(
        side: BorderSide(color: color.withOpacity(0.5)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  Widget _menu(AppPalette p, ShopRentSummary s) {
    final shop = s.shop;
    return PopupMenuButton<String>(
      icon: Icon(Icons.more_vert, color: p.textMuted),
      onSelected: (v) {
        switch (v) {
          case 'history':
            _historySheet(s);
          case 'rent':
            _changeRentDialog(s);
          case 'edit':
            _editShopDialog(s);
          case 'call':
            launchUrl(Uri(scheme: 'tel', path: shop.phone), mode: LaunchMode.externalApplication);
          case 'waive':
            _waiveDialog(s);
          case 'active':
            _run(() => ShopRentRepository.instance.setActive(shop.id, !shop.active));
          case 'delete':
            _deleteShop(s);
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem(value: 'history', child: Text(Loc.t('History', 'ہسٹری'))),
        if (shop.active) PopupMenuItem(value: 'rent', child: Text(Loc.t('Change Rent', 'کرایہ بدلیں'))),
        PopupMenuItem(value: 'edit', child: Text(Loc.t('Edit Shop', 'دکان میں ترمیم'))),
        if (shop.phone.isNotEmpty) PopupMenuItem(value: 'call', child: Text(Loc.t('Call Landlord', 'مالک کو کال کریں'))),
        if (shop.active && s.dues.isNotEmpty) PopupMenuItem(value: 'waive', child: Text(Loc.t('Waive a Month', 'ایک مہینہ معاف'))),
        PopupMenuItem(
            value: 'active',
            child: Text(shop.active ? Loc.t('Close Shop (stop rent)', 'دکان بند (کرایہ بند)') : Loc.t('Reopen Shop', 'دکان دوبارہ شروع'))),
        PopupMenuItem(value: 'delete', child: Text(Loc.t('Delete Shop', 'دکان حذف کریں'))),
      ],
    );
  }

  // ------------------------------------------------------------ small form helpers

  InputDecoration _deco(AppPalette p, String label, {String? hint}) => InputDecoration(
        labelText: label,
        hintText: hint,
        isDense: true,
        filled: true,
        fillColor: p.fieldFill,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      );

  TextField _numField(AppPalette p, TextEditingController c, String label, {bool decimal = true}) => TextField(
        controller: c,
        keyboardType: TextInputType.numberWithOptions(decimal: decimal),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(decimal ? r'[0-9.]' : r'[0-9]'))],
        decoration: _deco(p, label),
      );

  Widget _methodChips(String method, void Function(String) onPick) {
    return Wrap(spacing: 8, children: [
      for (final m in const ['cash', 'bank'])
        ChoiceChip(
          label: Text(m == 'cash' ? Loc.t('Cash', 'کیش') : Loc.t('Bank', 'بینک')),
          selected: method == m,
          onSelected: (_) => onPick(m),
        ),
    ]);
  }

  Future<DateTime?> _pickMonth(DateTime initial) => showDatePicker(
        context: context,
        initialDate: initial,
        firstDate: DateTime(initial.year - 10, 1, 1),
        lastDate: DateTime(initial.year + 10, 12, 31),
        helpText: Loc.t('Pick any day of the month', 'مہینے کا کوئی بھی دن چنیں'),
      );

  Future<bool> _confirm(String title, String body) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(Loc.t('Cancel', 'منسوخ'))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(Loc.t('Yes', 'ہاں'))),
        ],
      ),
    );
    return ok == true;
  }

  // ------------------------------------------------------------ dialogs

  Future<void> _addShopDialog() => _shopDialog(null);
  Future<void> _editShopDialog(ShopRentSummary s) => _shopDialog(s);

  Future<void> _shopDialog(ShopRentSummary? edit) async {
    final p = ThemeManager.palette;
    final shop = edit?.shop;
    final name = TextEditingController(text: shop?.shopName ?? '');
    final landlord = TextEditingController(text: shop?.landlord ?? '');
    final phone = TextEditingController(text: shop?.phone ?? '');
    final rent = TextEditingController();
    final dueDay = TextEditingController(text: '${shop?.dueDay ?? 1}');
    final openAdv = TextEditingController();
    final note = TextEditingController(text: shop?.note ?? '');
    var auto = shop?.autoApply ?? true;
    var start = DateTime.now();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(edit == null ? Loc.t('Add Shop', 'دکان شامل کریں') : Loc.t('Edit Shop', 'دکان میں ترمیم')),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: name, decoration: _deco(p, Loc.t('Shop name', 'دکان کا نام'))),
              const SizedBox(height: 10),
              TextField(controller: landlord, decoration: _deco(p, Loc.t('Landlord name', 'مالک کا نام'))),
              const SizedBox(height: 10),
              TextField(controller: phone, keyboardType: TextInputType.phone, decoration: _deco(p, Loc.t('Landlord phone', 'مالک کا فون'))),
              const SizedBox(height: 10),
              if (edit == null) ...[
                _numField(p, rent, Loc.t('Monthly rent', 'ماہانہ کرایہ')),
                const SizedBox(height: 10),
              ],
              _numField(p, dueDay, Loc.t('Pay on day of month (1-31)', 'مہینے کی کس تاریخ کو دینا ہے (1-31)'), decimal: false),
              const SizedBox(height: 10),
              if (edit == null) ...[
                InkWell(
                  onTap: () async {
                    final d = await _pickMonth(start);
                    if (d != null) setD(() => start = d);
                  },
                  child: InputDecorator(
                    decoration: _deco(p, Loc.t('Rent starts from', 'کرایہ کس مہینے سے')),
                    child: Text(DateFormat('MMMM yyyy').format(start)),
                  ),
                ),
                const SizedBox(height: 10),
                _numField(p, openAdv, Loc.t('Advance already given (optional)', 'پہلے سے دیا ہوا ایڈوانس (اختیاری)')),
                const SizedBox(height: 6),
              ],
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: auto,
                onChanged: (v) => setD(() => auto = v),
                title: Text(Loc.t('Deduct new rent from advance automatically', 'نیا کرایہ ایڈوانس سے خود کاٹیں'),
                    style: const TextStyle(fontSize: 13.5)),
              ),
              TextField(controller: note, decoration: _deco(p, Loc.t('Note (optional)', 'نوٹ (اختیاری)'))),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(Loc.t('Cancel', 'منسوخ'))),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(Loc.t('Save', 'محفوظ کریں'))),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final day = int.tryParse(dueDay.text.trim()) ?? 1;
    await _run(() async {
      if (edit == null) {
        await ShopRentRepository.instance.addShop(
          shopName: name.text,
          landlord: landlord.text,
          phone: phone.text,
          monthlyRent: double.tryParse(rent.text.trim()) ?? 0,
          dueDay: day,
          startMonth: start,
          openingAdvance: double.tryParse(openAdv.text.trim()) ?? 0,
          autoApply: auto,
          note: note.text,
        );
      } else {
        await ShopRentRepository.instance.updateShop(
          edit.shop.id,
          shopName: name.text,
          landlord: landlord.text,
          phone: phone.text,
          dueDay: day,
          autoApply: auto,
          note: note.text,
        );
      }
    }, ok: Loc.t('Saved', 'محفوظ ہو گیا'));
  }

  /// Ek hi dialog Rent dene aur Advance dene ke liye: raqam, cash/bank, note.
  Future<({double amount, String method, String note, DateTime date})?> _moneyDialog({
    required String title,
    String? info,
    double initial = 0,
    required String okLabel,
  }) async {
    final p = ThemeManager.palette;
    final amount = TextEditingController(text: initial > 0 ? initial.round().toString() : '');
    final note = TextEditingController();
    var method = 'cash';
    var date = DateTime.now();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (info != null) ...[
                Text(info, style: TextStyle(fontSize: 12.5, color: p.textMuted)),
                const SizedBox(height: 10),
              ],
              _numField(p, amount, Loc.t('Amount', 'رقم')),
              const SizedBox(height: 12),
              _methodChips(method, (m) => setD(() => method = m)),
              const SizedBox(height: 12),
              InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () async {
                  final today = DateTime.now();
                  final d = await showDatePicker(
                    context: ctx,
                    initialDate: date,
                    firstDate: DateTime(today.year - 5, 1, 1),
                    lastDate: today,
                    helpText: Loc.t('Payment date', 'ادائیگی کی تاریخ'),
                  );
                  if (d != null) setD(() => date = d);
                },
                child: InputDecorator(
                  decoration: _deco(p, Loc.t('Date', 'تاریخ')),
                  child: Row(children: [
                    Expanded(child: Text(DateFormat('dd MMM yyyy').format(date))),
                    Icon(Icons.calendar_today, size: 18, color: p.textMuted),
                  ]),
                ),
              ),
              const SizedBox(height: 12),
              TextField(controller: note, decoration: _deco(p, Loc.t('Note (optional)', 'نوٹ (اختیاری)'))),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(Loc.t('Cancel', 'منسوخ'))),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(okLabel)),
          ],
        ),
      ),
    );
    if (ok != true) return null;
    final a = double.tryParse(amount.text.trim());
    if (a == null || !a.isFinite || a <= 0) {
      _toast(Loc.t('Enter a valid amount', 'صحیح رقم لکھیں'));
      return null;
    }
    // Chuni hui tareekh + abhi ka waqt (aaj ho to bilkul abhi ka) — taake din ke andar tarteeb sahi rahe.
    final nowT = DateTime.now();
    final stamp = (date.year == nowT.year && date.month == nowT.month && date.day == nowT.day)
        ? nowT
        : DateTime(date.year, date.month, date.day, nowT.hour, nowT.minute, nowT.second);
    return (amount: a, method: method, note: note.text, date: stamp);
  }

  Future<void> _payDialog(ShopRentSummary s) async {
    final r = await _moneyDialog(
      title: '${Loc.t('Pay Rent', 'کرایہ دیں')} • ${s.shop.shopName}',
      info: s.outstanding > 0
          ? '${Loc.t('Due now', 'ابھی باقی')}: ${_rs(s.outstanding)}. ${Loc.t('Anything extra becomes advance.', 'زیادہ دیا تو باقی ایڈوانس بن جائے گا۔')}'
          : Loc.t('Nothing is due. This will be kept as advance.', 'کچھ باقی نہیں۔ یہ رقم ایڈوانس بن جائے گی۔'),
      initial: s.outstanding,
      okLabel: Loc.t('Pay', 'ادا کریں'),
    );
    if (r == null) return;
    PayResult? res;
    await _run(() async {
      res = await ShopRentRepository.instance.pay(s.shop.id, amount: r.amount, method: r.method, note: r.note, now: r.date);
    });
    final x = res;
    if (x != null && mounted) {
      _toast(x.toAdvance > 0
          ? '${Loc.t('Rent paid', 'کرایہ ادا')} ${_rs(x.toRent)} + ${Loc.t('advance', 'ایڈوانس')} ${_rs(x.toAdvance)}'
          : '${Loc.t('Rent paid', 'کرایہ ادا')} ${_rs(x.toRent)}');
    }
  }

  Future<void> _advanceDialog(ShopRentSummary s) async {
    final r = await _moneyDialog(
      title: '${Loc.t('Give Advance', 'ایڈوانس دیں')} • ${s.shop.shopName}',
      info: Loc.t('Advance is money kept with the landlord. It is a Cash/Bank out but NOT an expense — it becomes rent expense only when deducted.',
          'ایڈوانس مالک کے پاس جمع رقم ہے۔ یہ کیش/بینک سے نکلتی ہے مگر خرچہ نہیں — کرایہ میں کٹنے پر ہی خرچہ بنتی ہے۔'),
      okLabel: Loc.t('Give', 'دیں'),
    );
    if (r == null) return;
    await _run(() async {
      await ShopRentRepository.instance.giveAdvance(s.shop.id, amount: r.amount, method: r.method, note: r.note, now: r.date);
      if (s.shop.autoApply) await ShopRentRepository.instance.applyAdvance(s.shop.id, now: r.date);
    }, ok: Loc.t('Advance saved', 'ایڈوانس محفوظ'));
  }

  Future<void> _applyAdvance(ShopRentSummary s) async {
    double done = 0;
    var failed = false;
    await _run(() async {
      try {
        done = await ShopRentRepository.instance.applyAdvance(s.shop.id);
      } catch (_) {
        failed = true;
        rethrow;
      }
    });
    if (mounted && !failed) {
      _toast(done > 0
          ? '${Loc.t('Deducted from advance', 'ایڈوانس سے کٹا')}: ${_rs(done)}'
          : Loc.t('Nothing to deduct', 'کاٹنے کے لیے کچھ نہیں'));
    }
  }

  Future<void> _changeRentDialog(ShopRentSummary s) async {
    final p = ThemeManager.palette;
    final rent = TextEditingController(text: s.currentRent.round().toString());
    final pct = TextEditingController();
    var nextMonth = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text('${Loc.t('Change Rent', 'کرایہ بدلیں')} • ${s.shop.shopName}'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${Loc.t('Current rent', 'موجودہ کرایہ')}: ${_rs(s.currentRent)}  (${Loc.t('since', 'سے')} ${s.lastTermYm})',
                  style: TextStyle(fontSize: 12.5, color: p.textMuted)),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: _numField(p, pct, Loc.t('Increase %', 'اضافہ %'))),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: () {
                    final v = double.tryParse(pct.text.trim());
                    if (v != null) setD(() => rent.text = increaseByPercent(s.currentRent, v).round().toString());
                  },
                  child: Text(Loc.t('Apply', 'لگائیں')),
                ),
              ]),
              const SizedBox(height: 10),
              _numField(p, rent, Loc.t('New monthly rent', 'نیا ماہانہ کرایہ')),
              const SizedBox(height: 10),
              Wrap(spacing: 8, children: [
                ChoiceChip(
                    label: Text(Loc.t('From this month', 'اس مہینے سے')), selected: !nextMonth, onSelected: (_) => setD(() => nextMonth = false)),
                ChoiceChip(
                    label: Text(Loc.t('From next month', 'اگلے مہینے سے')), selected: nextMonth, onSelected: (_) => setD(() => nextMonth = true)),
              ]),
              const SizedBox(height: 6),
              Text(Loc.t('Past months stay as they were.', 'پچھلے مہینے ویسے ہی رہیں گے۔'),
                  style: TextStyle(fontSize: 12, color: p.textMuted)),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(Loc.t('Cancel', 'منسوخ'))),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(Loc.t('Save', 'محفوظ کریں'))),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final v = double.tryParse(rent.text.trim()) ?? 0;
    final from = ymOf(DateTime.now());
    await _run(() async {
      await ShopRentRepository.instance.changeRent(s.shop.id, fromYm: nextMonth ? addMonths(from, 1) : from, newRent: v);
    }, ok: Loc.t('Rent changed', 'کرایہ بدل گیا'));
  }

  Future<void> _waiveDialog(ShopRentSummary s) async {
    final ym = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(Loc.t('Waive which month?', 'کون سا مہینہ معاف کریں؟')),
        children: [
          for (final d in s.dues)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, d.ym),
              child: Text('${DateFormat('MMMM yyyy').format(ymToDate(d.ym))}  •  ${_rs(d.due)}'),
            ),
        ],
      ),
    );
    if (ym == null) return;
    await _run(() => ShopRentRepository.instance.waiveMonth(s.shop.id, ym), ok: Loc.t('Month waived', 'مہینہ معاف'));
  }

  Future<void> _deleteShop(ShopRentSummary s) async {
    if (!await _confirm(Loc.t('Delete Shop', 'دکان حذف کریں'),
        Loc.t('Delete "${s.shop.shopName}"? This works only if no payment/advance was recorded; otherwise use Close Shop.',
            'کیا "${s.shop.shopName}" حذف کریں؟ یہ صرف تب ہوگا جب کوئی ادائیگی/ایڈوانس نہ ہو، ورنہ "دکان بند" استعمال کریں۔'))) {
      return;
    }
    await _run(() => ShopRentRepository.instance.deleteShop(s.shop.id), ok: Loc.t('Deleted', 'حذف ہو گیا'));
  }

  // ------------------------------------------------------------ sheets

  String _kindLabel(String k) {
    switch (k) {
      case 'charge':
        return Loc.t('Rent due', 'کرایہ واجب');
      case 'payment':
        return Loc.t('Rent paid', 'کرایہ ادا');
      case 'advance':
        return Loc.t('Advance given', 'ایڈوانس دیا');
      case 'applied':
        return Loc.t('Cut from advance', 'ایڈوانس سے کٹا');
    }
    return k;
  }

  Future<void> _historySheet(ShopRentSummary s) async {
    final p = ThemeManager.palette;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: p.cardWhite,
      builder: (ctx) => _HistorySheet(summary: s, kindLabel: _kindLabel, rs: _rs),
    );
    await _load();
  }

  Future<void> _reportSheet() async {
    final p = ThemeManager.palette;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: p.cardWhite,
      builder: (ctx) => _ReportSheet(rs: _rs),
    );
  }
}

class _HistorySheet extends StatefulWidget {
  final ShopRentSummary summary;
  final String Function(String) kindLabel;
  final String Function(double) rs;
  const _HistorySheet({required this.summary, required this.kindLabel, required this.rs});

  @override
  State<_HistorySheet> createState() => _HistorySheetState();
}

class _HistorySheetState extends State<_HistorySheet> {
  List<RentLedgerEntry> _rows = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final rows = await ShopRentRepository.instance.history(widget.summary.shop.id);
    if (!mounted) return;
    setState(() {
      _rows = rows;
      _loading = false;
    });
  }

  Future<void> _delete(RentLedgerEntry e) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(Loc.t('Remove entry', 'اندراج حذف کریں')),
        content: Text(Loc.t('This also removes its Expense / Cash entry. Continue?', 'اس کا خرچہ/کیش اندراج بھی ہٹ جائے گا۔ جاری رکھیں؟')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(Loc.t('Cancel', 'منسوخ'))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(Loc.t('Remove', 'حذف کریں'))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ShopRentRepository.instance.deleteEntry(e.id);
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err is StateError ? err.message : err.toString())));
      }
    }
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final p = ThemeManager.palette;
    final df = DateFormat('dd MMM yyyy');
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.8),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${Loc.t('History', 'ہسٹری')} • ${widget.summary.shop.shopName}',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: p.textDark)),
            const SizedBox(height: 10),
            if (_loading)
              const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
            else if (_rows.isEmpty)
              Padding(padding: const EdgeInsets.all(16), child: Text(Loc.t('No entries', 'کوئی اندراج نہیں'), style: TextStyle(color: p.textMuted)))
            else
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: _rows.length,
                  separatorBuilder: (_, __) => Divider(height: 1, color: p.border),
                  itemBuilder: (ctx, i) {
                    final e = _rows[i];
                    final isOut = e.kind == 'payment' || e.kind == 'advance';
                    final color = e.kind == 'charge' ? p.red : (isOut ? p.teal : p.amber);
                    return ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        '${widget.kindLabel(e.kind)}${e.ym.isEmpty ? '' : '  •  ${DateFormat('MMM yyyy').format(ymToDate(e.ym))}'}',
                        style: TextStyle(fontWeight: FontWeight.w600, color: p.textDark),
                      ),
                      subtitle: Text(
                        '${df.format(DateTime.fromMillisecondsSinceEpoch(e.createdAt))}'
                        '${e.kind == 'charge' ? '' : '  •  ${e.method.toUpperCase()}'}'
                        '${e.note.isEmpty ? '' : '  •  ${e.note}'}',
                        style: TextStyle(fontSize: 11.5, color: p.textMuted),
                      ),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        Text(widget.rs(e.amount), style: TextStyle(fontWeight: FontWeight.bold, color: color)),
                        if (e.kind != 'charge')
                          IconButton(
                            icon: Icon(Icons.delete_outline, size: 18, color: p.red),
                            onPressed: () => _delete(e),
                          ),
                      ]),
                    );
                  },
                ),
              ),
          ]),
        ),
      ),
    );
  }
}

class _ReportSheet extends StatefulWidget {
  final String Function(double) rs;
  const _ReportSheet({required this.rs});

  @override
  State<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends State<_ReportSheet> {
  String _ym = ymOf(DateTime.now());
  List<MonthReportRow> _rows = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    final rows = await ShopRentRepository.instance.monthReport(_ym);
    if (!mounted) return;
    setState(() {
      _rows = rows;
      _loading = false;
    });
  }

  void _move(int n) {
    _ym = addMonths(_ym, n);
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final p = ThemeManager.palette;
    final rent = _rows.fold<double>(0, (a, r) => a + r.rent);
    final paid = _rows.fold<double>(0, (a, r) => a + r.paid);
    final due = _rows.fold<double>(0, (a, r) => a + r.due);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.8),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              IconButton(icon: const Icon(Icons.chevron_left), onPressed: () => _move(-1)),
              Expanded(
                child: Text(DateFormat('MMMM yyyy').format(ymToDate(_ym)),
                    textAlign: TextAlign.center, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: p.textDark)),
              ),
              IconButton(icon: const Icon(Icons.chevron_right), onPressed: () => _move(1)),
            ]),
            const SizedBox(height: 6),
            if (_loading)
              const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
            else if (_rows.isEmpty)
              Padding(padding: const EdgeInsets.all(16), child: Text(Loc.t('No rent for this month', 'اس مہینے کا کوئی کرایہ نہیں'), style: TextStyle(color: p.textMuted)))
            else ...[
              Flexible(
                child: ListView(shrinkWrap: true, children: [
                  for (final r in _rows)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(r.shop.displayName, style: TextStyle(fontWeight: FontWeight.w600, color: p.textDark)),
                      subtitle: Text('${Loc.t('Rent', 'کرایہ')} ${widget.rs(r.rent)}  •  ${Loc.t('Paid', 'ادا')} ${widget.rs(r.paid)}',
                          style: TextStyle(fontSize: 11.5, color: p.textMuted)),
                      trailing: Text(r.due > 0 ? widget.rs(r.due) : Loc.t('Paid', 'ادا'),
                          style: TextStyle(fontWeight: FontWeight.bold, color: r.due > 0 ? p.red : p.teal)),
                    ),
                ]),
              ),
              Divider(color: p.border),
              Row(children: [
                Expanded(child: Text(Loc.t('Total', 'کل'), style: TextStyle(fontWeight: FontWeight.bold, color: p.textDark))),
                Text('${widget.rs(rent)}  /  ${widget.rs(paid)}  /  ${widget.rs(due)}',
                    style: TextStyle(fontWeight: FontWeight.bold, color: p.textDark, fontSize: 12.5)),
              ]),
              const SizedBox(height: 4),
              Text(Loc.t('Rent / Paid / Due', 'کرایہ / ادا / باقی'), style: TextStyle(fontSize: 11, color: p.textMuted)),
            ],
          ]),
        ),
      ),
    );
  }
}
