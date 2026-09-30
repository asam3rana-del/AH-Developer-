import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../db/category_unit_repository.dart';
import '../db/party_repository.dart';
import '../db/product_repository.dart';
import '../db/purchase_history_repository.dart' show PurchaseHistoryRepository;
import '../db/purchase_repository.dart';
import '../db/rate_comparison_repository.dart' show RateComparisonRepository, SupplierRateRow;
import '../db/supplier_repository.dart';
import '../models/category_unit.dart' as models;
import '../models/party.dart';
import '../models/product.dart';
import '../services/purchase_hold_recall.dart';
import '../services/session.dart';
import '../theme/app_colors.dart';
import '../utils/bill_doc.dart';
import 'bill_preview_screen.dart';
import '../utils/input_validation.dart';
import '../utils/loc.dart';
import '../utils/purchase_calc.dart';
import '../utils/split_payment.dart';
import '../widgets/autocomplete_options.dart';
import '../widgets/premium_header.dart';
import '../widgets/premium_widgets.dart';

/// Mirrors PurchaseActivity.kt.
///
/// [editBillNo] null = naya purchase; nonnull = saved bill edit (History card tap / Party screens).
///
/// Done: naya purchase + saved purchase edit (sirf badli hui lines ka stock/cost touch), supplier ka apna
/// invoice no. + duplicate-invoice alert + same supplier/amount/date warning, item par qty+unit+rate
/// (pichli khareedi ka rate auto-fill), Retail/Wholesale rate purchase ke waqt set, margin/loss warning,
/// inline line edit, naya product mid-purchase, Split Payment (Cash + Bank), draft autosave,
/// supplier ka live balance, bill preview.
/// Edit mode mein DELETE button (poora bill: stock + cost + supplier balance + payments wapas, admin only) aur
/// item chun kar "Compare suppliers" popup (har supplier ka last / lowest / highest rate, admin + manager).
/// Bill Scan (OCR) + Bill Preview/Print (Phase 12) done.
class PurchaseScreen extends StatefulWidget {
  final String? editBillNo;

  const PurchaseScreen({super.key, this.editBillNo});

  @override
  State<PurchaseScreen> createState() => _PurchaseScreenState();
}

class _PurchaseScreenState extends State<PurchaseScreen> with WidgetsBindingObserver {
  final _repo = PurchaseRepository.instance;

  final _supplierCtrl = TextEditingController();
  final _supplierFocus = FocusNode();
  final _invoiceCtrl = TextEditingController();
  final _invoiceFocus = FocusNode();
  final _itemCtrl = TextEditingController();
  final _itemFocus = FocusNode();
  final _qtyCtrl = TextEditingController();
  final _qtyFocus = FocusNode();
  final _rateCtrl = TextEditingController();
  final _rateFocus = FocusNode();
  final _retailFocus = FocusNode();
  final _wholesaleFocus = FocusNode();
  final _paidFocus = FocusNode();
  final _retailCtrl = TextEditingController();
  final _wholesaleCtrl = TextEditingController();
  final _paidCtrl = TextEditingController();

  DateTime _purchaseDate = DateTime.now();
  Product? _pickedProduct;
  String _selectedUnit = '';

  // Product ki main (primary) unit basis par rates — unit badalne par field ka text inhi se dobara banta hai.
  double _mainRate = 0.0;
  double _mainRetail = 0.0;
  double _mainWholesale = 0.0;
  double _lastPurchaseMainRate = 0.0;

  final List<PurchaseLine> _lines = [];
  int? _editingIndex;

  List<PayEntry> _splitPayments = [];
  String _paymentMethod = 'Cash';

  List<Product> _products = const [];
  List<Supplier> _suppliers = const [];
  StreamSubscription<List<Product>>? _productSub;
  StreamSubscription<List<Supplier>>? _supplierSub;

  double? _supplierBalance;
  Timer? _draftTimer;

  bool _saving = false;
  bool _loading = false;

  bool get _isEdit => widget.editBillNo != null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ProductRepository.instance.listAll().then((v) {
      if (mounted) setState(() => _products = v);
    });
    _productSub = ProductRepository.instance.watchAll().listen((v) {
      if (mounted) setState(() => _products = v);
    });
    SupplierRepository.instance.listAll().then((v) {
      if (mounted) setState(() => _suppliers = v);
    });
    _supplierSub = SupplierRepository.instance.watchAll().listen((v) {
      if (mounted) setState(() => _suppliers = v);
    });
    if (_isEdit) {
      _loading = true;
      _loadForEdit();
    } else {
      _restoreDraft().then((_) => _restoreEntry());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // App background mein jaye to bill ka adha kaam na jaye (Kotlin onPause -> saveDraft).
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      _saveDraftNow();
      _saveEntryNow();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _draftTimer?.cancel();
    _entryTimer?.cancel();
    _saveEntryNow();
    _saveDraftNow(); // controllers dispose hone se PEHLE (text abhi parha jata hai)
    _productSub?.cancel();
    _supplierSub?.cancel();
    _supplierCtrl.dispose();
    _supplierFocus.dispose();
    _invoiceCtrl.dispose();
    _invoiceFocus.dispose();
    _rateFocus.dispose();
    _retailFocus.dispose();
    _wholesaleFocus.dispose();
    _paidFocus.dispose();
    _itemCtrl.dispose();
    _itemFocus.dispose();
    _qtyCtrl.dispose();
    _qtyFocus.dispose();
    _rateCtrl.dispose();
    _retailCtrl.dispose();
    _wholesaleCtrl.dispose();
    _paidCtrl.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ getters

  double get _subtotal => _lines.fold(0.0, (sum, l) => sum + l.amount);
  double get _grandTotal => _subtotal.roundToDouble();

  String get _effectiveUnit => _selectedUnit.isNotEmpty ? _selectedUnit : (_pickedProduct?.unit ?? 'pcs');

  double get _effectivePaid => effectivePaidInput(_splitPayments, double.tryParse(_paidCtrl.text.trim()) ?? 0.0);

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 3)));
  }

  // -------------------------------------------------------------------- draft

  PurchaseDraft _currentDraft() => PurchaseDraft(
        supplier: _supplierCtrl.text,
        supplierInvoiceNo: _invoiceCtrl.text,
        paidText: _paidCtrl.text,
        dateMillis: 0, // purani date par naya bill na bane (Sale draft jaisa)
        lines: List<PurchaseLine>.of(_lines),
      );

  void _saveDraftSoon() {
    if (_isEdit) return;
    _draftTimer?.cancel();
    _draftTimer = Timer(const Duration(milliseconds: 500), _saveDraftNow);
  }

  void _saveDraftNow() {
    if (_isEdit) return;
    PurchaseDraftStore.save(_currentDraft());
  }

  Future<void> _restoreDraft() async {
    final d = await PurchaseDraftStore.load();
    if (d == null || !mounted) return;
    setState(() {
      _supplierCtrl.text = d.supplier;
      _invoiceCtrl.text = d.supplierInvoiceNo;
      _paidCtrl.text = d.paidText;
      _lines
        ..clear()
        ..addAll(d.lines);
    });
    _refreshSupplierBalance(d.supplier);
    if (d.lines.isNotEmpty) _toast(Loc.t('Unsaved purchase draft restored', 'محفوظ نہ ہوئی خریداری کا مسودہ بحال ہو گیا'));
  }

  // ------------------------------------------- adhoora item (back dabane par bhi bacha rahe)

  static const _entryKey = 'purchase_entry_draft_json';
  Timer? _entryTimer;

  void _saveEntrySoon() {
    if (_isEdit) return;
    _entryTimer?.cancel();
    _entryTimer = Timer(const Duration(milliseconds: 400), _saveEntryNow);
  }

  void _saveEntryNow() {
    if (_isEdit) return;
    final data = jsonEncode({
      'item': _itemCtrl.text,
      'qty': _qtyCtrl.text,
      'rate': _rateCtrl.text,
      'retail': _retailCtrl.text,
      'wholesale': _wholesaleCtrl.text,
      'unit': _selectedUnit,
    });
    final empty = _itemCtrl.text.trim().isEmpty && _qtyCtrl.text.trim().isEmpty && _rateCtrl.text.trim().isEmpty;
    SharedPreferences.getInstance().then((p) => empty ? p.remove(_entryKey) : p.setString(_entryKey, data));
  }

  Future<void> _restoreEntry() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_entryKey);
    if (raw == null || !mounted) return;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final name = (m['item'] as String?) ?? '';
      if (name.trim().isEmpty && ((m['qty'] as String?) ?? '').isEmpty) return;
      // Products load hone ka intezar (max ~2s), taake item wapas pehchana ja sake.
      for (var i = 0; i < 20 && _products.isEmpty && mounted; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      if (!mounted) return;
      final product = _productByName(name);
      setState(() {
        _itemCtrl.text = name;
        if (product != null) {
          _pickedProduct = product;
          final u = (m['unit'] as String?) ?? '';
          _selectedUnit = u.isNotEmpty ? u : product.unit;
        }
        _qtyCtrl.text = (m['qty'] as String?) ?? '';
        _rateCtrl.text = (m['rate'] as String?) ?? '';
        _retailCtrl.text = (m['retail'] as String?) ?? '';
        _wholesaleCtrl.text = (m['wholesale'] as String?) ?? '';
        _mainRate = _toMain(double.tryParse(_rateCtrl.text.trim()) ?? 0.0);
        _mainRetail = _toMain(double.tryParse(_retailCtrl.text.trim()) ?? 0.0);
        _mainWholesale = _toMain(double.tryParse(_wholesaleCtrl.text.trim()) ?? 0.0);
      });
    } catch (_) {}
  }

  Future<void> _clearEntryDraft() async {
    _entryTimer?.cancel();
    final p = await SharedPreferences.getInstance();
    await p.remove(_entryKey);
  }

  // -------------------------------------------------------------- edit loading

  Future<void> _loadForEdit() async {
    try {
      final edit = await _repo.loadForEdit(widget.editBillNo!);
      if (!mounted) return;
      if (edit == null) {
        _toast('Ye bill nahi mila');
        Navigator.of(context).pop();
        return;
      }
      if (edit.purchase.status == 'returned') {
        _toast('Returned purchase edit nahi ho sakti');
        Navigator.of(context).pop();
        return;
      }
      setState(() {
        _supplierCtrl.text = edit.supplierName;
        _invoiceCtrl.text = edit.purchase.supplierInvoiceNo;
        _purchaseDate = DateTime.fromMillisecondsSinceEpoch(edit.purchase.createdAt);
        _lines
          ..clear()
          ..addAll(edit.lines);
        _paymentMethod = edit.paymentMethod;
        _splitPayments = List<PayEntry>.of(edit.payments);
        if (_splitPayments.isNotEmpty) {
          _paidCtrl.text = plainAmount(effectivePaidInput(_splitPayments, 0.0));
        } else {
          _paidCtrl.text = edit.purchase.paid > 0 ? plainAmount(edit.purchase.paid) : '';
        }
        _loading = false;
      });
      _refreshSupplierBalance(edit.supplierName);
    } catch (e) {
      if (!mounted) return;
      _toast('$e');
      Navigator.of(context).pop();
    }
  }

  // ---------------------------------------------------------- supplier balance

  Future<void> _refreshSupplierBalance(String name) async {
    final q = name.trim().toLowerCase();
    final match = q.isEmpty ? null : _suppliers.where((s) => s.name.toLowerCase() == q).firstOrNull;
    if (match == null || match.id == null) {
      if (mounted && _supplierBalance != null) setState(() => _supplierBalance = null);
      return;
    }
    final bal = await PartyRepository.instance.liveSupplierBalance(match.id!);
    if (!mounted) return;
    // Is dauran naam badal chuka ho to purana jawab na dikhayen.
    if (_supplierCtrl.text.trim().toLowerCase() != q) return;
    setState(() => _supplierBalance = bal);
  }

  // ----------------------------------------------------------- item entry logic

  Future<void> _onProductPicked(Product p) async {
    setState(() {
      _pickedProduct = p;
      _itemCtrl.text = p.name;
      _selectedUnit = p.unit;
      _mainRate = 0.0;
      _lastPurchaseMainRate = 0.0;
      _rateCtrl.text = '';
      _mainRetail = p.salePrice;
      _mainWholesale = p.wholesalePrice;
    });
    _fillRetailWholesaleText();
    _qtyFocus.requestFocus();

    // Pichli khareedi ka asli rate (running weighted-average cost nahi) — jab tak user ne khud rate na
    // likha ho, wahi auto-fill.
    final barcode = p.barcode;
    final last = await _repo.findLastPurchaseRate(barcode, excludeBillNo: widget.editBillNo);
    if (!mounted || _pickedProduct?.barcode != barcode) return;
    final lastMain = last == null ? 0.0 : p.toPrimaryUnitRate(last.rate, last.unit.isEmpty ? p.unit : last.unit);
    setState(() {
      _lastPurchaseMainRate = lastMain;
      if (_rateCtrl.text.trim().isEmpty) {
        _mainRate = lastMain > 0 ? lastMain : p.cost;
        _fillRateText();
      }
    });
  }

  void _fillRateText() {
    final p = _pickedProduct;
    final shown = (p != null && _mainRate > 0) ? p.fromPrimaryUnitRate(_mainRate, _effectiveUnit) : _mainRate;
    _rateCtrl.text = rateText(shown);
  }

  void _fillRetailWholesaleText() {
    final p = _pickedProduct;
    final unit = _effectiveUnit;
    final retail = (p != null && _mainRetail > 0) ? p.fromPrimaryUnitRate(_mainRetail, unit) : _mainRetail;
    final wholesale = (p != null && _mainWholesale > 0) ? p.fromPrimaryUnitRate(_mainWholesale, unit) : _mainWholesale;
    _retailCtrl.text = rateText(retail);
    _wholesaleCtrl.text = rateText(wholesale);
  }

  double _toMain(double entered) {
    final p = _pickedProduct;
    return p != null ? p.toPrimaryUnitRate(entered, _effectiveUnit) : entered;
  }

  void _onRateChanged(String v) => setState(() => _mainRate = _toMain(double.tryParse(v.trim()) ?? 0.0));
  void _onRetailChanged(String v) => setState(() => _mainRetail = _toMain(double.tryParse(v.trim()) ?? 0.0));
  void _onWholesaleChanged(String v) => setState(() => _mainWholesale = _toMain(double.tryParse(v.trim()) ?? 0.0));

  void _onUnitChanged(String u) {
    setState(() => _selectedUnit = u);
    _fillRateText();
    _fillRetailWholesaleText();
  }

  void _clearItemEntry() {
    _itemCtrl.clear();
    _qtyCtrl.clear();
    _rateCtrl.clear();
    _retailCtrl.clear();
    _wholesaleCtrl.clear();
    _pickedProduct = null;
    _selectedUnit = '';
    _mainRate = 0.0;
    _mainRetail = 0.0;
    _mainWholesale = 0.0;
    _lastPurchaseMainRate = 0.0;
    _editingIndex = null;
    _saveEntrySoon();
  }

  Product? _productByName(String name) {
    final n = name.trim().toLowerCase();
    return _products.where((p) => p.name.trim().toLowerCase() == n).firstOrNull;
  }

  Future<void> _addLine() async {
    final name = _itemCtrl.text.trim();
    final qty = double.tryParse(_qtyCtrl.text.trim()) ?? 0.0;
    final rate = double.tryParse(_rateCtrl.text.trim()) ?? 0.0;

    if (name.isEmpty) {
      _toast('Enter or pick an item');
      return;
    }
    if (qty <= 0) {
      _toast('Enter a valid quantity');
      return;
    }
    if (rate <= 0) {
      _toast('Enter a valid rate');
      return;
    }

    // Naam poora likha ho par list se na chuna ho to bhi pehchan lo.
    var product = _pickedProduct ?? _productByName(name);
    final editingIndex = _editingIndex;
    final editingBarcodeless = editingIndex != null && editingIndex < _lines.length && _lines[editingIndex].barcode == null;
    if (product == null && !editingBarcodeless) {
      // Kotlin: unknown item -> Add Product dialog (stock/cost sirf asli product par lagta hai).
      await _promptAddProduct(name);
      return;
    }
    if (product != null && _pickedProduct == null) {
      // Naam se mila product: uski primary unit par aa jao (rate wahi jo user ne likha).
      _pickedProduct = product;
      if (_selectedUnit.isEmpty) _selectedUnit = product.unit;
      _mainRate = product.toPrimaryUnitRate(rate, _effectiveUnit);
    }

    final unit = _effectiveUnit;
    final line = PurchaseLine(
      itemName: product?.name ?? name,
      barcode: product?.barcode,
      qty: qty,
      unit: unit,
      rate: rate,
      amount: qty * rate,
      retailRate: _retailCtrl.text.trim().isEmpty ? 0.0 : _mainRetail,
      wholesaleRate: _wholesaleCtrl.text.trim().isEmpty ? 0.0 : _mainWholesale,
    );

    setState(() {
      if (editingIndex != null && editingIndex < _lines.length) {
        _lines[editingIndex] = line;
      } else {
        _lines.add(line);
      }
      _clearItemEntry();
    });
    _saveDraftSoon();
    _itemFocus.requestFocus();
  }

  void _editLine(int i) {
    final l = _lines[i];
    final p = l.barcode == null ? null : _products.where((x) => x.barcode == l.barcode).firstOrNull;
    setState(() {
      _editingIndex = i;
      _pickedProduct = p;
      _itemCtrl.text = l.itemName;
      _selectedUnit = l.unit;
      _qtyCtrl.text = qtyText(l.qty);
      _rateCtrl.text = rateText(l.rate);
      _mainRate = p != null ? p.toPrimaryUnitRate(l.rate, l.unit) : l.rate;
      _mainRetail = l.retailRate;
      _mainWholesale = l.wholesaleRate;
      _lastPurchaseMainRate = 0.0;
    });
    _fillRetailWholesaleText();
  }

  void _cancelLineEdit() => setState(_clearItemEntry);

  void _removeLine(int index) {
    setState(() {
      _lines.removeAt(index);
      final e = _editingIndex;
      if (e != null) {
        if (e == index) {
          _clearItemEntry();
        } else if (e > index) {
          _editingIndex = e - 1;
        }
      }
    });
    _saveDraftSoon();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _purchaseDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked != null) setState(() => _purchaseDate = picked);
  }

  // ------------------------------------------------------------ new product

  /// Kotlin openAddProductDialog(): purchase ke beech mein naya product (naam, unit, retail, wholesale).
  /// Cost isi purchase se banti hai; stock isi bill ke save par lagta hai.
  Future<void> _promptAddProduct(String prefillName) async {
    final nameCtrl = TextEditingController(text: prefillName);
    final retailCtrl = TextEditingController(text: _retailCtrl.text);
    final wholesaleCtrl = TextEditingController(text: _wholesaleCtrl.text);
    final unitNames = <String>{};
    try {
      final units = await UnitRepository.instance.listAll();
      for (final u in units) {
        if (u.name.trim().isNotEmpty) unitNames.add(u.name.trim());
      }
    } catch (_) {}
    if (unitNames.isEmpty) unitNames.add('pcs');
    var unit = unitNames.contains(_selectedUnit) ? _selectedUnit : unitNames.first;
    if (!mounted) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(Loc.t('Add New Product', 'نیا پروڈکٹ شامل کریں')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(controller: nameCtrl, decoration: InputDecoration(labelText: Loc.t('Product name', 'پروڈکٹ کا نام'))),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: unit,
                  decoration: InputDecoration(labelText: Loc.t('Unit', 'یونٹ')),
                  items: [for (final u in unitNames) DropdownMenuItem(value: u, child: Text(u))],
                  onChanged: (v) => setD(() => unit = v ?? unit),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: retailCtrl,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(labelText: Loc.t('Retail rate (optional)', 'ریٹیل ریٹ (اختیاری)')),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: wholesaleCtrl,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(labelText: Loc.t('Wholesale rate (optional)', 'ہول سیل ریٹ (اختیاری)')),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(Loc.t('Cancel', 'منسوخ کریں'))),
            FilledButton(
              onPressed: () {
                if (nameCtrl.text.trim().isEmpty) {
                  _toast('Product name is required');
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

    final name = nameCtrl.text.trim();
    final retail = double.tryParse(retailCtrl.text.trim()) ?? 0.0;
    final wholesale = double.tryParse(wholesaleCtrl.text.trim()) ?? 0.0;
    nameCtrl.dispose();
    retailCtrl.dispose();
    wholesaleCtrl.dispose();
    if (ok != true || !mounted) return;

    final existing = _productByName(name);
    if (existing != null) {
      _toast(Loc.t('A product with this name already exists — picked it', 'اس نام کا پروڈکٹ پہلے سے ہے — وہی چن لیا'));
      await _onProductPicked(existing);
      return;
    }
    final product = Product(
      barcode: 'P${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      category: 'General',
      unit: unit,
      salePrice: retail,
      wholesalePrice: wholesale,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
      dirty: true,
    );
    await ProductRepository.instance.upsert(product, isNew: true);
    if (!mounted) return;
    _toast(Loc.t('Product added', 'پروڈکٹ شامل ہو گیا'));
    // Rate jo user pehle likh chuka tha, wahi rakho — sirf product/unit/rates set karo.
    final typedRate = double.tryParse(_rateCtrl.text.trim()) ?? 0.0;
    setState(() {
      _pickedProduct = product;
      _itemCtrl.text = product.name;
      _selectedUnit = product.unit;
      _mainRate = typedRate;
      _mainRetail = retail;
      _mainWholesale = wholesale;
    });
    _fillRateText();
    _fillRetailWholesaleText();
  }

  // -------------------------------------------------------------- Split payment

  void _applySplitPayments(List<PayEntry> entries) {
    setState(() {
      _splitPayments = entries;
      _paidCtrl.text = plainAmount(effectivePaidInput(entries, 0.0));
    });
    _saveDraftSoon();
  }

  void _clearSplitPayments() => setState(() => _splitPayments = []);

  /// Rs 300 Cash + Rs 200 Bank ek bill par. Mirrors openSplitPaymentDialog().
  Future<void> _openSplitPaymentDialog() async {
    const methods = ['Cash', 'Bank'];
    final amountCtrls = <TextEditingController>[];
    final rowMethods = <String>[];
    void addRow(String method, double amount) {
      amountCtrls.add(TextEditingController(text: amount > 0 ? plainAmount(amount) : ''));
      rowMethods.add(method);
    }

    final hadSplit = _splitPayments.isNotEmpty;
    if (hadSplit) {
      for (final p in _splitPayments) {
        addRow(p.method, p.amount);
      }
    } else {
      addRow('Cash', 0);
      addRow('Bank', 0);
    }
    final billTotal = _grandTotal;

    final result = await showDialog<List<PayEntry>?>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(Loc.t('Split Payment', 'ادائیگی تقسیم کریں')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  Loc.t('Bill Total: Rs ${billTotal.toStringAsFixed(2)}', 'بل کل: Rs ${billTotal.toStringAsFixed(2)}'),
                  style: const TextStyle(fontSize: 13, color: Colors.black54),
                ),
                const SizedBox(height: 8),
                for (var i = 0; i < amountCtrls.length; i++)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: DropdownButton<String>(
                            isExpanded: true,
                            value: rowMethods[i],
                            items: [for (final m in methods) DropdownMenuItem(value: m, child: Text(m))],
                            onChanged: (v) => setD(() => rowMethods[i] = v ?? 'Cash'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: amountCtrls[i],
                            textAlign: TextAlign.end,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            decoration: const InputDecoration(hintText: '0.00', isDense: true),
                          ),
                        ),
                        IconButton(
                          tooltip: Loc.t('Remove', 'ہٹائیں'),
                          icon: const Icon(Icons.close, color: AppColors.red, size: 20),
                          onPressed: () => setD(() {
                            amountCtrls[i].dispose();
                            amountCtrls.removeAt(i);
                            rowMethods.removeAt(i);
                          }),
                        ),
                      ],
                    ),
                  ),
                TextButton(
                  onPressed: () => setD(() => addRow('Cash', 0)),
                  child: Text(Loc.t('+ Add another method', '+ ایک اور طریقہ شامل کریں')),
                ),
              ],
            ),
          ),
          actions: [
            if (hadSplit)
              TextButton(
                onPressed: () => Navigator.pop(ctx, const <PayEntry>[]),
                child: Text(Loc.t('Remove Split', 'تقسیم ہٹائیں')),
              ),
            TextButton(onPressed: () => Navigator.pop(ctx, null), child: Text(Loc.t('Cancel', 'منسوخ کریں'))),
            FilledButton(
              onPressed: () {
                final entries = <PayEntry>[];
                for (var i = 0; i < amountCtrls.length; i++) {
                  final amt = parseMoneyOrWarn(ctx, amountCtrls[i].text, 'Payment Amount', 'ادائیگی کی رقم');
                  if (amt == null) return; // ghalat text: warn kiya, dialog khula rakho
                  if (amt > 0.009) entries.add(PayEntry(rowMethods[i], amt));
                }
                if (entries.isEmpty) {
                  _toast(Loc.t('Kam az kam ek payment amount daalen', 'کم از کم ایک ادائیگی کی رقم درج کریں'));
                  return;
                }
                Navigator.pop(ctx, entries);
              },
              child: Text(Loc.t('Apply', 'لاگو کریں')),
            ),
          ],
        ),
      ),
    );
    for (final c in amountCtrls) {
      c.dispose();
    }
    if (result == null || !mounted) return;
    if (result.isEmpty) {
      _clearSplitPayments();
    } else {
      _applySplitPayments(result);
    }
  }

  // ---------------------------------------------------------------------- save

  Future<bool> _confirm({required String title, required String message, required String yes, String? no}) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(no ?? Loc.t('Cancel', 'منسوخ کریں'))),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text(yes)),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _save() async {
    final party = _supplierCtrl.text.trim();
    if (party.isEmpty) {
      _toast('Supplier name is required');
      return;
    }
    if (_lines.isEmpty) {
      _toast('Add at least one item');
      return;
    }
    if (_editingIndex != null) {
      _toast(Loc.t('Pehle line update ya cancel karen', 'پہلے لائن اپڈیٹ یا منسوخ کریں'));
      return;
    }

    final grandTotal = _grandTotal;
    final paidParsed = parseMoneyOrWarn(context, _paidCtrl.text, 'Paid Amount', 'ادا شدہ رقم');
    if (paidParsed == null) return;
    final paid = effectivePaidInput(_splitPayments, paidParsed);

    if (paid <= 0.009 && grandTotal > 0) {
      final confirmed = await _confirm(
        title: 'Confirm Credit Purchase',
        message: 'You have not entered Paid Amount.\nTotal: Rs ${grandTotal.toStringAsFixed(0)}\n\n'
            'This bill will be saved as CREDIT (Udhaar).\nSupplier balance will increase.\n\nAre you sure?',
        yes: 'Yes, Save as Credit',
        no: 'Enter Payment',
      );
      if (!confirmed || !mounted) return;
    }

    final invoiceNo = _invoiceCtrl.text.trim();

    // 1) Exact duplicate: usi supplier ka usi invoice number.
    if (invoiceNo.isNotEmpty) {
      final dupInv = await _repo.findDuplicateBySupplierInvoice(party, invoiceNo, excludeBillNo: widget.editBillNo);
      if (!mounted) return;
      if (dupInv != null) {
        final go = await _confirm(
          title: Loc.t('Duplicate Invoice Number', 'ڈپلیکیٹ انوائس نمبر'),
          message: Loc.t(
            'Invoice #$invoiceNo from $party is already recorded as Bill #${dupInv.billNo}.\n\nSave this one anyway?',
            '$party کا انوائس نمبر #$invoiceNo پہلے ہی بل نمبر #${dupInv.billNo} کے طور پر محفوظ ہے۔\n\nکیا پھر بھی محفوظ کریں؟',
          ),
          yes: Loc.t('Save Anyway', 'پھر بھی محفوظ کریں'),
        );
        if (!go || !mounted) return;
      }
    }

    // 2) Andaza: same supplier + same total + same bill date.
    final dup = await _repo.findPossibleDuplicate(
      supplierName: party,
      total: grandTotal,
      dateMillis: _purchaseDate.millisecondsSinceEpoch,
      excludeBillNo: widget.editBillNo,
    );
    if (!mounted) return;
    if (dup != null) {
      final when = DateFormat('dd MMM yyyy, hh:mm a').format(DateTime.fromMillisecondsSinceEpoch(dup.createdAt));
      final go = await _confirm(
        title: Loc.t('Possible Duplicate Bill', 'ممکنہ ڈپلیکیٹ بل'),
        message: Loc.t(
          'A purchase from $party for Rs ${grandTotal.toStringAsFixed(0)} was already saved on $when (Bill #${dup.billNo}).\n\nSave this one anyway?',
          '$party کی طرف سے Rs ${grandTotal.toStringAsFixed(0)} کی خریداری پہلے ہی $when کو محفوظ ہو چکی ہے (بل نمبر ${dup.billNo})۔\n\nکیا پھر بھی محفوظ کریں؟',
        ),
        yes: Loc.t('Save Anyway', 'پھر بھی محفوظ کریں'),
      );
      if (!go || !mounted) return;
    }

    final snapshotLines = List<PurchaseLine>.of(_lines);
    final snapshotDate = _purchaseDate;
    final snapshotMethod = paymentMethodLabel(paid: paid, payments: _splitPayments, singleMethod: _paymentMethod);

    setState(() => _saving = true);
    try {
      final billNo = await _repo.savePurchase(
        supplierName: party,
        lines: _lines,
        amountPaid: paid,
        purchaseDateMillis: _purchaseDate.millisecondsSinceEpoch,
        paymentMethod: _paymentMethod,
        editBillNo: widget.editBillNo,
        supplierInvoiceNo: invoiceNo,
        payments: _splitPayments,
      );
      await PurchaseDraftStore.clear();
      await _clearEntryDraft();
      if (!mounted) return;
      _toast(_isEdit ? 'Purchase updated: $billNo' : 'Purchase saved: $billNo');

      // Bill Preview (print / WhatsApp / share) pehle jaisa: edit ho ya naya bill, dono par dikhao.
      await _showBillPreview(
        billNo: billNo,
        supplier: party,
        date: snapshotDate,
        lines: snapshotLines,
        total: grandTotal,
        paid: paid.clamp(0.0, grandTotal).toDouble(),
        method: snapshotMethod == 'credit' ? 'Credit' : snapshotMethod,
      );
      if (!mounted) return;

      if (_isEdit) {
        Navigator.of(context).pop(true);
        return;
      }
      setState(() {
        _lines.clear();
        _clearItemEntry();
        _supplierCtrl.clear();
        _invoiceCtrl.clear();
        _paidCtrl.clear();
        _splitPayments = [];
        _supplierBalance = null;
        _purchaseDate = DateTime.now();
      });
      _supplierFocus.requestFocus(); // naya bill: cursor seedha supplier par
    } catch (e) {
      _toast('Could not save purchase: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ------------------------------------------------------------ delete (edit mode)

  /// Kotlin `deletePurchase` (edit screen ka Delete button): confirm -> poora bill hata do. Stock + weighted
  /// cost, supplier ka baaqi, bill ke payments / cash rows sab ek transaction mein wapas (History ke Delete jaisa).
  Future<void> _deletePurchase() async {
    final billNo = widget.editBillNo;
    if (billNo == null || _saving) return;
    if (!Session.isAdmin) {
      _toast(Loc.t('Only Admin can delete a purchase', 'صرف ایڈمن خریداری ڈیلیٹ کر سکتا ہے'));
      return;
    }
    final confirmed = await _confirm(
      title: 'Delete Purchase',
      message: 'Bill $billNo poora delete ho jayega:\n'
          '• khareedi hua stock aur cost wapas\n'
          '• supplier ka baaqi theek\n'
          '• is bill ke payments / cash entries hat jayengi\n\n'
          'Ye wapas nahi ho sakta. Delete karen?',
      yes: 'DELETE',
    );
    if (!confirmed || !mounted) return;
    setState(() => _saving = true);
    try {
      await PurchaseHistoryRepository.instance.deletePurchase(billNo);
      await ProductRepository.instance.refresh();
      await SupplierRepository.instance.refresh();
      if (!mounted) return;
      _toast('Purchase deleted: $billNo');
      Navigator.of(context).pop(true);
    } catch (e) {
      _toast('Could not delete purchase: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ------------------------------------------------- supplier rate comparison

  /// Kotlin supplier comparison popup: chuna hua item kis supplier se kitne mein aaya (sasta pehle).
  /// Rates product ki PRIMARY unit par normalized hain; dikhate waqt maujuda chuni hui unit mein.
  Future<void> _showSupplierComparison() async {
    final product = _pickedProduct;
    if (product == null) {
      _toast(Loc.t('Pehle item chunen', 'پہلے آئٹم منتخب کریں'));
      return;
    }
    if (!Session.isAdminOrManager) return;
    List<SupplierRateRow> rows;
    try {
      rows = await RateComparisonRepository.instance.compare(product);
    } catch (e) {
      _toast('Could not load supplier rates: $e');
      return;
    }
    if (!mounted) return;
    final unit = _effectiveUnit;
    final fmt = DateFormat('dd MMM yy');
    String r(double primaryRate) => 'Rs ${product.fromPrimaryUnitRate(primaryRate, unit).toStringAsFixed(2)}';
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${product.name} — ${Loc.t('Supplier rates', 'سپلائر ریٹ')}'),
        content: SizedBox(
          width: double.maxFinite,
          child: rows.isEmpty
              ? Text(Loc.t('Is item ki abhi koi supplier khareed nahi.', 'اس آئٹم کی ابھی کوئی سپلائر خریداری نہیں۔'))
              : ListView.separated(
                  shrinkWrap: true,
                  itemCount: rows.length,
                  separatorBuilder: (_, __) => const Divider(height: 14),
                  itemBuilder: (_, i) {
                    final row = rows[i];
                    final best = i == 0 && rows.length > 1;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Expanded(
                            child: Text(row.supplierName,
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                          ),
                          if (best)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                  color: AppColors.teal.withOpacity(0.15), borderRadius: BorderRadius.circular(10)),
                              child: const Text('CHEAPEST',
                                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: AppColors.teal)),
                            ),
                        ]),
                        const SizedBox(height: 2),
                        Text(
                          'Last ${r(row.lastRate)} / $unit  (${fmt.format(DateTime.fromMillisecondsSinceEpoch(row.lastDate))})',
                          style: const TextStyle(fontSize: 12.5),
                        ),
                        Text(
                          'Low ${r(row.minRate)}  •  High ${r(row.maxRate)}  •  ${row.timesPurchased}x',
                          style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
                        ),
                      ],
                    );
                  },
                ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(Loc.t('Close', 'بند کریں')))],
      ),
    );
  }

  Future<void> _showBillPreview({
    required String billNo,
    required String supplier,
    required DateTime date,
    required List<PurchaseLine> lines,
    required double total,
    required double paid,
    required String method,
  }) async {
    if (!mounted) return;
    await BillPreviewScreen.open(
      context,
      BillDoc(
        isPurchase: true,
        ref: billNo,
        date: date,
        partyName: supplier,
        items: [
          for (final l in lines) BillItem(name: l.itemName, qty: l.qty, unit: l.unit, rate: l.rate, amount: l.amount),
        ],
        subtotal: lines.fold<double>(0, (s, l) => s + l.amount),
        discount: 0.0,
        total: total,
        paid: paid,
        paymentMethod: method,
      ),
    );
  }

  // --------------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                      padding: const EdgeInsets.fromLTRB(16, 20, 16, 20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          PremiumHeader(
                            title: _isEdit ? 'Edit Purchase' : 'New Purchase',
                            subtitle: _isEdit ? 'Bill ${widget.editBillNo}' : 'Stock In / Supplier Bill',
                          ),
                          _buildDateRow(),
                          _buildSupplierCard(),
                          _buildItemEntryCard(),
                          _buildLinesList(),
                          _buildTotalsCard(),
                        ],
                      ),
                    ),
                  ),
                  _buildSaveBar(),
                ],
              ),
      ),
    );
  }

  Widget _fieldBox({required Widget child}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        decoration: BoxDecoration(
          color: AppColors.fieldFill,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border, width: 1.2),
        ),
        child: child,
      );

  /// Upar ki row: sirf Date button (Hold / Recall / Scan Bill purchase se hata diye gaye).
  Widget _buildDateRow() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: _pickDate,
          icon: const Icon(Icons.calendar_today_outlined, size: 18),
          label: Text(DateFormat('dd MMM yyyy').format(_purchaseDate)),
        ),
      ),
    );
  }

  Widget _buildSupplierCard() {
    final bal = _supplierBalance;
    return PremiumCard(
      accentTop: AppColors.teal,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionLabel(emoji: '🧾', label: 'Supplier', accent: AppColors.teal),
          _fieldBox(
            child: RawAutocomplete<String>(
              textEditingController: _supplierCtrl,
              focusNode: _supplierFocus,
              onSelected: (v) {
                _refreshSupplierBalance(v);
                _saveDraftSoon();
              },
              optionsBuilder: (text) {
                final q = text.text.trim().toLowerCase();
                final names = _suppliers.map((s) => s.name);
                if (q.isEmpty) return names;
                return names.where((n) => n.toLowerCase().contains(q));
              },
              fieldViewBuilder: (context, controller, focusNode, onSubmit) => TextField(
                controller: controller,
                focusNode: focusNode,
                textInputAction: TextInputAction.next,
                onChanged: (v) {
                  _refreshSupplierBalance(v);
                  _saveDraftSoon();
                },
                onSubmitted: (_) {
                  // Sirf ek hi naam match kare to wahi chun lo (keyboard se); warna likha hua naam rehne do.
                  final q = controller.text.trim().toLowerCase();
                  final hits = q.isEmpty ? const <Supplier>[] : _suppliers.where((x) => x.name.toLowerCase().contains(q)).toList();
                  if (hits.length == 1 && hits.first.name.toLowerCase() != q) {
                    controller.text = hits.first.name;
                    controller.selection = TextSelection.collapsed(offset: controller.text.length);
                    _refreshSupplierBalance(hits.first.name);
                    _saveDraftSoon();
                  }
                  _invoiceFocus.requestFocus();
                },
                decoration: const InputDecoration(
                  hintText: 'Type or pick a supplier — new names are added automatically',
                  border: InputBorder.none,
                  isDense: true,
                ),
              ),
              optionsViewBuilder: (context, onSelected, options) =>
                  autocompleteOptionsView<String>(context, onSelected, options, (o) => o, maxWidth: 640),
            ),
          ),
          if (bal != null && bal.abs() > 0.009)
            Padding(
              padding: const EdgeInsets.only(top: 8, left: 4),
              child: Text(
                bal > 0
                    ? Loc.t('You owe: Rs ${bal.toStringAsFixed(0)}', 'آپ پر واجب الادا: Rs ${bal.toStringAsFixed(0)}')
                    : Loc.t('Advance with supplier: Rs ${(-bal).toStringAsFixed(0)}', 'سپلائر کے پاس ایڈوانس: Rs ${(-bal).toStringAsFixed(0)}'),
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: bal > 0 ? AppColors.red : AppColors.teal),
              ),
            ),
          const SizedBox(height: 12),
          PremiumLabeledField(
            emoji: '📄',
            label: "Supplier's Invoice No. (optional)",
            accent: AppColors.teal,
            controller: _invoiceCtrl,
            focusNode: _invoiceFocus,
            keyboardType: TextInputType.text,
            hint: 'e.g. INV-1042',
            onChanged: (_) => _saveDraftSoon(),
            onSubmitted: () => _itemFocus.requestFocus(),
          ),
        ],
      ),
    );
  }

  Widget _marginLabel(PurchaseMargin m) {
    if (m.level == MarginLevel.none) return const SizedBox.shrink();
    Color color;
    String text;
    if (m.level == MarginLevel.loss) {
      color = AppColors.red;
      text = Loc.t(
        '⚠ Loss! Purchase rate ≥ current Sale Rate (Rs ${m.salePrice.toStringAsFixed(2)})',
        '⚠ نقصان! خریداری ریٹ موجودہ سیل ریٹ (روپے ${m.salePrice.toStringAsFixed(2)}) کے برابر یا زیادہ ہے',
      );
    } else if (m.level == MarginLevel.low) {
      color = AppColors.orange;
      text = Loc.t(
        '⚠ Low margin: Rs ${m.margin.toStringAsFixed(2)} (${m.marginPct.toStringAsFixed(1)}%) vs Sale Rate Rs ${m.salePrice.toStringAsFixed(2)}',
        '⚠ کم منافع: روپے ${m.margin.toStringAsFixed(2)} (${m.marginPct.toStringAsFixed(1)}%) بمقابلہ سیل ریٹ روپے ${m.salePrice.toStringAsFixed(2)}',
      );
    } else {
      color = AppColors.teal;
      text = Loc.t(
        'Margin: Rs ${m.margin.toStringAsFixed(2)} (${m.marginPct.toStringAsFixed(1)}%) vs Sale Rate Rs ${m.salePrice.toStringAsFixed(2)}',
        'منافع: روپے ${m.margin.toStringAsFixed(2)} (${m.marginPct.toStringAsFixed(1)}%) بمقابلہ سیل ریٹ روپے ${m.salePrice.toStringAsFixed(2)}',
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 6, left: 4),
      child: Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: color)),
    );
  }

  Widget _buildItemEntryCard() {
    final picked = _pickedProduct;
    final unitOptions = picked != null ? picked.unitLadder().map((t) => t.unit).toList() : <String>['pcs'];
    final unitValue = unitOptions.contains(_selectedUnit) ? _selectedUnit : unitOptions.first;
    final margin = purchaseMargin(salePriceMain: picked?.salePrice ?? 0.0, purchaseRateMain: _mainRate);
    final qty = double.tryParse(_qtyCtrl.text.trim()) ?? 0.0;
    final rate = double.tryParse(_rateCtrl.text.trim()) ?? 0.0;
    final editing = _editingIndex != null;

    return PremiumCard(
      accentTop: AppColors.amber,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionLabel(emoji: editing ? '✏️' : '➕', label: editing ? 'Edit Line' : 'Add Item', accent: AppColors.amber),
          Row(
            children: [
              Expanded(
                child: _fieldBox(
                  child: RawAutocomplete<Product>(
                    textEditingController: _itemCtrl,
                    focusNode: _itemFocus,
                    displayStringForOption: (p) => p.name,
                    optionsBuilder: (text) {
                      if (text.text.trim().isEmpty) return const Iterable<Product>.empty();
                      return _products.where((p) => p.matchesQuery(text.text));
                    },
                    onSelected: _onProductPicked,
                    fieldViewBuilder: (context, controller, focusNode, onSubmit) => TextField(
                      controller: controller,
                      focusNode: focusNode,
                      textInputAction: TextInputAction.next,
                      onSubmitted: (_) {
                        // Ek hi match ho (ya naam poora mile) to wahi chun kar Qty par jao; khali ho to Paid par.
                        final t = _itemCtrl.text.trim();
                        if (t.isEmpty) {
                          _paidFocus.requestFocus();
                          return;
                        }
                        final exact = _productByName(t);
                        final hits = _products.where((x) => x.matchesQuery(t)).toList();
                        final chosen = exact ?? (hits.length == 1 ? hits.first : null);
                        if (chosen != null) {
                          _onProductPicked(chosen);
                        } else if (hits.isNotEmpty) {
                          _itemFocus.requestFocus(); // kai match: list se chunna hai
                        } else {
                          _qtyFocus.requestFocus();
                        }
                      },
                      onChanged: (v) {
                        _saveEntrySoon();
                        // Doosra naam likhne par pichla chuna hua product chhod do.
                        final pp = _pickedProduct;
                        if (pp != null && pp.name != v) {
                          setState(() {
                            _pickedProduct = null;
                            _selectedUnit = '';
                            _lastPurchaseMainRate = 0.0;
                          });
                        }
                      },
                      decoration: const InputDecoration(
                        hintText: 'Product name — pick from list or tap + for a new one',
                        border: InputBorder.none,
                        isDense: true,
                      ),
                    ),
                    optionsViewBuilder: (context, onSelected, options) =>
                        autocompleteOptionsView<Product>(context, onSelected, options, (o) => o.name, maxWidth: 640),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                tooltip: Loc.t('New product', 'نیا پروڈکٹ'),
                style: IconButton.styleFrom(backgroundColor: AppColors.teal),
                icon: const Icon(Icons.add),
                onPressed: () => _promptAddProduct(_itemCtrl.text.trim()),
              ),
            ],
          ),
          if (picked != null)
            Padding(
              padding: const EdgeInsets.only(top: 8, left: 4),
              child: Text(
                'In stock: ${picked.formatStockBreakdown()}'
                '${_lastPurchaseMainRate > 0 ? '   •   Last purchase: Rs ${picked.fromPrimaryUnitRate(_lastPurchaseMainRate, unitValue).toStringAsFixed(2)} / $unitValue' : ''}',
                style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
              ),
            ),
          if (picked != null && Session.isAdminOrManager)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 4), minimumSize: const Size(0, 32)),
                onPressed: _showSupplierComparison,
                icon: const Icon(Icons.compare_arrows, size: 18, color: AppColors.purple),
                label: Text(Loc.t('Compare suppliers', 'سپلائر موازنہ'),
                    style: const TextStyle(fontSize: 12.5, color: AppColors.purple)),
              ),
            ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: PremiumLabeledField(
                  emoji: '🔢',
                  label: 'Quantity',
                  accent: AppColors.amber,
                  controller: _qtyCtrl,
                  focusNode: _qtyFocus,
                  hint: '0',
                  onChanged: (_) {
                    setState(() {});
                    _saveEntrySoon();
                  },
                  onSubmitted: () => _rateFocus.requestFocus(),
                ),
              ),
              const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: AppColors.fieldFill,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.border, width: 1.2),
                ),
                child: DropdownButton<String>(
                  value: unitValue,
                  underline: const SizedBox.shrink(),
                  items: unitOptions.map((u) => DropdownMenuItem(value: u, child: Text(u))).toList(),
                  onChanged: (v) {
                    if (v != null) _onUnitChanged(v);
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          PremiumLabeledField(
            emoji: '💵',
            label: 'Rate (per $unitValue)',
            accent: AppColors.orange,
            controller: _rateCtrl,
            focusNode: _rateFocus,
            onChanged: (v) {
              _onRateChanged(v);
              _saveEntrySoon();
            },
            textInputAction: picked != null ? TextInputAction.next : TextInputAction.done,
            onSubmitted: () {
              if (picked != null) {
                _retailFocus.requestFocus();
              } else {
                _addLine();
              }
            },
          ),
          _marginLabel(margin),
          if (picked != null) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: PremiumLabeledField(
                    emoji: '🏷️',
                    label: 'Retail Rate',
                    accent: AppColors.teal,
                    controller: _retailCtrl,
                    focusNode: _retailFocus,
                    onChanged: (v) {
                      _onRetailChanged(v);
                      _saveEntrySoon();
                    },
                    onSubmitted: () => _wholesaleFocus.requestFocus(),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: PremiumLabeledField(
                    emoji: '📦',
                    label: 'Wholesale Rate',
                    accent: AppColors.blue,
                    controller: _wholesaleCtrl,
                    focusNode: _wholesaleFocus,
                    textInputAction: TextInputAction.done,
                    onChanged: (v) {
                      _onWholesaleChanged(v);
                      _saveEntrySoon();
                    },
                    onSubmitted: _addLine,
                  ),
                ),
              ],
            ),
          ],
          if (qty > 0 && rate > 0)
            Padding(
              padding: const EdgeInsets.only(top: 10, left: 4),
              child: Text(
                'Line total: Rs ${(qty * rate).toStringAsFixed(2)}',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: AppColors.textDark),
              ),
            ),
          const SizedBox(height: 12),
          Row(
            children: [
              if (editing) ...[
                Expanded(
                  child: OutlinedButton(
                    onPressed: _cancelLineEdit,
                    child: Text(Loc.t('Cancel', 'منسوخ کریں')),
                  ),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                flex: 2,
                child: GradientButton(
                  label: editing ? 'Update Line' : 'Add to Bill',
                  emoji: editing ? '✔' : '✚',
                  start: AppColors.teal,
                  end: AppColors.tealDark,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  onTap: _addLine,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLinesList() {
    if (_lines.isEmpty) return const SizedBox.shrink();
    return PremiumCard(
      accentTop: AppColors.navy,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionLabel(emoji: '🧾', label: 'Bill Items', accent: AppColors.navy),
          ..._lines.asMap().entries.map((entry) {
            final i = entry.key;
            final line = entry.value;
            final isEditing = _editingIndex == i;
            return InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => _editLine(i),
              child: Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: isEditing ? AppColors.savedHighlightBg : AppColors.fieldFill,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: isEditing ? AppColors.teal : AppColors.border),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(line.itemName, style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.textDark)),
                          Text(
                            '${qtyText(line.qty)} ${line.unit}  ×  ${line.rate.toStringAsFixed(2)}',
                            style: const TextStyle(fontSize: 11.5, color: AppColors.textMuted),
                          ),
                        ],
                      ),
                    ),
                    Text(line.amount.toStringAsFixed(2), style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.teal)),
                    IconButton(
                      icon: const Icon(Icons.close, size: 18, color: AppColors.red),
                      onPressed: () => _removeLine(i),
                    ),
                  ],
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildTotalsCard() {
    final total = _grandTotal;
    final paid = _effectivePaid;
    final due = (total - paid) < 0 ? 0.0 : (total - paid);
    final split = _splitPayments.isNotEmpty;
    return PremiumCard(
      accentTop: AppColors.purple,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionLabel(emoji: '💰', label: 'Payment', accent: AppColors.purple),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Subtotal', style: TextStyle(color: AppColors.textMuted)),
              Text(_subtotal.toStringAsFixed(2), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: AppColors.textDark)),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Total (rounded)', style: TextStyle(color: AppColors.textMuted)),
              Text(total.toStringAsFixed(0), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: AppColors.textDark)),
            ],
          ),
          const SizedBox(height: 12),
          PremiumLabeledField(
            emoji: '💵',
            label: 'Paid Amount (leave 0 for credit)',
            accent: AppColors.purple,
            controller: _paidCtrl,
            focusNode: _paidFocus,
            enabled: !split,
            textInputAction: TextInputAction.done,
            onSubmitted: () {
              FocusScope.of(context).unfocus();
              if (!_saving) _save();
            },
            onChanged: (_) {
              setState(() {});
              _saveDraftSoon();
            },
          ),
          const SizedBox(height: 10),
          if (!split)
            Row(
              children: [
                for (final m in const ['Cash', 'Bank']) ...[
                  ChoiceChip(
                    label: Text(m),
                    selected: _paymentMethod == m,
                    onSelected: (_) => setState(() => _paymentMethod = m),
                  ),
                  const SizedBox(width: 8),
                ],
                const Spacer(),
                TextButton(
                  onPressed: _openSplitPaymentDialog,
                  child: Text(Loc.t('Split Payment', 'ادائیگی تقسیم')),
                ),
              ],
            )
          else
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${Loc.t('Split', 'تقسیم')}: ${splitBreakdown(_splitPayments)}',
                    style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: AppColors.purple),
                  ),
                ),
                TextButton(onPressed: _openSplitPaymentDialog, child: Text(Loc.t('Edit', 'ترمیم'))),
                IconButton(
                  tooltip: Loc.t('Remove split', 'تقسیم ہٹائیں'),
                  icon: const Icon(Icons.close, size: 18, color: AppColors.red),
                  onPressed: _clearSplitPayments,
                ),
              ],
            ),
          if (total > 0)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                due > 0.009
                    ? Loc.t('Due to supplier: Rs ${due.toStringAsFixed(0)}', 'سپلائر کو باقی: Rs ${due.toStringAsFixed(0)}')
                    : Loc.t('Fully paid', 'مکمل ادا'),
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: due > 0.009 ? AppColors.red : AppColors.teal),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSaveBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
      decoration: BoxDecoration(
        color: AppColors.cardWhite,
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 10, offset: const Offset(0, -3))],
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            if (_isEdit && Session.isAdmin) ...[
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.red,
                  side: const BorderSide(color: AppColors.red),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                ),
                onPressed: _saving ? null : _deletePurchase,
                icon: const Icon(Icons.delete_outline),
                label: Text(Loc.t('Delete', 'ڈیلیٹ')),
              ),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: GradientButton(
                label: _saving ? 'SAVING…' : (_isEdit ? 'UPDATE PURCHASE' : 'SAVE PURCHASE'),
                emoji: '💾',
                start: AppColors.navy,
                end: AppColors.navyLight,
                radius: 16,
                padding: const EdgeInsets.symmetric(vertical: 18),
                onTap: _saving ? () {} : _save,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
