import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../db/due_reminders_repository.dart' show whatsAppDigits;
import '../db/user_repository.dart';
import '../utils/loc.dart';

/// Dukaan ka naam aur phone (Settings se) — har slip / bill ke header ke liye.
class ShopHeader {
  final String name;
  final String phone;
  const ShopHeader(this.name, this.phone);
}

Future<ShopHeader> loadShopHeader() async {
  try {
    final name = (await UserRepository.instance.getSetting('shop_name'))?.trim() ?? '';
    final phone = (await UserRepository.instance.getSetting('shop_phone'))?.trim() ?? '';
    return ShopHeader(name, phone);
  } catch (_) {
    return const ShopHeader('', '');
  }
}

/// [text] seedha [phone] ke WhatsApp chat mein (wa.me). Number khali ho to poochta hai. WhatsApp na khule to
/// text clipboard mein copy ho jata hai. Daily Bill / Bill Preview wala hi tareeqa, sab slips ke liye ek jagah.
Future<void> sendOnWhatsApp(BuildContext context, {required String phone, required String text}) async {
  final messenger = ScaffoldMessenger.of(context);
  var number = phone.trim();
  if (number.isEmpty) {
    final ctrl = TextEditingController();
    final entered = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(Loc.t('WhatsApp number', 'واٹس ایپ نمبر')),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.phone,
          decoration: const InputDecoration(hintText: '03001234567'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(Loc.t('Cancel', 'منسوخ'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: Text(Loc.t('Send', 'بھیجیں'))),
        ],
      ),
    );
    ctrl.dispose();
    if (entered == null || entered.isEmpty) return;
    number = entered;
  }
  final digits = whatsAppDigits(number);
  if (digits.isEmpty) {
    messenger.showSnackBar(SnackBar(content: Text(Loc.t('Invalid number', 'نمبر درست نہیں'))));
    return;
  }
  final uri = Uri.parse('https://wa.me/$digits?text=${Uri.encodeComponent(text)}');
  try {
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      await Clipboard.setData(ClipboardData(text: text));
      messenger.showSnackBar(SnackBar(content: Text(Loc.t('WhatsApp not found — copied', 'واٹس ایپ نہیں ملا — کاپی ہو گیا'))));
    }
  } catch (_) {
    await Clipboard.setData(ClipboardData(text: text));
    messenger.showSnackBar(SnackBar(content: Text(Loc.t('Copied', 'کاپی ہو گیا'))));
  }
}
