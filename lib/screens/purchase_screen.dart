import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:shared_preferences/shared_preferences.dart';

import '../db/category_unit_repository.dart';
import '../db/party_repository.dart';
import '../db/product_repository.dart';
import '../db/purchase_history_repository.dart' show PurchaseHistoryRepository;
import '../db/purchase_repository.dart';
import '../db/rate_comparison_repository.dart' show RateComparisonRepository, SupplierRateRow;
import '../db/supplier_repository.dart';
import '../db/user_repository.dart';
import '../models/category_unit.dart' as models;
import '../models/party.dart';
import '../models/product.dart';
import '../services/purchase_hold_recall.dart';
import '../services/session.dart';
import '../utils/bill_doc.dart';
import 'bill_preview_screen.dart';
import '../utils/input_validation.dart';
import '../utils/loc.dart';
import '../utils/purchase_calc.dart';
import '../utils/split_payment.dart';
import '../widgets/autocomplete_options.dart';
import 'purchase_history_screen.dart';
import '../widgets/premium_header.dart';
import '../widgets/premium_widgets.dart';
import '../widgets/unit_dialog.dart';
import '../theme/theme_manager.dart';

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
  // Total Lot Price (Kotlin totalLotPrice): qty × rate; lot likhne par rate = lot / qty.
  final _lotCtrl = TextEditingController();
  final _lotFocus = FocusNode();
  bool _suppressLotSync = false;
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
    _loadFirmName();
    _qtyCtrl.addListener(_syncLotFromRate);
    _rateCtrl.addListener(_syncLotFromRate);
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
    _lotFocus.dispose();
    _lotCtrl.dispose();
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
    final bal = await PartyRepository.instance.closingBalance(isCustomer: false, partyId: match.id!);
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

  /// qty ya rate badalne par Total Lot Price = qty × rate (Kotlin rate/qty watcher).
  void _syncLotFromRate() {
    if (_suppressLotSync) return;
    final q = double.tryParse(_qtyCtrl.text.trim()) ?? 0.0;
    final r = double.tryParse(_rateCtrl.text.trim()) ?? 0.0;
    if (q > 0 && r > 0) {
      _lotCtrl.text = _trimNum(q * r);
    } else if (q > 0 && r <= 0 && (double.tryParse(_lotCtrl.text.trim()) ?? 0.0) > 0) {
      // Pehle lot likha tha, ab qty aayi: rate = lot / qty.
      final newRate = (double.tryParse(_lotCtrl.text.trim()) ?? 0.0) / q;
      _suppressLotSync = true;
      _rateCtrl.text = _trimNum(newRate);
      _suppressLotSync = false;
      _mainRate = _toMain(newRate);
    } else if (_rateCtrl.text.trim().isEmpty && _qtyCtrl.text.trim().isEmpty) {
      _lotCtrl.text = '';
    }
  }

  /// Total Lot Price likhne par rate = lot / qty (Kotlin totalLotPrice watcher).
  void _onLotChanged(String v) {
    final lot = double.tryParse(v.trim()) ?? 0.0;
    final q = double.tryParse(_qtyCtrl.text.trim()) ?? 0.0;
    if (q > 0 && lot > 0) {
      final newRate = lot / q;
      _suppressLotSync = true;
      _rateCtrl.text = _trimNum(newRate);
      _suppressLotSync = false;
      setState(() => _mainRate = _toMain(newRate));
    } else {
      setState(() {});
    }
    _saveEntrySoon();
  }

  String _trimNum(double v) {
    final t = v.toStringAsFixed(2);
    return t.contains('.') ? t.replaceFirst(RegExp(r'\.?0+$'), '') : t;
  }

  /// Urdu/Arabic harf ho to RTL (text right par), warna app ki zabaan ke mutabiq.
  TextDirection _nameDirection(String text) {
    final rtl = RegExp(r'[\u0590-\u08FF\uFB1D-\uFDFF\uFE70-\uFEFF]');
    for (final r in text.runes) {
      final ch = String.fromCharCode(r);
      if (rtl.hasMatch(ch)) return TextDirection.rtl;
      if (RegExp(r'[A-Za-z]').hasMatch(ch)) return TextDirection.ltr;
    }
    return Loc.isUrdu ? TextDirection.rtl : TextDirection.ltr;
  }

  /// Enter/Next dabane par agli KHALI field par jao; jo field pehle se bhari ho (auto-fill rate,
  /// lot, retail, wholesale) usay skip karo. Sab bhari hon to seedha line add ho jaye.
  void _advanceFrom(FocusNode current) {
    final order = <MapEntry<TextEditingController, FocusNode>>[
      MapEntry(_qtyCtrl, _qtyFocus),
      MapEntry(_rateCtrl, _rateFocus),
      MapEntry(_lotCtrl, _lotFocus),
      MapEntry(_retailCtrl, _retailFocus),
      MapEntry(_wholesaleCtrl, _wholesaleFocus),
    ];
    final i = order.indexWhere((e) => identical(e.value, current));
    for (var j = i + 1; j < order.length; j++) {
      if (order[j].key.text.trim().isEmpty) {
        order[j].value.requestFocus();
        _ensureVisibleLater(order[j].value);
        return;
      }
    }
    _addLine();
  }

  void _ensureVisibleLater(FocusNode f) {
    Future.delayed(const Duration(milliseconds: 320), () {
      final ctx = f.context;
      if (!mounted || ctx == null || !f.hasFocus) return;
      Scrollable.ensureVisible(ctx, alignment: 0.3, duration: const Duration(milliseconds: 180), curve: Curves.easeOut);
    });
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
    final tagCtrl = TextEditingController();
    final categoryCtrl = TextEditingController(text: 'General');
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
    final categoryNames = <String>['General'];
    try {
      final cats = await CategoryRepository.instance.listAll();
      for (final c in cats) {
        final n = c.name.trim();
        if (n.isNotEmpty && !categoryNames.any((e) => e.toLowerCase() == n.toLowerCase())) categoryNames.add(n);
      }
    } catch (_) {}
    var unit = unitNames.contains(_selectedUnit) ? _selectedUnit : unitNames.first;
    var secondaryUnit = 'None';
    var secondaryQty = 0.0;
    var tertiaryUnit = 'None';
    var tertiaryQty = 0.0;
    var saleDefaultIdx = -1;
    var quickSaleDefaultIdx = -1;
    if (!mounted) return;

    List<String> tiers() => <String>[
          unit,
          if (secondaryUnit != 'None') secondaryUnit,
          if (secondaryUnit != 'None' && tertiaryUnit != 'None') tertiaryUnit,
        ];

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
                TextField(
                  controller: tagCtrl,
                  decoration: InputDecoration(
                    labelText: Loc.t('English tag (optional)', 'انگلش ٹیگ (اختیاری)'),
                    hintText: 'e.g. Aloo Bukhara',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: categoryCtrl,
                  textCapitalization: TextCapitalization.words,
                  decoration: InputDecoration(
                    labelText: Loc.t('Category', 'کیٹیگری'),
                    hintText: Loc.t('Type new or pick — new is added automatically', 'نئی لکھیں یا چنیں — نئی خود شامل ہو جائے گی'),
                    suffixIcon: PopupMenuButton<String>(
                      icon: const Icon(Icons.arrow_drop_down),
                      tooltip: Loc.t('Pick category', 'کیٹیگری چنیں'),
                      onSelected: (v) => setD(() => categoryCtrl.text = v),
                      itemBuilder: (_) => [
                        for (final c in categoryNames) PopupMenuItem(value: c, child: Text(c)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: unit,
                  decoration: InputDecoration(labelText: Loc.t('Unit', 'یونٹ')),
                  items: [for (final u in unitNames) DropdownMenuItem(value: u, child: Text(u))],
                  onChanged: (v) => setD(() {
                    unit = v ?? unit;
                    saleDefaultIdx = -1;
                    quickSaleDefaultIdx = -1;
                    secondaryUnit = 'None';
                    secondaryQty = 0.0;
                    tertiaryUnit = 'None';
                    tertiaryQty = 0.0;
                  }),
                ),
                const SizedBox(height: 8),
                InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () async {
                    final res = await showUnitDialog(
                      ctx,
                      knownUnits: unitNames.toList(),
                      initialPrimary: unit,
                      initialSecondary: secondaryUnit,
                      initialSecondaryQty: secondaryQty,
                      initialTertiary: tertiaryUnit,
                      initialTertiaryQty: tertiaryQty,
                      initialDefaultUnitIndex: saleDefaultIdx,
                      initialQuickSaleDefaultUnitIndex: quickSaleDefaultIdx,
                    );
                    if (res == null) return;
                    setD(() {
                      unitNames.add(res.primaryUnit);
                      if (res.secondaryUnit != 'None') unitNames.add(res.secondaryUnit);
                      if (res.tertiaryUnit != 'None') unitNames.add(res.tertiaryUnit);
                      unit = res.primaryUnit;
                      secondaryUnit = res.secondaryUnit;
                      secondaryQty = res.secondaryQty;
                      tertiaryUnit = res.tertiaryUnit;
                      tertiaryQty = res.tertiaryQty;
                      saleDefaultIdx = res.defaultUnitIndex;
                      quickSaleDefaultIdx = res.quickSaleDefaultUnitIndex;
                    });
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Text(
                      Loc.t('✚  Add more units (dozen, carton…)', '✚  مزید یونٹس (درجن، کارٹن…)'),
                      style: TextStyle(color: ThemeManager.palette.teal, fontSize: 12.5, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<int>(
                  key: ValueKey('sale_$saleDefaultIdx${tiers().length}'),
                  value: saleDefaultIdx < tiers().length ? saleDefaultIdx : -1,
                  decoration: InputDecoration(labelText: Loc.t('Default unit — Sale', 'ڈیفالٹ یونٹ — سیل')),
                  items: [
                    DropdownMenuItem(value: -1, child: Text(Loc.t('Auto', 'آٹو'))),
                    for (var i = 0; i < tiers().length; i++) DropdownMenuItem(value: i, child: Text(tiers()[i])),
                  ],
                  onChanged: (v) => setD(() => saleDefaultIdx = v ?? -1),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<int>(
                  key: ValueKey('qs_$quickSaleDefaultIdx${tiers().length}'),
                  value: quickSaleDefaultIdx < tiers().length ? quickSaleDefaultIdx : -1,
                  decoration: InputDecoration(labelText: Loc.t('Default unit — Quick Sale', 'ڈیفالٹ یونٹ — کوئیک سیل')),
                  items: [
                    DropdownMenuItem(value: -1, child: Text(Loc.t('Auto', 'آٹو'))),
                    for (var i = 0; i < tiers().length; i++) DropdownMenuItem(value: i, child: Text(tiers()[i])),
                  ],
                  onChanged: (v) => setD(() => quickSaleDefaultIdx = v ?? -1),
                ),
                const SizedBox(height: 12),
                const SizedBox(height: 4),
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
    final tag = tagCtrl.text.trim();
    var category = categoryCtrl.text.trim();
    categoryCtrl.dispose();
    final retail = double.tryParse(retailCtrl.text.trim()) ?? 0.0;
    final wholesale = double.tryParse(wholesaleCtrl.text.trim()) ?? 0.0;
    nameCtrl.dispose();
    tagCtrl.dispose();
    retailCtrl.dispose();
    wholesaleCtrl.dispose();
    if (ok != true || !mounted) return;

    final existing = _productByName(name);
    if (existing != null) {
      _toast(Loc.t('A product with this name already exists — picked it', 'اس نام کا پروڈکٹ پہلے سے ہے — وہی چن لیا'));
      await _onProductPicked(existing);
      return;
    }
    // Category maujood nahi to khud add karo.
    if (category.isEmpty) category = 'General';
    final sameCat = categoryNames.where((e) => e.toLowerCase() == category.toLowerCase());
    if (sameCat.isNotEmpty) {
      category = sameCat.first;
    } else {
      try {
        await CategoryRepository.instance.insert(models.Category(category));
      } catch (_) {}
    }
    // Nayi units (dialog mein likhi hui) units table mein bhi save karo.
    try {
      final known = (await UnitRepository.instance.listAll()).map((e) => e.name.toLowerCase()).toSet();
      for (final u in [unit, secondaryUnit, tertiaryUnit]) {
        if (u != 'None' && u.trim().isNotEmpty && !known.contains(u.toLowerCase())) {
          await UnitRepository.instance.insert(models.UnitType(u));
          known.add(u.toLowerCase());
        }
      }
    } catch (_) {}
    final hasSecondary = secondaryUnit != 'None' && secondaryQty > 0;
    final hasTertiary = hasSecondary && tertiaryUnit != 'None' && tertiaryQty > 0;
    final product = Product(
      barcode: 'P${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      category: category,
      unit: unit,
      secondaryUnit: hasSecondary ? secondaryUnit : '',
      secondaryUnitQty: hasSecondary ? secondaryQty : 0.0,
      tertiaryUnit: hasTertiary ? tertiaryUnit : '',
      tertiaryUnitQty: hasTertiary ? tertiaryQty : 0.0,
      salePrice: retail,
      wholesalePrice: wholesale,
      searchTag: tag,
      defaultUnitIndex: saleDefaultIdx,
      quickSaleDefaultUnitIndex: quickSaleDefaultIdx,
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
                          icon: Icon(Icons.close, color: ThemeManager.palette.red, size: 20),
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
                                  color: ThemeManager.palette.teal.withOpacity(0.15), borderRadius: BorderRadius.circular(10)),
                              child: Text(Loc.t('CHEAPEST', 'سب سے سستا'),
                                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: ThemeManager.palette.teal)),
                            ),
                        ]),
                        const SizedBox(height: 2),
                        Text(
                          'Last ${r(row.lastRate)} / $unit  (${fmt.format(DateTime.fromMillisecondsSinceEpoch(row.lastDate))})',
                          style: const TextStyle(fontSize: 12.5),
                        ),
                        Text(
                          'Low ${r(row.minRate)}  •  High ${r(row.maxRate)}  •  ${row.timesPurchased}x',
                          style: TextStyle(fontSize: 12, color: ThemeManager.palette.textMuted),
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
      justSaved: true,
    );
  }

  // --------------------------------------------------------------------- build

  /// Kotlin `isTabletWide = screenWidthDp >= 700`.
  static const double _tabletBreakpoint = 700;

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width >= _tabletBreakpoint;
    return Scaffold(
      backgroundColor: ThemeManager.palette.bg,
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : (wide ? _buildTwoPane() : _buildSinglePane()),
      ),
    );
  }

  // ===================================================== Kotlin-style UI
  // PurchaseActivity.buildUi() jaisa: neela header (History + ⋮), date chip, FIRM NAME / PARTY BALANCE card,
  // PARTY / SUPPLIER card, Add Item card (hamesha Retail/Wholesale ke saath), Total / Paid / Due / Save.

  static const Color _kBlue = Color(0xFF1450C7);
  static const Color _kGreen = Color(0xFF0E8A52);

  // Kotlin loadFirmName(): saved shop_name, warna "IBTISAAM Kiryana Store".
  String _firmName = 'IBTISAAM Kiryana Store';

  Future<void> _loadFirmName() async {
    final n = (await UserRepository.instance.getSetting('shop_name'))?.trim() ?? '';
    if (n.isNotEmpty && mounted) setState(() => _firmName = n);
  }

  Widget _kCard({
    required Widget child,
    EdgeInsets padding = const EdgeInsets.fromLTRB(22, 16, 22, 16),
    double radius = 18,
    double bottom = 14,
  }) =>
      Container(
        margin: EdgeInsets.only(bottom: bottom),
        padding: padding,
        decoration: BoxDecoration(
          color: ThemeManager.palette.cardWhite,
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: ThemeManager.palette.border),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 8, offset: const Offset(0, 2))],
        ),
        child: child,
      );

  Widget _kLabel(String text, {double size = 10.5}) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(
          text.toUpperCase(),
          style: TextStyle(fontSize: size, fontWeight: FontWeight.bold, letterSpacing: 0.5, color: ThemeManager.palette.textMuted),
        ),
      );

  /// Kotlin innerField(): label upar, neeche input, fieldFill box.
  Widget _kInner({required String label, required Widget child}) => Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
        decoration: BoxDecoration(
          color: ThemeManager.palette.fieldFill,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: ThemeManager.palette.border, width: 1.2),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [_kLabel(label), child],
        ),
      );

  Widget _kField({
    required TextEditingController controller,
    required FocusNode focus,
    required String hint,
    ValueChanged<String>? onChanged,
    VoidCallback? onSubmitted,
    TextInputAction action = TextInputAction.next,
    bool number = true,
  }) =>
      TextField(
        controller: controller,
        focusNode: focus,
        keyboardType: number ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.text,
        textInputAction: action,
        // Keyboard + Save bar ke upar field nazar aaye (Retail/Wholesale chhupti thi).
        scrollPadding: const EdgeInsets.fromLTRB(20, 20, 20, 220),
        onChanged: onChanged,
        onSubmitted: (_) => onSubmitted?.call(),
        style: TextStyle(fontSize: 15.5, color: ThemeManager.palette.textDark),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(color: ThemeManager.palette.textMuted),
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 4),
          border: InputBorder.none,
        ),
      );

  Widget _kCircle(String glyph, Color color, double size, VoidCallback onTap, {String? tooltip}) => Padding(
        padding: const EdgeInsets.only(left: 6),
        child: Tooltip(
          message: tooltip ?? '',
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: Container(
              width: size,
              height: size,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              child: Text(glyph, style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: size * 0.55, height: 1.0)),
            ),
          ),
        ),
      );

  Widget _kButton(String label, Color color, VoidCallback onTap, {double vPad = 16}) => Material(
        color: color,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: vPad),
            child: Center(
              child: Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15, letterSpacing: 0.5)),
            ),
          ),
        ),
      );

  Widget _buildHeader() {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.fromLTRB(24, 22, 14, 20),
      decoration: BoxDecoration(
        color: _kBlue,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(10), bottom: Radius.circular(26)),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.18), blurRadius: 10, offset: const Offset(0, 4))],
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _isEdit ? Loc.t('Edit Purchase', 'خریداری میں ترمیم') : Loc.t('Purchase', 'خریداری'),
                  style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                Text(
                  _isEdit ? 'BILL ${widget.editBillNo}' : 'STOCK IN · SUPPLIER BILLING',
                  style: const TextStyle(color: Color(0xFFA7B4CC), fontSize: 10.5, fontWeight: FontWeight.bold, letterSpacing: 0.8),
                ),
              ],
            ),
          ),
          if (Session.isAdmin) ...[
            InkWell(
              borderRadius: BorderRadius.circular(30),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PurchaseHistoryScreen())),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 11),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(30)),
                child: Text(Loc.t('History', 'ہسٹری'),
                    style: const TextStyle(color: _kBlue, fontWeight: FontWeight.bold, fontSize: 13.5)),
              ),
            ),
            const SizedBox(width: 8),
          ],
          // Print / Share = saved bill ka Bill Preview (naya bill => "Save the purchase first").
          PopupMenuButton<String>(
            tooltip: Loc.t('More', 'مزید'),
            padding: EdgeInsets.zero,
            onSelected: (v) => _printOrShare(),
            itemBuilder: (_) => [
              PopupMenuItem(value: 'print', child: Text(Loc.t('Print', 'پرنٹ'))),
              PopupMenuItem(value: 'share', child: Text(Loc.t('Share', 'شیئر کریں'))),
            ],
            child: Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: const BoxDecoration(color: Color(0x33FFFFFF), shape: BoxShape.circle),
              child: const Icon(Icons.more_vert, color: Colors.white, size: 20),
            ),
          ),
        ],
      ),
    );
  }

  /// Phone: Kotlin ki tarah ek hi column (original flow).
  Widget _buildSinglePane() {
    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 180),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildHeader(),
                _buildDateRow(),
                _buildFirmCard(),
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
    );
  }

  /// Tablet (>= 700dp): Kotlin twoPane — left = supplier/item entry (scroll),
  /// right = billed items (apni scroll) + Total/Payment/Due/Save neeche pinned,
  /// taa ke keyboard ya lambi list se Total/Paid/Save kabhi gayab na hon.
  Widget _buildTwoPane() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            flex: 13,
            child: SingleChildScrollView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: const EdgeInsets.fromLTRB(4, 20, 16, 180),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildHeader(),
                  _buildDateRow(),
                  _buildFirmCard(),
                  _buildSupplierCard(),
                  _buildItemEntryCard(),
                ],
              ),
            ),
          ),
          VerticalDivider(width: 1, thickness: 1, color: ThemeManager.palette.border),
          Expanded(
            flex: 10,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(16, 20, 4, 8),
                    child: _lines.isEmpty
                        ? Padding(
                            padding: const EdgeInsets.only(top: 40),
                            child: Center(
                              child: Text(
                                Loc.t('No items added yet', 'ابھی کوئی آئٹم شامل نہیں'),
                                style: TextStyle(color: ThemeManager.palette.textMuted),
                              ),
                            ),
                          )
                        : _buildLinesList(),
                  ),
                ),
                Flexible(
                  flex: 0,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(16, 0, 4, 0),
                    child: _buildTotalsCard(),
                  ),
                ),
                _buildSaveBar(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Kotlin dateChip: "📅  01/10/2026  ›".
  Widget _buildDateRow() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Align(
        alignment: Alignment.centerLeft,
        child: InkWell(
          borderRadius: BorderRadius.circular(30),
          onTap: _pickDate,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
            decoration: BoxDecoration(
              color: ThemeManager.palette.cardWhite,
              borderRadius: BorderRadius.circular(30),
              border: Border.all(color: ThemeManager.palette.border),
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 4, offset: const Offset(0, 1))],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('📅  ', style: TextStyle(fontSize: 13)),
                Text(DateFormat('dd/MM/yyyy').format(_purchaseDate),
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: ThemeManager.palette.textDark)),
                const Text('  ›', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: _kGreen)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Kotlin "FIRM NAME" + "PARTY BALANCE" card.
  Widget _buildFirmCard() {
    final bal = _supplierBalance;
    var balColor = ThemeManager.palette.textMuted;
    if (bal != null && bal.abs() > 0.009) balColor = bal > 0 ? ThemeManager.palette.red : _kGreen;
    return _kCard(
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _kLabel(Loc.t('Firm Name', 'فرم کا نام'), size: 9.5),
                Text(_firmName,
                    style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: ThemeManager.palette.textDark)),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _kLabel(Loc.t('Party Balance', 'پارٹی بیلنس'), size: 9.5),
              Text('Rs ${(bal ?? 0.0).toStringAsFixed(2)}',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: balColor)),
            ],
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------- Print / Share / Hold / Recall

  /// Kotlin overflow Print/Share: sirf SAVED bill (edit mode) ka Bill Preview; naya bill => "Save the purchase first".
  Future<void> _printOrShare() async {
    final billNo = widget.editBillNo;
    if (billNo == null) return _toast(Loc.t('Save the purchase first', 'پہلے خریداری محفوظ کریں'));
    if (_lines.isEmpty) return;
    final paid = _effectivePaid.clamp(0.0, _grandTotal).toDouble();
    await _showBillPreview(
      billNo: billNo,
      supplier: _supplierCtrl.text.trim(),
      date: _purchaseDate,
      lines: List<PurchaseLine>.of(_lines),
      total: _grandTotal,
      paid: paid,
      method: paid <= 0.009 ? 'Credit' : paymentMethodLabel(paid: paid, payments: _splitPayments, singleMethod: _paymentMethod),
    );
  }

  // ---------------------------------------------------------- Add Supplier (+)

  /// Kotlin promptAddSupplier(): Name*, Phone, Opening Balance. Add ke baad naam supplier field mein.
  Future<void> _promptAddSupplier() async {
    final nameCtrl = TextEditingController(text: _supplierCtrl.text.trim());
    final phoneCtrl = TextEditingController();
    final openingCtrl = TextEditingController();
    const decimal = TextInputType.numberWithOptions(decimal: true);
    Widget field(String label, TextEditingController c, {TextInputType? type, String? hint}) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: TextField(
            controller: c,
            keyboardType: type,
            decoration: InputDecoration(labelText: label, hintText: hint, border: const OutlineInputBorder(), isDense: true),
          ),
        );
    final added = await showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(Loc.t('Add Supplier', 'سپلائر شامل کریں')),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            field('NAME *', nameCtrl, hint: 'Supplier name'),
            field('PHONE (OPTIONAL)', phoneCtrl, type: TextInputType.phone, hint: 'Phone'),
            field('OPENING BALANCE (RS, IF ANY PREVIOUS DUE)', openingCtrl, type: decimal, hint: 'Opening balance'),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, null), child: Text(Loc.t('Cancel', 'منسوخ کریں'))),
          FilledButton(
            onPressed: () async {
              final name = nameCtrl.text.trim();
              if (name.isEmpty) {
                _toast(Loc.t('Name is required', 'نام ضروری ہے'));
                return;
              }
              final opening = parseMoneyOrWarn(ctx, openingCtrl.text, 'Opening Balance', 'افتتاحی بیلنس');
              if (opening == null) return;
              if (_suppliers.any((x) => x.name.toLowerCase() == name.toLowerCase())) {
                _toast(Loc.t('"$name" already exists', '"$name" پہلے سے موجود ہے'));
                return;
              }
              await PartyRepository.instance.addSupplier(name: name, phone: phoneCtrl.text, openingBalance: opening);
              if (ctx.mounted) Navigator.pop(ctx, name);
            },
            child: Text(Loc.t('Add', 'شامل کریں')),
          ),
        ],
      ),
    );
    nameCtrl.dispose();
    phoneCtrl.dispose();
    openingCtrl.dispose();
    if (added == null || !mounted) return;
    setState(() => _supplierCtrl.text = added);
    _refreshSupplierBalance(added);
    _saveDraftSoon();
  }

  Widget _buildSupplierCard() {
    return _kCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _kLabel(Loc.t('Party / Supplier', 'پارٹی / سپلائر')),
          Row(
            children: [
              Expanded(
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
                    style: TextStyle(fontSize: 15.5, color: ThemeManager.palette.textDark),
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
                    decoration: InputDecoration(
                      hintText: Loc.t('Party Name (Supplier) *', 'پارٹی کا نام (سپلائر) *'),
                      hintStyle: TextStyle(color: ThemeManager.palette.textMuted),
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                  ),
                  optionsViewBuilder: (context, onSelected, options) =>
                      autocompleteOptionsView<String>(context, onSelected, options, (o) => o, maxWidth: 640),
                ),
              ),
              _kCircle('+', _kGreen, 36, _promptAddSupplier, tooltip: Loc.t('Add Supplier', 'سپلائر شامل کریں')),
            ],
          ),
          const SizedBox(height: 10),
          _kLabel(Loc.t('Supplier Invoice/Bill No. (optional)', 'سپلائر انوائس/بل نمبر (اختیاری)')),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            decoration: BoxDecoration(
              color: ThemeManager.palette.fieldFill,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: ThemeManager.palette.border, width: 1.2),
            ),
            child: _kField(
              controller: _invoiceCtrl,
              focus: _invoiceFocus,
              hint: Loc.t('e.g. printed on their bill', 'مثلاً ان کے بل پر چھپا نمبر'),
              number: false,
              onChanged: (_) => _saveDraftSoon(),
              onSubmitted: () => _itemFocus.requestFocus(),
            ),
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
      color = ThemeManager.palette.red;
      text = Loc.t(
        '⚠ Loss! Purchase rate ≥ current Sale Rate (Rs ${m.salePrice.toStringAsFixed(2)})',
        '⚠ نقصان! خریداری ریٹ موجودہ سیل ریٹ (روپے ${m.salePrice.toStringAsFixed(2)}) کے برابر یا زیادہ ہے',
      );
    } else if (m.level == MarginLevel.low) {
      color = ThemeManager.palette.orange;
      text = Loc.t(
        '⚠ Low margin: Rs ${m.margin.toStringAsFixed(2)} (${m.marginPct.toStringAsFixed(1)}%) vs Sale Rate Rs ${m.salePrice.toStringAsFixed(2)}',
        '⚠ کم منافع: روپے ${m.margin.toStringAsFixed(2)} (${m.marginPct.toStringAsFixed(1)}%) بمقابلہ سیل ریٹ روپے ${m.salePrice.toStringAsFixed(2)}',
      );
    } else {
      color = ThemeManager.palette.teal;
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
    final lineTotal = qty * rate;
    final lineTotalText = lineTotal == lineTotal.roundToDouble() ? lineTotal.toStringAsFixed(0) : lineTotal.toStringAsFixed(2);

    // NOTE: Row(crossAxisAlignment: stretch) unbounded height (scroll) mein crash karta tha — isi liye
    // pehle tablet par yeh poora card blank aata tha. Ab sab Rows `start` alignment par hain.
    return _kCard(
      radius: 20,
      padding: const EdgeInsets.fromLTRB(24, 22, 24, 22),
      bottom: 12,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(
              editing ? '✏️  ${Loc.t('Edit Line', 'لائن میں ترمیم')}' : '➕  ${Loc.t('Add Item', 'آئٹم شامل کریں')}',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: _kGreen),
            ),
          ),
          _kInner(
            label: Loc.t('Item Name', 'آئٹم کا نام'),
            child: Row(
              children: [
                Expanded(
                  child: RawAutocomplete<Product>(
                    textEditingController: _itemCtrl,
                    focusNode: _itemFocus,
                    displayStringForOption: (p) => p.name,
                    optionsBuilder: (text) {
                      if (text.text.trim().isEmpty) return const Iterable<Product>.empty();
                      return _products.where((p) => p.matchesQuery(text.text));
                    },
                    onSelected: _onProductPicked,
                    fieldViewBuilder: (context, controller, focusNode, onSubmit) => ValueListenableBuilder<TextEditingValue>(
                      valueListenable: controller,
                      builder: (context, value, _) => TextField(
                        controller: controller,
                        focusNode: focusNode,
                        textDirection: _nameDirection(value.text),
                        textAlign: _nameDirection(value.text) == TextDirection.rtl ? TextAlign.right : TextAlign.left,
                        textInputAction: TextInputAction.next,
                        style: TextStyle(fontSize: 15.5, color: ThemeManager.palette.textDark),
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
                        decoration: InputDecoration(
                          hintText: Loc.t('Type to search…', 'تلاش کے لیے لکھیں…'),
                          hintStyle: TextStyle(color: ThemeManager.palette.textMuted),
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(vertical: 4),
                        ),
                      ),
                    ),
                    optionsViewBuilder: (context, onSelected, options) =>
                        autocompleteOptionsView<Product>(context, onSelected, options, (o) => o.name, maxWidth: 640),
                  ),
                ),
                // 📊 = supplier rate comparison (admin/manager), + = naya product.
                if (Session.isAdminOrManager)
                  _kCircle('📊', _kBlue, 32, _showSupplierComparison, tooltip: Loc.t('Compare suppliers', 'سپلائر موازنہ')),
                _kCircle('+', _kGreen, 32, () => _promptAddProduct(_itemCtrl.text.trim()), tooltip: Loc.t('New product', 'نیا پروڈکٹ')),
              ],
            ),
          ),
          if (picked != null)
            Padding(
              padding: const EdgeInsets.only(top: 8, left: 4),
              child: Text(
                'In stock: ${picked.formatStockBreakdown()}'
                '${_lastPurchaseMainRate > 0 ? '   •   Last purchase: Rs ${picked.fromPrimaryUnitRate(_lastPurchaseMainRate, unitValue).toStringAsFixed(2)} / $unitValue' : ''}',
                style: TextStyle(fontSize: 12, color: ThemeManager.palette.textMuted),
              ),
            ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _kInner(
                  label: Loc.t('Quantity', 'مقدار'),
                  child: _kField(
                    controller: _qtyCtrl,
                    focus: _qtyFocus,
                    hint: '0',
                    onChanged: (_) {
                      setState(() {});
                      _saveEntrySoon();
                    },
                    onSubmitted: () => _advanceFrom(_qtyFocus),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _kInner(
                  label: Loc.t('Unit', 'یونٹ'),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: unitValue,
                      isExpanded: true,
                      isDense: true,
                      style: TextStyle(fontSize: 16, color: ThemeManager.palette.textDark),
                      items: unitOptions.map((u) => DropdownMenuItem(value: u, child: Text(u))).toList(),
                      onChanged: (v) {
                        if (v != null) _onUnitChanged(v);
                      },
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _kInner(
                  label: picked == null ? Loc.t('Rate (per unit)', 'ریٹ (فی یونٹ)') : 'Rate (per $unitValue)',
                  child: _kField(
                    controller: _rateCtrl,
                    focus: _rateFocus,
                    hint: Loc.t('Price / Unit', 'قیمت / یونٹ'),
                    onChanged: (v) {
                      _onRateChanged(v);
                      _saveEntrySoon();
                    },
                    onSubmitted: () => _advanceFrom(_rateFocus),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _kInner(
                  label: Loc.t('Total Lot Price', 'کل لاٹ قیمت'),
                  child: _kField(
                    controller: _lotCtrl,
                    focus: _lotFocus,
                    hint: 'e.g. 5000 for 2 Ctn',
                    onChanged: _onLotChanged,
                    onSubmitted: () => _advanceFrom(_lotFocus),
                  ),
                ),
              ),
            ],
          ),
          _marginLabel(margin),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _kInner(
                  label: Loc.t('Retail Rate', 'ریٹیل ریٹ'),
                  child: _kField(
                    controller: _retailCtrl,
                    focus: _retailFocus,
                    hint: Loc.t('Sale Price', 'سیل قیمت'),
                    onChanged: (v) {
                      _onRetailChanged(v);
                      _saveEntrySoon();
                    },
                    onSubmitted: () => _advanceFrom(_retailFocus),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _kInner(
                  label: Loc.t('Wholesale Rate', 'ہول سیل ریٹ'),
                  child: _kField(
                    controller: _wholesaleCtrl,
                    focus: _wholesaleFocus,
                    hint: Loc.t('Wholesale Price', 'ہول سیل قیمت'),
                    action: TextInputAction.done,
                    onChanged: (v) {
                      _onWholesaleChanged(v);
                      _saveEntrySoon();
                    },
                    onSubmitted: _addLine,
                  ),
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 14, 0, 10),
            child: Text(
              'Total Amount: Rs $lineTotalText',
              style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold, color: _kBlue),
            ),
          ),
          Row(
            children: [
              if (editing) ...[
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                    onPressed: _cancelLineEdit,
                    child: Text(Loc.t('Cancel', 'منسوخ کریں')),
                  ),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                flex: 2,
                child: _kButton(
                  editing ? Loc.t('UPDATE ITEM', 'آئٹم اپ ڈیٹ کریں') : Loc.t('ADD ITEM', 'آئٹم شامل کریں'),
                  _kGreen,
                  _addLine,
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
      accentTop: ThemeManager.palette.navy,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionLabel(emoji: '🧾', label: 'Bill Items', accent: ThemeManager.palette.navyInk),
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
                  color: isEditing ? ThemeManager.palette.savedHighlightBg : ThemeManager.palette.fieldFill,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: isEditing ? ThemeManager.palette.teal : ThemeManager.palette.border),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(line.itemName, style: TextStyle(fontWeight: FontWeight.bold, color: ThemeManager.palette.textDark)),
                          Text(
                            '${qtyText(line.qty)} ${line.unit}  ×  ${line.rate.toStringAsFixed(2)}',
                            style: TextStyle(fontSize: 11.5, color: ThemeManager.palette.textMuted),
                          ),
                        ],
                      ),
                    ),
                    Text(line.amount.toStringAsFixed(2), style: TextStyle(fontWeight: FontWeight.bold, color: ThemeManager.palette.teal)),
                    IconButton(
                      icon: Icon(Icons.close, size: 18, color: ThemeManager.palette.red),
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
    final dueColor = total <= 0.009 ? _kBlue : (due > 0.009 ? ThemeManager.palette.red : _kGreen);

    Widget summaryCard(String label, String value, Color valueColor, double valueSize) => Container(
          margin: const EdgeInsets.only(bottom: 14),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
          decoration: BoxDecoration(
            color: ThemeManager.palette.cardWhite,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: ThemeManager.palette.border),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 6, offset: const Offset(0, 2))],
          ),
          child: Row(children: [
            Expanded(
              child: Text(label.toUpperCase(),
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 0.6, color: ThemeManager.palette.textMuted)),
            ),
            Text(value, style: TextStyle(fontSize: valueSize, fontWeight: FontWeight.bold, color: valueColor)),
          ]),
        );

    // Kotlin: "Total Amount" card -> Paid / Payment Method card -> "Due Amount" card.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        summaryCard(Loc.t('Total Amount', 'کل رقم'), 'Rs ${total.toStringAsFixed(0)}', _kBlue, 21),
        _kCard(
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(child: _kLabel(Loc.t('Paid Amount', 'ادا شدہ رقم'), size: 12)),
                  const Text('Rs ', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: _kGreen)),
                  SizedBox(
                    width: 120,
                    child: TextField(
                      controller: _paidCtrl,
                      focusNode: _paidFocus,
                      enabled: !split,
                      textAlign: TextAlign.end,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      textInputAction: TextInputAction.done,
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: _kGreen),
                      onSubmitted: (_) {
                        FocusScope.of(context).unfocus();
                        if (!_saving) _save();
                      },
                      onChanged: (_) {
                        setState(() {});
                        _saveDraftSoon();
                      },
                      decoration: InputDecoration(
                        hintText: '0',
                        hintStyle: TextStyle(color: ThemeManager.palette.textMuted, fontWeight: FontWeight.normal),
                        isDense: true,
                        border: InputBorder.none,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              if (!split) ...[
                _kLabel(Loc.t('Payment Method', 'ادائیگی کا طریقہ'), size: 11),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                  decoration: BoxDecoration(
                    color: ThemeManager.palette.fieldFill,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: ThemeManager.palette.border, width: 1.2),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: _paymentMethod == 'Bank' ? 'Bank' : 'Cash',
                      isExpanded: true,
                      style: TextStyle(fontSize: 16, color: ThemeManager.palette.textDark),
                      items: const [
                        DropdownMenuItem(value: 'Cash', child: Text('Cash')),
                        DropdownMenuItem(value: 'Bank', child: Text('Bank')),
                      ],
                      onChanged: (v) {
                        if (v != null) setState(() => _paymentMethod = v);
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: InkWell(
                    onTap: _openSplitPaymentDialog,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Text(
                        Loc.t('+ Split Payment (multiple methods)', '+ ادائیگی تقسیم کریں (ایک سے زیادہ طریقے)'),
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: _kBlue),
                      ),
                    ),
                  ),
                ),
              ] else
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${Loc.t('Split', 'تقسیم')}: ${splitBreakdown(_splitPayments)}',
                        style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: _kBlue),
                      ),
                    ),
                    TextButton(onPressed: _openSplitPaymentDialog, child: Text(Loc.t('Edit', 'ترمیم'))),
                    IconButton(
                      tooltip: Loc.t('Remove split', 'تقسیم ہٹائیں'),
                      icon: Icon(Icons.close, size: 18, color: ThemeManager.palette.red),
                      onPressed: _clearSplitPayments,
                    ),
                  ],
                ),
              // Kotlin paidWarningText: Paid khali + total > 0.
              if (total > 0 && !split && _paidCtrl.text.trim().isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('⚠ Paid khali hai - Ye Udhaar me jayega',
                      style: TextStyle(color: ThemeManager.palette.red, fontSize: 11, fontWeight: FontWeight.bold)),
                ),
            ],
          ),
        ),
        summaryCard(Loc.t('Due Amount', 'باقی رقم'), 'Rs ${due.toStringAsFixed(0)}', dueColor, 18),
      ],
    );
  }

  Widget _buildSaveBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
      color: ThemeManager.palette.bg,
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            if (_isEdit && Session.isAdmin) ...[
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: ThemeManager.palette.red,
                  side: BorderSide(color: ThemeManager.palette.red),
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
              child: _kButton(
                _saving
                    ? 'SAVING…'
                    : (_isEdit ? Loc.t('UPDATE PURCHASE', 'خریداری اپ ڈیٹ کریں') : Loc.t('SAVE PURCHASE', 'خریداری محفوظ کریں')),
                _kBlue,
                _saving ? () {} : _save,
                vPad: 18,
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
