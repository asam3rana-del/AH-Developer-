import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../db/due_reminders_repository.dart';
import '../db/party_repository.dart' show SavePartyResult;
import '../theme/theme_manager.dart';
import '../utils/loc.dart';
import '../widgets/premium_header.dart';
import '../widgets/role_guard.dart';

/// Dashboard ki "Amanat / Loan" screen.
///
/// Sab Amanat (customer ne paisa rakhwaya) aur Loan (dukaan ne udhar diya) wali parties ek jagah:
/// balance aur wapsi ki tarikh. Sync sirf dashboard header ke Sync button se.
/// Sab kaam yahin: "Add" (maujooda customer ko Amanat/Loan banao ya nayi party), card par tap = tarikh,
/// card ka menu = Amanat/Loan se hatao ya party delete.
///
/// Role: admin + manager (Due Reminders jaisa).
class AmanatLoanScreen extends StatelessWidget {
  const AmanatLoanScreen({super.key});

  @override
  Widget build(BuildContext context) => const RoleGuard(allowed: {'admin', 'manager'}, child: _Body());
}

class _Body extends StatefulWidget {
  const _Body();

  @override
  State<_Body> createState() => _BodyState();
}

class _BodyState extends State<_Body> with WidgetsBindingObserver {
  final _repo = DueRemindersRepository.instance;
  final _dateFmt = DateFormat('d MMM yyyy');

  bool _loading = true;
  int _filter = 0; // 0 = sab, 1 = Amanat, 2 = Loan
  List<ReturnReminder> _all = const [];

  AppPalette get _p => ThemeManager.palette;

  String _rs(double v) => 'Rs ${v.round()}';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load(showSpinner: false);
  }

  Future<void> _load({bool showSpinner = true}) async {
    if (showSpinner) setState(() => _loading = true);
    try {
      final list = await _repo.returnReminders();
      if (!mounted) return;
      setState(() {
        _all = list;
      });
    } catch (_) {
      if (mounted) _toast(Loc.t('Could not load the list', 'فہرست لوڈ نہیں ہو سکی'));
    } finally {
      // Ghalti par bhi spinner na atke (pehle list khali dikhti, spinner chalta rehta).
      if (mounted && _loading) setState(() => _loading = false);
    }
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _pickReturnDate(ReturnReminder r) async {
    final initial = r.returnDate > 0 ? DateTime.fromMillisecondsSinceEpoch(r.returnDate) : DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null || !mounted) return;
    final ok = await _repo.setReturnDate(
      partyId: r.partyId,
      returnDateMillis: DateTime(picked.year, picked.month, picked.day).millisecondsSinceEpoch,
    );
    if (!mounted) return;
    if (!ok) _toast(Loc.t('This party no longer exists', 'یہ پارٹی اب موجود نہیں'));
    await _load(showSpinner: false);
  }

  Future<void> _whatsApp(ReturnReminder r) async {
    try {
      final ok = await launchUrl(returnWhatsAppUri(r), mode: LaunchMode.externalApplication);
      if (!ok) throw Exception('launch failed');
    } catch (_) {
      if (mounted) _toast('WhatsApp nahi khul saka. Installed hai?');
    }
  }

  Future<void> _call(ReturnReminder r) async {
    try {
      final ok = await launchUrl(Uri(scheme: 'tel', path: r.partyPhone.trim()));
      if (!ok) throw Exception('launch failed');
    } catch (_) {
      if (mounted) _toast(Loc.t('Could not open the dialer', 'ڈائلر نہیں کھل سکا'));
    }
  }

  Future<void> _add() async {
    final res = await showModalBottomSheet<_AddResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _p.cardWhite,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (_) => _AddSheet(repo: _repo),
    );
    if (res == null || !mounted) return;
    if (res.existingId != null) {
      final ok = await _repo.tagParty(
          partyId: res.existingId!, kind: res.kind, returnDateMillis: res.returnDate, amount: res.openingBalance);
      if (!ok && mounted) _toast(Loc.t('This party no longer exists', 'یہ پارٹی اب موجود نہیں'));
    } else {
      final r = await _repo.addNewReturnParty(
        name: res.name,
        phone: res.phone,
        kind: res.kind,
        returnDateMillis: res.returnDate,
        openingBalance: res.openingBalance,
      );
      if (r == SavePartyResult.nameRequired && mounted) _toast(Loc.t('Name is required', 'نام ضروری ہے'));
    }
    if (mounted) await _load(showSpinner: false);
  }

  Future<void> _edit(ReturnReminder r) async {
    final res = await showModalBottomSheet<_AddResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _p.cardWhite,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (_) => _AddSheet(repo: _repo, initial: r),
    );
    if (res == null || !mounted) return;
    final out = await _repo.editReturnParty(
      partyId: r.partyId,
      name: res.name,
      phone: res.phone,
      kind: res.kind,
      returnDateMillis: res.returnDate,
    );
    if (out == SavePartyResult.nameRequired && mounted) _toast(Loc.t('Name is required', 'نام ضروری ہے'));
    if (mounted) await _load(showSpinner: false);
  }

  Future<bool> _confirm(String title, String body, String yes) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(Loc.t('Cancel', 'منسوخ'))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(yes)),
        ],
      ),
    );
    return r == true;
  }

  Future<void> _remove(ReturnReminder r) async {
    final yes = await _confirm(
      Loc.t('Remove from Amanat / Loan?', 'امانت / قرض سے ہٹائیں؟'),
      Loc.t('${r.partyName} will become a normal customer. Ledger and bills stay as they are.',
          '${r.partyName} عام کسٹمر بن جائے گا۔ کھاتہ اور بل جیسے ہیں ویسے رہیں گے۔'),
      Loc.t('Remove', 'ہٹائیں'),
    );
    if (!yes) return;
    await _repo.clearReturnTag(r.partyId);
    if (mounted) await _load(showSpinner: false);
  }

  Future<void> _delete(ReturnReminder r) async {
    final yes = await _confirm(
      Loc.t('Delete this party?', 'یہ پارٹی ڈیلیٹ کریں؟'),
      Loc.t('${r.partyName} will be deleted from this device and from synced devices. Old bills stay in history by name.',
          '${r.partyName} اس ڈیوائس اور سنک شدہ ڈیوائسز سے ڈیلیٹ ہو جائے گا۔ پرانے بل نام کے ساتھ ہسٹری میں رہیں گے۔'),
      Loc.t('Delete', 'ڈیلیٹ'),
    );
    if (!yes) return;
    await _repo.deleteReturnParty(r.partyId);
    if (mounted) await _load(showSpinner: false);
  }

  List<ReturnReminder> get _shown => switch (_filter) {
        1 => _all.where((r) => r.isAmanat).toList(),
        2 => _all.where((r) => !r.isAmanat).toList(),
        _ => _all,
      };

  @override
  Widget build(BuildContext context) {
    final amanat = _all.where((r) => r.isAmanat).toList();
    final loans = _all.where((r) => !r.isAmanat).toList();
    final amanatTotal = amanat.fold<double>(0, (a, r) => a + r.closing);
    final loanTotal = loans.fold<double>(0, (a, r) => a + r.closing);
    final list = _shown;

    return Scaffold(
      backgroundColor: _p.bg,
      appBar: AppBar(backgroundColor: _p.navy, foregroundColor: Colors.white, elevation: 0),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        backgroundColor: _p.flatPurpleFg,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: Text(Loc.t('Add', 'شامل کریں')),
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: () => _load(showSpinner: false),
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 100),
                  children: [
                    PremiumHeader(
                      title: Loc.t('Amanat / Loan', 'امانت / قرض'),
                      subtitle: Loc.t('All Amanat & Loan parties', 'تمام امانت اور قرض پارٹیاں'),
                    ),
                    const SizedBox(height: 10),
                    Row(children: [
                      Expanded(child: _totalCard(Loc.t('Amanat', 'امانت'), '${amanat.length}', _rs(amanatTotal), _p.flatTealFg)),
                      const SizedBox(width: 10),
                      Expanded(child: _totalCard(Loc.t('Loan', 'قرض'), '${loans.length}', _rs(loanTotal), _p.flatAmberFg)),
                    ]),
                    const SizedBox(height: 14),
                    _filterTabs(),
                    if (list.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 16),
                        child: Text(
                          Loc.t(
                              'No Amanat or Loan parties yet.\nTap "Add" to create one.',
                              'ابھی کوئی امانت یا قرض پارٹی نہیں۔\n"شامل کریں" دبائیں۔'),
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 13, color: _p.textMuted),
                        ),
                      )
                    else
                      for (final r in list) _card(r),
                  ],
                ),
              ),
      ),
    );
  }

  BoxDecoration _cardDeco() => BoxDecoration(
        color: _p.cardWhite,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _p.border),
      );

  Widget _totalCard(String label, String count, String total, Color accent) => Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: _cardDeco(),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('$label ($count)', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: _p.textMuted)),
          const SizedBox(height: 3),
          Text(total, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: accent)),
        ]),
      );

  Widget _filterTabs() {
    Widget pill(String label, int v) {
      final sel = _filter == v;
      return Expanded(
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => setState(() => _filter = v),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 12),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: sel ? _p.flatPurpleFg : _p.cardWhite,
              borderRadius: BorderRadius.circular(14),
              border: sel ? null : Border.all(color: _p.border),
            ),
            child: Text(label,
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: sel ? Colors.white : _p.textMuted)),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(children: [
        pill(Loc.t('All', 'سب'), 0),
        const SizedBox(width: 8),
        pill(Loc.t('Amanat', 'امانت'), 1),
        const SizedBox(width: 8),
        pill(Loc.t('Loan', 'قرض'), 2),
      ]),
    );
  }

  Widget _circleButton(IconData icon, Color bg, Color fg, VoidCallback onTap) => Material(
        color: bg,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(width: 38, height: 38, child: Icon(icon, size: 18, color: fg)),
        ),
      );

  Widget _card(ReturnReminder r) {
    final hasPhone = r.partyPhone.trim().isNotEmpty;
    final overdue = r.returnDate > 0 && r.returnDate < DateTime.now().millisecondsSinceEpoch - 86400000;
    final kindLabel = r.isAmanat
        ? Loc.t('Amanat — return to customer', 'امانت — کسٹمر کو واپس کرنی ہے')
        : Loc.t('Loan — collect from customer', 'قرض — کسٹمر سے وصول کرنا ہے');
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: _cardDeco(),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => _pickReturnDate(r),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(r.partyName, style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold, color: _p.textDark)),
                  const SizedBox(height: 2),
                  Text(kindLabel, style: TextStyle(fontSize: 11.5, color: _p.textMuted)),
                ]),
              ),
              PopupMenuButton<String>(
                padding: EdgeInsets.zero,
                icon: Icon(Icons.more_vert, size: 20, color: _p.textMuted),
                onSelected: (v) => v == 'edit' ? _edit(r) : v == 'remove' ? _remove(r) : _delete(r),
                itemBuilder: (_) => [
                  PopupMenuItem(value: 'edit', child: Text(Loc.t('Edit', 'ایڈٹ'))),
                  PopupMenuItem(value: 'remove', child: Text(Loc.t('Remove from Amanat / Loan', 'امانت / قرض سے ہٹائیں'))),
                  PopupMenuItem(value: 'delete', child: Text(Loc.t('Delete party', 'پارٹی ڈیلیٹ کریں'), style: TextStyle(color: _p.red))),
                ],
              ),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${Loc.t('Balance', 'بیلنس')}: ${_rs(r.closing)}',
                      style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: _p.flatPurpleFg)),
                  const SizedBox(height: 2),
                  Text(
                    r.returnDate > 0
                        ? '${Loc.t('Return: ', 'واپسی: ')}${_dateFmt.format(DateTime.fromMillisecondsSinceEpoch(r.returnDate))}'
                        : Loc.t('Tap to set a return date', 'تاریخ طے کرنے کے لیے دبائیں'),
                    style: TextStyle(fontSize: 11.5, color: overdue ? _p.red : _p.textMuted, fontWeight: overdue ? FontWeight.bold : null),
                  ),
                ]),
              ),
              if (hasPhone) ...[
                _circleButton(Icons.send, const Color(0xFF25D366), const Color(0xFFDDF6E8), () => _whatsApp(r)),
                const SizedBox(width: 10),
                _circleButton(Icons.phone, _p.flatPurpleFg, _p.flatPurpleBg, () => _call(r)),
              ],
            ]),
          ]),
        ),
      ),
    );
  }
}


class _AddResult {
  final String kind;
  final int? existingId; // null => nayi party
  final String name, phone;
  final double openingBalance;
  final int returnDate;
  const _AddResult({
    required this.kind,
    this.existingId,
    this.name = '',
    this.phone = '',
    this.openingBalance = 0,
    this.returnDate = 0,
  });
}

class _AddSheet extends StatefulWidget {
  final DueRemindersRepository repo;
  final ReturnReminder? initial; // null => naya add; warna Edit
  const _AddSheet({required this.repo, this.initial});

  @override
  State<_AddSheet> createState() => _AddSheetState();
}

class _AddSheetState extends State<_AddSheet> {
  String _kind = 'amanat';
  bool _existing = true;
  ({int id, String name, String phone})? _picked;
  DateTime? _date;
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _amount = TextEditingController();
  String? _error;

  AppPalette get _p => ThemeManager.palette;
  final _dateFmt = DateFormat('d MMM yyyy');

  bool get _editing => widget.initial != null;

  @override
  void initState() {
    super.initState();
    final r = widget.initial;
    if (r != null) {
      _kind = r.kind == 'loan' ? 'loan' : 'amanat';
      _existing = false;
      _name.text = r.partyName;
      _phone.text = r.partyPhone;
      if (r.returnDate > 0) _date = DateTime.fromMillisecondsSinceEpoch(r.returnDate);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _amount.dispose();
    super.dispose();
  }

  Widget _seg(List<(String, bool, VoidCallback)> items) => Row(children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: items[i].$3,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 11),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: items[i].$2 ? _p.flatPurpleFg : _p.bg,
                  borderRadius: BorderRadius.circular(12),
                  border: items[i].$2 ? null : Border.all(color: _p.border),
                ),
                child: Text(items[i].$1,
                    style: TextStyle(
                        fontSize: 13, fontWeight: FontWeight.bold, color: items[i].$2 ? Colors.white : _p.textMuted)),
              ),
            ),
          ),
        ],
      ]);

  Future<void> _pickCustomer() async {
    final all = await widget.repo.normalCustomers();
    if (!mounted) return;
    final res = await showDialog<({int id, String name, String phone})>(
      context: context,
      builder: (ctx) {
        var q = '';
        return StatefulBuilder(builder: (ctx, setD) {
          final list = all.where((c) => c.name.toLowerCase().contains(q.toLowerCase()) || c.phone.contains(q)).toList();
          return AlertDialog(
            title: Text(Loc.t('Select customer', 'کسٹمر چنیں')),
            content: SizedBox(
              width: double.maxFinite,
              height: 360,
              child: Column(children: [
                TextField(
                  autofocus: true,
                  decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: Loc.t('Search', 'تلاش')),
                  onChanged: (v) => setD(() => q = v),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: list.isEmpty
                      ? Center(child: Text(Loc.t('No customers', 'کوئی کسٹمر نہیں')))
                      : ListView.builder(
                          itemCount: list.length,
                          itemBuilder: (_, i) => ListTile(
                            dense: true,
                            title: Text(list[i].name),
                            subtitle: list[i].phone.isEmpty ? null : Text(list[i].phone),
                            onTap: () => Navigator.pop(ctx, list[i]),
                          ),
                        ),
                ),
              ]),
            ),
          );
        });
      },
    );
    if (res != null) setState(() => _picked = res);
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _date ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (d != null) setState(() => _date = d);
  }

  void _save() {
    if (!_editing && _existing && _picked == null) {
      setState(() => _error = Loc.t('Select a customer', 'کسٹمر چنیں'));
      return;
    }
    if (!_existing && _name.text.trim().isEmpty) {
      setState(() => _error = Loc.t('Name is required', 'نام ضروری ہے'));
      return;
    }
    final d = _date;
    final amount = (double.tryParse(_amount.text.trim()) ?? 0).abs();
    Navigator.pop(
      context,
      _AddResult(
        kind: _kind,
        existingId: _editing ? widget.initial!.partyId : (_existing ? _picked!.id : null),
        name: _name.text,
        phone: _phone.text,
        openingBalance: _kind == 'amanat' && amount > 0 ? -amount : amount,
        returnDate: d == null ? 0 : DateTime(d.year, d.month, d.day).millisecondsSinceEpoch,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(18, 16, 18, 18 + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_editing ? Loc.t('Edit Amanat / Loan', 'امانت / قرض ایڈٹ کریں') : Loc.t('Add Amanat / Loan', 'امانت / قرض شامل کریں'),
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: _p.textDark)),
          const SizedBox(height: 14),
          _seg([
            (Loc.t('Amanat', 'امانت'), _kind == 'amanat', () => setState(() => _kind = 'amanat')),
            (Loc.t('Loan', 'قرض'), _kind == 'loan', () => setState(() => _kind = 'loan')),
          ]),
          const SizedBox(height: 10),
          if (!_editing) ...[
            _seg([
              (Loc.t('Existing customer', 'موجودہ کسٹمر'), _existing, () => setState(() => _existing = true)),
              (Loc.t('New party', 'نئی پارٹی'), !_existing, () => setState(() => _existing = false)),
            ]),
            const SizedBox(height: 12),
          ],
          if (_existing)
            OutlinedButton.icon(
              onPressed: _pickCustomer,
              icon: const Icon(Icons.person_search),
              label: Text(_picked?.name ?? Loc.t('Select customer', 'کسٹمر چنیں')),
            )
          else ...[
            TextField(controller: _name, decoration: InputDecoration(labelText: Loc.t('Name', 'نام'))),
            TextField(
                controller: _phone,
                keyboardType: TextInputType.phone,
                decoration: InputDecoration(labelText: Loc.t('Phone (optional)', 'فون (اختیاری)'))),
          ],
          if (!_editing)
            TextField(
              controller: _amount,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: Loc.t('Amount', 'رقم'),
                prefixText: 'Rs ',
                // Customer balance: + = customer ne dena hai, - = dukaan ne dena hai. Amanat dukaan ki
                // zimmedari hai, is liye amount khud minus mein jama hota hai (keypad par '-' nahi hota).
                helperText: _kind == 'amanat'
                    ? Loc.t('Amount the shop holds for the customer (saved as minus: shop owes it)',
                        'دکان کے پاس رکھی گاہک کی رقم (مائنس میں جمع ہوگی: دکان نے دینی ہے)')
                    : Loc.t('Amount lent to the customer (saved as plus: customer owes it)',
                        'گاہک کو دی گئی رقم (پلس میں جمع ہوگی: گاہک نے دینی ہے)'),
                helperMaxLines: 2,
              ),
            ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _pickDate,
            icon: const Icon(Icons.event),
            label: Text(_date == null
                ? Loc.t('Return date (optional)', 'واپسی کی تاریخ (اختیاری)')
                : '${Loc.t('Return: ', 'واپسی: ')}${_dateFmt.format(_date!)}'),
          ),
          if (_error != null)
            Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: TextStyle(color: _p.red, fontSize: 12.5))),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton(onPressed: _save, child: Text(Loc.t('Save', 'محفوظ کریں'))),
          ),
        ]),
      ),
    );
  }
}
