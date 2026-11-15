import 'package:flutter/material.dart';

import '../db/month_cleanup_repository.dart';
import '../theme/theme_manager.dart';
import '../utils/loc.dart';
import '../widgets/role_guard.dart';

/// Settings > "Delete Month Data": ek mahine ke saare Sale + Purchase bills delete (Admin only).
class MonthCleanupScreen extends StatelessWidget {
  const MonthCleanupScreen({super.key});

  @override
  Widget build(BuildContext context) => const RoleGuard(allowed: {'admin'}, child: _Body());
}

class _Body extends StatefulWidget {
  const _Body();
  @override
  State<_Body> createState() => _BodyState();
}

class _BodyState extends State<_Body> {
  final _repo = MonthCleanupRepository.instance;
  final _confirm = TextEditingController();
  int _year = DateTime.now().year;
  int _month = 8;
  MonthCleanupPreview? _preview;
  bool _busy = false;
  String? _result;

  static const _months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];

  @override
  void dispose() {
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _result = null;
      _confirm.clear();
    });
    try {
      final p = await _repo.preview(_year, _month);
      if (mounted) setState(() => _preview = p);
    } catch (e) {
      if (mounted) setState(() => _result = 'Error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    setState(() => _busy = true);
    try {
      final r = await _repo.run(_year, _month);
      final fail = r.failures.isEmpty ? '' : '\n\nFailed (${r.failures.length}):\n${r.failures.take(5).join('\n')}';
      if (mounted) {
        setState(() {
          _result = 'Deleted ${r.salesDeleted} sales, ${r.purchasesDeleted} purchases.$fail\n\nAb Settings > Sync Now chalayen, phir Stock Audit dekh len.';
          _preview = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _result = 'Error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = ThemeManager.palette;
    final pv = _preview;
    final canDelete = pv != null && (pv.saleCount + pv.purchaseCount) > 0 && _confirm.text.trim() == 'DELETE' && !_busy;
    return Scaffold(
      backgroundColor: p.bg,
      appBar: AppBar(title: Text(Loc.t('Delete Month Data', 'مہینے کا ڈیٹا ڈیلیٹ'))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text(
            Loc.t('Is mahine ke saare Sale aur Purchase bills delete honge — stock, party balance aur cash reverse hoga aur sab devices se hat jayega. Pehle Backup le len.',
                'اس مہینے کے سب سیل اور پرچیز بل ڈیلیٹ ہوں گے۔ پہلے بیک اپ لیں۔'),
            style: TextStyle(color: p.red)),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(
            child: DropdownButtonFormField<int>(
              value: _month,
              items: [for (var i = 1; i <= 12; i++) DropdownMenuItem(value: i, child: Text(_months[i - 1]))],
              onChanged: (v) => setState(() {
                _month = v!;
                _preview = null;
              }),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: DropdownButtonFormField<int>(
              value: _year,
              items: [for (var y = DateTime.now().year - 3; y <= DateTime.now().year; y++) DropdownMenuItem(value: y, child: Text('$y'))],
              onChanged: (v) => setState(() {
                _year = v!;
                _preview = null;
              }),
            ),
          ),
        ]),
        const SizedBox(height: 12),
        FilledButton(onPressed: _busy ? null : _load, child: Text(Loc.t('PREVIEW', 'پری ویو'))),
        if (pv != null) ...[
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${_months[_month - 1]} $_year', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                const SizedBox(height: 8),
                Text('Sales: ${pv.saleCount} bills — Rs ${pv.saleTotal.round()}'),
                Text('Purchases: ${pv.purchaseCount} bills — Rs ${pv.purchaseTotal.round()}'),
              ]),
            ),
          ),
          if (pv.saleCount + pv.purchaseCount == 0)
            Padding(padding: const EdgeInsets.only(top: 8), child: Text(Loc.t('Is mahine mein koi bill nahi.', 'اس مہینے کوئی بل نہیں۔')))
          else ...[
            const SizedBox(height: 12),
            TextField(
              controller: _confirm,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(labelText: Loc.t('Confirm ke liye DELETE likhein', 'تصدیق کے لیے DELETE لکھیں'), border: const OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: p.red),
              onPressed: canDelete ? _delete : null,
              child: Text(Loc.t('DELETE ALL', 'سب ڈیلیٹ کریں')),
            ),
          ],
        ],
        if (_busy) const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator())),
        if (_result != null) Padding(padding: const EdgeInsets.only(top: 16), child: Text(_result!)),
      ]),
    );
  }
}
