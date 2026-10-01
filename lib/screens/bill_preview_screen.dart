import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../db/customer_repository.dart';
import '../db/due_reminders_repository.dart' show whatsAppDigits;
import '../db/party_repository.dart';
import '../db/supplier_repository.dart';
import '../db/user_repository.dart';
import '../services/printer_service.dart';
import '../utils/bill_doc.dart';
import '../utils/loc.dart';
import '../theme/theme_manager.dart';

/// Kotlin BillPreviewActivity: bill ka receipt-jaisa preview + PRINT (Bluetooth), WhatsApp par bhejein,
/// DONE, aur (naye bill ke baad) "+ NAYI SALE / PURCHASE BILL".
/// Pop result: 'new' agar "+ NAYA BILL" dabaya, warna null.
class BillPreviewScreen extends StatefulWidget {
  final BillDoc doc;
  final bool showNewBill;

  /// true => bill abhi save hui hai: Prev/Net balance party ke current ledger se (backdated bill par bhi).
  final bool justSaved;
  const BillPreviewScreen({super.key, required this.doc, this.showNewBill = false, this.justSaved = false});

  /// Sab call sites yahi istemal karte hain.
  static Future<String?> open(BuildContext context, BillDoc doc, {bool showNewBill = false, bool justSaved = false}) =>
      Navigator.of(context).push<String>(
          MaterialPageRoute(builder: (_) => BillPreviewScreen(doc: doc, showNewBill: showNewBill, justSaved: justSaved)));

  @override
  State<BillPreviewScreen> createState() => _BillPreviewScreenState();
}

class _BillPreviewScreenState extends State<BillPreviewScreen> {
  late BillDoc _doc = widget.doc;
  int? _partyId;
  double? _net; // Net Balance = bill ke waqt ka Prev Balance + is bill ka due
  bool _printing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    var d = widget.doc;
    try {
      final repo = UserRepository.instance;
      d = d.copyWith(
        shopName: d.shopName.isEmpty ? (await repo.getSetting('shop_name')) ?? '' : d.shopName,
        shopPhone: d.shopPhone.isEmpty ? (await repo.getSetting('shop_phone')) ?? '' : d.shopPhone,
        receiptFooter: (await repo.getSetting('receipt_footer')) ?? '',
      );
      final name = d.partyName.trim().toLowerCase();
      if (name.isNotEmpty) {
        if (d.isPurchase) {
          final s = (await SupplierRepository.instance.listAll()).where((x) => x.name.trim().toLowerCase() == name).firstOrNull;
          if (s?.id != null) {
            _partyId = s!.id;
            d = d.copyWith(partyPhone: d.partyPhone.isEmpty ? s.phone : d.partyPhone);
            _net = widget.justSaved
                ? await PartyRepository.instance.closingBalance(isCustomer: false, partyId: s.id!)
                : (await PartyRepository.instance.balanceBeforeBill(
                        isCustomer: false, partyId: s.id!, billRef: d.ref, billDate: d.date)) +
                    d.balance;
          }
        } else {
          final c = (await CustomerRepository.instance.listAll()).where((x) => x.name.trim().toLowerCase() == name).firstOrNull;
          if (c?.id != null) {
            _partyId = c!.id;
            d = d.copyWith(partyPhone: d.partyPhone.isEmpty ? c.phone : d.partyPhone);
            _net = widget.justSaved
                ? await PartyRepository.instance.closingBalance(isCustomer: true, partyId: c.id!)
                : (await PartyRepository.instance.balanceBeforeBill(
                        isCustomer: true, partyId: c.id!, billRef: d.ref, billDate: d.date)) +
                    d.balance;
          }
        }
      }
    } catch (_) {}
    if (mounted) setState(() => _doc = d);
  }

  void _toast(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _print() async {
    if (_printing) return;
    setState(() => _printing = true);
    try {
      // netBalance sirf tab jab party mili ho (BillDoc.partyId ke bina footer mein nahi aata).
      final doc = _partyId == null ? _doc : _withPartyId(_doc, _partyId!);
      final err = await PrinterService.instance.printBill(doc, netBalance: _net);
      if (!mounted) return;
      _toast(err ?? Loc.t('Printed', 'پرنٹ ہو گیا'));
    } catch (e) {
      if (mounted) _toast('Print: $e');
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }

  BillDoc _withPartyId(BillDoc d, int id) => BillDoc(
        isPurchase: d.isPurchase,
        ref: d.ref,
        date: d.date,
        items: d.items,
        subtotal: d.subtotal,
        discount: d.discount,
        total: d.total,
        paid: d.paid,
        shopName: d.shopName,
        shopPhone: d.shopPhone,
        receiptFooter: d.receiptFooter,
        partyName: d.partyName,
        partyPhone: d.partyPhone,
        partyId: id,
        paymentMethod: d.paymentMethod,
      );

  Future<void> _whatsApp() async {
    var phone = _doc.partyPhone.trim();
    if (phone.isEmpty) {
      final ctrl = TextEditingController();
      final entered = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(Loc.t('WhatsApp number', 'واٹس ایپ نمبر')),
          content: TextField(
            controller: ctrl,
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
      phone = entered;
    }
    final digits = whatsAppDigits(phone);
    if (digits.isEmpty) return _toast(Loc.t('Invalid number', 'نمبر درست نہیں'));
    final uri = Uri.parse('https://wa.me/$digits?text=${Uri.encodeComponent(_doc.toText(netBalance: _partyId == null ? null : _net))}');
    try {
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        await Clipboard.setData(ClipboardData(text: _doc.toText(netBalance: _partyId == null ? null : _net)));
        _toast(Loc.t('WhatsApp not found — bill copied', 'واٹس ایپ نہیں ملا — بل کاپی ہو گیا'));
      }
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: _doc.toText(netBalance: _partyId == null ? null : _net)));
      _toast(Loc.t('Bill copied', 'بل کاپی ہو گیا'));
    }
  }

  String _m(double v) => 'Rs ${v.toStringAsFixed(2)}';
  String _q(double v) => v == v.truncateToDouble() ? v.toInt().toString() : v.toString();

  Widget _kv(String k, String v, {bool bold = false, Color? color}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Expanded(child: Text(k, style: TextStyle(fontWeight: bold ? FontWeight.bold : FontWeight.normal, fontSize: 14))),
          Text(v, style: TextStyle(fontWeight: bold ? FontWeight.bold : FontWeight.normal, fontSize: 14, color: color ?? ThemeManager.palette.textDark)),
        ]),
      );

  Widget _btn(String label, IconData icon, Color color, VoidCallback? onTap) => SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: onTap,
          icon: Icon(icon, size: 18),
          label: Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
          style: FilledButton.styleFrom(backgroundColor: color, padding: const EdgeInsets.symmetric(vertical: 14)),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final d = _doc;
    final due = d.total - d.paid;
    final title = d.isPurchase ? Loc.t('Purchase Bill', 'خریداری بل') : Loc.t('Bill Preview', 'بل پری ویو');
    return Scaffold(
      backgroundColor: ThemeManager.palette.bg,
      appBar: AppBar(backgroundColor: ThemeManager.palette.navy, foregroundColor: Colors.white, title: Text(title)),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: ThemeManager.palette.cardWhite,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: ThemeManager.palette.border),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(d.shopName.trim().isEmpty ? 'IBTISAAM Kiryana Store' : d.shopName.trim(),
                textAlign: TextAlign.center, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: ThemeManager.palette.navyInk)),
            if (d.shopPhone.trim().isNotEmpty)
              Text('📞 ${d.shopPhone.trim()}', textAlign: TextAlign.center, style: TextStyle(color: ThemeManager.palette.textMuted, fontSize: 12)),
            const Divider(height: 20),
            _kv(d.isPurchase ? 'Bill No' : 'Invoice', d.ref),
            _kv('Date', '${d.date.day.toString().padLeft(2, '0')}/${d.date.month.toString().padLeft(2, '0')}/${d.date.year}'),
            _kv(d.isPurchase ? 'Supplier' : 'Customer',
                d.partyName.trim().isEmpty ? (d.isPurchase ? 'Cash Purchase' : 'Walk-in') : d.partyName.trim()),
            const Divider(height: 20),
            Row(children: const [
              Expanded(flex: 4, child: Text('ITEM', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
              Expanded(flex: 2, child: Text('QTY', textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
              Expanded(flex: 2, child: Text('RATE', textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
              Expanded(flex: 3, child: Text('AMOUNT', textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
            ]),
            const SizedBox(height: 6),
            for (final i in d.items)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(flex: 4, child: Text(i.name, style: const TextStyle(fontSize: 13))),
                  Expanded(flex: 2, child: Text('${_q(i.qty)} ${i.unit}', textAlign: TextAlign.right, style: const TextStyle(fontSize: 13))),
                  Expanded(flex: 2, child: Text(i.rate.toStringAsFixed(2), textAlign: TextAlign.right, style: const TextStyle(fontSize: 13))),
                  Expanded(flex: 3, child: Text(i.amount.toStringAsFixed(2), textAlign: TextAlign.right, style: const TextStyle(fontSize: 13))),
                ]),
              ),
            const Divider(height: 20),
            _kv('Subtotal', _m(d.subtotal)),
            if (d.discount > 0.009) _kv('Discount', '-${_m(d.discount)}'),
            _kv('Total', _m(d.total), bold: true),
            _kv('Paid (${d.paymentMethod})', _m(d.paid)),
            if (due > 0.009) _kv('Balance Due', _m(due), color: ThemeManager.palette.red),
            if (_partyId != null && _net != null) ...[
              _kv('Prev Balance', _m(_net! - due)),
              _kv('Net Balance', _m(_net!), bold: true, color: _net! > 0.009 ? ThemeManager.palette.red : ThemeManager.palette.textDark),
            ],
            const SizedBox(height: 10),
            Text(d.receiptFooter.trim().isEmpty ? 'Shukriya! Dobara tashreef layen.' : d.receiptFooter.trim(),
                textAlign: TextAlign.center, style: TextStyle(color: ThemeManager.palette.textMuted, fontSize: 12)),
          ]),
        ),
        const SizedBox(height: 16),
        _btn(_printing ? Loc.t('Printing…', 'پرنٹ ہو رہا ہے…') : Loc.t('PRINT', 'پرنٹ'), Icons.print, ThemeManager.palette.blue, _printing ? null : _print),
        const SizedBox(height: 10),
        _btn(Loc.t('WhatsApp par bhejein', 'واٹس ایپ پر بھیجیں'), Icons.send, const Color(0xFF25D366), _whatsApp),
        const SizedBox(height: 10),
        _btn(Loc.t('COPY TEXT', 'ٹیکسٹ کاپی'), Icons.copy, ThemeManager.palette.navyLight, () async {
          await Clipboard.setData(ClipboardData(text: d.toText(netBalance: _partyId == null ? null : _net)));
          _toast(Loc.t('Bill copied', 'بل کاپی ہو گیا'));
        }),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: _btn(Loc.t('DONE', 'مکمل'), Icons.check, ThemeManager.palette.teal, () => Navigator.of(context).pop())),
        ]),
        if (widget.showNewBill) ...[
          const SizedBox(height: 10),
          _btn(d.isPurchase ? Loc.t('+ NAYA PURCHASE BILL', '+ نیا خریداری بل') : Loc.t('+ NAYI SALE BILL', '+ نیا سیل بل'),
              Icons.add, ThemeManager.palette.navyInk, () => Navigator.of(context).pop('new')),
        ],
        const SizedBox(height: 30),
      ]),
    );
  }
}
