import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../db/cash_repository.dart';
import '../models/misc_entities.dart';
import '../theme/theme_manager.dart';
import '../utils/loc.dart';

/// Mirrors CashActivity.kt — record a Cash In / Cash Out, see today's totals
/// and the latest 50 cash movements. All roles (same as Kotlin).
///
/// A Cash Out under a real expense category also creates an Expense (see
/// CashRepository.save); "Non-expense" is a plain cash movement.
class CashScreen extends StatefulWidget {
  const CashScreen({super.key});

  @override
  State<CashScreen> createState() => _CashScreenState();
}

class _CashScreenState extends State<CashScreen> {
  final _amount = TextEditingController();
  final _reason = TextEditingController();
  final _miscDesc = TextEditingController();

  String _method = 'cash';
  String _category = CashCategories.all.first;
  bool _miscOpen = false; // "Add description" expanded
  bool _saving = false; // double-tap guard (Kotlin FIX: duplicate entry)

  CashTotals _totals = const CashTotals(0, 0);
  List<CashTransaction> _recent = const [];

  bool get _isMisc => _category == CashCategories.miscellaneous;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _amount.dispose();
    _reason.dispose();
    _miscDesc.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final totals = await CashRepository.instance.todayTotals();
    final recent = await CashRepository.instance.recent();
    if (!mounted) return;
    setState(() {
      _totals = totals;
      _recent = recent;
    });
  }

  void _toast(String msg) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _save(String type) async {
    if (_saving) return;
    final amt = double.tryParse(_amount.text.trim());
    if (amt == null || !amt.isFinite || amt <= 0) {
      _toast(Loc.t('Enter a valid amount', 'صحیح رقم لکھیں'));
      return;
    }
    setState(() => _saving = true);
    try {
      await CashRepository.instance.save(
        type: type,
        amount: amt,
        method: _method,
        category: _category,
        misc: _miscDesc.text,
        note: _reason.text,
      );
      if (!mounted) return;
      _toast(Loc.t('Saved', 'محفوظ ہو گیا'));
      _amount.clear();
      _reason.clear();
      _miscDesc.clear();
      setState(() {
        _miscOpen = false;
        _category = CashCategories.all.first;
      });
      await _reload();
    } catch (e) {
      if (mounted) _toast(e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = ThemeManager.palette;
    return Scaffold(
      backgroundColor: p.bg,
      body: Column(
        children: [
          _header(p),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
              children: [
                Row(children: [
                  _totalCard(p, Icons.trending_up, Loc.t('Today Cash In', 'آج کیش ان'), _totals.cashIn, p.flatTealFg, p.flatTealBg),
                  const SizedBox(width: 12),
                  _totalCard(p, Icons.trending_down, Loc.t('Today Cash Out', 'آج کیش آؤٹ'), _totals.cashOut, p.red, p.red.withOpacity(0.14)),
                ]),
                const SizedBox(height: 20),
                _form(p),
                const SizedBox(height: 22),
                Text(Loc.t('RECENT TRANSACTIONS', 'حالیہ لین دین'),
                    style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: p.textMuted)),
                const SizedBox(height: 10),
                if (_recent.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(Loc.t('No entries yet', 'کوئی انٹری نہیں ہے'), style: TextStyle(color: p.textMuted)),
                  )
                else
                  for (final t in _recent) _txTile(p, t),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(AppPalette p) {
    return Container(
      color: p.navy,
      padding: EdgeInsets.fromLTRB(8, MediaQuery.of(context).padding.top + 10, 16, 16),
      child: Row(children: [
        IconButton(icon: const Icon(Icons.arrow_back, color: Colors.white), onPressed: () => Navigator.of(context).maybePop()),
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(color: p.headerBadgeOverlay, shape: BoxShape.circle),
          child: const Icon(Icons.account_balance_wallet_outlined, color: Colors.white, size: 18),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(Loc.t('Cash In / Cash Out', 'کیش ان / کیش آؤٹ'),
                style: const TextStyle(color: Colors.white, fontSize: 18.5, fontWeight: FontWeight.bold)),
            Text(Loc.t('Record cash movements', 'کیش کی آمد و رفت درج کریں'),
                style: TextStyle(color: p.headerSubtitleColor, fontSize: 11)),
          ]),
        ),
      ]),
    );
  }

  BoxDecoration _cardDeco(AppPalette p, double r) => BoxDecoration(
        color: p.cardWhite,
        borderRadius: BorderRadius.circular(r),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 8, offset: const Offset(0, 3))],
      );

  Widget _totalCard(AppPalette p, IconData icon, String label, double value, Color accent, Color tint) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: _cardDeco(p, 22),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(color: tint, shape: BoxShape.circle),
              child: Icon(icon, size: 18, color: accent),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: p.textMuted)),
            ),
          ]),
          const SizedBox(height: 10),
          Text('Rs ${value.toStringAsFixed(2)}', style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold, color: accent)),
        ]),
      ),
    );
  }

  InputDecoration _fieldDeco(AppPalette p, String hint) => InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: p.textMuted),
        filled: true,
        fillColor: p.fieldFill,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: p.border)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: p.teal)),
      );

  Widget _dropdown(AppPalette p, String value, List<String> items, ValueChanged<String> onChanged) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: p.fieldFill,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: p.border),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isExpanded: true,
          dropdownColor: p.cardWhite,
          style: TextStyle(fontSize: 15, color: p.textDark),
          items: [for (final i in items) DropdownMenuItem(value: i, child: Text(i, overflow: TextOverflow.ellipsis))],
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
      ),
    );
  }

  Widget _form(AppPalette p) {
    final showToggle = _isMisc && !_miscOpen && _miscDesc.text.trim().isEmpty;
    final showDesc = _isMisc && (_miscOpen || _miscDesc.text.trim().isNotEmpty);
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: _cardDeco(p, 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(Loc.t('New Entry', 'نئی انٹری'), style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: p.textDark)),
        const SizedBox(height: 14),
        TextField(
          controller: _amount,
          style: TextStyle(color: p.textDark),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
          decoration: _fieldDeco(p, Loc.t('Amount', 'رقم')),
        ),
        const SizedBox(height: 14),
        _dropdown(p, _method, const ['cash', 'bank'], (v) => setState(() => _method = v)),
        const SizedBox(height: 14),
        Text(Loc.t('Expense Category', 'خرچہ کیٹیگری'),
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: p.textDark)),
        const SizedBox(height: 2),
        Text(Loc.t('Used for Cash Out only', 'صرف کیش آؤٹ کے لیے'), style: TextStyle(fontSize: 11, color: p.textMuted)),
        const SizedBox(height: 10),
        _dropdown(p, _category, CashCategories.all, (v) => setState(() => _category = v)),
        const SizedBox(height: 14),
        if (showToggle)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: InkWell(
              onTap: () => setState(() => _miscOpen = true),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.text_fields, size: 13, color: p.teal),
                  const SizedBox(width: 6),
                  Text(Loc.t('Add description', 'تفصیل شامل کریں'),
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: p.teal)),
                ]),
              ),
            ),
          ),
        if (showDesc) ...[
          TextField(
            controller: _miscDesc,
            style: TextStyle(color: p.textDark),
            minLines: 2,
            maxLines: 4,
            onChanged: (_) => setState(() {}),
            decoration: _fieldDeco(p, Loc.t('Describe this expense', 'اس خرچے کی تفصیل لکھیں')),
          ),
          const SizedBox(height: 14),
        ],
        TextField(
          controller: _reason,
          style: TextStyle(color: p.textDark),
          decoration: _fieldDeco(p, Loc.t('Reason / Note (optional)', 'وجہ / نوٹ (اختیاری)')),
        ),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: _actionBtn(Loc.t('CASH IN', 'کیش ان'), p.flatTealFg, () => _save('IN'))),
          const SizedBox(width: 12),
          Expanded(child: _actionBtn(Loc.t('CASH OUT', 'کیش آؤٹ'), p.red, () => _save('OUT'))),
        ]),
      ]),
    );
  }

  Widget _actionBtn(String label, Color color, VoidCallback onTap) {
    return SizedBox(
      height: 52,
      child: ElevatedButton(
        onPressed: _saving ? null : onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          disabledBackgroundColor: color.withOpacity(0.5),
          disabledForegroundColor: Colors.white70,
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
        child: Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
      ),
    );
  }

  Widget _txTile(AppPalette p, CashTransaction t) {
    final isIn = t.type == 'IN';
    final color = isIn ? p.flatTealFg : p.red;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: _cardDeco(p, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(color: color.withOpacity(0.14), shape: BoxShape.circle),
            child: Icon(isIn ? Icons.trending_up : Icons.trending_down, size: 15, color: color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              t.method.toUpperCase() + (t.reason.isNotEmpty ? ' - ${t.reason}' : ''),
              style: TextStyle(fontSize: 14, color: p.textDark),
            ),
          ),
          const SizedBox(width: 8),
          Text('${isIn ? '+' : '-'} Rs ${t.amount.toStringAsFixed(2)}',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: color)),
        ]),
        const SizedBox(height: 6),
        Text(DateFormat('dd MMM, hh:mm a').format(DateTime.fromMillisecondsSinceEpoch(t.createdAt)),
            style: TextStyle(fontSize: 11.5, color: p.textMuted)),
      ]),
    );
  }
}
