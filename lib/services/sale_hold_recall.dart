import '../db/sale_repository.dart' show SaleLine;

/// Dart port of SaleHoldRecall.kt's encode/decode. A held bill is one string
/// (stored in `held_bills.payload`) using control-character separators:
///
///   header \u0004 items
///   header = customer \u0001 saleType \u0001 CASH|CREDIT \u0001 discount
///   items  = row \u0002 row ...
///   row    = 12 fields joined by \u0003 (barcode, name, qty, unit, unitPrice,
///            cost, amount, mainUnit, secondaryUnit, secondaryUnitQty,
///            tertiaryUnit, tertiaryUnitQty)
const _sepHeaderField = '\u0001';
const _sepRow = '\u0002';
const _sepItemField = '\u0003';
const _sepHeaderItems = '\u0004';

/// Prefix that marks a Sale hold (Purchase holds use `PHOLD`).
const String kSaleHoldPrefix = 'HOLD';

/// What a held sale restores on recall.
class HeldSaleDraft {
  final String customerName;
  final bool isWholesale;
  final bool isShopkeeper;
  final bool isCash;
  final String discountText;
  final List<SaleLine> lines;

  const HeldSaleDraft({
    required this.customerName,
    required this.isWholesale,
    this.isShopkeeper = false,
    required this.isCash,
    required this.discountText,
    required this.lines,
  });
}

String encodeHold(HeldSaleDraft d) {
  final header = [
    d.customerName,
    d.isShopkeeper ? 'Shopkeeper' : (d.isWholesale ? 'Wholesale' : 'Retail'),
    d.isCash ? 'CASH' : 'CREDIT',
    d.discountText,
  ].join(_sepHeaderField);

  final items = d.lines
      .map((l) => [
            l.barcode,
            l.itemName,
            l.qty,
            l.unit,
            l.unitPrice,
            l.cost,
            l.amount,
            l.mainUnit,
            l.secondaryUnit,
            l.secondaryUnitQty,
            l.tertiaryUnit,
            l.tertiaryUnitQty,
          ].join(_sepItemField))
      .join(_sepRow);

  return header + _sepHeaderItems + items;
}

/// Inverse of [encodeHold]. Like the Kotlin version it is forgiving: a short
/// header restores no header fields, rows with fewer than 10 fields are
/// skipped, and missing numbers become 0.
HeldSaleDraft decodeHold(String payload) {
  final parts = payload.split(_sepHeaderItems);

  var customer = '';
  var wholesale = false;
  var shopkeeper = false;
  var cash = true;
  var discount = '';
  if (parts.isNotEmpty) {
    final header = parts[0].split(_sepHeaderField);
    if (header.length >= 4) {
      customer = header[0];
      wholesale = header[1] == 'Wholesale';
      shopkeeper = header[1] == 'Shopkeeper';
      cash = header[2] != 'CREDIT';
      discount = header[3];
    }
  }

  final lines = <SaleLine>[];
  if (parts.length > 1 && parts[1].isNotEmpty) {
    for (final row in parts[1].split(_sepRow)) {
      final f = row.split(_sepItemField);
      if (f.length < 10) continue;
      double n(int i) => (i < f.length ? double.tryParse(f[i]) : null) ?? 0.0;
      lines.add(SaleLine(
        barcode: f[0],
        itemName: f[1],
        qty: n(2),
        unit: f[3],
        unitPrice: n(4),
        cost: n(5),
        amount: n(6),
        mainUnit: f[7],
        secondaryUnit: f[8],
        secondaryUnitQty: n(9),
        tertiaryUnit: f.length > 10 ? f[10] : '',
        tertiaryUnitQty: n(11),
      ));
    }
  }

  return HeldSaleDraft(
    customerName: customer,
    isWholesale: wholesale,
    isShopkeeper: shopkeeper,
    isCash: cash,
    discountText: discount,
    lines: lines,
  );
}

/// Number of items in a held payload (for the "3 items" label in the recall
/// list) without fully decoding it.
int heldItemCount(String payload) {
  final parts = payload.split(_sepHeaderItems);
  if (parts.length < 2) return 0;
  return parts[1].split(_sepRow).where((r) => r.isNotEmpty).length;
}
