import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../db/expense_repository.dart';
import '../models/misc_entities.dart';
import '../theme/theme_manager.dart';
import '../utils/loc.dart';

/// Mirrors ExpenseActivity.kt — record an expense (paid from cash or bank),
/// see today's / this month's totals and the latest 50 expenses. All roles
/// (same as Kotlin).
///
/// Save and Delete both go through [ExpenseRepository], which writes/removes
/// the Expense AND its linked cash OUT row in ONE transaction.
class ExpenseScreen extends StatefulWidget {
  const ExpenseScreen({super.key});

  @override
  State<ExpenseScreen> createState() => _ExpenseScreenState();
}

class _ExpenseScreenState extends State<ExpenseScreen> {
  final _amount = TextEditingController();
  final _note = TextEditingController();
  final _miscDesc = TextEditingController();

  String _method = 'cash';
  String _category = ExpenseCategories.all.first;
  bool _miscOpen = false; // "Add description" expanded
  bool _saving = false; // double-tap guard

  ExpenseTotals _totals = const ExpenseTotals(0, 0);
  List<Expense> _recent = const [];

  bool get _isMisc => _category == ExpenseCategories.miscellaneous;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    _miscDesc.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final totals = await ExpenseRepository.instance.totals();
    final recent = await ExpenseRepository.instance.recent();
    if (!mounted) return;
    setState(() {
      _totals = totals;
      _recent = recent;
    });
  }

  void _toast(String msg) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _save() async {
    if (_saving) return;
    final amt = double.tryParse(_amount.text.trim());
    if (amt == null || !amt.isFinite || amt <= 0) {
      _toast(Loc.t('Enter a valid amount', 'صحیح رقم لکھیں'));
      return;
    }
    setState(() => _saving = true);
    try {
      await ExpenseRepository.instance.save(
        amount: amt,
        category: _category,
        method: _method,
        misc: _miscDesc.text,
        note: _note.text,
      );
      if (!mounted) return;
      _toast(Loc.t('Saved', 'محفوظ ہو گیا'));
      _amount.clear();
      _note.clear();
      _miscDesc.clear();
      setState(() {
        _miscOpen = false;
        _category = ExpenseCategories.all.first;
        _method = 'cash';
      });
      await _reload();
    } catch (e) {
      if (mounted) _toast(e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _confirmDelete(Expense e) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(Loc.t('Delete Expense', 'خرچہ حذف کریں')),
        content: Text(Loc.t('Remove this expense entry?', 'کیا یہ خرچہ حذف کر دیں؟')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(Loc.t('Cancel', 'منسوخ'))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(Loc.t('Delete', 'حذف کریں'))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ExpenseRepository.instance.delete(e);
      await _reload();
    } catch (err) {
      if (mounted) _toast(err.toString());
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
                  _totalCard(p, Icons.trending_down, Loc.t("Today's Expense", 'آج کا خرچہ'), _totals.today),
                  const SizedBox(width: 12),
                  _totalCard(p, Icons.calendar_today, Loc.t('This Month', 'اس مہینے'), _totals.month),
                ]),
                const SizedBox(height: 20),
                _form(p),
                const SizedBox(height: 22),
                Text(Loc.t('RECENT EXPENSES', 'حالیہ اخراجات'),
                    style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: p.textMuted)),
                const SizedBox(height: 10),
                if (_recent.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(Loc.t('No expenses yet', 'ابھی تک کوئی خرچہ نہیں'), style: TextStyle(color: p.textMuted)),
                  )
                else
                  for (final e in _recent) _expenseTile(p, e),
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
            Text(Loc.t('Expenses', 'اخراجات'),
                style: const TextStyle(color: Colors.white, fontSize: 18.5, fontWeight: FontWeight.bold)),
            Text(Loc.t('Track your business spending', 'اپنے کاروباری اخراجات ٹریک کریں'),
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

  Widget _totalCard(AppPalette p, IconData icon, String label, double value) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: _cardDeco(p, 22),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(color: p.red.withOpacity(0.14), shape: BoxShape.circle),
              child: Icon(icon, size: 18, color: p.red),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: p.textMuted)),
            ),
          ]),
          const SizedBox(height: 10),
          Text('Rs ${value.toStringAsFixed(2)}', style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold, color: p.red)),
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

  Widget _label(AppPalette p, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(text, style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: p.textDark)),
      );

  Widget _form(AppPalette p) {
    final showToggle = _isMisc && !_miscOpen && _miscDesc.text.trim().isEmpty;
    final showDesc = _isMisc && (_miscOpen || _miscDesc.text.trim().isNotEmpty);
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: _cardDeco(p, 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _label(p, Loc.t('New Expense', 'نیا خرچہ')),
        TextField(
          controller: _amount,
          style: TextStyle(color: p.textDark),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
          decoration: _fieldDeco(p, Loc.t('Amount', 'رقم')),
        ),
        const SizedBox(height: 14),
        _label(p, Loc.t('Expense Category', 'خرچہ کیٹیگری')),
        _dropdown(p, _category, ExpenseCategories.all, (v) => setState(() => _category = v)),
        const SizedBox(height: 14),
        _label(p, Loc.t('Paid From', 'کہاں سے ادا کیا')),
        _dropdown(p, _method, const ['cash', 'bank'], (v) => setState(() => _method = v)),
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
          controller: _note,
          style: TextStyle(color: p.textDark),
          decoration: _fieldDeco(p, Loc.t('Note (optional)', 'نوٹ (اختیاری)')),
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          height: 52,
          child: ElevatedButton(
            onPressed: _saving ? null : _save,
            style: ElevatedButton.styleFrom(
              backgroundColor: p.red,
              foregroundColor: Colors.white,
              disabledBackgroundColor: p.red.withOpacity(0.5),
              disabledForegroundColor: Colors.white70,
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            ),
            child: Text(Loc.t('SAVE EXPENSE', 'خرچہ محفوظ کریں'), style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
        ),
      ]),
    );
  }

  Widget _expenseTile(AppPalette p, Expense e) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: _cardDeco(p, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(color: p.red.withOpacity(0.14), shape: BoxShape.circle),
            child: Icon(Icons.receipt_long, size: 15, color: p.red),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              e.category + (e.description.isNotEmpty ? ' - ${e.description}' : ''),
              style: TextStyle(fontSize: 14, color: p.textDark),
            ),
          ),
          const SizedBox(width: 8),
          Text('- Rs ${e.amount.toStringAsFixed(2)}',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: p.red)),
        ]),
        const SizedBox(height: 6),
        Row(children: [
          Expanded(
            child: Text(DateFormat('dd MMM, hh:mm a').format(DateTime.fromMillisecondsSinceEpoch(e.createdAt)),
                style: TextStyle(fontSize: 11.5, color: p.textMuted)),
          ),
          InkWell(
            onTap: () => _confirmDelete(e),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
              child: Icon(Icons.delete_outline, size: 16, color: p.red),
            ),
          ),
        ]),
      ]),
    );
  }
}
