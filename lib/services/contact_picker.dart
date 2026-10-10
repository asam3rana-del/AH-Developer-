import 'package:flutter_contacts/flutter_contacts.dart';

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
}
