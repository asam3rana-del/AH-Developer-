import 'package:flutter/material.dart';

import '../db/party_dashboard_repository.dart';
import '../theme/theme_manager.dart';
import '../utils/loc.dart';

/// Ports PartyQuickAddMenu.kt — Party Dashboard ke "+" menu ke teen hisse:
///  * [showPartyMenuSheet]  (Kotlin showPremiumMenuSheet): icon badge + title + subtitle + rows wali sheet.
///  * [PartyMenuItem]       (Kotlin QuickMenuItem).
///  * [showPartyPickerForPayment]: Payment Received (customer) / Payment Made (supplier) ke liye
///    searchable party picker; chuni hui party par `PartyTransactionScreen(openPayment: true)` khulti hai
///    (dashboard `onPicked` mein kholta hai).
///
/// Farq (Kotlin se): Kotlin picker dashboard ki `allItems` istemal karta hai — yahan wahi list
/// (`List<PartyRow>`) argument mein aati hai, alag DB query nahi.

/// Kotlin QuickMenuItem.
class PartyMenuItem {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  const PartyMenuItem(this.icon, this.color, this.title, this.subtitle, this.onTap);
}

/// Picker ki list: sirf `forCustomer` wali parties, naam (lowercase) ke hisaab se sorted; query khali
/// ho to sab, warna naam (case-insensitive) ya phone (substring) match. PURE — test ke liye.
List<PartyRow> pickerCandidates(List<PartyRow> all, {required bool forCustomer, String query = ''}) {
  final q = query.trim();
  final qLower = q.toLowerCase();
  final list = all.where((r) => r.isCustomer == forCustomer).toList()
    ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  if (q.isEmpty) return list;
  return list.where((r) => r.name.toLowerCase().contains(qLower) || r.phone.contains(q)).toList();
}

/// Kotlin showPremiumMenuSheet(): bottom sheet, height 78% par capped, rows scroll hoti hain.
Future<void> showPartyMenuSheet(
  BuildContext context, {
  required IconData icon,
  required String title,
  required String subtitle,
  required List<PartyMenuItem> items,
}) {
  final p = ThemeManager.palette;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: p.cardWhite,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (ctx) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.78),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
            child: Row(children: [
              CircleAvatar(radius: 22, backgroundColor: p.navy.withOpacity(0.13), child: Icon(icon, color: p.navy)),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: p.textDark)),
                  Text(subtitle, style: TextStyle(fontSize: 12.5, color: p.textMuted)),
                ]),
              ),
            ]),
          ),
          Divider(height: 1, thickness: 1, color: p.border),
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: items.length,
              separatorBuilder: (_, __) => Divider(height: 1, indent: 20, color: p.border),
              itemBuilder: (_, i) {
                final it = items[i];
                return ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
                  leading: CircleAvatar(
                    radius: 20,
                    // Kotlin tintBg: accent ka ~13% (#22 alpha) — dark mode mein bhi muted.
                    backgroundColor: it.color.withOpacity(0.13),
                    child: Icon(it.icon, color: it.color, size: 20),
                  ),
                  title: Text(it.title, style: TextStyle(fontWeight: FontWeight.bold, color: p.textDark)),
                  subtitle: Text(it.subtitle, style: TextStyle(fontSize: 12, color: p.textMuted)),
                  trailing: Text('\u203A', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: it.color)),
                  onTap: () {
                    Navigator.pop(ctx);
                    it.onTap();
                  },
                );
              },
            ),
          ),
        ]),
      ),
    ),
  );
}

/// Kotlin showPartyPickerForPayment(): searchable list (name ya phone); tap => [onPicked].
Future<void> showPartyPickerForPayment(
  BuildContext context, {
  required List<PartyRow> parties,
  required bool forCustomer,
  required void Function(PartyRow party) onPicked,
}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => _PartyPickerDialog(
      parties: parties,
      forCustomer: forCustomer,
      onPicked: (r) {
        Navigator.pop(ctx);
        onPicked(r);
      },
    ),
  );
}

class _PartyPickerDialog extends StatefulWidget {
  final List<PartyRow> parties;
  final bool forCustomer;
  final void Function(PartyRow) onPicked;
  const _PartyPickerDialog({required this.parties, required this.forCustomer, required this.onPicked});

  @override
  State<_PartyPickerDialog> createState() => _PartyPickerDialogState();
}

class _PartyPickerDialogState extends State<_PartyPickerDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = ThemeManager.palette;
    final forC = widget.forCustomer;
    final filtered = pickerCandidates(widget.parties, forCustomer: forC, query: _ctrl.text);
    return AlertDialog(
      title: Text(forC ? Loc.t('Payment Received', 'ادائیگی وصول ہوئی') : Loc.t('Payment Made', 'ادائیگی ہوئی')),
      contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: _ctrl,
            autofocus: false,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: forC ? Loc.t('Search customer', 'کسٹمر تلاش کریں') : Loc.t('Search supplier', 'سپلائر تلاش کریں'),
              prefixIcon: const Icon(Icons.search),
              filled: true,
              fillColor: p.fieldFill,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: BorderSide.none),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 320,
            child: filtered.isEmpty
                ? Center(
                    child: Text(
                      forC ? Loc.t('No customers found', 'کوئی کسٹمر نہیں ملا') : Loc.t('No suppliers found', 'کوئی سپلائر نہیں ملا'),
                      style: TextStyle(fontSize: 13.5, color: p.textMuted),
                    ),
                  )
                : ListView.builder(
                    itemCount: filtered.length,
                    itemBuilder: (_, i) {
                      final r = filtered[i];
                      return InkWell(
                        onTap: () => widget.onPicked(r),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 14),
                          child: Text(
                            r.name + (r.phone.trim().isNotEmpty ? '  \u00B7  ${r.phone}' : ''),
                            style: TextStyle(fontSize: 14.5, color: p.textDark),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ]),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(Loc.t('Cancel', 'منسوخ کریں')))],
    );
  }
}
