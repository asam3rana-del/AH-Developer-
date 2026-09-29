import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../db/purchase_repository.dart' show PurchaseLine;

/// Purchase screen ka Hold / Recall + Draft autosave (Kotlin PurchaseActivity.encodeHold / decodeHold /
/// saveDraft / restoreDraftIfAny).
///
/// Held bill = ek string (`held_bills.payload`), control-character separators:
///   header \u0004 items
///   header = supplier \u0001 supplierInvoiceNo \u0001 paidText \u0001 dateMillis
///   items  = row \u0002 row ...
///   row    = barcode \u0003 name \u0003 qty \u0003 unit \u0003 rate \u0003 amount \u0003 retailRate \u0003 wholesaleRate
///
/// Purchase holds ka `holdId` `PHOLD...` se shuru hota hai (Sale holds `HOLD...`).
const _sepHeaderField = '\u0001';
const _sepRow = '\u0002';
const _sepItemField = '\u0003';
const _sepHeaderItems = '\u0004';

const String kPurchaseHoldPrefix = 'PHOLD';
const String kPurchaseDraftPrefsKey = 'purchase_draft_json';

/// Jo cheez hold / recall ya draft mein wapas aati hai.
class PurchaseDraft {
  final String supplier;
  final String supplierInvoiceNo;
  final String paidText;

  /// 0 = date nahi likhi (draft mein aaj ki date rakhi jati hai — purani date par naya bill nahi banta).
  final int dateMillis;
  final List<PurchaseLine> lines;

  const PurchaseDraft({
    this.supplier = '',
    this.supplierInvoiceNo = '',
    this.paidText = '',
    this.dateMillis = 0,
    this.lines = const [],
  });

  bool get hasContent => lines.isNotEmpty || supplier.trim().isNotEmpty || supplierInvoiceNo.trim().isNotEmpty;
}

String encodePurchaseHold(PurchaseDraft d) {
  final header = [d.supplier, d.supplierInvoiceNo, d.paidText, d.dateMillis.toString()].join(_sepHeaderField);
  final items = d.lines
      .map((l) => [
            l.barcode ?? '',
            l.itemName,
            l.qty,
            l.unit,
            l.rate,
            l.amount,
            l.retailRate,
            l.wholesaleRate,
          ].join(_sepItemField))
      .join(_sepRow);
  return header + _sepHeaderItems + items;
}

/// [encodePurchaseHold] ka ulta. Kotlin ki tarah narm: chhota header = header fields wapas nahi aate;
/// 6 se kam fields wali rows skip; gayab numbers 0.
PurchaseDraft decodePurchaseHold(String payload) {
  final parts = payload.split(_sepHeaderItems);

  var supplier = '';
  var invoice = '';
  var paid = '';
  var date = 0;
  if (parts.isNotEmpty) {
    final header = parts[0].split(_sepHeaderField);
    if (header.length >= 3) {
      supplier = header[0];
      invoice = header[1];
      paid = header[2];
      if (header.length > 3) date = int.tryParse(header[3]) ?? 0;
    }
  }

  final lines = <PurchaseLine>[];
  if (parts.length > 1 && parts[1].isNotEmpty) {
    for (final row in parts[1].split(_sepRow)) {
      final f = row.split(_sepItemField);
      if (f.length < 6) continue;
      lines.add(PurchaseLine(
        barcode: f[0].isEmpty ? null : f[0],
        itemName: f[1],
        qty: double.tryParse(f[2]) ?? 0.0,
        unit: f[3],
        rate: double.tryParse(f[4]) ?? 0.0,
        amount: double.tryParse(f[5]) ?? 0.0,
        retailRate: f.length > 6 ? (double.tryParse(f[6]) ?? 0.0) : 0.0,
        wholesaleRate: f.length > 7 ? (double.tryParse(f[7]) ?? 0.0) : 0.0,
      ));
    }
  }
  return PurchaseDraft(supplier: supplier, supplierInvoiceNo: invoice, paidText: paid, dateMillis: date, lines: lines);
}

/// Draft ko SharedPreferences mein likhna / parhna / mitana. Edit-mode (saved bill) draft nahi
/// istemal karta.
class PurchaseDraftStore {
  PurchaseDraftStore._();

  static Future<void> save(PurchaseDraft d) async {
    final p = await SharedPreferences.getInstance();
    if (!d.hasContent) {
      await p.remove(kPurchaseDraftPrefsKey);
      return;
    }
    await p.setString(kPurchaseDraftPrefsKey, jsonEncode({'hold': encodePurchaseHold(d)}));
  }

  static Future<PurchaseDraft?> load() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(kPurchaseDraftPrefsKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final d = decodePurchaseHold((m['hold'] as String?) ?? '');
      return d.hasContent ? d : null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> clear() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(kPurchaseDraftPrefsKey);
  }
}
