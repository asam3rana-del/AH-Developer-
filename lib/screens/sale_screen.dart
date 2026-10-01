import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../db/customer_repository.dart';
import '../db/product_repository.dart';
import '../db/sale_repository.dart';
import '../db/user_repository.dart';
import 'sale_history_screen.dart';
import '../models/party.dart';
import '../models/product.dart';
import '../models/sale.dart';
import '../services/sale_draft.dart';
import '../services/sale_hold_recall.dart';
import '../services/session.dart';
import '../utils/bill_doc.dart';
import 'bill_preview_screen.dart';
import '../utils/discount_calculator.dart';
import '../utils/input_validation.dart';
import '../utils/loc.dart';
import '../utils/sale_cart.dart';
import '../utils/split_payment.dart';
import '../utils/stock_touch_policy.dart';
import '../widgets/autocomplete_options.dart';
import '../widgets/held_bills_dialog.dart';
import '../widgets/premium_header.dart';
import '../widgets/premium_widgets.dart';
import '../widgets/role_guard.dart';
import 'sale_quick_sale.dart';
import '../theme/theme_manager.dart';

class SaleScreen extends StatefulWidget {
  /// null = new sale. An invoice number re-opens that SAVED bill for
  /// edit / return / delete — admin only (Session role is checked again in
  /// SaleRepository, this is just the UI side).
  final String? editInvoice;

  /// Dashboard "Quick Sale" tile (Kotlin EXTRA_OPEN_QUICK_SALE): screen khulte hi Quick Sale dialog.
  /// Sirf naye sale par (edit mode mein ignore).
  final bool openQuickSale;

  const SaleScreen({super.key, this.editInvoice, this.openQuickSale = false});

  @override
  State<SaleScreen> createState() => _SaleScreenState();
}

class _SaleScreenState extends State<SaleScreen> with WidgetsBindingObserver {
  final _customerCtrl = TextEditingController();
  final _customerFocus = FocusNode();
  final _itemCtrl = TextEditingController();
  final _itemFocus = FocusNode();
  final _qtyCtrl = TextEditingController();
  final _priceCtrl = TextEditingController();
  final _discountCtrl = TextEditingController();
  final _paidCtrl = TextEditingController();

  DateTime _saleDate = DateTime.now();
  bool _isWholesale = false;
  Product? _pickedProduct;
  String _selectedUnit = '';

  /// Rate per PRIMARY unit of what the cashier last typed — switching the
  /// unit re-converts their own rate. Reset when a product is picked or the
  /// sale type changes. Mirrors `lastMainPrice` in SaleActivity.kt.
  double _lastMainPrice = 0.0;

  final List<SaleLine> _lines = [];
  bool _saving = false;
  final _scrollCtrl = ScrollController();

  /// "Rs" mode: the Quantity box holds a rupee amount and the quantity is
  /// worked out from the rate (SaleActivity.qtyIsAmountMode).
  bool _qtyIsAmountMode = false;

  /// Index of the billed line being corrected in place, or null when adding.
  int? _editingIndex;

  /// Set when the price box was filled with THIS customer's usual rate.
  String? _customerRateName;

  // Draft autosave (new sales only).
  Timer? _draftTimer;
  // True until the saved draft (if any) has been restored — autosaving before
  // that would overwrite it with an empty bill.
  bool _suppressDraft = true;
  bool _draftRestored = false;

  // Saved-sale edit mode.
  bool get _isEdit => widget.editInvoice != null;
  Sale? _originalSale;
  String _paymentMethod = 'Cash';

  /// Split Payment rows (method, amount). Empty = single method, using
  /// [_paymentMethod] + the Paid Amount box. While non-empty the rows are the
  /// source of truth and the Paid box is locked to their sum.
  List<PayEntry> _splitPayments = [];

  /// barcode -> smallest units the ORIGINAL bill already took out of stock.
  /// Added back to "available" while editing so raising a qty isn't rejected.
  final Map<String, double> _originalSmallestByBarcode = {};

  List<Product> _products = const [];
  List<Customer> _customers = const [];
  StreamSubscription<List<Product>>? _productSub;
  StreamSubscription<List<Customer>>? _customerSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _customerFocus.addListener(() {
      // Customer picked/typed AFTER the item: re-check their usual rate.
      if (!_customerFocus.hasFocus) _suggestCustomerRate();
    });
    _load();
  }

  // Kotlin loadFirmName(): saved shop_name, warna "IBTISAAM Kiryana Store".
  String _firmName = 'IBTISAAM Kiryana Store';

  Future<void> _loadFirmName() async {
    final n = (await UserRepository.instance.getSetting('shop_name'))?.trim() ?? '';
    if (n.isNotEmpty && mounted) setState(() => _firmName = n);
  }

  Future<void> _load() async {
    if (_isEdit && !Session.isAdmin) return; // build() shows the lock screen
    _loadFirmName();
    final products = await ProductRepository.instance.listAll();
    final customers = await CustomerRepository.instance.listAll();
    if (!mounted) return;
    setState(() {
      _products = products;
      _customers = customers;
    });
    // The repositories' streams only emit on change, so load once (above)
    // and then follow updates.
    _productSub = ProductRepository.instance.watchAll().listen((v) {
      if (mounted) setState(() => _products = v);
    });
    _customerSub = CustomerRepository.instance.watchAll().listen((v) {
      if (mounted) setState(() => _customers = v);
    });
    if (_isEdit) {
      await _loadForEdit();
    } else {
      await _restoreDraft();
      if (widget.openQuickSale) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _openQuickSale();
        });
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // App sent to background / closed mid-bill -> keep the bill.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      _saveDraftNow();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _draftTimer?.cancel();
    // Leaving the screen (back button etc.) also keeps the bill. Built BEFORE
    // the controllers are disposed; after a successful save they are empty,
    // which just clears the stored draft.
    if (!_isEdit && !_suppressDraft) {
      unawaited(SaleDraftStore.save(_currentDraft()));
    }
    _productSub?.cancel();
    _customerSub?.cancel();
    _scrollCtrl.dispose();
    _customerCtrl.dispose();
    _customerFocus.dispose();
    _itemCtrl.dispose();
    _itemFocus.dispose();
    _qtyCtrl.dispose();
    _priceCtrl.dispose();
    _discountCtrl.dispose();
    _paidCtrl.dispose();
    super.dispose();
  }

  /// Every state change may change the bill, so every one schedules a
  /// (debounced) draft save — the same coverage as the Kotlin text watchers.
  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    _scheduleDraftSave();
  }

  // ------------------------------------------------------------------ draft

  SaleDraft _currentDraft() => SaleDraft(
        customer: _customerCtrl.text,
        isWholesale: _isWholesale,
        discount: _discountCtrl.text,
        paid: _paidCtrl.text,
        pendingItemName: _itemCtrl.text,
        pendingQty: _qtyCtrl.text,
        pendingPrice: _priceCtrl.text,
        lines: List.of(_lines),
      );

  void _scheduleDraftSave() {
    if (_isEdit || _suppressDraft) return;
    _draftTimer?.cancel();
    _draftTimer = Timer(const Duration(milliseconds: 600), _saveDraftNow);
  }

  Future<void> _saveDraftNow() async {
    if (_isEdit || _suppressDraft) return;
    _draftTimer?.cancel();
    await SaleDraftStore.save(_currentDraft());
  }

  Future<void> _clearDraft() async {
    _draftTimer?.cancel();
    await SaleDraftStore.clear();
  }

  Future<void> _restoreDraft() async {
    final draft = await SaleDraftStore.load();
    if (!mounted) return; // left the screen first: keep the stored draft as-is
    if (draft == null || _draftRestored) {
      _suppressDraft = false;
      return;
    }
    _draftRestored = true;
    try {
      setState(() {
        _customerCtrl.text = draft.customer;
        _isWholesale = draft.isWholesale;
        if (draft.discount.isNotEmpty) _discountCtrl.text = draft.discount;
        if (draft.paid.isNotEmpty) _paidCtrl.text = draft.paid;
        // The saved date is intentionally not restored (see SaleDraft) —
        // the bill is dated "now"; the date picker still allows another day.
        _lines
          ..clear()
          ..addAll(draft.lines);
        if (draft.pendingItemName.trim().isNotEmpty) {
          _itemCtrl.text = draft.pendingItemName;
          final match = _findProductByName(draft.pendingItemName);
          if (match != null) {
            _pickedProduct = match;
            _selectedUnit = defaultUnitFor(match);
            _lastMainPrice = 0.0;
          }
        }
        if (draft.pendingQty.isNotEmpty) _qtyCtrl.text = draft.pendingQty;
        if (draft.pendingPrice.isNotEmpty) {
          _priceCtrl.text = draft.pendingPrice;
          final pp = _pickedProduct;
          if (pp != null) {
            final unit = _selectedUnit.isEmpty ? pp.unit : _selectedUnit;
            _lastMainPrice = pp.toPrimaryUnitRate(double.tryParse(draft.pendingPrice.trim()) ?? 0.0, unit);
          }
        }
      });
    } finally {
      _suppressDraft = false;
    }
    if (draft.worthAnnouncing) {
      _toast(Loc.t('Restored your unsaved sale draft', 'آپ کا غیر محفوظ شدہ سیل ڈرافٹ بحال کر دیا گیا'));
    }
  }

  // ------------------------------------------------------- saved-sale edit

  Future<void> _loadForEdit() async {
    try {
      final edit = await SaleRepository.instance.loadForEdit(widget.editInvoice!);
      if (!mounted) return;
      if (edit == null) {
        _toast('Ye bill nahi mila');
        Navigator.of(context).maybePop();
        return;
      }
      final original = <String, double>{};
      for (final si in edit.items) {
        Product? product;
        for (final p in _products) {
          if (p.barcode == si.barcode) {
            product = p;
            break;
          }
        }
        original[si.barcode] = (original[si.barcode] ?? 0) + saleItemSmallestQty(si, product);
      }
      setState(() {
        _originalSale = edit.sale;
        _originalSmallestByBarcode
          ..clear()
          ..addAll(original);
        _saleDate = DateTime.fromMillisecondsSinceEpoch(edit.sale.createdAt);
        _customerCtrl.text = edit.customerName;
        _isWholesale = edit.sale.saleType == 'wholesale';
        _discountCtrl.text = edit.sale.discount > 0 ? edit.sale.discount.toStringAsFixed(2) : '';
        _paidCtrl.text = edit.sale.paid.toStringAsFixed(2);
        _paymentMethod = edit.sale.paymentMethod.toLowerCase() == 'bank' ? 'Bank' : 'Cash';
        // A bill saved with 2+ methods re-opens in split mode.
        _splitPayments = List<PayEntry>.of(edit.payments);
        if (_splitPayments.isNotEmpty) {
          _paidCtrl.text = plainAmount(effectivePaidInput(_splitPayments, 0.0));
        }
        _lines
          ..clear()
          ..addAll(edit.lines);
      });
    } on ArgumentError catch (e) {
      _toast(e.message.toString());
    } catch (e) {
      _toast('Bill load nahi hui: $e');
    }
  }

  double get _subtotal => _lines.fold(0.0, (sum, l) => sum + l.amount);

  BillTotals get _totals => DiscountCalculator.compute(
        _subtotal,
        double.tryParse(_discountCtrl.text.trim()) ?? 0.0,
        effectivePaidInput(_splitPayments, double.tryParse(_paidCtrl.text.trim()) ?? 0.0),
      );

  Product? _findProductByName(String name) {
    final t = name.trim().toLowerCase();
    if (t.isEmpty) return null;
    for (final p in _products) {
      if (p.name.toLowerCase() == t) return p;
    }
    return null;
  }

  // ------------------------------------------------------------ item entry

  void _onProductPicked(Product p) {
    setState(() {
      _pickedProduct = p;
      _itemCtrl.text = p.name;
      // Manual default-unit override wins; otherwise the Auto rule
      // (1-tier: only unit, 3-tier: 2nd unit, 2-tier: 2nd unit except Beverages).
      _selectedUnit = defaultUnitFor(p);
      _lastMainPrice = 0.0;
      _customerRateName = null;
      _refillAutoPrice();
    });
    // A regular customer's own usual rate replaces the standard one.
    _suggestCustomerRate();
  }

  void _refillAutoPrice() {
    final p = _pickedProduct;
    if (p == null) return;
    final basePrice = _isWholesale ? p.wholesalePrice : p.salePrice;
    final unit = _selectedUnit.isEmpty ? p.unit : _selectedUnit;
    final base = _lastMainPrice > 0 ? _lastMainPrice : basePrice;
    final price = p.fromPrimaryUnitRate(base, unit);
    _priceCtrl.text = price > 0 ? price.toStringAsFixed(2) : '';
  }

  void _onPriceChanged(String v) {
    final p = _pickedProduct;
    if (p != null) {
      final unit = _selectedUnit.isEmpty ? p.unit : _selectedUnit;
      _lastMainPrice = p.toPrimaryUnitRate(double.tryParse(v.trim()) ?? 0.0, unit);
    }
    // The shopkeeper typed their own number: it wins over the suggestion.
    setState(() => _customerRateName = null);
  }

  /// If [customer] has bought the picked item before, use THEIR last rate
  /// instead of the standard retail/wholesale one so a deliberately
  /// custom-priced regular doesn't need it re-typed every bill. Silent when
  /// there is no match, or when the cashier already typed their own rate.
  /// Mirrors `suggestCustomerRate()`.
  Future<void> _suggestCustomerRate() async {
    final product = _pickedProduct;
    if (product == null) return;
    final name = _customerCtrl.text.trim();
    if (name.isEmpty) return;
    Customer? customer;
    for (final c in _customers) {
      if (c.name.toLowerCase() == name.toLowerCase()) {
        customer = c;
        break;
      }
    }
    final customerId = customer?.id;
    if (customer == null || customerId == null) return;
    final customerDisplayName = customer.name;
    // Their own typed rate (not one we applied) must never be overwritten.
    if (_lastMainPrice > 0 && _customerRateName == null) return;

    final priceBefore = _priceCtrl.text;
    final barcodeAtLookup = product.barcode;
    final last = await SaleRepository.instance.lastRateForCustomerItem(customerId, barcodeAtLookup);
    if (last == null || !mounted) return;
    // Bail if the item or the price changed while we were querying.
    if (_pickedProduct?.barcode != barcodeAtLookup) return;
    if (_priceCtrl.text != priceBefore) return;

    final unit = _selectedUnit.isEmpty ? product.unit : _selectedUnit;
    final suggestion = customerRateFor(product,
        lastUnitPrice: last.unitPrice, lastUnit: last.unit, chosenUnit: unit);
    if (suggestion == null) return;
    setState(() {
      _lastMainPrice = suggestion.primaryRate;
      _priceCtrl.text = suggestion.priceInChosenUnit.toStringAsFixed(2);
      _customerRateName = customerDisplayName;
    });
  }

  void _onSaleTypeChanged(int index) {
    final wholesale = index == 1;
    if (wholesale == _isWholesale) return;
    setState(() {
      _isWholesale = wholesale;
      _lastMainPrice = 0.0;
      _customerRateName = null;
      _refillAutoPrice();
      // Lines already in the cart are re-rated too (cost untouched).
      final result = repriceLinesForSaleType(_lines, _products, isWholesale: wholesale);
      if (result.changed) {
        _lines
          ..clear()
          ..addAll(result.lines);
      }
    });
    _suggestCustomerRate();
  }

  void _toggleAmountMode() {
    setState(() {
      _qtyIsAmountMode = !_qtyIsAmountMode;
      _qtyCtrl.clear();
    });
  }

  void _addLine() {
    final name = _itemCtrl.text.trim();
    final product = _findProductByName(name);
    final price = double.tryParse(_priceCtrl.text.trim()) ?? 0.0;
    var qty = double.tryParse(_qtyCtrl.text.trim()) ?? 0.0;

    // Rs mode: the box holds a rupee amount — turn it into a quantity first
    // so nothing below needs to know which mode was used.
    if (_qtyIsAmountMode) {
      if (price <= 0) {
        _toast('Pehle Rate likhein, phir Rs se qty nikalegi');
        return;
      }
      final amount = double.tryParse(_qtyCtrl.text.trim()) ?? 0.0;
      final computed = qtyFromAmount(amount, price);
      if (computed == null) {
        _toast('Rs amount theek se likhen');
        return;
      }
      qty = computed;
    }

    if (product == null) {
      _toast('Ye item product list mein nahi hai');
      return;
    }
    if (qty <= 0) {
      _toast('Quantity theek se likhen');
      return;
    }

    final samePicked = _pickedProduct?.barcode == product.barcode;
    final unit = (samePicked && _selectedUnit.isNotEmpty) ? _selectedUnit : defaultUnitFor(product);
    final neededSmallest = product.toSmallestUnits(qty, unit);

    if (!product.isValidSmallestQty(neededSmallest)) {
      _toast('Qty (${formatQty(qty)} $unit) whole ${product.smallestUnitName()} mein convert nahi hoti');
      return;
    }

    // While correcting a line, that line's own qty must not count against
    // itself, or raising the qty would be wrongly rejected as "stock kam hai".
    final editIndex = _editingIndex;
    var alreadyInCartSmallest = 0.0;
    for (var i = 0; i < _lines.length; i++) {
      final l = _lines[i];
      if (l.barcode == product.barcode && i != editIndex) {
        alreadyInCartSmallest += product.toSmallestUnits(l.qty, l.unit);
      }
    }
    // Editing a SAVED bill: its own original qty is already out of `stock`.
    final availableForThisAdd =
        product.stock + (_originalSmallestByBarcode[product.barcode] ?? 0.0) - alreadyInCartSmallest;

    if (availableForThisAdd < neededSmallest) {
      _toast('Stock kam hai — "${product.name}" mein sirf ${formatQty(availableForThisAdd < 0 ? 0 : availableForThisAdd)} ${product.smallestUnitName()} bacha hai');
      return;
    }

    final factor = product.smallestUnitFactor();
    final costPerSmallest = factor > 0 ? product.cost / factor : product.cost;
    final costForThisLine = costPerSmallest * neededSmallest;

    final newLine = SaleLine(
      itemName: product.name,
      barcode: product.barcode,
      qty: qty,
      unit: unit,
      unitPrice: price,
      cost: costForThisLine,
      amount: qty * price,
      // Unit ladder snapshot so a held bill can be recalled later.
      mainUnit: product.unit,
      secondaryUnit: product.secondaryUnit,
      secondaryUnitQty: product.secondaryUnitQty,
      tertiaryUnit: product.tertiaryUnit,
      tertiaryUnitQty: product.tertiaryUnitQty,
    );

    setState(() {
      // Correcting a line updates it in place instead of adding a duplicate.
      if (editIndex != null && editIndex >= 0 && editIndex < _lines.length) {
        _lines[editIndex] = newLine;
      } else {
        _lines.add(newLine);
      }
      _editingIndex = null;
      _clearItemEntry();
    });
    _itemFocus.requestFocus();
  }

  void _clearItemEntry() {
    _itemCtrl.clear();
    _qtyCtrl.clear();
    _priceCtrl.clear();
    _pickedProduct = null;
    _selectedUnit = '';
    _lastMainPrice = 0.0;
    _qtyIsAmountMode = false;
    _customerRateName = null;
  }

  /// Loads a billed line back into the entry fields so a mistake can be
  /// corrected instead of deleting and retyping the line. Mirrors `editLine()`.
  void _editLine(int index) {
    if (index < 0 || index >= _lines.length) return;
    final line = _lines[index];
    Product? product;
    for (final p in _products) {
      if (p.barcode == line.barcode) {
        product = p;
        break;
      }
    }
    if (product == null) {
      for (final p in _products) {
        if (p.name.toLowerCase() == line.itemName.toLowerCase()) {
          product = p;
          break;
        }
      }
    }
    final Product? prod = product; // final copy: stays promotable in the closure
    setState(() {
      _editingIndex = index;
      _pickedProduct = prod; // null if the product was renamed/removed
      _itemCtrl.text = prod?.name ?? line.itemName;
      final choices = prod != null ? saleUnitChoices(prod) : <String>[line.unit];
      _selectedUnit = choices.contains(line.unit) ? line.unit : choices.first;
      _qtyCtrl.text = formatQty(line.qty);
      _qtyIsAmountMode = false;
      _customerRateName = null;
      _priceCtrl.text = line.unitPrice == line.unitPrice.truncateToDouble()
          ? line.unitPrice.toInt().toString()
          : line.unitPrice.toString();
      // So switching the unit re-converts THIS line's own rate.
      _lastMainPrice = prod != null ? prod.toPrimaryUnitRate(line.unitPrice, _selectedUnit) : 0.0;
    });
    if (_scrollCtrl.hasClients) {
      _scrollCtrl.animateTo(0, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    }
  }

  void _cancelLineEdit() {
    setState(() {
      _editingIndex = null;
      _clearItemEntry();
    });
  }

  void _removeLine(int index) {
    setState(() {
      // Keep an in-progress edit pointed at the right line.
      final editing = _editingIndex;
      if (editing != null) {
        if (editing == index) {
          _editingIndex = null;
          _clearItemEntry();
        } else if (editing > index) {
          _editingIndex = editing - 1;
        }
      }
      _lines.removeAt(index);
    });
  }

  void _clearAll() {
    setState(() {
      _lines.clear();
      _customerCtrl.clear();
      _discountCtrl.clear();
      _paidCtrl.clear();
      _splitPayments = [];
      _paymentMethod = 'Cash';
      _saleDate = DateTime.now();
      _isWholesale = false;
      _editingIndex = null;
      _clearItemEntry();
    });
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _saleDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked != null) setState(() => _saleDate = picked);
  }

  // ------------------------------------------------------------------ save

  Future<void> _save({bool overrideCreditLimit = false, bool skipDuplicateCheck = false}) async {
    if (_lines.isEmpty) {
      _toast('Kam az kam ek item add karen');
      return;
    }
    if (_isEdit && _originalSale == null) return; // bill still loading

    final totals = _totals;
    if (totals.due > 0.009 && _customerCtrl.text.trim().isEmpty) {
      _toast('Due amount ke liye Customer zaroori hai');
      return;
    }

    // Double-bill alert. Skipped on the credit-limit retry (the cashier has
    // already confirmed this exact bill once), like Kotlin's override path.
    if (!skipDuplicateCheck) {
      final dup = await SaleRepository.instance.findDuplicateSale(
        customerName: _customerCtrl.text.trim(),
        total: totals.total,
        saleDateMillis: _saleDate.millisecondsSinceEpoch,
        excludeInvoice: widget.editInvoice,
      );
      if (!mounted) return;
      if (dup != null && !await _confirmDuplicate(dup, totals.total)) return;
    }

    // Snapshot for the bill preview — _clearAll() wipes the screen after save.
    final previewLines = List<SaleLine>.of(_lines);
    final previewCustomer = _customerCtrl.text.trim();
    final previewDate = _saleDate;
    final previewMethod = _paymentLabel(totals.paid);

    setState(() => _saving = true);
    final stockWarnings = <String>[];
    try {
      final invoice = await SaleRepository.instance.saveSale(
        lines: _lines,
        customerName: _customerCtrl.text.trim(),
        discountInput: double.tryParse(_discountCtrl.text.trim()) ?? 0.0,
        paidInput: double.tryParse(_paidCtrl.text.trim()) ?? 0.0,
        saleType: _isWholesale ? 'wholesale' : 'retail',
        saleDateMillis: _saleDate.millisecondsSinceEpoch,
        paymentMethod: _paymentMethod,
        payments: _splitPayments,
        overrideCreditLimit: overrideCreditLimit,
        editInvoice: widget.editInvoice,
        stockWarnings: stockWarnings,
      );
      if (!mounted) return;
      // Kotlin SaleSaveSuccess: har stock warning alag toast (save phir bhi ho chuka hai).
      for (final w in stockWarnings) {
        _toast(w);
      }
      if (_isEdit) {
        _toast(Loc.t('Sale updated: $invoice', 'سیل اپ ڈیٹ ہو گئی: $invoice'));
        Navigator.of(context).pop(true);
        return;
      }
      // Saved: the draft must go NOW (not after the debounce) or a kill in
      // the next second would bring the already-saved bill back.
      await _clearDraft();
      _toast('Sale saved: $invoice');
      final shownTotals = totals;
      _clearAll();
      await _showBillPreview(
        invoice: invoice,
        date: previewDate,
        customer: previewCustomer,
        lines: previewLines,
        subtotal: shownTotals.subtotal,
        discount: shownTotals.discount,
        total: shownTotals.total,
        paid: shownTotals.paid,
        paymentLabel: previewMethod,
        showNew: true,
      );
    } on SaleCreditLimitException catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      if (await _confirmCreditLimit(e) == true && mounted) {
        await _save(overrideCreditLimit: true, skipDuplicateCheck: true);
      }
      return;
    } on SaleStockException catch (e) {
      _toast(e.message);
    } on ArgumentError catch (e) {
      _toast(e.message.toString());
    } catch (e) {
      _toast('Could not save sale: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ------------------------------------------------------- Return / Delete

  Future<bool> _confirm(String title, String message, String okLabel, {Color? okColor}) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(Loc.t('Cancel', 'منسوخ'))),
          FilledButton(
            style: okColor == null ? null : FilledButton.styleFrom(backgroundColor: okColor),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(okLabel),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _returnSale() async {
    final invoice = widget.editInvoice;
    if (invoice == null) return;
    final ok = await _confirm(
      Loc.t('Return Sale', 'سیل واپس کریں'),
      Loc.t(
        'The items go back to stock, the customer balance is reversed and the sale is marked Returned. Continue?',
        'آئٹمز واپس اسٹاک میں جائیں گے، کسٹمر بیلنس واپس ہوگا اور سیل "واپس" نشان زد ہوگی۔ جاری رکھیں؟',
      ),
      Loc.t('Return', 'واپس'),
      okColor: ThemeManager.palette.amber,
    );
    if (!ok || !mounted) return;
    setState(() => _saving = true);
    try {
      await SaleRepository.instance.returnSale(invoice);
      if (!mounted) return;
      _toast(Loc.t('Sale returned', 'سیل واپس ہو گئی'));
      Navigator.of(context).pop(true);
    } on ArgumentError catch (e) {
      _toast(e.message.toString());
    } catch (e) {
      _toast('Return nahi ho saki: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _deleteSale() async {
    final invoice = widget.editInvoice;
    if (invoice == null) return;
    final ok = await _confirm(
      Loc.t('Delete Sale', 'سیل حذف کریں'),
      Loc.t(
        'This will remove the bill and reverse its stock and customer balance effect. Continue?',
        'یہ بل حذف کر دے گا اور اس کا اسٹاک اور کسٹمر بیلنس پر اثر واپس کر دے گا۔ جاری رکھیں؟',
      ),
      Loc.t('Delete', 'حذف کریں'),
      okColor: ThemeManager.palette.red,
    );
    if (!ok || !mounted) return;
    setState(() => _saving = true);
    try {
      await SaleRepository.instance.deleteSale(invoice);
      if (!mounted) return;
      _toast(Loc.t('Sale deleted', 'سیل حذف ہو گئی'));
      Navigator.of(context).pop(true);
    } on ArgumentError catch (e) {
      _toast(e.message.toString());
    } catch (e) {
      _toast('Delete nahi ho saki: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ------------------------------------------------------------------ Print

  /// Print / Share entry (overflow menu in Kotlin). Only a SAVED bill has an
  /// invoice number, so a new unsaved sale is asked to be saved first.
  Future<void> _printCurrent() async {
    final invoice = widget.editInvoice;
    if (invoice == null) {
      _toast(Loc.t('Save the sale first', 'پہلے سیل محفوظ کریں'));
      return;
    }
    if (_lines.isEmpty) return;
    final t = _totals;
    await _showBillPreview(
      invoice: invoice,
      date: _saleDate,
      customer: _customerCtrl.text.trim(),
      lines: List<SaleLine>.of(_lines),
      subtotal: t.subtotal,
      discount: t.discount,
      total: t.total,
      paid: t.paid,
      paymentLabel: _paymentLabel(t.paid),
    );
  }

  /// Bill Preview screen (print / WhatsApp / copy) — after a save and from Print.
  Future<void> _showBillPreview({
    required String invoice,
    required DateTime date,
    required String customer,
    required List<SaleLine> lines,
    required double subtotal,
    required double discount,
    required double total,
    required double paid,
    required String paymentLabel,
    bool showNew = false,
  }) async {
    if (!mounted) return;
    await BillPreviewScreen.open(
      context,
      BillDoc(
        isPurchase: false,
        ref: invoice,
        date: date,
        partyName: customer,
        items: [
          for (final l in lines) BillItem(name: l.itemName, qty: l.qty, unit: l.unit, rate: l.unitPrice, amount: l.amount),
        ],
        subtotal: subtotal,
        discount: discount,
        total: total,
        paid: paid,
        paymentMethod: paymentLabel,
      ),
      showNewBill: showNew,
    );
  }

  /// "Save Anyway?" prompt — a shopkeeper can knowingly let a trusted customer
  /// go over their limit, so this asks instead of hard-blocking.
  Future<bool?> _confirmCreditLimit(SaleCreditLimitException e) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(Loc.t('Credit Limit Exceeded', 'کریڈٹ لیمٹ سے تجاوز')),
        content: Text(
          '${e.customerName} ki credit limit Rs.${formatQty(e.creditLimit)} hai. '
          'Ye bill save karne ke baad balance Rs.${formatQty(e.projectedBalance)} ho jayega.\n\n'
          'Phir bhi save karen?',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(Loc.t('Cancel', 'منسوخ'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: ThemeManager.palette.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(Loc.t('Save Anyway', 'پھر بھی محفوظ کریں')),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------- Quick Sale

  Future<void> _openQuickSale() async {
    final top = await SaleRepository.instance.topProductNames();
    if (!mounted) return;
    final request = await showQuickSaleDialog(
      context,
      products: _products,
      customers: _customers,
      topNames: top,
    );
    if (request == null || !mounted) return;
    await _submitQuickSale(request);
  }

  Future<void> _submitQuickSale(QuickSaleRequest r, {bool overrideCreditLimit = false}) async {
    try {
      final result = await SaleRepository.instance.saveQuickSale(
        product: r.product,
        qty: r.qty,
        price: r.price,
        unit: r.unit,
        customerName: r.customerName,
        overrideCreditLimit: overrideCreditLimit,
      );
      HapticFeedback.mediumImpact(); // Kotlin QuickSaleSuccess -> vibrateShort()
      _toast(result.isCredit
          ? 'Quick Sale (credit) saved: ${result.invoice}'
          : 'Quick Sale saved: ${result.invoice}');
    } on SaleCreditLimitException catch (e) {
      if (!mounted) return;
      if (await _confirmCreditLimit(e) == true && mounted) {
        await _submitQuickSale(r, overrideCreditLimit: true);
      }
    } on SaleStockException catch (e) {
      _toast(e.message);
    } on ArgumentError catch (e) {
      _toast(e.message.toString());
    } catch (e) {
      _toast('Quick Sale save nahi hui: $e');
    }
  }

  // ---------------------------------------------------------- Hold / Recall

  Future<void> _holdBill() async {
    if (_lines.isEmpty) {
      _toast('Add items pehle, phir hold karen');
      return;
    }
    final payload = encodeHold(HeldSaleDraft(
      customerName: _customerCtrl.text.trim(),
      isWholesale: _isWholesale,
      isCash: _customerCtrl.text.trim().isEmpty,
      discountText: _discountCtrl.text.trim(),
      lines: List.of(_lines),
    ));
    try {
      await SaleRepository.instance.holdBill(payload);
      if (!mounted) return;
      _toast('Bill hold ho gayi');
      _clearAll();
    } catch (e) {
      _toast('Hold nahi ho saki: $e');
    }
  }

  Future<void> _openRecall() async {
    final held = await SaleRepository.instance.heldBills();
    if (!mounted) return;
    final choice = await showHeldBillsDialog(context, held);
    if (choice == null || !mounted) return;

    if (choice.action == HeldBillAction.delete) {
      await SaleRepository.instance.deleteHeldBill(choice.bill);
      _toast('Held bill hata di');
      return;
    }

    // Recall replaces the bill on screen (same as Android) — don't silently
    // throw away items the cashier is in the middle of entering.
    if (_lines.isNotEmpty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Recall'),
          content: const Text('Current bill ki items replace ho jayengi. Recall karen?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(Loc.t('Cancel', 'منسوخ'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Recall')),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }

    final draft = decodeHold(choice.bill.payload);
    setState(() {
      _editingIndex = null;
      _clearItemEntry();
      _customerCtrl.text = draft.customerName;
      _isWholesale = draft.isWholesale;
      _discountCtrl.text = draft.discountText;
      _paidCtrl.clear();
      _splitPayments = [];
      _lines
        ..clear()
        ..addAll(draft.lines);
    });
    await SaleRepository.instance.deleteHeldBill(choice.bill);
  }

  // ------------------------------------------------- Split payment / extras

  /// Label shown on the bill ("Cash", "Cash + Bank", "Credit").
  String _paymentLabel(double paid) {
    final l = paymentMethodLabel(paid: paid, payments: _splitPayments, singleMethod: _paymentMethod);
    return l == 'credit' ? 'Credit' : l;
  }

  Future<bool> _confirmDuplicate(Sale dup, double total) async {
    final fmt = DateFormat('dd MMM yyyy, hh:mm a');
    final who = _customerCtrl.text.trim().isEmpty ? 'Walk-in' : _customerCtrl.text.trim();
    final when = fmt.format(DateTime.fromMillisecondsSinceEpoch(dup.createdAt));
    final amount = total.toStringAsFixed(0);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(Loc.t('Possible Duplicate Bill', 'ممکنہ ڈپلیکیٹ بل')),
        content: Text(Loc.t(
          'A sale for $who of Rs $amount was already saved on $when (Invoice #${dup.invoice}).\n\nSave this one anyway?',
          '$who کے لیے Rs $amount کی سیل پہلے ہی $when کو محفوظ ہو چکی ہے (انوائس نمبر ${dup.invoice})۔\n\nکیا پھر بھی محفوظ کریں؟',
        )),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(Loc.t('Cancel', 'منسوخ کریں'))),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(Loc.t('Save Anyway', 'پھر بھی محفوظ کریں')),
          ),
        ],
      ),
    );
    return ok == true;
  }

  void _applySplitPayments(List<PayEntry> entries) {
    setState(() {
      _splitPayments = entries;
      _paidCtrl.text = plainAmount(effectivePaidInput(entries, 0.0));
    });
  }

  void _clearSplitPayments() {
    setState(() => _splitPayments = []);
  }

  /// Rs 300 Cash + Rs 200 Bank on one bill. Mirrors openSplitPaymentDialog().
  Future<void> _openSplitPaymentDialog() async {
    const methods = ['Cash', 'Bank'];
    final rows = <({String method, TextEditingController amount})>[];
    void addRow(String method, double amount) {
      rows.add((method: method, amount: TextEditingController(text: amount > 0 ? plainAmount(amount) : '')));
    }

    // Rows keep their method in a parallel mutable list (records are immutable).
    final rowMethods = <String>[];
    void addRowM(String method, double amount) {
      addRow(method, amount);
      rowMethods.add(method);
    }

    if (_splitPayments.isNotEmpty) {
      for (final p in _splitPayments) {
        addRowM(p.method, p.amount);
      }
    } else {
      // Two blank rows nudge the cashier toward actually splitting.
      addRowM('Cash', 0);
      addRowM('Bank', 0);
    }
    final billTotal = _totals.total;
    final hadSplit = _splitPayments.isNotEmpty;

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
                for (var i = 0; i < rows.length; i++)
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
                            controller: rows[i].amount,
                            textAlign: TextAlign.end,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            decoration: const InputDecoration(hintText: '0.00', isDense: true),
                          ),
                        ),
                        IconButton(
                          tooltip: Loc.t('Remove', 'ہٹائیں'),
                          icon: Icon(Icons.close, color: ThemeManager.palette.red, size: 20),
                          onPressed: () => setD(() {
                            rows[i].amount.dispose();
                            rows.removeAt(i);
                            rowMethods.removeAt(i);
                          }),
                        ),
                      ],
                    ),
                  ),
                TextButton(
                  onPressed: () => setD(() => addRowM('Cash', 0)),
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
                for (var i = 0; i < rows.length; i++) {
                  final amt = parseMoneyOrWarn(ctx, rows[i].amount.text, 'Payment Amount', 'ادائیگی کی رقم');
                  if (amt == null) return; // invalid text: warned, keep dialog open
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
    for (final r in rows) {
      r.amount.dispose();
    }
    if (result == null || !mounted) return;
    if (result.isEmpty) {
      _clearSplitPayments();
    } else {
      _applySplitPayments(result);
    }
  }

  /// Full "New Customer" form (Name*, Phone, Credit Limit, Opening Balance)
  /// so a customer added mid-sale isn't missing the details normally filled
  /// in from the Customers screen. Mirrors promptAddCustomer().
  Future<void> _promptAddCustomer() async {
    final nameCtrl = TextEditingController(text: _customerCtrl.text.trim());
    final phoneCtrl = TextEditingController();
    final limitCtrl = TextEditingController();
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
        title: Text(Loc.t('New Customer', 'نیا کسٹمر')),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              field('NAME *', nameCtrl, hint: 'Customer name'),
              field('PHONE (OPTIONAL)', phoneCtrl, type: TextInputType.phone, hint: 'Phone'),
              field('CREDIT LIMIT (OPTIONAL)', limitCtrl, type: decimal, hint: 'Credit limit'),
              field('OPENING BALANCE (RS, IF ANY PREVIOUS DUE)', openingCtrl, type: decimal, hint: 'Opening balance'),
            ],
          ),
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
              final limit = parseMoneyOrWarn(ctx, limitCtrl.text, 'Credit Limit', 'کریڈٹ حد');
              if (limit == null) return;
              final opening = parseMoneyOrWarn(ctx, openingCtrl.text, 'Opening Balance', 'افتتاحی بیلنس');
              if (opening == null) return;
              final exists = _customers.any((c) => c.name.toLowerCase() == name.toLowerCase());
              if (exists) {
                _toast(Loc.t('"$name" already exists', '"$name" پہلے سے موجود ہے'));
                return;
              }
              await CustomerRepository.instance.insert(Customer(
                name: name,
                phone: phoneCtrl.text.trim(),
                creditLimit: limit,
                openingBalance: opening,
                updatedAt: DateTime.now().millisecondsSinceEpoch,
              ));
              if (ctx.mounted) Navigator.pop(ctx, name);
            },
            child: Text(Loc.t('Add', 'شامل کریں')),
          ),
        ],
      ),
    );
    nameCtrl.dispose();
    phoneCtrl.dispose();
    limitCtrl.dispose();
    openingCtrl.dispose();
    if (added == null || !mounted) return;
    setState(() => _customerCtrl.text = added);
    _toast(Loc.t('Customer added: $added', 'کسٹمر شامل ہو گیا: $added'));
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 2)));
  }

  // ------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    // Editing a saved bill is admin-only.
    if (_isEdit && !Session.isAdmin) {
      return const RoleGuard(allowed: {'admin'}, child: SizedBox.shrink());
    }
    if (_isEdit && _originalSale == null) {
      return Scaffold(
        backgroundColor: ThemeManager.palette.bg,
        body: Center(child: CircularProgressIndicator()),
      );
    }
    final returned = _originalSale?.status == 'returned';
    return Scaffold(
      backgroundColor: ThemeManager.palette.bg,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                controller: _scrollCtrl,
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    PremiumHeader(
                      title: _isEdit ? Loc.t('Edit Sale', 'سیل میں ترمیم') : Loc.t('New Sale', 'نئی سیل'),
                      subtitle: _isEdit ? 'Invoice ${widget.editInvoice}' : 'Stock Out / Customer Bill',
                    ),
                    if (returned)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(
                          Loc.t('This sale is already Returned', 'یہ سیل پہلے ہی واپس ہو چکی ہے'),
                          style: TextStyle(color: ThemeManager.palette.red, fontWeight: FontWeight.bold),
                        ),
                      ),
                    _buildActionRow(),
                    _buildFirmCard(),
                    _buildTopRow(),
                    _buildCustomerCard(),
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

  Widget _pill(String emoji, String label, Color color, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(30)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(emoji, style: const TextStyle(fontSize: 13)),
            const SizedBox(width: 6),
            Text(label, style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }

  Widget _buildActionRow() {
    final returned = _originalSale?.status == 'returned';
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Wrap(
        spacing: 10,
        runSpacing: 8,
        children: [
          if (!_isEdit) ...[
            _pill('⚡', Loc.t('Quick Sale', 'فوری سیل'), ThemeManager.palette.teal, _openQuickSale),
            _pill('⏸', Loc.t('Hold', 'ہولڈ'), ThemeManager.palette.amber, _holdBill),
            _pill('▶', Loc.t('Recall', 'ریکال'), ThemeManager.palette.blue, _openRecall),
          ],
          _pill('🕘', Loc.t('History', 'ہسٹری'), ThemeManager.palette.navyInk,
              () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SaleHistoryScreen()))),
          _pill('🖨', Loc.t('Print', 'پرنٹ'), ThemeManager.palette.navyInk, _printCurrent),
          if (_isEdit && !returned) _pill('↩', Loc.t('Return', 'واپس'), ThemeManager.palette.orange, _saving ? () {} : _returnSale),
          if (_isEdit) _pill('🗑', Loc.t('Delete', 'حذف'), ThemeManager.palette.red, _saving ? () {} : _deleteSale),
        ],
      ),
    );
  }

  /// Kotlin "FIRM NAME" card (shop_name, warna default naam).
  Widget _buildFirmCard() => Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        decoration: BoxDecoration(
          color: ThemeManager.palette.cardWhite,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: ThemeManager.palette.border),
        ),
        child: Column(children: [
          Text(Loc.t('Firm Name', 'فرم کا نام').toUpperCase(),
              style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.bold, letterSpacing: 0.5, color: ThemeManager.palette.textMuted)),
          const SizedBox(height: 2),
          Text(_firmName, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: ThemeManager.palette.textDark)),
        ]),
      );

  Widget _buildTopRow() {
    return PremiumCard(
      accentTop: ThemeManager.palette.blue,
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                BadgeIcon(emoji: '📅', color: ThemeManager.palette.blue, size: 38),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('DATE', style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.bold, color: ThemeManager.palette.blue)),
                      GestureDetector(
                        onTap: _pickDate,
                        child: Text(DateFormat('dd MMM yyyy').format(_saleDate),
                            style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: ThemeManager.palette.textDark)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(color: ThemeManager.palette.fieldFill, borderRadius: BorderRadius.circular(30), border: Border.all(color: ThemeManager.palette.border)),
            child: ToggleButtons(
              isSelected: [!_isWholesale, _isWholesale],
              borderRadius: BorderRadius.circular(30),
              selectedColor: Colors.white,
              fillColor: ThemeManager.palette.teal,
              color: ThemeManager.palette.textMuted,
              constraints: const BoxConstraints(minHeight: 36, minWidth: 72),
              onPressed: _onSaleTypeChanged,
              children: const [Text('Retail'), Text('Wholesale')],
            ),
          ),
        ],
      ),
    );
  }

  Widget _fieldBox({required Widget child}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        decoration: BoxDecoration(color: ThemeManager.palette.fieldFill, borderRadius: BorderRadius.circular(16), border: Border.all(color: ThemeManager.palette.border)),
        child: child,
      );

  Widget _buildCustomerCard() {
    return PremiumCard(
      accentTop: ThemeManager.palette.purple,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionLabel(emoji: '🧑‍🤝‍🧑', label: 'Customer (optional unless on credit)', accent: ThemeManager.palette.purple),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: _fieldBox(
                  child: RawAutocomplete<String>(
                    textEditingController: _customerCtrl,
                    focusNode: _customerFocus,
                    onSelected: (_) => _suggestCustomerRate(),
                    optionsBuilder: (text) {
                      final q = text.text.trim().toLowerCase();
                      final names = _customers.map((c) => c.name);
                      if (q.isEmpty) return names;
                      return names.where((n) => n.toLowerCase().contains(q));
                    },
                    fieldViewBuilder: (context, controller, focusNode, onSubmit) => TextField(
                      controller: controller,
                      focusNode: focusNode,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(hintText: 'Walk-in customer — leave blank if fully paid', border: InputBorder.none, isDense: true),
                    ),
                    optionsViewBuilder: (context, onSelected, options) =>
                        autocompleteOptionsView<String>(context, onSelected, options, (o) => o, maxWidth: 640),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                tooltip: Loc.t('New customer', 'نیا کسٹمر'),
                style: IconButton.styleFrom(backgroundColor: ThemeManager.palette.teal),
                icon: const Icon(Icons.add),
                onPressed: _promptAddCustomer,
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// "1 Carton = 12 Dozen • 1 Dozen = 12 Pcs" line under the unit picker.
  String _conversionInfo(Product p) {
    final choices = saleUnitChoices(p);
    final parts = <String>[];
    if (choices.length > 1 && p.secondaryUnitQty > 0) {
      parts.add('1 ${p.unit} = ${formatQty(p.secondaryUnitQty)} ${p.secondaryUnit}');
    }
    if (choices.length > 2 && p.tertiaryUnitQty > 0) {
      parts.add('1 ${p.secondaryUnit} = ${formatQty(p.tertiaryUnitQty)} ${p.tertiaryUnit}');
    }
    return parts.join('   •   ');
  }

  Widget _buildMarginWarning() {
    final p = _pickedProduct;
    if (p == null) return const SizedBox.shrink();
    final unit = _selectedUnit.isEmpty ? p.unit : _selectedUnit;
    final price = double.tryParse(_priceCtrl.text.trim()) ?? 0.0;
    final m = marginFor(p, price, unit);
    if (m.level == MarginLevel.none) return const SizedBox.shrink();

    // Cost figures are admin/manager only; a cashier still gets the loss
    // warning (same protection) but never sees the cost or margin numbers.
    final showFigures = Session.isAdminOrManager;
    late final String text;
    late final Color color;
    switch (m.level) {
      case MarginLevel.loss:
        color = ThemeManager.palette.red;
        text = showFigures
            ? Loc.t('⚠ Loss! Sale rate ≤ Cost (Rs ${m.costInUnit.toStringAsFixed(2)})',
                '⚠ نقصان! سیل ریٹ لاگت (روپے ${m.costInUnit.toStringAsFixed(2)}) کے برابر یا کم ہے')
            : Loc.t('⚠ Loss! Rate is too low', '⚠ نقصان! ریٹ بہت کم ہے');
        break;
      case MarginLevel.low:
        color = ThemeManager.palette.amber;
        text = showFigures
            ? Loc.t('⚠ Low margin: Rs ${m.margin.toStringAsFixed(2)} (${m.marginPct.toStringAsFixed(1)}%) vs Cost Rs ${m.costInUnit.toStringAsFixed(2)}',
                '⚠ کم منافع: روپے ${m.margin.toStringAsFixed(2)} (${m.marginPct.toStringAsFixed(1)}%) بمقابلہ لاگت روپے ${m.costInUnit.toStringAsFixed(2)}')
            : Loc.t('⚠ Low margin', '⚠ کم منافع');
        break;
      default:
        if (!showFigures) return const SizedBox.shrink();
        color = ThemeManager.palette.teal;
        text = Loc.t('Margin: Rs ${m.margin.toStringAsFixed(2)} (${m.marginPct.toStringAsFixed(1)}%) vs Cost Rs ${m.costInUnit.toStringAsFixed(2)}',
            'منافع: روپے ${m.margin.toStringAsFixed(2)} (${m.marginPct.toStringAsFixed(1)}%) بمقابلہ لاگت روپے ${m.costInUnit.toStringAsFixed(2)}');
    }
    return Padding(
      padding: const EdgeInsets.only(top: 8, left: 4),
      child: Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: color)),
    );
  }

  /// "Total Amount: Rs 500" — in Rs mode also the qty that amount buys.
  String _itemTotalText(double qty, double price, String unit) {
    if (_qtyIsAmountMode) {
      final amount = double.tryParse(_qtyCtrl.text.trim()) ?? 0.0;
      final derived = qtyFromAmount(amount, price);
      if (derived != null) {
        return '≈ ${formatQty(derived)} $unit   •   Total Amount: Rs ${amount.round()}';
      }
      return 'Total Amount: Rs 0';
    }
    return 'Total Amount: Rs ${(qty * price).round()}';
  }

  Widget _buildItemEntryCard() {
    final picked = _pickedProduct;
    final unitOptions = picked != null ? saleUnitChoices(picked) : <String>['pcs'];
    final unitValue = unitOptions.contains(_selectedUnit) ? _selectedUnit : unitOptions.first;
    final qty = double.tryParse(_qtyCtrl.text.trim()) ?? 0.0;
    final price = double.tryParse(_priceCtrl.text.trim()) ?? 0.0;

    return PremiumCard(
      accentTop: ThemeManager.palette.amber,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionLabel(emoji: '➕', label: 'Add Item', accent: ThemeManager.palette.amber),
          _fieldBox(
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
                onChanged: (v) {
                  // Typing a different name drops the previous pick.
                  final pp = _pickedProduct;
                  if (pp != null && pp.name != v) {
                    setState(() {
                      _pickedProduct = null;
                      _selectedUnit = '';
                      _lastMainPrice = 0.0;
                      _customerRateName = null;
                    });
                  }
                },
                decoration: const InputDecoration(hintText: 'Search a product to sell', border: InputBorder.none, isDense: true),
              ),
              optionsViewBuilder: (context, onSelected, options) =>
                  autocompleteOptionsView<Product>(context, onSelected, options, (o) => o.name, maxWidth: 640),
            ),
          ),
          if (picked != null)
            Padding(
              padding: const EdgeInsets.only(top: 8, left: 4),
              child: Text(
                'In stock: ${picked.formatStockBreakdown()}',
                style: TextStyle(fontSize: 11, color: ThemeManager.palette.textMuted),
              ),
            ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: PremiumLabeledField(
                  emoji: _qtyIsAmountMode ? '₨' : '🔢',
                  label: _qtyIsAmountMode ? Loc.t('Amount (Rs)', 'رقم (روپے)') : 'Quantity',
                  accent: ThemeManager.palette.amber,
                  controller: _qtyCtrl,
                  hint: _qtyIsAmountMode ? Loc.t('Amount in Rs', 'روپے میں رقم') : '0',
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: 8),
              // "Rs" pill: type the rupee amount, qty is worked out from the rate.
              GestureDetector(
                onTap: _toggleAmountMode,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: _qtyIsAmountMode ? ThemeManager.palette.teal : ThemeManager.palette.cardWhite,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: _qtyIsAmountMode ? ThemeManager.palette.teal : ThemeManager.palette.border),
                  ),
                  child: Text(
                    'Rs',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: _qtyIsAmountMode ? Colors.white : ThemeManager.palette.textMuted,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(color: ThemeManager.palette.fieldFill, borderRadius: BorderRadius.circular(16), border: Border.all(color: ThemeManager.palette.border)),
                child: DropdownButton<String>(
                  value: unitValue,
                  underline: const SizedBox.shrink(),
                  items: unitOptions.map((u) => DropdownMenuItem(value: u, child: Text(u))).toList(),
                  onChanged: picked == null
                      ? null
                      : (v) {
                          if (v == null) return;
                          setState(() {
                            _selectedUnit = v;
                            _refillAutoPrice();
                          });
                        },
                ),
              ),
            ],
          ),
          if (picked != null && _conversionInfo(picked).isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8, left: 4),
              child: Text(_conversionInfo(picked), style: TextStyle(fontSize: 11.5, color: ThemeManager.palette.textMuted)),
            ),
          const SizedBox(height: 12),
          PremiumLabeledField(
            emoji: '💵',
            label: 'Unit Price (auto-filled, editable)',
            accent: ThemeManager.palette.teal,
            controller: _priceCtrl,
            onChanged: _onPriceChanged,
          ),
          if (_customerRateName != null)
            Padding(
              padding: const EdgeInsets.only(top: 8, left: 4),
              child: Text(
                Loc.t(
                  "$_customerRateName's usual rate applied: Rs ${price.toStringAsFixed(2)} / $unitValue",
                  '$_customerRateName کا معمول کا ریٹ لگا دیا گیا: روپے ${price.toStringAsFixed(2)} / $unitValue',
                ),
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: ThemeManager.palette.blue),
              ),
            ),
          _buildMarginWarning(),
          Padding(
            padding: const EdgeInsets.only(top: 10, left: 4),
            child: Text(_itemTotalText(qty, price, unitValue),
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: ThemeManager.palette.textDark)),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: GradientButton(
              label: _editingIndex != null ? Loc.t('UPDATE ITEM', 'آئٹم اپ ڈیٹ کریں') : 'Add to Bill',
              emoji: _editingIndex != null ? '✔' : '✚',
              start: _editingIndex != null ? ThemeManager.palette.amber : ThemeManager.palette.teal,
              end: _editingIndex != null ? ThemeManager.palette.orange : ThemeManager.palette.tealDark,
              padding: const EdgeInsets.symmetric(vertical: 14),
              onTap: _addLine,
            ),
          ),
          if (_editingIndex != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: TextButton(
                onPressed: _cancelLineEdit,
                child: Text(Loc.t('Cancel edit', 'ترمیم منسوخ کریں'), style: TextStyle(color: ThemeManager.palette.red)),
              ),
            ),
        ],
      ),
    );
  }

  /// Compact trigger (Kotlin `billedItemsTrigger`): the full list lives in a popup
  /// so the entry fields and totals stay on screen while items are added.
  Widget _buildLinesList() {
    if (_lines.isEmpty) return const SizedBox.shrink();
    return PremiumCard(
      accentTop: ThemeManager.palette.navy,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: _openBilledItemsDialog,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              const Text('🧾', style: TextStyle(fontSize: 18)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${Loc.t('Billed Items', 'بل کردہ آئٹمز')}  (${_lines.length})  ·  Rs ${_subtotal.toStringAsFixed(0)}',
                  style: TextStyle(fontWeight: FontWeight.bold, color: ThemeManager.palette.navyInk),
                ),
              ),
              Icon(Icons.keyboard_arrow_down, color: ThemeManager.palette.navyInk),
            ],
          ),
        ),
      ),
    );
  }

  /// Kotlin `openBilledItemsDialog()`: closing it just returns to where the
  /// cashier was (no focus jump to Paid).
  Future<void> _openBilledItemsDialog() async {
    if (_lines.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(Loc.t('No items added yet', 'ابھی تک کوئی آئٹم شامل نہیں'))),
      );
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          if (_lines.isEmpty) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (Navigator.of(dialogCtx).canPop()) Navigator.of(dialogCtx).pop();
            });
          }
          return AlertDialog(
            title: Text(Loc.t('Billed Items', 'بل کردہ آئٹمز')),
            contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            content: SizedBox(
              width: double.maxFinite,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < _lines.length; i++)
                      _billedLineTile(
                        i,
                        _lines[i],
                        onEdit: () {
                          Navigator.of(dialogCtx).pop();
                          _editLine(i); // refills the entry fields + scrolls up
                        },
                        onDelete: () {
                          _removeLine(i);
                          setDialogState(() {});
                        },
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogCtx).pop(),
                child: Text(Loc.t('Close', 'بند کریں')),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _billedLineTile(int i, SaleLine line, {required VoidCallback onEdit, required VoidCallback onDelete}) {
    final beingEdited = _editingIndex == i;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: beingEdited ? ThemeManager.palette.amber.withOpacity(0.12) : ThemeManager.palette.fieldFill,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: beingEdited ? ThemeManager.palette.amber : ThemeManager.palette.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: onEdit,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(line.itemName, style: TextStyle(fontWeight: FontWeight.bold, color: ThemeManager.palette.textDark)),
                  Text('${formatQty(line.qty)} ${line.unit}  ×  ${line.unitPrice.toStringAsFixed(2)}',
                      style: TextStyle(fontSize: 11.5, color: ThemeManager.palette.textMuted)),
                ],
              ),
            ),
          ),
          Text(line.amount.toStringAsFixed(2), style: TextStyle(fontWeight: FontWeight.bold, color: ThemeManager.palette.teal)),
          IconButton(icon: Icon(Icons.edit, size: 18, color: ThemeManager.palette.blue), tooltip: 'Edit', onPressed: onEdit),
          IconButton(icon: Icon(Icons.close, size: 18, color: ThemeManager.palette.red), onPressed: onDelete),
        ],
      ),
    );
  }

  Widget _buildTotalsCard() {
    final totals = _totals;
    return PremiumCard(
      accentTop: ThemeManager.palette.purple,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionLabel(emoji: '💰', label: 'Billing', accent: ThemeManager.palette.purple),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Subtotal', style: TextStyle(color: ThemeManager.palette.textMuted)),
              Text(totals.subtotal.toStringAsFixed(2), style: TextStyle(fontWeight: FontWeight.bold, color: ThemeManager.palette.textDark)),
            ],
          ),
          const SizedBox(height: 12),
          PremiumLabeledField(emoji: '➖', label: 'Discount', accent: ThemeManager.palette.orange, controller: _discountCtrl, onChanged: (_) => setState(() {})),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Total', style: TextStyle(fontWeight: FontWeight.bold, color: ThemeManager.palette.textDark)),
              Text(totals.total.toStringAsFixed(2), style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17, color: ThemeManager.palette.navyInk)),
            ],
          ),
          const SizedBox(height: 12),
          PremiumLabeledField(emoji: '💵', label: 'Paid Amount', accent: ThemeManager.palette.purple, controller: _paidCtrl, enabled: _splitPayments.isEmpty, onChanged: (_) => setState(() {})),
          const SizedBox(height: 8),
          if (_splitPayments.isEmpty)
            Row(
              children: [
                Expanded(
                  child: _fieldBox(
                    child: DropdownButton<String>(
                      isExpanded: true,
                      underline: const SizedBox.shrink(),
                      value: _paymentMethod,
                      items: const [
                        DropdownMenuItem(value: 'Cash', child: Text('Cash')),
                        DropdownMenuItem(value: 'Bank', child: Text('Bank')),
                      ],
                      onChanged: (v) => setState(() => _paymentMethod = v ?? 'Cash'),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: _openSplitPaymentDialog,
                  child: Text(Loc.t('+ Split Payment', '+ ادائیگی تقسیم کریں')),
                ),
              ],
            )
          else
            InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () async {
                final remove = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: Text(Loc.t('Remove Split Payment?', 'تقسیم شدہ ادائیگی ہٹائیں؟')),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(Loc.t('Edit', 'ترمیم کریں'))),
                      FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(Loc.t('Remove', 'ہٹائیں'))),
                    ],
                  ),
                );
                if (remove == true) {
                  _clearSplitPayments();
                } else if (remove == false) {
                  await _openSplitPaymentDialog();
                }
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                child: Text(
                  '${Loc.t('Split', 'تقسیم')}: ${splitBreakdown(_splitPayments)}   ✕',
                  style: TextStyle(fontWeight: FontWeight.bold, color: ThemeManager.palette.navyInk, fontSize: 13),
                ),
              ),
            ),
          // Kotlin refreshDue(): Paid khali + total > 0 => "Paid khali hai - Rs X Udhaar jayega".
          if ((double.tryParse(_paidCtrl.text.trim()) ?? 0.0) <= 0.009 && _splitPayments.isEmpty && totals.total > 0)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('⚠ Paid khali hai - Rs ${totals.due.toStringAsFixed(2)} Udhaar jayega',
                  style: TextStyle(color: ThemeManager.palette.red, fontSize: 11, fontWeight: FontWeight.bold)),
            ),
          const SizedBox(height: 12),
          // Kotlin "DUE AMOUNT" card: hamesha dikhta hai; baqi ho to laal, warna hara.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
            decoration: BoxDecoration(
              color: ThemeManager.palette.fieldFill,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: ThemeManager.palette.border),
            ),
            child: Row(children: [
              Expanded(
                child: Text(Loc.t('Due Amount', 'باقی رقم').toUpperCase(),
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 0.5, color: ThemeManager.palette.textMuted)),
              ),
              Text('Rs ${totals.due.toStringAsFixed(2)}',
                  style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: totals.due > 0.009 ? ThemeManager.palette.red : ThemeManager.palette.teal)),
            ]),
          ),
          if (totals.due > 0.009)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(Loc.t('Customer required for due amount', 'باقی رقم کے لیے کسٹمر ضروری ہے'),
                  style: TextStyle(color: ThemeManager.palette.red, fontSize: 12, fontWeight: FontWeight.bold)),
            ),
        ],
      ),
    );
  }

  Widget _buildSaveBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
      decoration: BoxDecoration(color: ThemeManager.palette.cardWhite, boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 10, offset: const Offset(0, -3))]),
      child: SafeArea(
        top: false,
        child: SizedBox(
          width: double.infinity,
          child: GradientButton(
            label: _saving ? 'SAVING…' : (_isEdit ? Loc.t('UPDATE SALE', 'سیل اپ ڈیٹ کریں') : 'SAVE SALE'),
            emoji: '💾',
            start: ThemeManager.palette.navy,
            end: ThemeManager.palette.navyLight,
            radius: 16,
            padding: const EdgeInsets.symmetric(vertical: 18),
            onTap: _saving ? () {} : _save,
          ),
        ),
      ),
    );
  }
}
