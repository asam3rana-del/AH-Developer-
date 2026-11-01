import 'package:flutter/material.dart';

import '../db/purchase_history_repository.dart' show ReturnableLine, parseReturnRequest;
import '../theme/theme_manager.dart';
import '../utils/loc.dart';

/// Partial-return dialog: har line par "Return qty (khali = skip)". Validation `parseReturnRequest` se
/// (purchase return jaisi). Pop karta hai `Map<lineId, qty>` ya null (cancel).
/// [qtyLabel] = "Purchased" / "Sold" jaisa lafz (English), [qtyLabelUr] = urdu.
class ReturnQtyDialog extends StatefulWidget {
  final List<ReturnableLine> lines;
  final AppPalette palette;
  final String description;
  final String descriptionUr;
  final String qtyLabel;
  final String qtyLabelUr;

  const ReturnQtyDialog({
    super.key,
    required this.lines,
    required this.palette,
    required this.description,
    required this.descriptionUr,
    required this.qtyLabel,
    required this.qtyLabelUr,
  });

  @override
  State<ReturnQtyDialog> createState() => _ReturnQtyDialogState();
}

class _ReturnQtyDialogState extends State<ReturnQtyDialog> {
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

  void _fillAll() {
    setState(() {
      _error = null;
      for (final l in widget.lines) {
        _ctrls[l.itemId]!.text = _qty(l.qty);
      }
    });
  }

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
          Text(Loc.t(widget.description, widget.descriptionUr), style: TextStyle(fontSize: 13, color: p.textMuted)),
          const SizedBox(height: 8),
          Flexible(
            child: ListView(shrinkWrap: true, children: [
              for (final l in widget.lines)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(l.name, style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: p.textDark)),
                    Text(
                        Loc.t('${widget.qtyLabel}: ${_qty(l.qty)} ${l.unit}', '${widget.qtyLabelUr}: ${_qty(l.qty)} ${l.unit}'),
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
        TextButton(onPressed: _fillAll, child: Text(Loc.t('Fill all', 'سب بھریں'))),
        TextButton(onPressed: () => Navigator.pop(context), child: Text(Loc.t('Cancel', 'منسوخ کریں'))),
        FilledButton(onPressed: _submit, child: Text(Loc.t('Return', 'واپسی'))),
      ],
    );
  }
}
