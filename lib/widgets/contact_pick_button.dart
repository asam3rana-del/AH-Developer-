import 'package:flutter/material.dart';

import '../services/contact_picker.dart';
import '../utils/loc.dart';

/// Har phone field ke saath 📇 button: phone ke contacts se number chun kar [phone] mein bhar deta hai.
/// [name] diya ho aur khali ho to contact ka naam bhi bhar deta hai (pehle se likha naam nahi badalta).
///
/// Istemaal: `decoration: InputDecoration(..., suffixIcon: ContactPickButton(phone: ctrl))`.
class ContactPickButton extends StatelessWidget {
  final TextEditingController phone;
  final TextEditingController? name;
  final Color? color;

  const ContactPickButton({super.key, required this.phone, this.name, this.color});

  Future<void> _pick(BuildContext context) async {
    final r = await ContactPicker.pickInApp(context);
    if (!context.mounted) return;
    String? msg;
    switch (r.status) {
      case ContactPickStatus.picked:
        final c = r.contact!;
        phone.text = c.phone;
        phone.selection = TextSelection.collapsed(offset: c.phone.length);
        final n = name;
        if (n != null && n.text.trim().isEmpty && c.name.trim().isNotEmpty) n.text = c.name.trim();
        break;
      case ContactPickStatus.cancelled:
        break;
      case ContactPickStatus.noPhone:
        msg = Loc.t('No phone number for this contact', 'اس رابطے کا کوئی نمبر نہیں');
        break;
      case ContactPickStatus.permissionDenied:
        msg = Loc.t('Contacts permission denied', 'رابطوں کی اجازت مسترد');
        break;
      case ContactPickStatus.failed:
        msg = Loc.t("Couldn't open contacts", 'رابطے نہیں کھل سکے');
        break;
    }
    if (msg != null) {
      ScaffoldMessenger.maybeOf(context)
        ?..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  @override
  Widget build(BuildContext context) => IconButton(
        icon: Icon(Icons.contacts, color: color ?? Theme.of(context).colorScheme.primary),
        tooltip: Loc.t('Pick from contacts', 'رابطوں سے چنیں'),
        onPressed: () => _pick(context),
      );
}
