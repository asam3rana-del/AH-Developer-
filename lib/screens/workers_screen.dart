import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../db/worker_repository.dart';
import '../theme/theme_manager.dart';
import '../utils/loc.dart';

/// Workers: profile, roz ki hazri/chhutti, advance aur mahine ki salary.
/// Sirf Admin/Manager (Settings mein row aur RoleGuard dono).

String _plain(double v) => v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(2);
String _rs(double v) => 'Rs ${_plain(v)}';

void _toast(BuildContext c, String m) => ScaffoldMessenger.of(c)
  ..hideCurrentSnackBar()
  ..showSnackBar(SnackBar(content: Text(m)));

String _err(Object e) {
  if (e is StateError) return e.message;
  if (e is ArgumentError) return '${e.message}';
  return e.toString();
}

BoxDecoration _card(AppPalette p, [double r = 16]) => BoxDecoration(
      color: p.cardWhite,
      borderRadius: BorderRadius.circular(r),
      boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 8, offset: const Offset(0, 3))],
    );

InputDecoration _deco(AppPalette p, String hint) => InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(color: p.textMuted),
      filled: true,
      fillColor: p.fieldFill,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: p.border)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: p.teal)),
    );

Widget _header(BuildContext context, AppPalette p, String title, String subtitle, {List<Widget> actions = const []}) {
  return Container(
    color: p.navy,
    padding: EdgeInsets.fromLTRB(8, MediaQuery.of(context).padding.top + 10, 8, 14),
    child: Row(children: [
      IconButton(icon: const Icon(Icons.arrow_back, color: Colors.white), onPressed: () => Navigator.of(context).maybePop()),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 18.5, fontWeight: FontWeight.bold)),
          Text(subtitle, style: TextStyle(color: p.headerSubtitleColor, fontSize: 11)),
        ]),
      ),
      ...actions,
    ]),
  );
}

Widget _methodPicker(AppPalette p, String value, ValueChanged<String> onChanged) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    decoration: BoxDecoration(color: p.fieldFill, borderRadius: BorderRadius.circular(14), border: Border.all(color: p.border)),
    child: DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        value: value,
        isExpanded: true,
        dropdownColor: p.cardWhite,
        style: TextStyle(fontSize: 15, color: p.textDark),
        items: [
          DropdownMenuItem(value: 'cash', child: Text(Loc.t('Cash', 'کیش'))),
          DropdownMenuItem(value: 'bank', child: Text(Loc.t('Bank', 'بینک'))),
        ],
        onChanged: (v) {
          if (v != null) onChanged(v);
        },
      ),
    ),
  );
}

String _typeLabel(Worker w) => w.isDaily
    ? '${Loc.t('Daily', 'روزانہ')} • ${_rs(w.rate)}/${Loc.t('day', 'دن')}'
    : '${Loc.t('Monthly', 'ماہانہ')} • ${_rs(w.rate)}/${Loc.t('month', 'ماہ')}';

// ===================================================================== list

class WorkersScreen extends StatefulWidget {
  const WorkersScreen({super.key});

  @override
  State<WorkersScreen> createState() => _WorkersScreenState();
}

class _WorkersScreenState extends State<WorkersScreen> {
  List<Worker> _workers = const [];
  Map<int, double> _adv = const {};
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final list = await WorkerRepository.instance.list();
    final adv = await WorkerRepository.instance.allAdvanceBalances();
    if (!mounted) return;
    setState(() {
      _workers = list;
      _adv = adv;
      _loaded = true;
    });
  }

  Future<void> _addWorker() async {
    final w = await showDialog<Worker>(context: context, builder: (_) => const _WorkerForm());
    if (w == null) return;
    try {
      await WorkerRepository.instance.save(w);
      await _reload();
    } catch (e) {
      if (mounted) _toast(context, _err(e));
    }
  }

  Future<void> _open(Worker w) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => WorkerDetailScreen(worker: w)));
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final p = ThemeManager.palette;
    final totalAdv = _adv.values.fold<double>(0, (a, b) => a + b);
    return Scaffold(
      backgroundColor: p.bg,
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: p.teal,
        foregroundColor: Colors.white,
        onPressed: _addWorker,
        icon: const Icon(Icons.person_add_alt_1),
        label: Text(Loc.t('Add Worker', 'ورکر شامل کریں')),
      ),
      body: Column(children: [
        _header(context, p, Loc.t('Workers', 'ورکرز'), Loc.t('Salary, advance and leave record', 'تنخواہ، ایڈوانس اور چھٹی کا ریکارڈ')),
        Expanded(
          child: !_loaded
              ? const Center(child: CircularProgressIndicator())
              : _workers.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(Loc.t('No workers yet. Tap "Add Worker".', 'ابھی کوئی ورکر نہیں۔ "ورکر شامل کریں" دبائیں۔'),
                            textAlign: TextAlign.center, style: TextStyle(color: p.textMuted)),
                      ),
                    )
                  : ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 96), children: [
                      if (totalAdv > 0)
                        Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          padding: const EdgeInsets.all(16),
                          decoration: _card(p, 18),
                          child: Row(children: [
                            Icon(Icons.payments_outlined, color: p.amber),
                            const SizedBox(width: 10),
                            Expanded(
                                child: Text(Loc.t('Total advance outstanding', 'کل باقی ایڈوانس'),
                                    style: TextStyle(color: p.textMuted, fontWeight: FontWeight.bold))),
                            Text(_rs(totalAdv), style: TextStyle(color: p.textDark, fontWeight: FontWeight.bold, fontSize: 16)),
                          ]),
                        ),
                      for (final w in _workers) _workerTile(p, w),
                    ]),
        ),
      ]),
    );
  }

  Widget _workerTile(AppPalette p, Worker w) {
    final adv = _adv[w.id] ?? 0;
    return Opacity(
      opacity: w.active ? 1 : 0.55,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _open(w),
        child: Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(16),
          decoration: _card(p),
          child: Row(children: [
            CircleAvatar(
              backgroundColor: p.teal.withOpacity(0.15),
              child: Text(w.name.isEmpty ? '?' : String.fromCharCode(w.name.runes.first).toUpperCase(),
                  style: TextStyle(color: p.teal, fontWeight: FontWeight.bold)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(w.name + (w.active ? '' : ' (${Loc.t('Left', 'فارغ')})'),
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: p.textDark)),
                const SizedBox(height: 3),
                Text(_typeLabel(w), style: TextStyle(fontSize: 12, color: p.textMuted)),
              ]),
            ),
            if (adv > 0)
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(Loc.t('Advance', 'ایڈوانس'), style: TextStyle(fontSize: 10.5, color: p.textMuted)),
                Text(_rs(adv), style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: p.amber)),
              ]),
            Icon(Icons.chevron_right, color: p.textMuted),
          ]),
        ),
      ),
    );
  }
}

// ============================================================ worker dialog

class _WorkerForm extends StatefulWidget {
  final Worker? worker;
  const _WorkerForm({this.worker});

  @override
  State<_WorkerForm> createState() => _WorkerFormState();
}

class _WorkerFormState extends State<_WorkerForm> {
  late final TextEditingController _name = TextEditingController(text: widget.worker?.name ?? '');
  late final TextEditingController _phone = TextEditingController(text: widget.worker?.phone ?? '');
  late final TextEditingController _rate =
      TextEditingController(text: widget.worker == null ? '' : _plain(widget.worker!.rate));
  late String _type = widget.worker?.payType ?? workerMonthly;
  late bool _active = widget.worker?.active ?? true;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _rate.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    final rate = double.tryParse(_rate.text.trim());
    if (name.isEmpty) {
      setState(() => _error = Loc.t('Enter the name', 'نام لکھیں'));
      return;
    }
    if (rate == null || !rate.isFinite || rate <= 0) {
      setState(() => _error = Loc.t('Enter a valid salary / daily rate', 'صحیح تنخواہ / روزانہ اجرت لکھیں'));
      return;
    }
    final old = widget.worker;
    Navigator.pop(
      context,
      Worker(
        id: old?.id,
        name: name,
        phone: _phone.text.trim(),
        payType: _type,
        rate: rate,
        active: _active,
        createdAt: old?.createdAt ?? 0,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = ThemeManager.palette;
    return AlertDialog(
      backgroundColor: p.cardWhite,
      title: Text(widget.worker == null ? Loc.t('New Worker', 'نیا ورکر') : Loc.t('Edit Worker', 'ورکر میں تبدیلی')),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(controller: _name, style: TextStyle(color: p.textDark), decoration: _deco(p, Loc.t('Name', 'نام'))),
          const SizedBox(height: 10),
          TextField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            style: TextStyle(color: p.textDark),
            decoration: _deco(p, Loc.t('Phone (optional)', 'فون (اختیاری)')),
          ),
          const SizedBox(height: 12),
          Wrap(spacing: 8, children: [
            ChoiceChip(
              label: Text(Loc.t('Monthly salary', 'ماہانہ تنخواہ')),
              selected: _type == workerMonthly,
              onSelected: (_) => setState(() => _type = workerMonthly),
            ),
            ChoiceChip(
              label: Text(Loc.t('Daily wage', 'روزانہ اجرت')),
              selected: _type == workerDaily,
              onSelected: (_) => setState(() => _type = workerDaily),
            ),
          ]),
          const SizedBox(height: 10),
          TextField(
            controller: _rate,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
            style: TextStyle(color: p.textDark),
            decoration: _deco(p, _type == workerDaily ? Loc.t('Rate per day', 'روزانہ کی اجرت') : Loc.t('Salary per month', 'ماہانہ تنخواہ')),
          ),
          if (widget.worker != null)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(Loc.t('Currently working', 'ابھی کام کر رہا ہے')),
              value: _active,
              onChanged: (v) => setState(() => _active = v),
            ),
          if (_error != null)
            Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: TextStyle(color: p.red, fontSize: 12.5))),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(Loc.t('Cancel', 'منسوخ'))),
        TextButton(onPressed: _submit, child: Text(Loc.t('Save', 'محفوظ کریں'))),
      ],
    );
  }
}

// ========================================================== advance dialog

class _AdvanceInput {
  final double amount;
  final String method;
  final String note;
  const _AdvanceInput(this.amount, this.method, this.note);
}

class _AdvanceForm extends StatefulWidget {
  const _AdvanceForm();

  @override
  State<_AdvanceForm> createState() => _AdvanceFormState();
}

class _AdvanceFormState extends State<_AdvanceForm> {
  final _amount = TextEditingController();
  final _note = TextEditingController();
  String _method = 'cash';
  String? _error;

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  void _submit() {
    final amt = double.tryParse(_amount.text.trim());
    if (amt == null || !amt.isFinite || amt <= 0) {
      setState(() => _error = Loc.t('Enter a valid amount', 'صحیح رقم لکھیں'));
      return;
    }
    Navigator.pop(context, _AdvanceInput(amt, _method, _note.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    final p = ThemeManager.palette;
    return AlertDialog(
      backgroundColor: p.cardWhite,
      title: Text(Loc.t('Give Advance', 'ایڈوانس دیں')),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: _amount,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
            style: TextStyle(color: p.textDark),
            decoration: _deco(p, Loc.t('Amount', 'رقم')),
          ),
          const SizedBox(height: 10),
          _methodPicker(p, _method, (v) => setState(() => _method = v)),
          const SizedBox(height: 10),
          TextField(controller: _note, style: TextStyle(color: p.textDark), decoration: _deco(p, Loc.t('Note (optional)', 'نوٹ (اختیاری)'))),
          if (_error != null)
            Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: TextStyle(color: p.red, fontSize: 12.5))),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(Loc.t('Cancel', 'منسوخ'))),
        TextButton(onPressed: _submit, child: Text(Loc.t('Give', 'دیں'))),
      ],
    );
  }
}

// ==================================================================== detail

class WorkerDetailScreen extends StatefulWidget {
  final Worker worker;
  const WorkerDetailScreen({super.key, required this.worker});

  @override
  State<WorkerDetailScreen> createState() => _WorkerDetailScreenState();
}

class _WorkerDetailScreenState extends State<WorkerDetailScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);
  late Worker _w = widget.worker;
  late int _year;
  late int _month;

  Map<int, String> _marks = const {};
  double _advBal = 0;
  List<WorkerAdvance> _advances = const [];
  List<WorkerSalaryPayment> _payments = const [];
  final _cut = TextEditingController();
  String _method = 'cash';
  bool _busy = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _year = now.year;
    _month = now.month;
    _reload();
  }

  @override
  void dispose() {
    _tabs.dispose();
    _cut.dispose();
    super.dispose();
  }

  EarnedResult _calc() => computeEarned(
        payType: _w.payType,
        rate: _w.rate,
        year: _year,
        month: _month,
        counts: attendanceCounts(_marks, _year, _month),
      );

  WorkerSalaryPayment? get _paid {
    final key = workerMonthKey(_year, _month);
    for (final x in _payments) {
      if (x.month == key) return x;
    }
    return null;
  }

  Future<void> _reload() async {
    final repo = WorkerRepository.instance;
    final id = _w.id!;
    final marks = await repo.monthAttendance(id, _year, _month);
    final bal = await repo.advanceBalance(id);
    final adv = await repo.advances(id);
    final pays = await repo.payments(id);
    if (!mounted) return;
    setState(() {
      _marks = marks;
      _advBal = bal;
      _advances = adv;
      _payments = pays;
      _loaded = true;
    });
    final earned = _calc().earned;
    final v = bal < earned ? bal : earned;
    _cut.text = v > 0 ? _plain(v) : '';
  }

  void _shift(int delta) {
    final d = DateTime(_year, _month + delta, 1);
    setState(() {
      _year = d.year;
      _month = d.month;
    });
    _reload();
  }

  Future<void> _edit() async {
    final w = await showDialog<Worker>(context: context, builder: (_) => _WorkerForm(worker: _w));
    if (w == null) return;
    try {
      await WorkerRepository.instance.save(w);
      setState(() => _w = w);
      await _reload();
    } catch (e) {
      if (mounted) _toast(context, _err(e));
    }
  }

  Future<void> _cycle(int day) async {
    const order = <String?>[null, 'P', 'A', 'H', 'L'];
    final next = order[(order.indexOf(_marks[day]) + 1) % order.length];
    try {
      await WorkerRepository.instance.setAttendance(_w.id!, DateTime(_year, _month, day), next);
      await _reload();
    } catch (e) {
      if (mounted) _toast(context, _err(e));
    }
  }

  Future<void> _markAllPresent() async {
    final now = DateTime.now();
    final monthEnd = DateTime(_year, _month, daysInMonth(_year, _month));
    final upTo = monthEnd.isBefore(now) ? monthEnd : now;
    try {
      await WorkerRepository.instance.markUnmarkedPresent(_w.id!, _year, _month, upTo: upTo);
      await _reload();
    } catch (e) {
      if (mounted) _toast(context, _err(e));
    }
  }

  Future<void> _giveAdvance() async {
    final input = await showDialog<_AdvanceInput>(context: context, builder: (_) => const _AdvanceForm());
    if (input == null) return;
    try {
      await WorkerRepository.instance.addAdvance(
        workerId: _w.id!,
        workerName: _w.name,
        amount: input.amount,
        method: input.method,
        note: input.note,
      );
      await _reload();
    } catch (e) {
      if (mounted) _toast(context, _err(e));
    }
  }

  Future<bool> _confirm(String title, String body, String yes) async {
    final ok = await showDialog<bool>(
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
    return ok == true;
  }

  Future<void> _deleteAdvance(WorkerAdvance a) async {
    if (!await _confirm(Loc.t('Delete advance', 'ایڈوانس حذف کریں'),
        Loc.t('Remove this advance and its cash entry?', 'یہ ایڈوانس اور اس کی کیش انٹری حذف کر دیں؟'), Loc.t('Delete', 'حذف کریں'))) {
      return;
    }
    try {
      await WorkerRepository.instance.deleteAdvance(a);
      await _reload();
    } catch (e) {
      if (mounted) _toast(context, _err(e));
    }
  }

  Future<void> _pay() async {
    if (_busy) return;
    final calc = _calc();
    final cut = double.tryParse(_cut.text.trim()) ?? 0;
    final net = calc.earned - cut;
    if (!await _confirm(
      Loc.t('Pay salary', 'تنخواہ دیں'),
      '${DateFormat('MMMM yyyy').format(DateTime(_year, _month))}\n'
      '${Loc.t('Earned', 'کمائی')}: ${_rs(calc.earned)}\n'
      '${Loc.t('Advance cut', 'ایڈوانس کٹوتی')}: ${_rs(cut)}\n'
      '${Loc.t('Pay now', 'ادا کریں')}: ${_rs(net)}',
      Loc.t('Pay', 'ادا کریں'),
    )) {
      return;
    }
    setState(() => _busy = true);
    try {
      await WorkerRepository.instance.paySalary(worker: _w, year: _year, month: _month, advanceCut: cut, method: _method);
      if (mounted) _toast(context, Loc.t('Salary paid', 'تنخواہ ادا ہو گئی'));
      await _reload();
    } catch (e) {
      if (mounted) _toast(context, _err(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _undoPayment(WorkerSalaryPayment pay) async {
    if (!await _confirm(
        Loc.t('Undo salary', 'تنخواہ واپس کریں'),
        Loc.t('This removes the salary expense and its cash entry; the advance comes back.',
            'اس سے تنخواہ کا خرچہ اور کیش انٹری ہٹ جائے گی اور ایڈوانس واپس باقی میں آ جائے گا۔'),
        Loc.t('Undo', 'واپس کریں'))) {
      return;
    }
    try {
      await WorkerRepository.instance.deletePayment(pay);
      await _reload();
    } catch (e) {
      if (mounted) _toast(context, _err(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = ThemeManager.palette;
    return Scaffold(
      backgroundColor: p.bg,
      body: Column(children: [
        _header(context, p, _w.name, _typeLabel(_w),
            actions: [IconButton(icon: const Icon(Icons.edit_outlined, color: Colors.white), onPressed: _edit)]),
        Container(
          color: p.cardWhite,
          child: Row(children: [
            IconButton(icon: Icon(Icons.chevron_left, color: p.textDark), onPressed: () => _shift(-1)),
            Expanded(
              child: Text(DateFormat('MMMM yyyy').format(DateTime(_year, _month)),
                  textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.bold, color: p.textDark)),
            ),
            IconButton(icon: Icon(Icons.chevron_right, color: p.textDark), onPressed: () => _shift(1)),
          ]),
        ),
        Container(
          color: p.cardWhite,
          child: TabBar(
            controller: _tabs,
            labelColor: p.teal,
            unselectedLabelColor: p.textMuted,
            indicatorColor: p.teal,
            tabs: [
              Tab(text: Loc.t('Attendance', 'حاضری')),
              Tab(text: Loc.t('Advance', 'ایڈوانس')),
              Tab(text: Loc.t('Salary', 'تنخواہ')),
            ],
          ),
        ),
        Expanded(
          child: !_loaded
              ? const Center(child: CircularProgressIndicator())
              : TabBarView(controller: _tabs, children: [_attendanceTab(p), _advanceTab(p), _salaryTab(p)]),
        ),
      ]),
    );
  }

  // ----------------------------------------------------------- hazri tab

  Color _statusColor(AppPalette p, String s) {
    switch (s) {
      case 'P':
        return p.teal;
      case 'A':
        return p.red;
      case 'H':
        return p.amber;
      default:
        return p.blue;
    }
  }

  Widget _attendanceTab(AppPalette p) {
    final counts = attendanceCounts(_marks, _year, _month);
    final locked = _paid != null;
    final first = DateTime(_year, _month, 1).weekday; // Mon=1
    final n = daysInMonth(_year, _month);
    final names = [
      Loc.t('Mon', 'پیر'),
      Loc.t('Tue', 'منگل'),
      Loc.t('Wed', 'بدھ'),
      Loc.t('Thu', 'جمعرات'),
      Loc.t('Fri', 'جمعہ'),
      Loc.t('Sat', 'ہفتہ'),
      Loc.t('Sun', 'اتوار'),
    ];
    return ListView(padding: const EdgeInsets.all(16), children: [
      Wrap(spacing: 8, runSpacing: 8, children: [
        _chip(p, 'P', Loc.t('Present', 'حاضر'), counts.present),
        _chip(p, 'A', Loc.t('Absent', 'غیر حاضر'), counts.absent),
        _chip(p, 'H', Loc.t('Half day', 'آدھا دن'), counts.half),
        _chip(p, 'L', Loc.t('Paid leave', 'پیڈ چھٹی'), counts.paidLeave),
      ]),
      const SizedBox(height: 12),
      Container(
        padding: const EdgeInsets.all(12),
        decoration: _card(p),
        child: Column(children: [
          Row(children: [
            for (final d in names)
              Expanded(child: Text(d, textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: p.textMuted))),
          ]),
          const SizedBox(height: 6),
          GridView.count(
            crossAxisCount: 7,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 4,
            crossAxisSpacing: 4,
            children: [
              for (var i = 1; i < first; i++) const SizedBox.shrink(),
              for (var d = 1; d <= n; d++) _dayCell(p, d, locked),
            ],
          ),
        ]),
      ),
      const SizedBox(height: 10),
      Text(
        _w.isDaily
            ? Loc.t('Tap a day to change: Present → Absent → Half → Paid leave → clear. Unmarked days are NOT counted.',
                'دن پر دبائیں: حاضر ← غیر حاضر ← آدھا ← پیڈ چھٹی ← خالی۔ خالی دن شمار نہیں ہوں گے۔')
            : Loc.t('Tap a day to change: Present → Absent → Half → Paid leave → clear. Unmarked days count as present.',
                'دن پر دبائیں: حاضر ← غیر حاضر ← آدھا ← پیڈ چھٹی ← خالی۔ خالی دن حاضر شمار ہوں گے۔'),
        style: TextStyle(fontSize: 12, color: p.textMuted),
      ),
      if (locked)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(Loc.t('Salary for this month is paid, so attendance is locked.', 'اس مہینے کی تنخواہ ادا ہو چکی ہے، اس لیے حاضری بند ہے۔'),
              style: TextStyle(fontSize: 12.5, color: p.amber, fontWeight: FontWeight.bold)),
        )
      else
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: OutlinedButton.icon(
            onPressed: _markAllPresent,
            icon: const Icon(Icons.done_all),
            label: Text(Loc.t('Mark unmarked days present (till today)', 'باقی خالی دن (آج تک) حاضر لگائیں')),
          ),
        ),
    ]);
  }

  Widget _chip(AppPalette p, String status, String label, double v) {
    final c = _statusColor(p, status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: c.withOpacity(0.14), borderRadius: BorderRadius.circular(20)),
      child: Text('$label: ${_plain(v)}', style: TextStyle(color: c, fontWeight: FontWeight.bold, fontSize: 12.5)),
    );
  }

  Widget _dayCell(AppPalette p, int day, bool locked) {
    final s = _marks[day];
    final c = s == null ? p.border : _statusColor(p, s);
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: locked ? null : () => _cycle(day),
      child: Container(
        decoration: BoxDecoration(
          color: s == null ? Colors.transparent : c.withOpacity(0.18),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: c),
        ),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Text('$day', style: TextStyle(fontSize: 13, color: p.textDark)),
          if (s != null) Text(s, style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: c)),
        ]),
      ),
    );
  }

  // --------------------------------------------------------- advance tab

  Widget _advanceTab(AppPalette p) {
    return ListView(padding: const EdgeInsets.all(16), children: [
      Container(
        padding: const EdgeInsets.all(18),
        decoration: _card(p, 20),
        child: Row(children: [
          Icon(Icons.account_balance_wallet_outlined, color: p.amber),
          const SizedBox(width: 10),
          Expanded(child: Text(Loc.t('Advance balance', 'باقی ایڈوانس'), style: TextStyle(color: p.textMuted, fontWeight: FontWeight.bold))),
          Text(_rs(_advBal), style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: p.textDark)),
        ]),
      ),
      const SizedBox(height: 12),
      SizedBox(
        height: 50,
        child: ElevatedButton.icon(
          onPressed: _giveAdvance,
          style: ElevatedButton.styleFrom(
              backgroundColor: p.teal, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
          icon: const Icon(Icons.add),
          label: Text(Loc.t('GIVE ADVANCE', 'ایڈوانس دیں'), style: const TextStyle(fontWeight: FontWeight.bold)),
        ),
      ),
      const SizedBox(height: 16),
      if (_advances.isEmpty)
        Text(Loc.t('No advance given yet', 'ابھی تک کوئی ایڈوانس نہیں دیا'), style: TextStyle(color: p.textMuted))
      else
        for (final a in _advances)
          Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(14),
            decoration: _card(p),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(_rs(a.amount), style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: p.textDark)),
                  const SizedBox(height: 3),
                  Text(
                    '${DateFormat('dd MMM yyyy, hh:mm a').format(DateTime.fromMillisecondsSinceEpoch(a.createdAt))} • ${a.method}'
                    '${a.note.isEmpty ? '' : ' • ${a.note}'}',
                    style: TextStyle(fontSize: 11.5, color: p.textMuted),
                  ),
                ]),
              ),
              IconButton(icon: Icon(Icons.delete_outline, size: 20, color: p.red), onPressed: () => _deleteAdvance(a)),
            ]),
          ),
    ]);
  }

  // ---------------------------------------------------------- salary tab

  Widget _line(AppPalette p, String label, String value, {bool bold = false, Color? color}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Expanded(child: Text(label, style: TextStyle(color: p.textMuted, fontSize: 13.5))),
          Text(value,
              style: TextStyle(
                  color: color ?? p.textDark, fontSize: bold ? 16 : 14, fontWeight: bold ? FontWeight.bold : FontWeight.w600)),
        ]),
      );

  Widget _salaryTab(AppPalette p) {
    final counts = attendanceCounts(_marks, _year, _month);
    final calc = _calc();
    final paid = _paid;
    final cut = double.tryParse(_cut.text.trim()) ?? 0;
    final net = calc.earned - cut;
    final cutTooBig = cut > _advBal + 0.005 || cut > calc.earned + 0.005;

    return ListView(padding: const EdgeInsets.all(16), children: [
      Container(
        padding: const EdgeInsets.all(18),
        decoration: _card(p, 20),
        child: Column(children: [
          if (_w.isDaily) ...[
            _line(p, Loc.t('Days counted', 'گنے گئے دن'), _plain(calc.days)),
            _line(p, Loc.t('Daily rate', 'روزانہ اجرت'), _rs(_w.rate)),
          ] else ...[
            _line(p, Loc.t('Monthly salary', 'ماہانہ تنخواہ'), _rs(_w.rate)),
            _line(p, '${Loc.t('Absent / half-day cut', 'غیر حاضری کی کٹوتی')} (${_plain(calc.days)} ${Loc.t('days', 'دن')})',
                '- ${_rs(calc.deduction)}',
                color: calc.deduction > 0 ? p.red : null),
          ],
          Divider(color: p.border),
          _line(p, Loc.t('Earned this month', 'اس مہینے کی کمائی'), _rs(calc.earned), bold: true),
          if (counts.unmarked > 0)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                _w.isDaily
                    ? Loc.t('${counts.unmarked} days are unmarked and are not counted.', '${counts.unmarked} دن خالی ہیں اور شمار نہیں ہوئے۔')
                    : Loc.t('${counts.unmarked} days are unmarked and count as present.', '${counts.unmarked} دن خالی ہیں اور حاضر شمار ہوئے۔'),
                style: TextStyle(fontSize: 12, color: p.amber),
              ),
            ),
        ]),
      ),
      const SizedBox(height: 12),
      if (paid != null)
        Container(
          padding: const EdgeInsets.all(18),
          decoration: _card(p, 20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(Icons.check_circle, color: p.teal),
              const SizedBox(width: 8),
              Text(Loc.t('Salary paid', 'تنخواہ ادا ہو چکی'), style: TextStyle(fontWeight: FontWeight.bold, color: p.teal)),
            ]),
            const SizedBox(height: 8),
            _line(p, Loc.t('Earned', 'کمائی'), _rs(paid.earned)),
            _line(p, Loc.t('Advance cut', 'ایڈوانس کٹوتی'), '- ${_rs(paid.advanceCut)}'),
            _line(p, Loc.t('Paid', 'ادا کیا'), _rs(paid.net), bold: true),
            const SizedBox(height: 6),
            OutlinedButton.icon(
              onPressed: () => _undoPayment(paid),
              icon: Icon(Icons.undo, color: p.red),
              label: Text(Loc.t('Undo this payment', 'یہ ادائیگی واپس کریں'), style: TextStyle(color: p.red)),
            ),
          ]),
        )
      else
        Container(
          padding: const EdgeInsets.all(18),
          decoration: _card(p, 20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _line(p, Loc.t('Advance balance', 'باقی ایڈوانس'), _rs(_advBal)),
            const SizedBox(height: 8),
            TextField(
              controller: _cut,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
              onChanged: (_) => setState(() {}),
              style: TextStyle(color: p.textDark),
              decoration: _deco(p, Loc.t('Advance to deduct', 'کتنا ایڈوانس کاٹنا ہے')),
            ),
            if (cutTooBig)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(Loc.t('Deduction is more than the advance balance or the earned amount.',
                    'کٹوتی باقی ایڈوانس یا کمائی سے زیادہ ہے۔'),
                    style: TextStyle(fontSize: 12, color: p.red)),
              ),
            const SizedBox(height: 10),
            _methodPicker(p, _method, (v) => setState(() => _method = v)),
            const SizedBox(height: 10),
            _line(p, Loc.t('Pay now', 'ابھی ادا کریں'), _rs(net < 0 ? 0 : net), bold: true, color: p.teal),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton(
                onPressed: (_busy || calc.earned <= 0 || cutTooBig) ? null : _pay,
                style: ElevatedButton.styleFrom(
                    backgroundColor: p.teal,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                child: Text(Loc.t('PAY SALARY', 'تنخواہ دیں'), style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
          ]),
        ),
      const SizedBox(height: 18),
      Text(Loc.t('SALARY HISTORY', 'تنخواہ کی ہسٹری'), style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: p.textMuted)),
      const SizedBox(height: 8),
      if (_payments.isEmpty)
        Text(Loc.t('No salary paid yet', 'ابھی تک کوئی تنخواہ ادا نہیں ہوئی'), style: TextStyle(color: p.textMuted))
      else
        for (final x in _payments)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(14),
            decoration: _card(p),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(x.month, style: TextStyle(fontWeight: FontWeight.bold, color: p.textDark)),
                  Text('${Loc.t('Earned', 'کمائی')} ${_rs(x.earned)}  •  ${Loc.t('Advance', 'ایڈوانس')} ${_rs(x.advanceCut)}',
                      style: TextStyle(fontSize: 11.5, color: p.textMuted)),
                ]),
              ),
              Text(_rs(x.net), style: TextStyle(fontWeight: FontWeight.bold, color: p.textDark)),
            ]),
          ),
    ]);
  }
}
