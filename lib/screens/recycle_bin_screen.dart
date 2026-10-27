import 'package:flutter/material.dart';

import '../db/recycle_bin_repository.dart';
import '../services/session.dart';
import '../theme/theme_manager.dart';
import '../utils/loc.dart';

/// Recycle Bin: delete hui cheezen (bill, kharcha, payment, party, item, worker) — sirf Admin wapas la ya hamesha
/// ke liye hata sakta hai. Restore par stock / balance / cash bhi wapas aate hain.
class RecycleBinScreen extends StatefulWidget {
  const RecycleBinScreen({super.key});

  @override
  State<RecycleBinScreen> createState() => _RecycleBinScreenState();
}

class _RecycleBinScreenState extends State<RecycleBinScreen> {
  final _repo = RecycleBinRepository.instance;
  List<RecycleBinEntry> _entries = const [];
  String? _kind; // null = sab
  bool _loading = true;
  bool _busy = false;

  static const _kinds = <String, (String, String, IconData)>{
    RecycleBinRepository.kindSale: ('Sales', 'سیل', Icons.receipt_long),
    RecycleBinRepository.kindExpense: ('Expenses', 'خرچے', Icons.money_off),
    RecycleBinRepository.kindPayment: ('Payments', 'ادائیگیاں', Icons.payments_outlined),
    RecycleBinRepository.kindCustomer: ('Customers', 'کسٹمرز', Icons.person),
    RecycleBinRepository.kindSupplier: ('Suppliers', 'سپلائرز', Icons.local_shipping_outlined),
    RecycleBinRepository.kindProduct: ('Items', 'آئٹمز', Icons.inventory_2_outlined),
    RecycleBinRepository.kindWorker: ('Workers', 'ورکرز', Icons.badge_outlined),
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await _repo.list(kind: _kind);
    if (!mounted) return;
    setState(() {
      _entries = list;
      _loading = false;
    });
  }

  void _msg(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<bool> _confirm(String title, String body, String action) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(Loc.t('Cancel', 'منسوخ'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(action)),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _restore(RecycleBinEntry e) async {
    if (_busy) return;
    final ok = await _confirm(
      Loc.t('Restore?', 'واپس لائیں؟'),
      Loc.t('"${e.title}" wapas aa jayega (stock / balance / cash bhi).', '"${e.title}" واپس آ جائے گا (اسٹاک / بیلنس / کیش بھی)۔'),
      Loc.t('RESTORE', 'واپس لائیں'),
    );
    if (!ok) return;
    setState(() => _busy = true);
    try {
      await _repo.restore(e.id);
      _msg(Loc.t('Restore ho gaya', 'واپس آ گیا'));
    } on RecycleBinException catch (ex) {
      _msg(ex.message);
    } on StateError catch (ex) {
      _msg(ex.message);
    } catch (ex) {
      _msg('$ex');
    } finally {
      if (mounted) setState(() => _busy = false);
      await _load();
    }
  }

  Future<void> _purge(RecycleBinEntry e) async {
    if (_busy) return;
    final ok = await _confirm(
      Loc.t('Delete forever?', 'ہمیشہ کے لیے حذف؟'),
      Loc.t('"${e.title}" dobara wapas nahi aa sakega.', '"${e.title}" دوبارہ واپس نہیں آ سکے گا۔'),
      Loc.t('DELETE FOREVER', 'ہمیشہ کے لیے حذف'),
    );
    if (!ok) return;
    try {
      await _repo.purge(e.id);
    } on StateError catch (ex) {
      _msg(ex.message);
    }
    await _load();
  }

  Future<void> _purgeAll() async {
    if (_entries.isEmpty) return;
    final ok = await _confirm(
      Loc.t('Empty Recycle Bin?', 'ری سائیکل بن خالی کریں؟'),
      Loc.t('Sab entries hamesha ke liye hat jayengi.', 'تمام اندراجات ہمیشہ کے لیے ہٹ جائیں گے۔'),
      Loc.t('EMPTY', 'خالی کریں'),
    );
    if (!ok) return;
    try {
      await _repo.purgeAll();
    } on StateError catch (ex) {
      _msg(ex.message);
    }
    await _load();
  }

  String _when(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.day)}-${two(d.month)}-${d.year} ${two(d.hour)}:${two(d.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final p = ThemeManager.palette;
    final admin = Session.isAdmin;
    return Scaffold(
      backgroundColor: p.bg,
      appBar: AppBar(
        backgroundColor: p.navy,
        foregroundColor: Colors.white,
        title: Text(Loc.t('Recycle Bin', 'ری سائیکل بِن')),
        actions: [
          if (admin && _entries.isNotEmpty)
            IconButton(
              tooltip: Loc.t('Empty bin', 'بن خالی کریں'),
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: _purgeAll,
            ),
        ],
      ),
      body: !admin
          ? Center(child: Text(Loc.t('Sirf Admin', 'صرف ایڈمن')))
          : Column(children: [
              SizedBox(
                height: 52,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(Loc.t('All', 'سب')),
                        selected: _kind == null,
                        onSelected: (_) {
                          _kind = null;
                          _load();
                        },
                      ),
                    ),
                    for (final e in _kinds.entries)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(Loc.t(e.value.$1, e.value.$2)),
                          selected: _kind == e.key,
                          onSelected: (_) {
                            _kind = e.key;
                            _load();
                          },
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _entries.isEmpty
                        ? Center(child: Text(Loc.t('Recycle Bin khali hai', 'ری سائیکل بن خالی ہے')))
                        : ListView.builder(
                            padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                            itemCount: _entries.length,
                            itemBuilder: (_, i) => _tile(_entries[i]),
                          ),
              ),
            ]),
    );
  }

  Widget _tile(RecycleBinEntry e) {
    final meta = _kinds[e.kind];
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(meta?.$3 ?? Icons.delete_outline, color: ThemeManager.palette.navyInk),
            const SizedBox(width: 8),
            Expanded(child: Text(e.title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15))),
            if (e.amount != 0) Text(e.amount.toStringAsFixed(e.amount % 1 == 0 ? 0 : 2), style: const TextStyle(fontWeight: FontWeight.w600)),
          ]),
          if (e.subtitle.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 2), child: Text(e.subtitle)),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '${Loc.t('Deleted', 'حذف')}: ${_when(e.deletedAt)}  •  ${e.deletedBy}',
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _busy ? null : () => _restore(e),
                icon: const Icon(Icons.restore_from_trash_outlined),
                label: Text(Loc.t('RESTORE', 'واپس لائیں')),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: _busy ? null : () => _purge(e),
              child: Text(Loc.t('DELETE FOREVER', 'ہمیشہ کے لیے حذف')),
            ),
          ]),
        ]),
      ),
    );
  }
}
