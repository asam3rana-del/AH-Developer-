import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/held_bill.dart';
import '../services/sale_hold_recall.dart';
import '../theme/app_colors.dart';

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
              color: AppColors.navy,
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
              child: const Text('Held Bills', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
            ),
            Flexible(
              child: held.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('Koi held bill nahi hai', style: TextStyle(color: AppColors.textMuted)),
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
                            color: AppColors.fieldFill,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: AppColors.border),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 30,
                                height: 30,
                                alignment: Alignment.center,
                                decoration: const BoxDecoration(color: AppColors.amber, shape: BoxShape.circle),
                                child: const Text('⏸', style: TextStyle(fontSize: 13)),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('${heldItemCount(h.payload)} items',
                                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: AppColors.textDark)),
                                    Text(fmt.format(DateTime.fromMillisecondsSinceEpoch(h.createdAt)),
                                        style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
                                  ],
                                ),
                              ),
                              GestureDetector(
                                onTap: () => Navigator.of(ctx).pop(HeldBillChoice(HeldBillAction.recall, h)),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
                                  decoration: BoxDecoration(color: AppColors.teal, borderRadius: BorderRadius.circular(20)),
                                  child: const Text('RECALL', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                                ),
                              ),
                              const SizedBox(width: 10),
                              GestureDetector(
                                onTap: () => Navigator.of(ctx).pop(HeldBillChoice(HeldBillAction.delete, h)),
                                child: Container(
                                  width: 26,
                                  height: 26,
                                  alignment: Alignment.center,
                                  decoration: const BoxDecoration(color: AppColors.red, shape: BoxShape.circle),
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
              child: const Text('Close', style: TextStyle(color: AppColors.textMuted)),
            ),
          ],
        ),
      ),
    ),
  );
}
