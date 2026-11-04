import 'package:intl/intl.dart';

/// Slip / bill ke header aur Payment Received / Payment Made ki WhatsApp slip ka text.
/// Sab PURE functions hain (DB / UI nahi) taake test ho sakein.

/// [t] ko [width] columns mein center karta hai (monospace maan kar). Lamba ho to jaisa hai waisa.
String centerText(String t, {int width = 32}) {
  final s = t.trim();
  if (s.length >= width) return s;
  return ' ' * ((width - s.length) ~/ 2) + s;
}

/// WhatsApp mein ``` ke andar ka text monospace dikhta hai, is liye centering wahan theek nazar aati hai.
/// Shop ka naam aur phone center mein (khali ho to chhod diya jata hai). Dono khali => ''.
String slipHeaderBlock({required String shopName, String shopPhone = '', int width = 32}) {
  final lines = <String>[
    if (shopName.trim().isNotEmpty) centerText(shopName, width: width),
    if (shopPhone.trim().isNotEmpty) centerText(shopPhone, width: width),
  ];
  if (lines.isEmpty) return '';
  return '```\n${lines.join('\n')}\n```\n';
}

/// Bill ke text (buildSaleBillText / buildPurchaseBillText) ka upar wala header hissa (pehli '-----' line se
/// pehle ki lines) WhatsApp ke liye monospace block bana deta hai. Rule line na mile to text jaisa hai waisa.
String wrapBillHeaderForWhatsApp(String billText) {
  final lines = billText.split('\n');
  final i = lines.indexWhere((l) => l.startsWith('--------'));
  if (i <= 0) return billText;
  final header = lines.sublist(0, i).join('\n');
  if (header.trim().isEmpty) return billText;
  return '```\n$header\n```\n${lines.sublist(i).join('\n')}';
}

/// Payment Received (customer) / Payment Made (supplier) ki slip. [balanceNow] = us waqt party ka baqi
/// (customer: +ve = customer ne dena hai; supplier: +ve = humne dena hai), null ho to nahi likha jata.
String buildPaymentSlipText({
  required bool received,
  required String shopName,
  String shopPhone = '',
  required String partyName,
  required double amount,
  required DateTime date,
  String method = '',
  String billRef = '',
  String note = '',
  String? slipNo,
  double? balanceNow,
}) {
  final b = StringBuffer();
  b.write(slipHeaderBlock(shopName: shopName, shopPhone: shopPhone));
  b.writeln(received ? 'PAYMENT RECEIVED' : 'PAYMENT MADE');
  b.writeln('--------------------------');
  if (slipNo != null && slipNo.isNotEmpty) b.writeln('Slip: $slipNo');
  b.writeln('${received ? 'Customer' : 'Supplier'}: ${partyName.trim().isEmpty ? '-' : partyName.trim()}');
  b.writeln('Date: ${DateFormat('dd/MM/yyyy hh:mm a').format(date)}');
  b.writeln('Amount: Rs ${amount.round()}');
  if (method.trim().isNotEmpty) b.writeln('Method: ${method.trim().toUpperCase()}');
  if (billRef.trim().isNotEmpty) b.writeln('Against Bill: ${billRef.trim()}');
  if (note.trim().isNotEmpty) b.writeln('Note: ${note.trim()}');
  if (balanceNow != null) {
    b.writeln('--------------------------');
    if (balanceNow.abs() < 0.5) {
      b.writeln('Balance now: Rs 0');
    } else if (received) {
      b.writeln(balanceNow > 0 ? 'Balance due: Rs ${balanceNow.round()}' : 'Advance with us: Rs ${(-balanceNow).round()}');
    } else {
      b.writeln(balanceNow > 0 ? 'Balance payable: Rs ${balanceNow.round()}' : 'Advance with you: Rs ${(-balanceNow).round()}');
    }
  }
  b.writeln('--------------------------');
  b.writeln('Thank you!');
  return b.toString();
}
