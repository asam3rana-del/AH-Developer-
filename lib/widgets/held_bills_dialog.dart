import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/held_bill.dart';
import '../services/sale_hold_recall.dart';
import '../theme/theme_manager.dart';
import '../utils/loc.dart';

enum HeldBillAction { recall, delete }

class HeldBillChoice {
  final HeldBillAction action;
  final HeldBill bill;
  const HeldBillChoice(this.action, this.bill);
}

/// Dart port of `openRecallDialog()` (SaleHoldRecall.kt): lists parked bills,
/// each with a RECALL button and a delete (✕) button. The caller does the
/// actual restore / delete using the returned [HeldBillChoice].
Future<HeldBillChoice?> showHeldBillsDialog(BuildContext context, List<HeldBill> held) {
  final fmt = DateFormat('dd MMM, hh:mm a');
  return showDialog<HeldBillChoice>(
    context: context,
    builder: (ctx) => Dialog(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              color: ThemeManager.palette.navyInk,
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
              child: Text(Loc.t('Held Bills', 'ہولڈ بلز'), style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
            ),
            Flexible(
              child: held.isEmpty
                  ? Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(Loc.t('No held bills', 'کوئی ہولڈ بل نہیں'), style: TextStyle(color: ThemeManager.palette.textMuted)),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      padding: const EdgeInsets.all(16),
                      itemCount: held.length,
                      itemBuilder: (context, i) {
                        final h = held[i];
                        return Container(
                          margin: const EdgeInsets.only(bottom: 10),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          decoration: BoxDecoration(
                            color: ThemeManager.palette.fieldFill,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: ThemeManager.palette.border),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 30,
                                height: 30,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(color: ThemeManager.palette.amber, shape: BoxShape.circle),
                                child: const Text('⏸', style: TextStyle(fontSize: 13)),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('${heldItemCount(h.payload)} items',
                                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: ThemeManager.palette.textDark)),
                                    Text(fmt.format(DateTime.fromMillisecondsSinceEpoch(h.createdAt)),
                                        style: TextStyle(fontSize: 12, color: ThemeManager.palette.textMuted)),
                                  ],
                                ),
                              ),
                              GestureDetector(
                                onTap: () => Navigator.of(ctx).pop(HeldBillChoice(HeldBillAction.recall, h)),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
                                  decoration: BoxDecoration(color: ThemeManager.palette.teal, borderRadius: BorderRadius.circular(20)),
                                  child: Text(Loc.t('RECALL', 'ریکال'), style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                                ),
                              ),
                              const SizedBox(width: 10),
                              GestureDetector(
                                onTap: () => Navigator.of(ctx).pop(HeldBillChoice(HeldBillAction.delete, h)),
                                child: Container(
                                  width: 26,
                                  height: 26,
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(color: ThemeManager.palette.red, shape: BoxShape.circle),
                                  child: const Text('✕', style: TextStyle(color: Colors.white, fontSize: 13)),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(Loc.t('Close', 'بند کریں'), style: TextStyle(color: ThemeManager.palette.textMuted)),
            ),
          ],
        ),
      ),
    ),
  );
}
