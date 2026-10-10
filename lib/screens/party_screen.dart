import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../db/customer_repository.dart';
import '../db/party_repository.dart';
import '../db/supplier_repository.dart';
import '../models/party.dart';
import '../services/contact_picker.dart';
import '../services/session.dart';
import '../theme/theme_manager.dart';
import '../utils/input_validation.dart';
import '../utils/loc.dart';

/// Mirrors PartyActivity.kt — "Customers & Suppliers": add / edit / delete, search, "Dues only",
/// tap-for-history, call, plus the maintenance chips (Fix Balances, Merge Duplicates, Cleanup
/// Payments, Cleanup Orphaned). Sab roles (same as Kotlin).
///
/// Closing figure HAMESHA live ledger balance se aata hai (PartyRepository.liveCustomerBalances),
/// stored `balance` se nahi. Stuck balance ka field sirf admin/manager ko nazar aata hai (aur
/// PartyRepository bhi cashier ke liye ise ignore karta hai).
///
/// Baaki (Phase 6 ke agle screens): party par tap abhi history dialog kholta hai; Party Dashboard /
/// Party Transaction screens port hone par yahan se link honge.
class PartyScreen extends StatefulWidget {
  const PartyScreen({super.key});

  @override
  State<PartyScreen> createState() => _PartyScreenState();
}

class _PartyScreenState extends State<PartyScreen> with WidgetsBindingObserver {
  bool _showingCustomers = true;
  List<Customer> _customers = const [];
  List<Supplier> _suppliers = const [];
  Map<int, double> _customerBalances = const {};
  Map<int, double> _supplierBalances = const {};

  String _query = '';
  bool _duesOnly = false;
  bool _busy = false; // double-tap guard (save + maintenance actions)

  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _credit = TextEditingController();
  final _opening = TextEditingController();
  final _stuck = TextEditingController();

  StreamSubscription<List<Customer>>? _custSub;
  StreamSubscription<List<Supplier>>? _suppSub;

  bool get _canEditStuck => Session.isAdminOrManager;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _custSub = CustomerRepository.instance.watchAll().listen((_) => _reload());
    _suppSub = SupplierRepository.instance.watchAll().listen((_) => _reload());
    _reload();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _custSub?.cancel();
    _suppSub?.cancel();
    _name.dispose();
    _phone.dispose();
    _credit.dispose();
    _opening.dispose();
    _stuck.dispose();
    super.dispose();
  }

  // Kotlin onResume(): app wapas aane par balances dobara (payment kisi aur screen se ho sakti hai).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _reload();
  }

  Future<void> _reload() async {
    try {
      final customers = await CustomerRepository.instance.listAll();
      final suppliers = await SupplierRepository.instance.listAll();
      final cb = await PartyRepository.instance.liveCustomerBalances();
      final sb = await PartyRepository.instance.liveSupplierBalances();
      if (!mounted) return;
      setState(() {
        _customers = customers;
        _suppliers = suppliers;
        _customerBalances = cb;
        _supplierBalances = sb;
      });
    } catch (e) {
      if (mounted) _toast(e.toString());
    }
  }

  void _toast(String msg, {int seconds = 3}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg), duration: Duration(seconds: seconds)));
  }

  String _rs(double v) => 'Rs ${v.toStringAsFixed(2)}';

  Color get _customerAccent => ThemeManager.palette.flatPinkFg;
  Color get _supplierAccent => ThemeManager.palette.flatCoralFg;
  Color get _accent => _showingCustomers ? _customerAccent : _supplierAccent;

  // ------------------------------------------------------------------ actions

  Future<bool> _confirm(String title, String message, String confirmLabel, {bool destructive = false}) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(message)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(Loc.t('Cancel', 'منسوخ کریں'))),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(confirmLabel, style: destructive ? TextStyle(color: ThemeManager.palette.red) : null),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _runBusy(Future<void> Function() job) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await job();
    } catch (e) {
      if (mounted) _toast(e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (_busy) return;
    final limit = parseMoneyOrWarn(context, _credit.text, 'Credit Limit', 'کریڈٹ حد');
    if (limit == null) return;
    final opening = parseMoneyOrWarn(context, _opening.text, 'Opening Balance', 'افتتاحی بیلنس');
    if (opening == null) return;
    // Chhupa hua field hamesha khali => 0.0 (Kotlin jaisa).
    final double? stuck = (_showingCustomers && _canEditStuck)
        ? parseMoneyOrWarn(context, _stuck.text, 'Stuck Balance', 'پھنسا ہوا بیلنس')
        : 0.0;
    if (stuck == null) return;

    final name = _name.text.trim();
    if (name.isEmpty) {
      _toast(Loc.t('Name is required', 'نام ضروری ہے'));
      return;
    }

    // Kotlin "IMPROVEMENT PACK": ek jaise naam par warning (do asli log ka naam ek ho sakta hai,
    // is liye rokta nahi, sirf sochne ka mauqa deta hai).
    final lower = name.toLowerCase();
    final exists = _showingCustomers
        ? _customers.any((c) => c.name.trim().toLowerCase() == lower)
        : _suppliers.any((s) => s.name.trim().toLowerCase() == lower);
    if (exists) {
      final ok = await _confirm(
        Loc.t('Name already exists', 'یہ نام پہلے سے موجود ہے'),
        Loc.t('A party named "$name" already exists. Add another one with the same name?',
            '"$name" نام کی ایک پارٹی پہلے سے موجود ہے۔ کیا اسی نام سے ایک اور شامل کی جائے؟'),
        Loc.t('Add anyway', 'پھر بھی شامل کریں'),
      );
      if (!ok || !mounted) return;
    }

    await _runBusy(() async {
      final res = _showingCustomers
          ? await PartyRepository.instance.addCustomer(
              name: name, phone: _phone.text, creditLimit: limit, openingBalance: opening, stuckBalance: stuck)
          : await PartyRepository.instance.addSupplier(name: name, phone: _phone.text, openingBalance: opening);
      if (!mounted) return;
      if (res == SavePartyResult.nameRequired) {
        _toast(Loc.t('Name is required', 'نام ضروری ہے'));
        return;
      }
      _toast(Loc.t('Saved', 'محفوظ ہو گیا'));
      _name.clear();
      _phone.clear();
      _credit.clear();
      _opening.clear();
      _stuck.clear();
      await _reload();
    });
  }

  /// Kotlin `openContactPicker()`: fills Phone, and Name too when it is still blank.
  Future<void> _pickContact() async {
    final r = await ContactPicker.pick();
    if (!mounted) return;
    switch (r.status) {
      case ContactPickStatus.picked:
        final c = r.contact!;
        setState(() {
          _phone.text = c.phone;
          if (_name.text.trim().isEmpty && c.name.trim().isNotEmpty) _name.text = c.name;
        });
        break;
      case ContactPickStatus.cancelled:
        break;
      case ContactPickStatus.noPhone:
        _snack(Loc.t('No phone number for this contact', 'اس رابطے کا کوئی نمبر نہیں'));
        break;
      case ContactPickStatus.permissionDenied:
        _snack(Loc.t('Contacts permission denied', 'رابطوں کی اجازت مسترد'));
        break;
      case ContactPickStatus.failed:
        _snack(Loc.t("Couldn't open contacts", 'رابطے نہیں کھل سکے'));
        break;
    }
  }

  void _snack(String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _dial(String phone) async {
    if (phone.trim().isEmpty) return;
    try {
      final ok = await launchUrl(Uri(scheme: 'tel', path: phone.trim()));
      if (!ok && mounted) _toast(Loc.t("Couldn't open dialer", 'ڈائلر نہیں کھل سکا'));
    } catch (_) {
      if (mounted) _toast(Loc.t("Couldn't open dialer", 'ڈائلر نہیں کھل سکا'));
    }
  }

  // ------------------------------------------------------------------ edit dialogs

  InputDecoration _dlgDeco(String label, {String? error}) =>
      InputDecoration(labelText: label, errorText: error, isDense: true);

  Future<void> _editCustomer(Customer c) async {
    final name = TextEditingController(text: c.name);
    final phone = TextEditingController(text: c.phone);
    final limit = TextEditingController(text: c.creditLimit.toString());
    final opening = TextEditingController(text: c.openingBalance.toString());
    final stuck = _canEditStuck ? TextEditingController(text: c.stuckBalance == 0.0 ? '' : c.stuckBalance.toString()) : null;
    const money = TextInputType.numberWithOptions(decimal: true);
    var rateType = c.rateType;

    var nameError = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(Loc.t('Edit Customer', 'کسٹمر میں ترمیم کریں')),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                  controller: name,
                  decoration: _dlgDeco(Loc.t('Name', 'نام'),
                      error: nameError ? Loc.t('Name is required', 'نام ضروری ہے') : null)),
              const SizedBox(height: 10),
              TextField(controller: phone, keyboardType: TextInputType.phone, decoration: _dlgDeco(Loc.t('Phone', 'فون'))),
              const SizedBox(height: 10),
              TextField(controller: limit, keyboardType: money, decoration: _dlgDeco(Loc.t('Credit Limit', 'کریڈٹ لیمٹ'))),
              const SizedBox(height: 10),
              TextField(
                  controller: opening, keyboardType: money, decoration: _dlgDeco(Loc.t('Opening Balance', 'ابتدائی بیلنس'))),
              if (stuck != null) ...[
                const SizedBox(height: 10),
                TextField(
                    controller: stuck,
                    keyboardType: money,
                    decoration: _dlgDeco(Loc.t('Stuck Balance (optional)', 'اسٹک بیلنس (اختیاری)'))),
              ],
              if (_canEditStuck) ...[
                const SizedBox(height: 10),
                // Rate-type: sale mein is customer ko chunte hi rate khud isi hisab se lagta hai.
                DropdownButtonFormField<String>(
                  value: const ['', 'retail', 'wholesale', 'shopkeeper'].contains(rateType) ? rateType : '',
                  isExpanded: true,
                  decoration: _dlgDeco(Loc.t('Rate Type', 'ریٹ کی قسم')),
                  items: [
                    DropdownMenuItem(value: '', child: Text(Loc.t('Follow bill (default)', 'بل کے مطابق (ڈیفالٹ)'))),
                    DropdownMenuItem(value: 'retail', child: Text(Loc.t('Retail', 'ریٹیل'))),
                    DropdownMenuItem(value: 'wholesale', child: Text(Loc.t('Wholesale', 'ہول سیل'))),
                    DropdownMenuItem(value: 'shopkeeper', child: Text(Loc.t('Shopkeeper (lowest margin)', 'دکاندار (کم ترین مارجن)'))),
                  ],
                  onChanged: (v) => setLocal(() => rateType = v ?? ''),
                ),
              ],
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(Loc.t('Cancel', 'منسوخ کریں'))),
            TextButton(
              onPressed: () {
                if (name.text.trim().isEmpty) {
                  setLocal(() => nameError = true);
                  return;
                }
                Navigator.pop(ctx, true);
              },
              child: Text(Loc.t('Save', 'محفوظ کریں')),
            ),
          ],
        ),
      ),
    );

    try {
      if (ok != true || !mounted) return;
      // Kotlin: ghalat limit/opening => purani value; stuck ghalat => save roko + warning.
      double? stuckValue;
      if (stuck != null) {
        stuckValue = parseMoneyOrWarn(context, stuck.text, 'Stuck Balance', 'پھنسا ہوا بیلنس');
        if (stuckValue == null) return;
      }
      await _runBusy(() async {
        await PartyRepository.instance.editCustomer(
          c,
          name: name.text,
          phone: phone.text,
          creditLimit: double.tryParse(limit.text.trim()) ?? c.creditLimit,
          openingBalance: double.tryParse(opening.text.trim()) ?? c.openingBalance,
          stuckBalance: stuckValue, // null (cashier) => purana stuck barqarar
          rateType: _canEditStuck ? rateType : null, // cashier rate-type nahi badal sakta
        );
        if (mounted) _toast(Loc.t('Updated', 'اپ ڈیٹ ہو گیا'));
        await _reload();
      });
    } finally {
      name.dispose();
      phone.dispose();
      limit.dispose();
      opening.dispose();
      stuck?.dispose();
    }
  }

  Future<void> _editSupplier(Supplier s) async {
    final name = TextEditingController(text: s.name);
    final phone = TextEditingController(text: s.phone);
    final opening = TextEditingController(text: s.openingBalance.toString());
    var nameError = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(Loc.t('Edit Supplier', 'سپلائر میں ترمیم کریں')),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                  controller: name,
                  decoration: _dlgDeco(Loc.t('Name', 'نام'),
                      error: nameError ? Loc.t('Name is required', 'نام ضروری ہے') : null)),
              const SizedBox(height: 10),
              TextField(controller: phone, keyboardType: TextInputType.phone, decoration: _dlgDeco(Loc.t('Phone', 'فون'))),
              const SizedBox(height: 10),
              TextField(
                  controller: opening,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: _dlgDeco(Loc.t('Opening Balance', 'ابتدائی بیلنس'))),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(Loc.t('Cancel', 'منسوخ کریں'))),
            TextButton(
              onPressed: () {
                if (name.text.trim().isEmpty) {
                  setLocal(() => nameError = true);
                  return;
                }
                Navigator.pop(ctx, true);
              },
              child: Text(Loc.t('Save', 'محفوظ کریں')),
            ),
          ],
        ),
      ),
    );

    try {
      if (ok != true || !mounted) return;
      await _runBusy(() async {
        await PartyRepository.instance.editSupplier(
          s,
          name: name.text,
          phone: phone.text,
          openingBalance: double.tryParse(opening.text.trim()) ?? s.openingBalance,
        );
        if (mounted) _toast(Loc.t('Updated', 'اپ ڈیٹ ہو گیا'));
        await _reload();
      });
    } finally {
      name.dispose();
      phone.dispose();
      opening.dispose();
    }
  }

  // ------------------------------------------------------------------ delete

  // Kotlin ne yahan STORED balance (c.totalPayable) dikhaya tha; hum live ledger balance dikhate hain
  // (baaki screen ke saath mel — "balance drift" fix).
  Future<void> _deleteCustomer(Customer c) async {
    final closing = partyClosing(
        opening: c.openingBalance, running: _customerBalances[c.id] ?? 0.0, stuck: c.stuckBalance);
    final String message;
    if (closing.abs() > 0.009) {
      final direction = closing > 0
          ? Loc.t("you'll get from them", 'آپ نے ان سے لینے ہیں')
          : Loc.t("you'll give to them", 'آپ نے انہیں دینے ہیں');
      final amt = closing.abs().toStringAsFixed(2);
      message = Loc.t(
        '${c.name} still has an outstanding balance of Rs $amt ($direction). Deleting this customer will permanently lose track of this due. Delete anyway?',
        '${c.name} کا Rs $amt ($direction) کا واجب الادا بیلنس ہے۔ اس کسٹمر کو حذف کرنے سے یہ ریکارڈ ہمیشہ کے لیے ختم ہو جائے گا۔ پھر بھی حذف کریں؟',
      );
    } else {
      message = Loc.t('Delete ${c.name}? This cannot be undone.', '${c.name} کو حذف کریں؟ اسے واپس نہیں لایا جا سکتا۔');
    }
    if (!await _confirm(Loc.t('Delete Customer', 'کسٹمر حذف کریں'), message, Loc.t('Delete', 'حذف کریں'),
        destructive: true)) {
      return;
    }
    await _runBusy(() async {
      await PartyRepository.instance.deleteCustomer(c);
      if (mounted) _toast(Loc.t('Deleted', 'حذف ہو گیا'));
      await _reload();
    });
  }

  Future<void> _deleteSupplier(Supplier s) async {
    final closing = partyClosing(opening: s.openingBalance, running: _supplierBalances[s.id] ?? 0.0);
    final String message;
    if (closing.abs() > 0.009) {
      final direction = closing > 0
          ? Loc.t("you'll give to them", 'آپ نے انہیں دینے ہیں')
          : Loc.t("you'll get from them", 'آپ نے ان سے لینے ہیں');
      final amt = closing.abs().toStringAsFixed(2);
      message = Loc.t(
        '${s.name} still has an outstanding balance of Rs $amt ($direction). Deleting this supplier will permanently lose track of this due. Delete anyway?',
        '${s.name} کا Rs $amt ($direction) کا واجب الادا بیلنس ہے۔ اس سپلائر کو حذف کرنے سے یہ ریکارڈ ہمیشہ کے لیے ختم ہو جائے گا۔ پھر بھی حذف کریں؟',
      );
    } else {
      message = Loc.t('Delete ${s.name}? This cannot be undone.', '${s.name} کو حذف کریں؟ اسے واپس نہیں لایا جا سکتا۔');
    }
    if (!await _confirm(Loc.t('Delete Supplier', 'سپلائر حذف کریں'), message, Loc.t('Delete', 'حذف کریں'),
        destructive: true)) {
      return;
    }
    await _runBusy(() async {
      await PartyRepository.instance.deleteSupplier(s);
      if (mounted) _toast(Loc.t('Deleted', 'حذف ہو گیا'));
      await _reload();
    });
  }

  // ------------------------------------------------------------------ maintenance chips

  Future<void> _fixBalances() async {
    final ok = await _confirm(
      Loc.t('Recalculate Balances', 'بیلنس دوبارہ شمار کریں'),
      Loc.t(
          "This checks every customer's and supplier's balance against their actual bills and payments, and fixes any that don't match. Continue?",
          'یہ ہر کسٹمر اور سپلائر کا بیلنس ان کے اصل بلوں اور ادائیگیوں سے ملا کر چیک کرے گا، اور جو میل نہیں کھاتے انہیں ٹھیک کر دے گا۔ جاری رکھیں؟'),
      Loc.t('Recalculate', 'دوبارہ شمار کریں'),
    );
    if (!ok) return;
    await _runBusy(() async {
      final r = await PartyRepository.instance.recalculateBalances();
      if (!mounted) return;
      _toast(r.customersFixed + r.suppliersFixed == 0
          ? Loc.t('All balances already correct', 'تمام بیلنس پہلے ہی درست ہیں')
          : Loc.t('Fixed ${r.customersFixed} customer(s), ${r.suppliersFixed} supplier(s)',
              '${r.customersFixed} کسٹمرز اور ${r.suppliersFixed} سپلائرز کا بیلنس ٹھیک ہو گیا'));
      await _reload();
    });
  }

  Future<void> _mergeDuplicates() async {
    final ok = await _confirm(
      Loc.t('Merge Duplicates', 'ڈپلیکیٹ ملائیں'),
      Loc.t(
          "This finds customers/suppliers that share the exact same name, combines their purchase/sale history and balance into one record, and deletes the extra copy. This can't be undone. Continue?",
          'یہ ایک جیسے نام والے کسٹمرز/سپلائرز کو ڈھونڈ کر ان کی خرید/فروخت کی تاریخ اور بیلنس ایک ریکارڈ میں ملا دے گا، اور اضافی کاپی حذف کر دے گا۔ یہ واپس نہیں ہو سکتا۔ جاری رکھیں؟'),
      Loc.t('Merge', 'ملائیں'),
      destructive: true,
    );
    if (!ok) return;
    await _runBusy(() async {
      final r = await PartyRepository.instance.mergeDuplicateParties();
      if (!mounted) return;
      _toast(r.customersMerged + r.suppliersMerged == 0
          ? Loc.t('No duplicates found', 'کوئی ڈپلیکیٹ نہیں ملا')
          : Loc.t('Merged ${r.customersMerged} customer(s), ${r.suppliersMerged} supplier(s)',
              '${r.customersMerged} کسٹمرز اور ${r.suppliersMerged} سپلائرز ملا دیے گئے'));
      await _reload();
    });
  }

  String _cleanedMessage(String enOne, String urOne, CleanupPaymentsResult r) => Loc.t(
        'Removed ${r.paymentsRemoved} $enOne payment(s). Fixed ${r.recalc.customersFixed} customer(s), ${r.recalc.suppliersFixed} supplier(s)',
        '${r.paymentsRemoved} $urOne ادائیگیاں حذف ہو گئیں۔ ${r.recalc.customersFixed} کسٹمرز اور ${r.recalc.suppliersFixed} سپلائرز کا بیلنس ٹھیک ہو گیا',
      );

  Future<void> _cleanupPayments() async {
    await _runBusy(() async {
      final groups = await PartyRepository.instance.findDuplicatePayments();
      if (!mounted) return;
      if (groups.isEmpty) {
        _toast(Loc.t('No duplicate payments found', 'کوئی ڈپلیکیٹ ادائیگی نہیں ملی'));
        return;
      }
      final totalRows = groups.fold<int>(0, (a, g) => a + g.remove.length);
      final totalAmount = groups.fold<double>(0, (a, g) => a + g.removeTotal);
      final lines = groups.map((g) {
        final ref = g.reference.length > 24 ? g.reference.substring(0, 24) : g.reference;
        return '• ${g.partyName} ($ref) — ${g.remove.length} × ${_rs(g.removeTotal / g.remove.length)}';
      }).join('\n');
      final ok = await _confirm(
        Loc.t('Cleanup Payments', 'ادائیگیاں صاف کریں'),
        Loc.t(
            "Found $totalRows leftover duplicate payment(s) totalling ${_rs(totalAmount)}:\n\n$lines\n\nEach of these is an old row a bill edit left behind before the sync fix — the one correct payment for each bill is kept, only the extra copies above are removed. Balances will be corrected afterward. This can't be undone. Continue?",
            'بل ایڈٹ کے دوران sync fix سے پہلے رہ جانے والی $totalRows پرانی ڈپلیکیٹ ادائیگیاں ملیں، مجموعی رقم ${_rs(totalAmount)}:\n\n$lines\n\nہر بل کی ایک درست ادائیگی رکھی جائے گی، صرف اضافی کاپیاں حذف ہوں گی۔ اس کے بعد بیلنس ٹھیک کر دیا جائے گا۔ یہ واپس نہیں ہو سکتا۔ جاری رکھیں؟'),
        Loc.t('Clean Up', 'صاف کریں'),
        destructive: true,
      );
      if (!ok || !mounted) return;
      // Wahi groups jo preview mein dikhaye gaye.
      final r = await PartyRepository.instance.cleanupDuplicatePayments(groups);
      if (!mounted) return;
      _toast(
          r.paymentsRemoved == 0
              ? Loc.t('No duplicate payments found', 'کوئی ڈپلیکیٹ ادائیگی نہیں ملی')
              : _cleanedMessage('duplicate', 'ڈپلیکیٹ', r),
          seconds: 5);
      await _reload();
    });
  }

  Future<void> _cleanupOrphaned() async {
    await _runBusy(() async {
      final payments = await PartyRepository.instance.findOrphanedPayments();
      if (!mounted) return;
      if (payments.isEmpty) {
        _toast(Loc.t('No orphaned payments found', 'کوئی بے مالک ادائیگی نہیں ملی'));
        return;
      }
      final cNames = {for (final c in _customers) c.id: c.name};
      final sNames = {for (final s in _suppliers) s.id: s.name};
      final total = payments.fold<double>(0, (a, p) => a + p.amount);
      final lines = payments.map((p) {
        final name = (p.partyType == 'customer' ? cNames[p.partyId] : sNames[p.partyId]) ?? '#${p.partyId}';
        final ref = p.reference.length > 24 ? p.reference.substring(0, 24) : p.reference;
        return '• $name ($ref) — ${_rs(p.amount)}';
      }).join('\n');
      final ok = await _confirm(
        Loc.t('Cleanup Orphaned Payments', 'بے مالک ادائیگیاں صاف کریں'),
        Loc.t(
            "Found ${payments.length} orphaned payment(s) totalling ${_rs(total)}:\n\n$lines\n\nEach of these is a bill-payment row whose purchase/sale bill was deleted by an old app version before it cleaned up this row too — it's being wrongly counted as real money, throwing that party's balance the wrong way. Balances will be corrected afterward. This can't be undone. Continue?",
            'ان میں سے ہر ایک اس بل کی ادائیگی ہے جس کا purchase/sale پرانی ایپ ورژن سے حذف ہوا تھا مگر یہ ادائیگی حذف نہیں ہوئی — یہ غلطی سے اصل رقم شمار ہو رہی ہے اور پارٹی کا بیلنس غلط سمت دکھا رہی ہے۔ اس کے بعد بیلنس ٹھیک کر دیا جائے گا۔ یہ واپس نہیں ہو سکتا۔ جاری رکھیں؟'),
        Loc.t('Clean Up', 'صاف کریں'),
        destructive: true,
      );
      if (!ok || !mounted) return;
      final r = await PartyRepository.instance.cleanupOrphanedPayments(payments);
      if (!mounted) return;
      _toast(
          r.paymentsRemoved == 0
              ? Loc.t('No orphaned payments found', 'کوئی بے مالک ادائیگی نہیں ملی')
              : _cleanedMessage('orphaned', 'بے مالک', r),
          seconds: 5);
      await _reload();
    });
  }

  // ------------------------------------------------------------------ history dialogs

  Future<void> _showCustomerHistory(Customer c) async {
    final sales = await PartyRepository.instance.salesByCustomer(c.id!);
    if (!mounted) return;
    await _historyDialog(
      name: c.name,
      accent: _customerAccent,
      icon: Icons.person,
      opening: c.openingBalance,
      running: _customerBalances[c.id] ?? 0.0,
      stuck: c.stuckBalance,
      emptyText: Loc.t('No sales yet', 'ابھی تک کوئی سیل نہیں ہوئی'),
      rows: [for (final s in sales) (s.createdAt, s.total, s.paid)],
    );
  }

  Future<void> _showSupplierHistory(Supplier s) async {
    final purchases = await PartyRepository.instance.purchasesBySupplier(s.id!);
    if (!mounted) return;
    await _historyDialog(
      name: s.name,
      accent: _supplierAccent,
      icon: Icons.shopping_bag,
      opening: s.openingBalance,
      running: _supplierBalances[s.id] ?? 0.0,
      stuck: 0.0,
      emptyText: Loc.t('No purchases yet', 'ابھی تک کوئی خریداری نہیں ہوئی'),
      rows: [for (final p in purchases) (p.createdAt, p.total, p.paid)],
    );
  }

  Future<void> _historyDialog({
    required String name,
    required Color accent,
    required IconData icon,
    required double opening,
    required double running,
    required double stuck,
    required String emptyText,
    required List<(int, double, double)> rows,
  }) {
    final p = ThemeManager.palette;
    final fmt = DateFormat('dd MMM yyyy, hh:mm a');
    // Newest first; bill number nahi, sirf tareekh (Kotlin jaisa).
    final sorted = [...rows]..sort((a, b) => b.$1.compareTo(a.$1));
    final hasStuck = stuck != 0.0;
    const light = Color(0xFFF2F3FF);

    return showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: p.bg,
        insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 520, maxHeight: MediaQuery.of(ctx).size.height * 0.8),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [accent, Color.lerp(accent, Colors.white, 0.3)!]),
              ),
              child: Row(children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(color: p.cardWhite, shape: BoxShape.circle),
                  child: Icon(icon, color: accent, size: 18),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(name, style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 6),
                    Row(children: [
                      Expanded(
                        child: Text(
                          hasStuck
                              ? '${Loc.t('Daily', 'روزانہ')}: ${_rs(opening + running)}'
                              : '${Loc.t('Opening', 'ابتدائی')}: ${_rs(opening)}',
                          style: const TextStyle(color: light, fontSize: 11),
                        ),
                      ),
                      Text(
                        hasStuck
                            ? '${Loc.t('Total', 'کل')}: ${_rs(opening + running + stuck)}'
                            : '${Loc.t('Closing', 'اختتامی')}: ${_rs(opening + running)}',
                        style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                      ),
                    ]),
                    if (hasStuck)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text('${Loc.t('Stuck', 'اسٹک')}: ${_rs(stuck)}',
                            style: const TextStyle(color: light, fontSize: 11)),
                      ),
                  ]),
                ),
              ]),
            ),
            Flexible(
              child: sorted.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(emptyText, style: TextStyle(color: p.textMuted, fontSize: 13)),
                    )
                  : ListView(
                      shrinkWrap: true,
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                      children: [
                        for (final r in sorted)
                          Container(
                            margin: const EdgeInsets.only(bottom: 10),
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                            decoration: BoxDecoration(
                              color: p.cardWhite,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: p.border),
                            ),
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Row(children: [
                                Expanded(
                                  child: Text(fmt.format(DateTime.fromMillisecondsSinceEpoch(r.$1)),
                                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: p.textDark)),
                                ),
                                Text(_rs(r.$2), style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: accent)),
                              ]),
                              const SizedBox(height: 4),
                              Text('${Loc.t('Paid', 'ادا شدہ')}: ${_rs(r.$3)}',
                                  style: TextStyle(fontSize: 11, color: p.textMuted)),
                            ]),
                          ),
                      ],
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                      backgroundColor: accent,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(Loc.t('Close', 'بند کریں')),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final p = ThemeManager.palette;
    final rows = _buildRows(p);
    return Scaffold(
      backgroundColor: p.bg,
      body: Column(children: [
        _header(p),
        Expanded(
          child: ListView(
            // Neeche 90 ka khali hissa: aakhri card gesture-nav strip se upar scroll ho sake
            // (Kotlin "TABLET/DENSITY FIX": aakhri row ka Edit/Delete nahi dabta tha).
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 90),
            children: [
              _tabs(p),
              const SizedBox(height: 16),
              _formCard(p),
              const SizedBox(height: 18),
              _listHeader(p),
              _searchField(p),
              const SizedBox(height: 10),
              _chipRow(p),
              const SizedBox(height: 12),
              ...rows,
            ],
          ),
        ),
      ]),
    );
  }

  List<Widget> _buildRows(AppPalette p) {
    final widgets = <Widget>[];
    if (_showingCustomers) {
      final filtered = _customers.where((c) {
        final running = _customerBalances[c.id] ?? 0.0;
        return partyMatchesQuery(c.name, c.phone, _query) &&
            (!_duesOnly || partyHasDue(opening: c.openingBalance, running: running, stuck: c.stuckBalance));
      }).toList();
      if (filtered.isEmpty) {
        widgets.add(_emptyCard(p, _customers.isEmpty
            ? Loc.t('No customers yet', 'کوئی کسٹمر نہیں ہے')
            : Loc.t('No matching customers', 'کوئی مماثل کسٹمر نہیں')));
      }
      for (final c in filtered) {
        widgets.add(_partyCard(
          p,
          name: c.name,
          phone: c.phone,
          opening: c.openingBalance,
          running: _customerBalances[c.id] ?? 0.0,
          stuck: c.stuckBalance,
          accent: _customerAccent,
          icon: Icons.person,
          isCustomer: true,
          onTap: () => _showCustomerHistory(c),
          onEdit: () => _editCustomer(c),
          onDelete: () => _deleteCustomer(c),
        ));
      }
    } else {
      final filtered = _suppliers.where((s) {
        final running = _supplierBalances[s.id] ?? 0.0;
        return partyMatchesQuery(s.name, s.phone, _query) &&
            (!_duesOnly || partyHasDue(opening: s.openingBalance, running: running));
      }).toList();
      if (filtered.isEmpty) {
        widgets.add(_emptyCard(p, _suppliers.isEmpty
            ? Loc.t('No suppliers yet', 'کوئی سپلائر نہیں ہے')
            : Loc.t('No matching suppliers', 'کوئی مماثل سپلائر نہیں')));
      }
      for (final s in filtered) {
        widgets.add(_partyCard(
          p,
          name: s.name,
          phone: s.phone,
          opening: s.openingBalance,
          running: _supplierBalances[s.id] ?? 0.0,
          stuck: 0.0,
          accent: _supplierAccent,
          icon: Icons.shopping_bag,
          isCustomer: false,
          onTap: () => _showSupplierHistory(s),
          onEdit: () => _editSupplier(s),
          onDelete: () => _deleteSupplier(s),
        ));
      }
    }
    return widgets;
  }

  Widget _header(AppPalette p) {
    return Container(
      color: p.navy,
      padding: EdgeInsets.fromLTRB(8, MediaQuery.of(context).padding.top + 10, 16, 16),
      child: Row(children: [
        IconButton(icon: const Icon(Icons.arrow_back, color: Colors.white), onPressed: () => Navigator.of(context).maybePop()),
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(color: p.headerBadgeOverlay, shape: BoxShape.circle),
          child: const Icon(Icons.people, color: Colors.white, size: 18),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(Loc.t('Customers & Suppliers', 'کسٹمرز اور سپلائرز'),
                style: const TextStyle(color: Colors.white, fontSize: 18.5, fontWeight: FontWeight.bold)),
            Text(Loc.t('Manage parties & view ledgers', 'پارٹیز کا انتظام اور کھاتے دیکھیں'),
                style: TextStyle(color: p.headerSubtitleColor, fontSize: 11)),
          ]),
        ),
      ]),
    );
  }

  BoxDecoration _cardDeco(AppPalette p, {double r = 16}) => BoxDecoration(
        color: p.cardWhite,
        borderRadius: BorderRadius.circular(r),
        border: Border.all(color: p.border),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 8, offset: const Offset(0, 3))],
      );

  Widget _tabs(AppPalette p) {
    Widget tab(String label, IconData icon, bool selected, Color accent, VoidCallback onTap) => Expanded(
          child: InkWell(
            borderRadius: BorderRadius.circular(24),
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 13),
              decoration: BoxDecoration(
                color: selected ? accent : p.fieldFill,
                borderRadius: BorderRadius.circular(24),
                border: selected ? null : Border.all(color: p.border),
              ),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(icon, size: 15, color: selected ? Colors.white : p.textMuted),
                const SizedBox(width: 6),
                Text(label,
                    style: TextStyle(
                        fontSize: 12, fontWeight: FontWeight.bold, color: selected ? Colors.white : p.textMuted)),
              ]),
            ),
          ),
        );

    return Row(children: [
      tab(Loc.t('CUSTOMERS', 'کسٹمرز'), Icons.person, _showingCustomers, _customerAccent,
          () => setState(() => _showingCustomers = true)),
      const SizedBox(width: 12),
      tab(Loc.t('SUPPLIERS', 'سپلائرز'), Icons.shopping_bag, !_showingCustomers, _supplierAccent,
          () => setState(() => _showingCustomers = false)),
    ]);
  }

  InputDecoration _fieldDeco(AppPalette p, String hint, {Widget? prefix}) => InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: p.textMuted, fontSize: 14),
        prefixIcon: prefix,
        isDense: true,
        filled: true,
        fillColor: p.fieldFill,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: p.border)),
        enabledBorder:
            OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: p.border)),
        focusedBorder:
            OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: _accent, width: 1.4)),
      );

  Widget _formCard(AppPalette p) {
    const money = TextInputType.numberWithOptions(decimal: true);
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: _cardDeco(p),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(_showingCustomers ? Icons.person : Icons.shopping_bag, size: 14, color: _accent),
          const SizedBox(width: 8),
          Text(_showingCustomers ? Loc.t('Add Customer', 'کسٹمر شامل کریں') : Loc.t('Add Supplier', 'سپلائر شامل کریں'),
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: _accent)),
        ]),
        const SizedBox(height: 12),
        TextField(
          controller: _name,
          textCapitalization: TextCapitalization.words,
          style: TextStyle(color: p.textDark),
          decoration: _fieldDeco(p, Loc.t('Name *', 'نام *')),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _phone,
          keyboardType: TextInputType.phone,
          style: TextStyle(color: p.textDark),
          decoration: _fieldDeco(p, Loc.t('Phone (optional)', 'فون (اختیاری)')).copyWith(
            suffixIcon: IconButton(
              icon: Icon(Icons.contacts, color: _accent),
              tooltip: Loc.t('Pick from contacts', 'رابطوں سے چنیں'),
              onPressed: _pickContact,
            ),
          ),
        ),
        if (_showingCustomers) ...[
          const SizedBox(height: 10),
          TextField(
            controller: _credit,
            keyboardType: money,
            style: TextStyle(color: p.textDark),
            decoration: _fieldDeco(p, Loc.t('Credit Limit (optional)', 'کریڈٹ لیمٹ (اختیاری)')),
          ),
        ],
        const SizedBox(height: 10),
        TextField(
          controller: _opening,
          keyboardType: money,
          style: TextStyle(color: p.textDark),
          decoration: _fieldDeco(p, Loc.t('Opening Balance (Rs, if any previous due)',
              'ابتدائی بیلنس (روپے، اگر کوئی پرانا واجب الادا ہو)')),
        ),
        if (_showingCustomers && _canEditStuck) ...[
          const SizedBox(height: 10),
          TextField(
            controller: _stuck,
            keyboardType: money,
            style: TextStyle(color: p.textDark),
            decoration: _fieldDeco(
                p,
                Loc.t("Stuck Balance (Rs, optional — old amount that doesn't move)",
                    'اسٹک بیلنس (روپے، اختیاری — پرانا رکا ہوا رقم)')),
          ),
        ],
        const SizedBox(height: 14),
        FilledButton(
          style: FilledButton.styleFrom(
              backgroundColor: _accent,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
          onPressed: _busy ? null : _save,
          child: Text(Loc.t('SAVE', 'محفوظ کریں'), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
        ),
      ]),
    );
  }

  Widget _listHeader(AppPalette p) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
        child: Row(children: [
          Icon(Icons.list, size: 16, color: p.navy),
          const SizedBox(width: 8),
          Text(Loc.t('Party List', 'پارٹی لسٹ'),
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: p.textDark)),
          const Spacer(),
          Flexible(
            child: Text(Loc.t('Tap for history · icons to edit/delete', 'تاریخ کے لیے ٹیپ کریں · ترمیم/حذف کے آئیکنز'),
                textAlign: TextAlign.end, style: TextStyle(fontSize: 11, color: p.textMuted)),
          ),
        ]),
      );

  Widget _searchField(AppPalette p) => TextField(
        onChanged: (v) => setState(() => _query = v),
        style: TextStyle(color: p.textDark),
        decoration: _fieldDeco(p, Loc.t('Search by name or phone', 'نام یا فون سے تلاش کریں'),
            prefix: Icon(Icons.search, size: 18, color: p.textMuted)),
      );

  Widget _chipRow(AppPalette p) {
    Widget chip(String label, IconData icon, VoidCallback? onTap, {bool active = false}) => Padding(
          padding: const EdgeInsets.only(right: 10),
          child: InkWell(
            borderRadius: BorderRadius.circular(24),
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: active ? _accent : p.fieldFill,
                borderRadius: BorderRadius.circular(24),
                border: active ? null : Border.all(color: p.border),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(icon, size: 14, color: active ? Colors.white : p.textMuted),
                const SizedBox(width: 6),
                Text(label,
                    style: TextStyle(
                        fontSize: 12, fontWeight: FontWeight.bold, color: active ? Colors.white : p.textMuted)),
              ]),
            ),
          ),
        );

    // Maintenance chips kaam ke dauran (busy) band rehte hain — double-tap guard.
    VoidCallback? guard(VoidCallback f) => _busy ? null : f;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: [
        chip(Loc.t('Dues only', 'صرف واجبات'), Icons.account_balance_wallet_outlined,
            () => setState(() => _duesOnly = !_duesOnly),
            active: _duesOnly),
        chip(Loc.t('Fix Balances', 'بیلنس ٹھیک کریں'), Icons.sync, guard(_fixBalances)),
        chip(Loc.t('Merge Duplicates', 'ڈپلیکیٹ ملائیں'), Icons.people_outline, guard(_mergeDuplicates)),
        chip(Loc.t('Cleanup Payments', 'ادائیگیاں صاف کریں'), Icons.account_balance_wallet_outlined,
            guard(_cleanupPayments)),
        chip(Loc.t('Cleanup Orphaned', 'بے مالک صاف کریں'), Icons.account_balance_wallet_outlined,
            guard(_cleanupOrphaned)),
      ]),
    );
  }

  Widget _emptyCard(AppPalette p, String text) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        decoration: _cardDeco(p),
        alignment: Alignment.center,
        child: Text(text, style: TextStyle(color: p.textMuted, fontSize: 13)),
      );

  /// Closing figure ka rang party ki qism ke hisaab se (Kotlin FIX):
  ///  Customer closing > 0 => sabz (lene hain), < 0 => surkh (dene hain);
  ///  Supplier closing > 0 => surkh (dene hain), < 0 => sabz (lene hain).
  Widget _partyCard(
    AppPalette p, {
    required String name,
    required String phone,
    required double opening,
    required double running,
    required double stuck,
    required Color accent,
    required IconData icon,
    required bool isCustomer,
    required VoidCallback onTap,
    required VoidCallback onEdit,
    required VoidCallback onDelete,
  }) {
    final closing = partyClosing(opening: opening, running: running, stuck: stuck);
    final isGive = partyIsGive(isCustomer: isCustomer, closing: closing);
    final closingColor = isGive ? p.red : p.flatTealFg;

    Widget action(IconData i, String label, Color color, VoidCallback onPressed, {bool danger = false}) => InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: _busy ? null : onPressed,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
              color: danger ? p.red.withOpacity(0.12) : accent.withOpacity(0.10),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(i, size: 14, color: color),
              const SizedBox(width: 6),
              Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: color)),
            ]),
          ),
        );

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
      decoration: _cardDeco(p),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        InkWell(
          onTap: onTap,
          child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(color: accent.withOpacity(0.14), shape: BoxShape.circle),
              child: Icon(icon, size: 19, color: accent),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(name, style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: p.textDark)),
                if (phone.isNotEmpty) Text(phone, style: TextStyle(fontSize: 12, color: p.textMuted)),
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    // Stuck ho to "Daily • Stuck" split, warna sirf Opening.
                    stuck != 0.0
                        ? '${Loc.t('Daily', 'روزانہ')}: ${_rs(opening + running)}  •  ${Loc.t('Stuck', 'اسٹک')}: ${_rs(stuck)}'
                        : '${Loc.t('Opening', 'ابتدائی')}: ${_rs(opening)}',
                    style: TextStyle(fontSize: 11, color: p.textMuted),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(Loc.t('Tap for full history  ›', 'مکمل تاریخ کے لیے ٹیپ کریں  ›'),
                      style: TextStyle(fontSize: 11, color: accent)),
                ),
              ]),
            ),
            const SizedBox(width: 10),
            Text(_rs(closing), style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: closingColor)),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 8),
          child: Divider(height: 1, color: p.border),
        ),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: Wrap(spacing: 10, runSpacing: 8, children: [
            if (phone.isNotEmpty) action(Icons.phone, Loc.t('Call', 'کال کریں'), p.flatTealFg, () => _dial(phone)),
            action(Icons.edit, Loc.t('Edit', 'ترمیم'), accent, onEdit),
            action(Icons.delete, Loc.t('Delete', 'حذف کریں'), p.red, onDelete, danger: true),
          ]),
        ),
      ]),
    );
  }
}
