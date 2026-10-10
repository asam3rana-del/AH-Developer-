import 'package:flutter/material.dart';

import '../models/product.dart';
import '../utils/loc.dart';
import '../utils/rate_margin.dart';

String _n(double v) => v == v.truncateToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);

/// Rate cost se kam ho to "Save anyway?" poochta hai. Sab rate PRIMARY unit par (null / 0 = set nahi).
/// Koi rate cost se kam nahi to bina dialog `true`. Cost 0 ho to bhi `true`.
Future<bool> confirmBelowCost(
  BuildContext context, {
  required Product product,
  double? retail,
  double? wholesale,
  double? shopkeeper,
}) async {
  final cost = product.cost;
  final lines = <String>[
    if (isBelowCost(retail ?? 0, cost)) '${Loc.t('Retail', 'خوردہ')}: Rs ${_n(retail!)}',
    if (isBelowCost(wholesale ?? 0, cost)) '${Loc.t('Wholesale', 'ہول سیل')}: Rs ${_n(wholesale!)}',
    if (isBelowCost(shopkeeper ?? 0, cost)) '${Loc.t('Shopkeeper', 'دکاندار')}: Rs ${_n(shopkeeper!)}',
  ];
  if (lines.isEmpty) return true;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(Loc.t('Rate below cost', 'ریٹ لاگت سے کم')),
      content: Text(Loc.t(
        '"${product.name}" cost is Rs ${_n(cost)} / ${product.unit}. These rates are lower (loss):\n\n${lines.join('\n')}\n\nSave anyway?',
        '"${product.name}" کی لاگت Rs ${_n(cost)} / ${product.unit} ہے۔ یہ ریٹ کم ہیں (نقصان):\n\n${lines.join('\n')}\n\nپھر بھی محفوظ کریں؟',
      )),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(Loc.t('Edit', 'درست کریں'))),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(Loc.t('Save anyway', 'پھر بھی محفوظ کریں'))),
      ],
    ),
  );
  return ok == true;
}
