import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../db/due_followup_repository.dart';
import '../db/due_reminders_repository.dart';
import '../models/due_followup.dart';
import '../screens/payments_screen.dart' show showPaymentDialog;
import '../utils/loc.dart';

/// Wasooli ke 1-tap kaam (dashboard card + Receivables screen dono yahin se):
///  * [receiveFromParty] — "Paisa mila": usi payment dialog se payment likho (bill / cash-bank / date), phir
///    follow-up log mein khud "paid" (ya "partial") entry — taake toota wada / follow-up saaf ho jaye.
///  * [sendReminderTo] — WhatsApp reminder (message party ki halat ke hisaab se) + log entry.
///
/// Koi bhi ghalti app ko nahi rokti; log likhne mein masla ho to payment phir bhi mehfooz rehti hai.

/// Customer se paisa mila. true = payment save hui.
Future<bool> receiveFromParty(
  BuildContext context, {
  required int partyId,
  required String partyName,
  required double due,
}) async {
  final saved = await showPaymentDialog(context, isCustomer: true, partyId: partyId, partyName: partyName, due: due);
  if (!saved) return false;
  try {
    // Payment ke baad party ka naya baqi dekh kar likho kitna mila aur poora chuka ya nahi.
    var after = 0.0;
    for (final b in await DueRemindersRepository.instance.dueSales()) {
      if (b.partyId == partyId && !b.isAdvance) after += b.due;
    }
    final received = due - after;
    await DueFollowUpRepository.instance.add(
      partyId: partyId,
      partyName: partyName,
      method: FollowUpMethod.note,
      outcome: after <= 0.009 ? FollowUpOutcome.paid : FollowUpOutcome.partial,
      amount: received > 0 ? received : 0,
      note: 'Paisa mila',
    );
  } catch (_) {}
  return true;
}

/// WhatsApp reminder (aur log entry). true = WhatsApp khul gaya.
Future<bool> sendReminderTo(BuildContext context, DueParty g) async {
  final messenger = ScaffoldMessenger.of(context);
  final id = g.partyId;
  try {
    final entries = id == null ? const <DueFollowUp>[] : await DueFollowUpRepository.instance.forParty(id);
    final ok = await launchUrl(reminderUriFor(g, entries), mode: LaunchMode.externalApplication);
    if (!ok) throw Exception('launch failed');
    if (id != null) {
      await DueFollowUpRepository.instance
          .add(partyId: id, partyName: g.partyName, method: FollowUpMethod.whatsapp, outcome: FollowUpOutcome.sent);
    }
    return true;
  } catch (_) {
    messenger.showSnackBar(SnackBar(content: Text(Loc.t('Could not open WhatsApp', 'واٹس ایپ نہیں کھل سکا'))));
    return false;
  }
}
