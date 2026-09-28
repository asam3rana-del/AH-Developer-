import 'package:flutter/material.dart';

import 'loc.dart';

/// Mirrors InputValidation.kt `parseMoneyOrWarn`.
/// Khali field => 0.0. Ghalat text => SnackBar dikha kar `null` (save rokein).
/// Istemal: `final paid = parseMoneyOrWarn(context, ctrl.text, 'Paid Amount', 'ادا شدہ رقم'); if (paid == null) return;`
double? parseMoneyOrWarn(BuildContext context, String text, String labelEn, String labelUr) {
  final raw = text.trim();
  if (raw.isEmpty) return 0.0;
  final v = double.tryParse(raw);
  if (v == null) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      duration: const Duration(seconds: 4),
      content: Text(Loc.t(
        'Invalid amount in "$labelEn" ("$raw") — please correct it.',
        '“$labelUr” میں غلط رقم (“$raw”) — براہ کرم درست کریں۔',
      )),
    ));
  }
  return v;
}
