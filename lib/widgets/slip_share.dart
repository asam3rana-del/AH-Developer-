import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../db/due_reminders_repository.dart' show whatsAppDigits;
import '../services/slip_pdf_service.dart';
import '../services/whatsapp_pdf.dart';
import '../utils/loc.dart';
import '../utils/slip_pdf_data.dart';

/// Slip ka PDF banao aur share sheet mein kholo — sab screens ke liye ek hi jagah.
/// - Progress dialog sheet ke upar (root navigator) dikhta hai.
/// - PDF ban jaye to progress dialog pehle band hota hai, phir share sheet khulti hai.
/// - PDF na ban sake to [fallbackText] clipboard par copy hota hai aur error dialog (trace ke saath) dikhta hai.
bool _slipBusy = false;

Future<bool> shareSlip(
  BuildContext context,
  SlipPdfData data, {
  String? fileBase,
  String? fileName,
  String? fallbackText,
  String? whatsappPhone,
}) =>
    _runSlipPdf(
      context,
      () => SlipPdfService.save(data, fileBase: fileBase, fileName: fileName ?? slipAutoFileName(data)),
      subject: data.title,
      fallbackText: fallbackText,
      whatsappPhone: whatsappPhone,
    );

/// Kai slips ek PDF mein (jaise poore din ke sab customers) — share sheet se.
Future<bool> shareSlips(
  BuildContext context,
  List<SlipPdfData> data, {
  required String fileBase,
  String? fileName,
  String subject = 'Bills',
}) =>
    _runSlipPdf(context, () => SlipPdfService.saveMany(data, fileBase: fileBase, fileName: fileName), subject: subject);

/// [whatsappPhone] diya ho (Android) to PDF seedha usi number ki WhatsApp chat mein khulti hai; warna / na ho sake
/// to aam share sheet. Kamyab => true (share sheet khul gayi ya chat khul gayi).
Future<bool> _runSlipPdf(
  BuildContext context,
  Future<File> Function() make, {
  required String subject,
  String? fallbackText,
  String? whatsappPhone,
}) async {
  if (_slipBusy) return false; // dobara dabane se kai PDF ek saath na banein
  _slipBusy = true;
  final nav = Navigator.of(context, rootNavigator: true);
  Rect? origin;
  final box = context.findRenderObject();
  if (box is RenderBox && box.hasSize) {
    origin = box.localToGlobal(Offset.zero) & box.size;
  }
  var progressOpen = true;
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    useRootNavigator: true,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(children: [
          const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 3)),
          const SizedBox(width: 16),
          Expanded(child: Text(Loc.t('Creating PDF...', 'پی ڈی ایف بن رہی ہے...'))),
        ]),
      ),
    ),
  );
  void closeProgress() {
    if (progressOpen && nav.canPop()) nav.pop();
    progressOpen = false;
  }

  Object? error;
  StackTrace? stack;
  try {
    final file = await make().timeout(const Duration(seconds: 90));
    closeProgress(); // share sheet se pehle dialog hat jaye
    final digits = whatsappPhone == null ? '' : whatsAppDigits(whatsappPhone);
    final direct = digits.isNotEmpty && await WhatsAppPdf.send(file, digits);
    if (!direct) await SlipPdfService.shareFile(file, subject: subject, origin: origin);
  } catch (e, st) {
    error = e;
    stack = st;
    debugPrint('Slip PDF failed: $e\n$st');
  } finally {
    closeProgress();
    _slipBusy = false;
  }
  if (error == null) return true;

  var copied = false;
  if (fallbackText != null) {
    try {
      await Clipboard.setData(ClipboardData(text: fallbackText));
      copied = true;
    } catch (_) {}
  }
  if (!context.mounted) return false;
  final trace = stack.toString().split('\n').take(6).join('\n');
  await showDialog<void>(
    context: context,
    useRootNavigator: true,
    builder: (ctx) => AlertDialog(
      title: Text(Loc.t('PDF could not be created', 'پی ڈی ایف نہیں بن سکی')),
      content: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          SelectableText('$error'),
          if (copied) ...[
            const SizedBox(height: 10),
            Text(Loc.t('The text was copied — paste it in WhatsApp.', 'ٹیکسٹ کاپی ہو گیا — واٹس ایپ میں پیسٹ کریں۔')),
          ],
          const SizedBox(height: 10),
          SelectableText(trace, style: const TextStyle(fontSize: 10, color: Colors.grey)),
        ]),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
    ),
  );
  return false;
}
