import 'bill_text.dart';
import '../db/sale_repository.dart' show SaleLine;

/// One printed bill row (sale ya purchase dono ke liye).
class BillItem {
  final String name;
  final double qty;
  final String unit;
  final double rate;
  final double amount;
  const BillItem({required this.name, required this.qty, required this.unit, required this.rate, required this.amount});
}

/// Bill Preview / Print / WhatsApp ka saara data ek jagah.
/// Kotlin BillPreviewActivity ke intent extras ka Dart version.
class BillDoc {
  final bool isPurchase;
  final String shopName;
  final String shopPhone;
  final String receiptFooter;

  /// Invoice no (sale) ya Bill no (purchase).
  final String ref;
  final String partyName;
  final String partyPhone;
  final int? partyId;
  final DateTime date;
  final List<BillItem> items;
  final double subtotal;
  final double discount;
  final double total;
  final double paid;
  final String paymentMethod;

  const BillDoc({
    required this.isPurchase,
    required this.ref,
    required this.date,
    required this.items,
    required this.subtotal,
    required this.discount,
    required this.total,
    required this.paid,
    this.shopName = '',
    this.shopPhone = '',
    this.receiptFooter = '',
    this.partyName = '',
    this.partyPhone = '',
    this.partyId,
    this.paymentMethod = 'Cash',
  });

  double get balance => total - paid;

  BillDoc copyWith({String? shopName, String? shopPhone, String? receiptFooter, String? partyPhone}) => BillDoc(
        isPurchase: isPurchase,
        ref: ref,
        date: date,
        items: items,
        subtotal: subtotal,
        discount: discount,
        total: total,
        paid: paid,
        shopName: shopName ?? this.shopName,
        shopPhone: shopPhone ?? this.shopPhone,
        receiptFooter: receiptFooter ?? this.receiptFooter,
        partyName: partyName,
        partyPhone: partyPhone ?? this.partyPhone,
        partyId: partyId,
        paymentMethod: paymentMethod,
      );

  /// Plain 32-column text (Copy / WhatsApp).
  String toText({double? netBalance}) {
    if (isPurchase) {
      return buildPurchaseBillText(
        shopName: shopName,
        shopPhone: shopPhone,
        billNo: ref,
        date: date,
        supplier: partyName,
        lines: [for (final i in items) (name: i.name, qty: i.qty, unit: i.unit, unitCost: i.rate, amount: i.amount)],
        subtotal: subtotal,
        discount: discount,
        total: total,
        paid: paid,
        paymentMethod: paymentMethod,
        netBalance: netBalance,
      );
    }
    return buildSaleBillText(
      shopName: shopName,
      shopPhone: shopPhone,
      invoice: ref,
      date: date,
      customer: partyName,
      lines: [
        for (final i in items)
          SaleLine(itemName: i.name, barcode: '', qty: i.qty, unit: i.unit, unitPrice: i.rate, cost: 0, amount: i.amount),
      ],
      subtotal: subtotal,
      discount: discount,
      total: total,
      paid: paid,
      paymentMethod: paymentMethod,
      netBalance: netBalance,
    );
  }
}
