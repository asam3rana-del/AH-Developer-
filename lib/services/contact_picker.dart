import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';

import '../utils/loc.dart';
import 'app_lock.dart';

/// Result of picking a phone contact (Kotlin `PartyActivity.fetchPhoneFromContact`).
class PickedContact {
  final String name;
  final String phone; // digits and '+' only
  const PickedContact({required this.name, required this.phone});
}

/// Kotlin: `number.replace(Regex("[^0-9+]"), "")`.
String cleanPhoneNumber(String raw) => raw.replaceAll(RegExp(r'[^0-9+]'), '');

/// Outcome of [ContactPicker.pick] — the UI turns each into a message.
enum ContactPickStatus { picked, cancelled, noPhone, permissionDenied, failed }

class ContactPickResult {
  final ContactPickStatus status;
  final PickedContact? contact;
  const ContactPickResult(this.status, [this.contact]);
}

class ContactPicker {
  ContactPicker._();

  /// Opens the system contact picker and returns the first phone number.
  /// The system picker itself needs no permission; READ_CONTACTS / iOS Contacts
  /// access is asked only if the picked contact comes back without its numbers.
  static Future<ContactPickResult> pick() async {
    // System contact picker khulte hi app 'paused' hoti hai; AppLock isay background samajh kar
    // wapas aane par login par bhej deta tha (saari screens hat jati thin = "app band").
    // Biometric prompt jaisa hi: picker ke dauran lock arm/consume na ho.
    AppLock.instance.suspendLock = true;
    try {
      Contact? c = await FlutterContacts.openExternalPick();
      if (c == null) return const ContactPickResult(ContactPickStatus.cancelled);
      if (c.phones.isEmpty && c.id.isNotEmpty) {
        if (!await FlutterContacts.requestPermission(readonly: true)) {
          return const ContactPickResult(ContactPickStatus.permissionDenied);
        }
        c = await FlutterContacts.getContact(c.id, withProperties: true) ?? c;
      }
      if (c.phones.isEmpty) return const ContactPickResult(ContactPickStatus.noPhone);
      final number = cleanPhoneNumber(c.phones.first.number);
      if (number.isEmpty) return const ContactPickResult(ContactPickStatus.noPhone);
      return ContactPickResult(
        ContactPickStatus.picked,
        PickedContact(name: c.displayName, phone: number),
      );
    } catch (_) {
      return const ContactPickResult(ContactPickStatus.failed);
    } finally {
      AppLock.instance.suspendLock = false;
    }
  }

  /// App ke andar apni list se contact chunna (system picker ki doosri activity nahi khulti — isi se
  /// "contact chunte hi app crash/band" wali masle se bachta hai). Permission na mile to purana system picker.
  static Future<ContactPickResult> pickInApp(BuildContext context) async {
    List<Contact> contacts;
    AppLock.instance.suspendLock = true; // permission dialog ke dauran lock arm na ho
    try {
      final granted = await FlutterContacts.requestPermission(readonly: true);
      if (!granted) {
        AppLock.instance.suspendLock = false;
        return pick(); // system picker permission ke baghair chalta hai
      }
      contacts = await FlutterContacts.getContacts(withProperties: true, withPhoto: false);
    } catch (_) {
      AppLock.instance.suspendLock = false;
      return pick();
    } finally {
      AppLock.instance.suspendLock = false;
    }
    if (!context.mounted) return const ContactPickResult(ContactPickStatus.cancelled);

    // Har number alag row (ek contact ke kai number ho sakte hain).
    final entries = <PickedContact>[];
    for (final c in contacts) {
      for (final ph in c.phones) {
        final n = cleanPhoneNumber(ph.number);
        if (n.isNotEmpty) entries.add(PickedContact(name: c.displayName, phone: n));
      }
    }
    if (entries.isEmpty) return const ContactPickResult(ContactPickStatus.noPhone);
    entries.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    final chosen = await showModalBottomSheet<PickedContact>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => _ContactListSheet(entries: entries),
    );
    if (chosen == null) return const ContactPickResult(ContactPickStatus.cancelled);
    return ContactPickResult(ContactPickStatus.picked, chosen);
  }
}

class _ContactListSheet extends StatefulWidget {
  final List<PickedContact> entries;
  const _ContactListSheet({required this.entries});

  @override
  State<_ContactListSheet> createState() => _ContactListSheetState();
}

class _ContactListSheetState extends State<_ContactListSheet> {
  final _q = TextEditingController();

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = _q.text.trim().toLowerCase();
    final list = q.isEmpty
        ? widget.entries
        : widget.entries.where((e) => e.name.toLowerCase().contains(q) || e.phone.contains(q)).toList();
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.8,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: TextField(
              controller: _q,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: Loc.t('Search contact (name or number)', 'رابطہ تلاش کریں (نام یا نمبر)'),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          Expanded(
            child: list.isEmpty
                ? Center(child: Text(Loc.t('No contact found', 'کوئی رابطہ نہیں ملا')))
                : ListView.builder(
                    itemCount: list.length,
                    itemBuilder: (_, i) {
                      final e = list[i];
                      return ListTile(
                        leading: const Icon(Icons.person_outline),
                        title: Text(e.name.isEmpty ? e.phone : e.name),
                        subtitle: e.name.isEmpty ? null : Text(e.phone),
                        onTap: () => Navigator.pop(context, e),
                      );
                    },
                  ),
          ),
        ]),
      ),
    );
  }
}
