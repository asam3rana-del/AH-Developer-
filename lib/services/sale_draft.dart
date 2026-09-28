import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../db/sale_repository.dart' show SaleLine;

/// Draft autosave for the New Sale screen (SaleActivity.saveDraft /
/// restoreDraftIfAny). If the app is closed mid-bill the whole bill comes
/// back on next open. Edit-mode (a saved invoice) never uses drafts.
///
/// The draft's date is deliberately NOT stored: restoring a days-old date
/// silently stamped new bills with a stale date in Kotlin (FIX noted in
/// SaleActivity.restoreDraftIfAny), so a restored bill is always dated "now".
const String kSaleDraftPrefsKey = 'sale_draft_json';

class SaleDraft {
  final String customer;
  final bool isWholesale;
  final String discount;
  final String paid;
  final String pendingItemName;
  final String pendingQty;
  final String pendingPrice;
  final List<SaleLine> lines;

  const SaleDraft({
    this.customer = '',
    this.isWholesale = false,
    this.discount = '',
    this.paid = '',
    this.pendingItemName = '',
    this.pendingQty = '',
    this.pendingPrice = '',
    this.lines = const [],
  });

  /// Kotlin only saves when something was actually typed.
  bool get hasContent =>
      lines.isNotEmpty ||
      customer.trim().isNotEmpty ||
      pendingItemName.trim().isNotEmpty ||
      pendingQty.trim().isNotEmpty ||
      pendingPrice.trim().isNotEmpty;

  /// Something worth telling the user about after a restore.
  bool get worthAnnouncing => lines.isNotEmpty || pendingItemName.trim().isNotEmpty;
}

String encodeSaleDraft(SaleDraft d) => jsonEncode({
      'customer': d.customer,
      'saleType': d.isWholesale ? 'Wholesale' : 'Retail',
      'discount': d.discount,
      'paid': d.paid,
      'pendingItemName': d.pendingItemName,
      'pendingQty': d.pendingQty,
      'pendingPrice': d.pendingPrice,
      'lines': d.lines
          .map((l) => {
                'barcode': l.barcode,
                'itemName': l.itemName,
                'qty': l.qty,
                'unit': l.unit,
                'unitPrice': l.unitPrice,
                'cost': l.cost,
                'amount': l.amount,
                'mainUnit': l.mainUnit,
                'secondaryUnit': l.secondaryUnit,
                'secondaryUnitQty': l.secondaryUnitQty,
                'tertiaryUnit': l.tertiaryUnit,
                'tertiaryUnitQty': l.tertiaryUnitQty,
              })
          .toList(),
    });

double _d(Object? v) => v is num ? v.toDouble() : (double.tryParse('$v') ?? 0.0);
String _s(Object? v) => v is String ? v : '';

/// Null when [raw] is not a readable draft (corrupt prefs must never crash
/// the Sale screen).
SaleDraft? decodeSaleDraft(String raw) {
  try {
    final o = jsonDecode(raw);
    if (o is! Map) return null;
    final rawLines = o['lines'];
    final lines = <SaleLine>[];
    if (rawLines is List) {
      for (final e in rawLines) {
        if (e is! Map) continue;
        lines.add(SaleLine(
          barcode: _s(e['barcode']),
          itemName: _s(e['itemName']),
          qty: _d(e['qty']),
          unit: _s(e['unit']),
          unitPrice: _d(e['unitPrice']),
          cost: _d(e['cost']),
          amount: _d(e['amount']),
          mainUnit: _s(e['mainUnit']),
          secondaryUnit: _s(e['secondaryUnit']),
          secondaryUnitQty: _d(e['secondaryUnitQty']),
          tertiaryUnit: _s(e['tertiaryUnit']),
          tertiaryUnitQty: _d(e['tertiaryUnitQty']),
        ));
      }
    }
    return SaleDraft(
      customer: _s(o['customer']),
      isWholesale: _s(o['saleType']) == 'Wholesale',
      discount: _s(o['discount']),
      paid: _s(o['paid']),
      pendingItemName: _s(o['pendingItemName']),
      pendingQty: _s(o['pendingQty']),
      pendingPrice: _s(o['pendingPrice']),
      lines: lines,
    );
  } catch (_) {
    return null;
  }
}

class SaleDraftStore {
  SaleDraftStore._();

  /// Empty draft = nothing to keep, so the stored one is removed (same as
  /// Kotlin's `if (!hasContent) clearDraft()`).
  static Future<void> save(SaleDraft d) async {
    final p = await SharedPreferences.getInstance();
    if (!d.hasContent) {
      await p.remove(kSaleDraftPrefsKey);
      return;
    }
    await p.setString(kSaleDraftPrefsKey, encodeSaleDraft(d));
  }

  static Future<SaleDraft?> load() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(kSaleDraftPrefsKey);
    if (raw == null) return null;
    return decodeSaleDraft(raw);
  }

  static Future<void> clear() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(kSaleDraftPrefsKey);
  }
}
