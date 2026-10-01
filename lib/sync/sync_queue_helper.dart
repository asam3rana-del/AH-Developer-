import 'dart:async';
import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import 'branch_config_store.dart';
import 'device_tag.dart';

/// Kotlin `SyncQueueHelper.kt` — Firestore schema Android jaisa (dono apps ek backend).
///
/// Har `enqueueX` DB se taaza row parh kar Android wala payload banata hai aur `sync_queue` mein likhta
/// hai. Hamesha usi transaction ke `DatabaseExecutor` par chalayein jis mein data badla ho (Kotlin ki
/// tarah: pehle likho, phir enqueue — payload row + items abhi ki halat se banta hai).
///
/// FARQ (Kotlin se, jaan boojh kar):
///  * Entity id "serverId-preferred": row par pehle se serverId ho to wahi (doosre device se pull hui
///    row ko edit karne par naya duplicate document nahi banta); warna `<type>:<DeviceTag>-<localId>`.
///    Kotlin ye sirf payment/expense/cash/shell ke liye karta hai, baqi ke liye har baar apne device ka
///    id dobara banata tha (pulled row edit => duplicate). Apni bani rows ke liye dono barabar hain.
///  * `saleUid` / `lineUid` / `purchaseUid` payload mein nahi (Flutter schema mein column nahi;
///    Android pull khali uid par naya random banata hai).
///  * Purchase payload mein extra `dueDate` + `supplierInvoiceNo`, sale mein `dueDate` (Android unhein
///    ignore karta hai; Flutter pull unhein wapas laata hai).
///  * Payment ka `partyServerId` local column mein nahi — enqueue ke waqt party ki row se nikalta hai.
class SyncQueueHelper {
  SyncQueueHelper._();

  /// Sirf yeh app_settings keys sync hoti hain (baaqi device-specific: printer, login_method ...).
  static const Set<String> syncedAppSettingKeys = {
    'shop_name', 'shop_phone', 'shop_address', 'receipt_footer', 'currency', 'tax_percent',
  };

  // ------------------------------------------------------------------ ids

  static String _tag() => DeviceTag.current;

  /// serverId ho to wahi, warna `<prefix><tag>-<id>`.
  static String _own(String prefix, Map<String, Object?> row) {
    final sid = row['serverId'];
    if (sid is String && sid.trim().isNotEmpty) return sid;
    return '$prefix${_tag()}-${row['id']}';
  }

  static String customerEntityId(Map<String, Object?> r) => _own('customer:', r);
  static String supplierEntityId(Map<String, Object?> r) => _own('supplier:', r);
  static String productEntityId(Map<String, Object?> r) => r['barcode'] as String;
  static String saleEntityId(String invoice) => 'sale:$invoice';
  static String purchaseEntityId(String billNo) => 'purchase:$billNo';
  static String paymentEntityId(Map<String, Object?> r) => _own('payment:', r);
  static String expenseEntityId(Map<String, Object?> r) => _own('expense:', r);
  static String cashTransactionEntityId(Map<String, Object?> r) => _own('cash_transaction:', r);
  static String userEntityId(String username) => 'user:$username';
  static String zakatYearEntityId(Map<String, Object?> r) => _own('zakat_year:', r);
  static String zakatPaymentEntityId(Map<String, Object?> r) => _own('zakat_payment:', r);
  static String returnEntityId(Map<String, Object?> r) => _own('return:', r);
  static String stockMovementEntityId(Map<String, Object?> r) => _own('stock_movement:', r);
  static String cashRegisterEntityId(String date) => date;
  static String appSettingEntityId(String key) => key;
  static String unitEntityId(String name) => name;
  static String categoryEntityId(String name) => name;
  static String shellCustomerEntityId(Map<String, Object?> r) => _own('shell_customer:', r);
  static String shellTransactionEntityId(Map<String, Object?> r) => _own('shell_transaction:', r);
  static String shopEmptyShellLogEntityId(Map<String, Object?> r) => _own('shop_empty_shell_log:', r);

  // -------------------------------------------------------------- plumbing

  /// Test/main() inject karte hain; `now` aur `branch` payload stamp ke liye.
  static int Function() nowMs = () => DateTime.now().millisecondsSinceEpoch;
  static String Function() branchId = () => BranchConfigStore.current;

  /// Enqueue ke baad sync chalane ki koshish (Kotlin `trigger`). main() mein
  /// `SyncHelperHooks.onQueued = SyncWorker.instance.triggerNow`. Debounce: transaction khatam hone ka
  /// intezar (2 s), aur burst mein sirf ek baar.
  static void Function()? onQueued;
  static Timer? _debounce;
  static Duration triggerDelay = const Duration(seconds: 2);

  static void _scheduleTrigger() {
    final cb = onQueued;
    if (cb == null) return;
    _debounce?.cancel();
    _debounce = Timer(triggerDelay, cb);
  }

  static String _s(Object? v) => v is String ? v : '';
  static bool _b(Object? v) => v == 1 || v == true;

  /// Kotlin `enqueue()`. `payload` JSON ban kar `payloadJson` mein.
  static Future<void> enqueue(
    DatabaseExecutor ex,
    String entityType,
    String entityId,
    String operation,
    Map<String, Object?> payload,
  ) async {
    await ex.insert('sync_queue', {
      'entityType': entityType,
      'entityId': entityId,
      'operation': operation,
      'payloadJson': jsonEncode(payload),
      'createdAt': nowMs(),
      'retryCount': 0,
    });
    _scheduleTrigger();
  }

  static Map<String, Object?> _stamp(Map<String, Object?> m) =>
      {...m, 'updatedAt': nowMs(), 'branchId': branchId()};

  static Future<Map<String, Object?>?> _row(
      DatabaseExecutor ex, String table, String col, Object value) async {
    final r = await ex.query(table, where: '$col = ?', whereArgs: [value], limit: 1);
    return r.isEmpty ? null : Map<String, Object?>.from(r.first);
  }

  /// Row par serverId nahi ya alag ho to `entityId` laga do (self-duplication FIX: apni push hui row
  /// agli pull par dobara "naye" ki tarah insert na ho). `dirty` ko nahi chhoota.
  static Future<void> _stampServerId(
      DatabaseExecutor ex, String table, Map<String, Object?> row, String entityId) async {
    if (row['serverId'] == entityId) return;
    await ex.update(table, {'serverId': entityId}, where: 'id = ?', whereArgs: [row['id']]);
    row['serverId'] = entityId;
  }

  // -------------------------------------------------------- payload builders

  static Map<String, Object?> customerPayload(Map<String, Object?> c) => _stamp({
        'serverId': customerEntityId(c),
        'name': c['name'],
        'phone': c['phone'],
        // "balance" jaan boojh kar nahi — sirf increment_balance se (conflict-safe sync).
        'creditLimit': c['creditLimit'],
        'openingBalance': c['openingBalance'],
        // Stuck Balance: plain snapshot (sales/payments se nahi hilta).
        'stuckBalance': c['stuckBalance'],
      });

  static Map<String, Object?> supplierPayload(Map<String, Object?> s) => _stamp({
        'serverId': supplierEntityId(s),
        'name': s['name'],
        'phone': s['phone'],
        'openingBalance': s['openingBalance'],
      });

  static Map<String, Object?> productPayload(Map<String, Object?> p) => _stamp({
        'barcode': productEntityId(p),
        'name': p['name'],
        'category': p['category'],
        'cost': p['cost'],
        'salePrice': p['salePrice'],
        'wholesalePrice': p['wholesalePrice'],
        'reorderLevel': p['reorderLevel'],
        'expiry': p['expiry'],
        'unit': p['unit'],
        'unitSize': p['unitSize'],
        'unitNote': p['unitNote'],
        'secondaryUnit': p['secondaryUnit'],
        'secondaryUnitQty': p['secondaryUnitQty'],
        'tertiaryUnit': p['tertiaryUnit'],
        'tertiaryUnitQty': p['tertiaryUnitQty'],
        'defaultUnitIndex': p['defaultUnitIndex'],
        'quickSaleDefaultUnitIndex': p['quickSaleDefaultUnitIndex'],
        'searchTag': p['searchTag'],
        // "stock" / "openingStock" jaan boojh kar nahi — sirf increment_stock se.
      });

  static Map<String, Object?> unitPayload(String name) => _stamp({'name': name});
  static Map<String, Object?> categoryPayload(String name) => _stamp({'name': name});

  static Map<String, Object?> zakatYearPayload(Map<String, Object?> y) => _stamp({
        'serverId': zakatYearEntityId(y),
        'startDate': y['startDate'],
        'endDate': y['endDate'],
        'assetsSnapshot': y['assetsSnapshot'],
        'totalPayable': y['totalPayable'],
        'currency': y['currency'],
        'calendarType': y['calendarType'],
        'createdAt': y['createdAt'],
      });

  /// [yearServerId] = parent ZakatYear ki serverId (local id nahi).
  static Map<String, Object?> zakatPaymentPayload(Map<String, Object?> p, String yearServerId) => _stamp({
        'serverId': zakatPaymentEntityId(p),
        'zakatYearServerId': yearServerId,
        'amount': p['amount'],
        'method': p['method'],
        'note': p['note'],
        'category': p['category'],
        'paymentDate': p['paymentDate'],
        'createdAt': p['createdAt'],
      });

  static Map<String, Object?> returnPayload(Map<String, Object?> r) => _stamp({
        'serverId': returnEntityId(r),
        'reference': r['reference'],
        'type': r['type'],
        'barcode': r['barcode'],
        'qty': r['qty'],
        'amount': r['amount'],
        'createdAt': r['createdAt'],
      });

  static Map<String, Object?> shellCustomerPayload(Map<String, Object?> c) => _stamp({
        'serverId': shellCustomerEntityId(c),
        'name': c['name'],
        'phone': c['phone'],
        'shellsOwed': c['shellsOwed'],
        'createdAt': c['createdAt'],
      });

  /// customerId local hai — doosre device ke liye shell customer ki serverId se link.
  static Map<String, Object?> shellTransactionPayload(Map<String, Object?> t, String? customerServerId) =>
      _stamp({
        'serverId': shellTransactionEntityId(t),
        'customerServerId': customerServerId,
        'type': t['type'],
        'qty': t['qty'],
        'note': t['note'],
        'createdAt': t['createdAt'],
      });

  static Map<String, Object?> shopEmptyShellLogPayload(Map<String, Object?> l) => _stamp({
        'serverId': shopEmptyShellLogEntityId(l),
        'delta': l['delta'],
        'reason': l['reason'],
        'note': l['note'],
        'createdAt': l['createdAt'],
      });

  static Map<String, Object?> stockMovementPayload(Map<String, Object?> m) => _stamp({
        'serverId': stockMovementEntityId(m),
        'barcode': m['barcode'],
        'type': m['type'],
        'qty': m['qty'],
        'unit': m['unit'],
        'cost': m['cost'],
        'reference': m['reference'],
        'note': m['note'],
        'createdAt': m['createdAt'],
      });

  static Map<String, Object?> cashRegisterPayload(Map<String, Object?> r) => _stamp({
        'date': r['date'],
        'openingCash': r['openingCash'],
        'closingCash': r['closingCash'],
        'openingBank': r['openingBank'],
        'closingBank': r['closingBank'],
        'closed': _b(r['closed']),
      });

  static Map<String, Object?> appSettingPayload(String key, String value) =>
      _stamp({'key': key, 'value': value});

  /// [items] = sale_items rows; [customerServerId] = customer ki entity id (local id nahi).
  static Map<String, Object?> salePayload(
      Map<String, Object?> sale, List<Map<String, Object?>> items, String? customerServerId) {
    final itemMaps = [
      for (final it in items)
        {
          'barcode': it['barcode'],
          'product': it['product'],
          'qty': it['qty'],
          'unit': it['unit'],
          'unitPrice': it['unitPrice'],
          'cost': it['cost'],
          'amount': it['amount'],
          // Transaction-time conversion factor (unit ladder badalne par purani sale ka reversal sahi).
          'conversionFactor': it['conversionFactor'],
        }
    ];
    return _stamp({
      'serverId': saleEntityId(_s(sale['invoice'])),
      'invoice': sale['invoice'],
      'customerServerId': customerServerId,
      'subtotal': sale['subtotal'],
      'discount': sale['discount'],
      'total': sale['total'],
      'paid': sale['paid'],
      'paymentMethod': sale['paymentMethod'],
      'saleType': sale['saleType'],
      'createdAt': sale['createdAt'],
      'status': sale['status'],
      'dueDate': sale['dueDate'],
      'itemCount': items.length,
      'items': itemMaps,
    });
  }

  static Map<String, Object?> purchasePayload(
      Map<String, Object?> p, List<Map<String, Object?>> items, String? supplierServerId) {
    final itemMaps = [
      for (final it in items)
        {
          'barcode': it['barcode'],
          'qty': it['qty'],
          'unit': it['unit'],
          'unitCost': it['unitCost'],
          'amount': it['amount'],
          'conversionFactor': it['conversionFactor'],
          // Item naam + retail/wholesale rate ka apna snapshot (product row na ho tab bhi dikhe).
          'itemName': it['itemName'],
          'retailRate': it['retailRate'],
          'wholesaleRate': it['wholesaleRate'],
        }
    ];
    return _stamp({
      'serverId': purchaseEntityId(_s(p['billNo'])),
      'billNo': p['billNo'],
      'supplierServerId': supplierServerId,
      'subtotal': p['subtotal'],
      'discount': p['discount'],
      'total': p['total'],
      'paid': p['paid'],
      'createdAt': p['createdAt'],
      'status': p['status'],
      'dueDate': p['dueDate'],
      'supplierInvoiceNo': p['supplierInvoiceNo'],
      'itemCount': items.length,
      'items': itemMaps,
    });
  }

  static Map<String, Object?> paymentPayload(Map<String, Object?> p, String? partyServerId) => _stamp({
        'serverId': paymentEntityId(p),
        'reference': p['reference'],
        'partyType': p['partyType'],
        'partyId': p['partyId'],
        // Doosra device party is stable id se dhoondta hai (partyId sirf purane docs ke liye).
        'partyServerId': partyServerId,
        'amount': p['amount'],
        'method': p['method'],
        'note': p['note'],
        'billReference': p['billReference'],
        'createdAt': p['createdAt'],
      });

  static Map<String, Object?> expensePayload(Map<String, Object?> e) => _stamp({
        'serverId': expenseEntityId(e),
        'category': e['category'],
        'description': e['description'],
        'amount': e['amount'],
        'method': e['method'],
        'createdAt': e['createdAt'],
      });

  static Map<String, Object?> cashTransactionPayload(Map<String, Object?> t) => _stamp({
        'serverId': cashTransactionEntityId(t),
        'type': t['type'],
        'method': t['method'],
        'amount': t['amount'],
        'reason': t['reason'],
        'reference': t['reference'],
        'createdAt': t['createdAt'],
      });

  /// passwordHash jaan boojh kar nahi (Firestore mein nahi jata).
  static Map<String, Object?> userPayload(Map<String, Object?> u) => _stamp({
        'serverId': userEntityId(_s(u['username'])),
        'username': u['username'],
        'displayName': u['displayName'],
        'role': u['role'],
        'phone': u['phone'],
        'active': _b(u['active']),
      });

  static Map<String, Object?> deltaPayload(double delta) =>
      {'delta': delta, 'updatedAt': nowMs(), 'branchId': branchId()};

  // ------------------------------------------------------------- enqueueX

  static Future<void> enqueueCustomer(DatabaseExecutor ex, int id) async {
    final c = await _row(ex, 'customers', 'id', id);
    if (c == null) return;
    final eid = customerEntityId(c);
    await _stampServerId(ex, 'customers', c, eid);
    await enqueue(ex, 'customer', eid, 'upsert', customerPayload(c));
  }

  static Future<void> enqueueSupplier(DatabaseExecutor ex, int id) async {
    final s = await _row(ex, 'suppliers', 'id', id);
    if (s == null) return;
    final eid = supplierEntityId(s);
    await _stampServerId(ex, 'suppliers', s, eid);
    await enqueue(ex, 'supplier', eid, 'upsert', supplierPayload(s));
  }

  static Future<void> enqueueProduct(DatabaseExecutor ex, String barcode) async {
    final p = await _row(ex, 'products', 'barcode', barcode);
    if (p == null) return;
    await enqueue(ex, 'product', productEntityId(p), 'upsert', productPayload(p));
  }

  static Future<void> enqueueSale(DatabaseExecutor ex, String invoice) async {
    final sale = await _row(ex, 'sales', 'invoice', invoice);
    if (sale == null) return;
    final items = await ex.query('sale_items', where: 'invoice = ?', whereArgs: [invoice], orderBy: 'id');
    String? custSid;
    final cid = sale['customerId'];
    if (cid is int) {
      final c = await _row(ex, 'customers', 'id', cid);
      if (c != null) custSid = customerEntityId(c);
    }
    // Party local mein nahi mili thi (pull par) => cloud ki mehfooz pehchan wapas bhejo, null nahi.
    if (custSid == null) {
      final stored = sale['customerServerId'];
      if (stored is String && stored.trim().isNotEmpty) custSid = stored;
    }
    await enqueue(ex, 'sale', saleEntityId(invoice), 'upsert',
        salePayload(sale, [for (final i in items) Map<String, Object?>.from(i)], custSid));
  }

  static Future<void> enqueuePurchase(DatabaseExecutor ex, String billNo) async {
    final p = await _row(ex, 'purchases', 'billNo', billNo);
    if (p == null) return;
    final items = await ex.query('purchase_items', where: 'billNo = ?', whereArgs: [billNo], orderBy: 'id');
    String? supSid;
    final sid = p['supplierId'];
    if (sid is int) {
      final s = await _row(ex, 'suppliers', 'id', sid);
      if (s != null) supSid = supplierEntityId(s);
    }
    if (supSid == null) {
      final stored = p['supplierServerId'];
      if (stored is String && stored.trim().isNotEmpty) supSid = stored;
    }
    await enqueue(ex, 'purchase', purchaseEntityId(billNo), 'upsert',
        purchasePayload(p, [for (final i in items) Map<String, Object?>.from(i)], supSid));
  }

  static Future<void> enqueuePayment(DatabaseExecutor ex, int id) async {
    final p = await _row(ex, 'payments', 'id', id);
    if (p == null) return;
    final eid = paymentEntityId(p);
    await _stampServerId(ex, 'payments', p, eid);
    String? partySid;
    final pid = p['partyId'];
    if (pid is int) {
      final table = p['partyType'] == 'customer'
          ? 'customers'
          : p['partyType'] == 'supplier'
              ? 'suppliers'
              : null;
      if (table != null) {
        final party = await _row(ex, table, 'id', pid);
        if (party != null) {
          partySid = table == 'customers' ? customerEntityId(party) : supplierEntityId(party);
        }
      }
    }
    if (partySid == null) {
      final stored = p['partyServerId'];
      if (stored is String && stored.trim().isNotEmpty) partySid = stored;
    }
    await enqueue(ex, 'payment', eid, 'upsert', paymentPayload(p, partySid));
  }

  static Future<void> enqueueExpense(DatabaseExecutor ex, int id) async {
    final e = await _row(ex, 'expenses', 'id', id);
    if (e == null) return;
    final eid = expenseEntityId(e);
    await _stampServerId(ex, 'expenses', e, eid);
    await enqueue(ex, 'expense', eid, 'upsert', expensePayload(e));
  }

  static Future<void> enqueueCashTransaction(DatabaseExecutor ex, int id) async {
    final t = await _row(ex, 'cash_transactions', 'id', id);
    if (t == null) return;
    final eid = cashTransactionEntityId(t);
    await _stampServerId(ex, 'cash_transactions', t, eid);
    await enqueue(ex, 'cash_transaction', eid, 'upsert', cashTransactionPayload(t));
  }

  static Future<void> enqueueUser(DatabaseExecutor ex, String username) async {
    final u = await _row(ex, 'users', 'username', username);
    if (u == null) return;
    await enqueue(ex, 'user', userEntityId(username), 'upsert', userPayload(u));
  }

  static Future<void> enqueueUnit(DatabaseExecutor ex, String name) =>
      enqueue(ex, 'unit', unitEntityId(name), 'upsert', unitPayload(name));

  static Future<void> enqueueCategory(DatabaseExecutor ex, String name) =>
      enqueue(ex, 'category', categoryEntityId(name), 'upsert', categoryPayload(name));

  /// Parent year ki serverId lauta deta hai (payments ko chahiye).
  static Future<String?> enqueueZakatYear(DatabaseExecutor ex, int id) async {
    final y = await _row(ex, 'zakat_years', 'id', id);
    if (y == null) return null;
    final eid = zakatYearEntityId(y);
    await _stampServerId(ex, 'zakat_years', y, eid);
    await enqueue(ex, 'zakat_year', eid, 'upsert', zakatYearPayload(y));
    return eid;
  }

  static Future<void> enqueueZakatPayment(DatabaseExecutor ex, int id) async {
    final p = await _row(ex, 'zakat_payments', 'id', id);
    if (p == null) return;
    final y = await _row(ex, 'zakat_years', 'id', p['zakatYearId'] as Object);
    if (y == null) return; // parent ke baghair payment ka koi matlab nahi (doosra device skip karega)
    final yearSid = zakatYearEntityId(y);
    await _stampServerId(ex, 'zakat_years', y, yearSid);
    final eid = zakatPaymentEntityId(p);
    await _stampServerId(ex, 'zakat_payments', p, eid);
    await enqueue(ex, 'zakat_payment', eid, 'upsert', zakatPaymentPayload(p, yearSid));
  }

  static Future<void> enqueueReturn(DatabaseExecutor ex, int id) async {
    final r = await _row(ex, 'returns', 'id', id);
    if (r == null) return;
    final eid = returnEntityId(r);
    await _stampServerId(ex, 'returns', r, eid);
    await enqueue(ex, 'return', eid, 'upsert', returnPayload(r));
  }

  static Future<void> enqueueStockMovement(DatabaseExecutor ex, int id) async {
    final m = await _row(ex, 'stock_movements', 'id', id);
    if (m == null) return;
    final eid = stockMovementEntityId(m);
    await _stampServerId(ex, 'stock_movements', m, eid);
    await enqueue(ex, 'stock_movement', eid, 'upsert', stockMovementPayload(m));
  }

  static Future<void> enqueueCashRegister(DatabaseExecutor ex, String date) async {
    final r = await _row(ex, 'cash_register', 'date', date);
    if (r == null) return;
    await enqueue(ex, 'cash_register', cashRegisterEntityId(date), 'upsert', cashRegisterPayload(r));
  }

  /// OPEN register: "create_if_absent" (do device ek hi din ka register khol dein to doosra drop ho).
  static Future<void> enqueueCashRegisterCreate(DatabaseExecutor ex, String date) async {
    final r = await _row(ex, 'cash_register', 'date', date);
    if (r == null) return;
    await enqueue(ex, 'cash_register', cashRegisterEntityId(date), 'create_if_absent', cashRegisterPayload(r));
  }

  /// Whitelist se bahar ki key par khamoshi se kuch nahi.
  static Future<void> enqueueAppSetting(DatabaseExecutor ex, String key, String value) async {
    if (!syncedAppSettingKeys.contains(key)) return;
    await enqueue(ex, 'app_setting', appSettingEntityId(key), 'upsert', appSettingPayload(key, value));
  }

  static Future<void> enqueueShellCustomer(DatabaseExecutor ex, int id) async {
    final c = await _row(ex, 'shell_customers', 'id', id);
    if (c == null) return;
    final eid = shellCustomerEntityId(c);
    await _stampServerId(ex, 'shell_customers', c, eid);
    await enqueue(ex, 'shell_customer', eid, 'upsert', shellCustomerPayload(c));
  }

  static Future<void> enqueueShellTransaction(DatabaseExecutor ex, int id) async {
    final t = await _row(ex, 'shell_transactions', 'id', id);
    if (t == null) return;
    final eid = shellTransactionEntityId(t);
    await _stampServerId(ex, 'shell_transactions', t, eid);
    String? custSid;
    final c = await _row(ex, 'shell_customers', 'id', t['customerId'] as Object);
    if (c != null) custSid = shellCustomerEntityId(c);
    await enqueue(ex, 'shell_transaction', eid, 'upsert', shellTransactionPayload(t, custSid));
  }

  static Future<void> enqueueShopEmptyShellLog(DatabaseExecutor ex, int id) async {
    final l = await _row(ex, 'shop_empty_shell_log', 'id', id);
    if (l == null) return;
    final eid = shopEmptyShellLogEntityId(l);
    await _stampServerId(ex, 'shop_empty_shell_log', l, eid);
    await enqueue(ex, 'shop_empty_shell_log', eid, 'upsert', shopEmptyShellLogPayload(l));
  }

  /// Kisi bhi entity ka delete (tombstone). Row delete hone se PEHLE uski entity id nikal len
  /// ([entityIdFor]) warna doosre device se aayi row ki asal serverId kho jati hai.
  static Future<void> enqueueDelete(DatabaseExecutor ex, String entityType, String entityId) =>
      enqueue(ex, entityType, entityId, 'delete', const {});

  // ------------------------------------------------------- balance / stock

  /// Kotlin `adjustCustomerBalance/adjustSupplierBalance` ka queue hissa: balance ka DELTA
  /// (`FieldValue.increment`) — do offline device ek hi party par kaam karein to koi asar nahi khota.
  /// Local balance ka SQL update caller khud karta hai (repositories ka apna SQL).
  static Future<void> enqueueBalanceDelta(
      DatabaseExecutor ex, {required bool customer, required int partyId, required double delta}) async {
    if (delta == 0) return;
    final table = customer ? 'customers' : 'suppliers';
    final row = await _row(ex, table, 'id', partyId);
    if (row == null) return;
    final eid = customer ? customerEntityId(row) : supplierEntityId(row);
    await _stampServerId(ex, table, row, eid);
    await enqueue(ex, customer ? 'customer' : 'supplier', eid, 'increment_balance', deltaPayload(delta));
  }

  /// Kotlin `decreaseProductStock/increaseProductStock` ka queue hissa (stock ka DELTA).
  static Future<void> enqueueStockDelta(DatabaseExecutor ex, String barcode, double delta) async {
    if (delta == 0) return;
    await enqueue(ex, 'product', barcode, 'increment_stock', deltaPayload(delta));
  }

  // ------------------------------------------------- delete helpers (Kotlin)

  /// Kotlin `deletePaymentsByReference`: rows padho (serverId samet), local delete, har ka sync delete.
  static Future<void> deletePaymentsByReference(DatabaseExecutor ex, String reference) async {
    final rows = await ex.query('payments', where: 'reference = ?', whereArgs: [reference]);
    if (rows.isEmpty) return;
    await ex.delete('payments', where: 'reference = ?', whereArgs: [reference]);
    for (final p in rows) {
      await enqueueDelete(ex, 'payment', paymentEntityId(Map<String, Object?>.from(p)));
    }
  }

  static Future<void> deletePaymentRow(DatabaseExecutor ex, Map<String, Object?> payment) async {
    await ex.delete('payments', where: 'id = ?', whereArgs: [payment['id']]);
    await enqueueDelete(ex, 'payment', paymentEntityId(payment));
  }

  static Future<void> deleteCashTransactionsByReference(DatabaseExecutor ex, String reference) async {
    final rows = await ex.query('cash_transactions', where: 'reference = ?', whereArgs: [reference]);
    if (rows.isEmpty) return;
    await ex.delete('cash_transactions', where: 'reference = ?', whereArgs: [reference]);
    for (final t in rows) {
      await enqueueDelete(ex, 'cash_transaction', cashTransactionEntityId(Map<String, Object?>.from(t)));
    }
  }

  // ------------------------------------------------------ one-off repairs

  /// Kotlin `mergeOwnDuplicateExpenses`: purani "expense do baar save" bug ki safai — bina serverId wali
  /// row ka twin (is device ke prefix wala, millisecond tak barabar) sirf LOCAL hata do (sync-delete
  /// nahi: wo shared document ko tombstone kar deta), original us document ki serverId apna le.
  static Future<int> mergeOwnDuplicateExpenses(Database db) async {
    final prefix = 'expense:${_tag()}-';
    var merged = 0;
    await db.transaction((txn) async {
      final unstamped = await txn.query('expenses', where: "serverId IS NULL OR serverId = ''");
      for (final o in unstamped) {
        final twins = await txn.query(
          'expenses',
          where: "serverId LIKE ? AND createdAt = ? AND amount = ? AND category = ? AND description = ? "
              "AND method = ? AND id != ?",
          whereArgs: ['$prefix%', o['createdAt'], o['amount'], o['category'], o['description'], o['method'], o['id']],
          limit: 1,
        );
        if (twins.isEmpty) continue;
        final twin = twins.first;
        await txn.delete('expenses', where: 'id = ?', whereArgs: [twin['id']]);
        final ou = (o['updatedAt'] as num?)?.toInt() ?? 0;
        final tu = (twin['updatedAt'] as num?)?.toInt() ?? 0;
        await txn.update(
          'expenses',
          {'serverId': twin['serverId'], 'updatedAt': ou > tu ? ou : tu, 'dirty': 0},
          where: 'id = ?',
          whereArgs: [o['id']],
        );
        merged++;
      }
    });
    return merged;
  }

  /// Kotlin `fixBackdatedCashTransactionDates`: "Purchase"/"Sale" cash row ki tareekh us bill ki
  /// createdAt se mila do (pehle wo "abhi" ki tareekh par thi). Kitni row badli.
  static Future<int> fixBackdatedCashTransactionDates(Database db) async {
    var fixed = 0;
    await db.transaction((txn) async {
      final rows = await txn.query('cash_transactions', where: "reason IN ('Purchase', 'Sale')");
      for (final t in rows) {
        final isSale = t['reason'] == 'Sale';
        final bill = await txn.query(
          isSale ? 'sales' : 'purchases',
          columns: ['createdAt'],
          where: isSale ? 'invoice = ?' : 'billNo = ?',
          whereArgs: [t['reference']],
          limit: 1,
        );
        if (bill.isEmpty) continue;
        final correct = (bill.first['createdAt'] as num).toInt();
        if (correct == (t['createdAt'] as num).toInt()) continue;
        await txn.update('cash_transactions', {'createdAt': correct, 'dirty': 1, 'updatedAt': nowMs()},
            where: 'id = ?', whereArgs: [t['id']]);
        await enqueueCashTransaction(txn, t['id'] as int);
        fixed++;
      }
    });
    return fixed;
  }

  /// Kotlin `resyncAllLocalData`: har local row dobara push ke liye queue (pehle kabhi synced ho ya
  /// nahi). Zakat: year pehle, phir uske payments. Kai baar chalana safe hai.
  static Future<void> resyncAllLocalData(Database db) async {
    await db.transaction((txn) async {
      for (final r in await txn.query('customers')) {
        await enqueueCustomer(txn, r['id'] as int);
      }
      for (final r in await txn.query('suppliers')) {
        await enqueueSupplier(txn, r['id'] as int);
      }
      for (final r in await txn.query('products')) {
        await enqueueProduct(txn, r['barcode'] as String);
      }
      for (final r in await txn.query('users')) {
        await enqueueUser(txn, r['username'] as String);
      }
      for (final r in await txn.query('sales')) {
        await enqueueSale(txn, r['invoice'] as String);
      }
      for (final r in await txn.query('purchases')) {
        await enqueuePurchase(txn, r['billNo'] as String);
      }
      for (final r in await txn.query('payments')) {
        await enqueuePayment(txn, r['id'] as int);
      }
      for (final r in await txn.query('expenses')) {
        await enqueueExpense(txn, r['id'] as int);
      }
      for (final r in await txn.query('cash_transactions')) {
        await enqueueCashTransaction(txn, r['id'] as int);
      }
      for (final r in await txn.query('units')) {
        await enqueueUnit(txn, r['name'] as String);
      }
      for (final r in await txn.query('categories')) {
        await enqueueCategory(txn, r['name'] as String);
      }
      for (final y in await txn.query('zakat_years')) {
        await enqueueZakatYear(txn, y['id'] as int);
        for (final p in await txn.query('zakat_payments', where: 'zakatYearId = ?', whereArgs: [y['id']])) {
          await enqueueZakatPayment(txn, p['id'] as int);
        }
      }
      for (final r in await txn.query('returns')) {
        await enqueueReturn(txn, r['id'] as int);
      }
      for (final r in await txn.query('stock_movements')) {
        await enqueueStockMovement(txn, r['id'] as int);
      }
      for (final key in syncedAppSettingKeys) {
        final v = await _row(txn, 'app_settings', 'key', key);
        if (v != null) await enqueueAppSetting(txn, key, _s(v['value']));
      }
      for (final r in await txn.query('cash_register')) {
        await enqueueCashRegister(txn, r['date'] as String);
      }
      for (final r in await txn.query('shell_customers')) {
        await enqueueShellCustomer(txn, r['id'] as int);
      }
      for (final r in await txn.query('shell_transactions')) {
        await enqueueShellTransaction(txn, r['id'] as int);
      }
      for (final r in await txn.query('shop_empty_shell_log')) {
        await enqueueShopEmptyShellLog(txn, r['id'] as int);
      }
    });
  }

  // ------------------------------------------------------- legacy adapter

  /// Purane repositories ka `_enqueue(ex, type, id, op, payload)` yahan aata hai. Purani `payload` map
  /// ab IGNORE hoti hai (wo raw row/`toString()` thi, Android shape ki nahi) — asal payload row + items
  /// DB se abhi ki halat mein banta hai, is liye enqueue hamesha data likhne ke BAAD ho.
  ///
  /// `id` ki tashreeh type ke hisaab se: sale = invoice, purchase = billNo, product = barcode,
  /// unit/category = naam, baqi = local numeric id, ya serverId, ya `type:N`.
  ///
  /// Ops: create/update/upsert => enqueueX (row na mile to kuch nahi); delete => tombstone (row mile
  /// to us ki asal serverId, warna id); increment_balance => `payload['delta']`.
  static Future<void> enqueueLegacy(
    DatabaseExecutor ex,
    String type,
    String id,
    String op,
    Map<String, Object?> payload,
  ) async {
    if (op == 'increment_balance' && (type == 'customer' || type == 'supplier')) {
      final pid = await _localId(ex, type == 'customer' ? 'customers' : 'suppliers', id, type);
      final d = payload['delta'];
      if (pid != null && d is num) {
        await enqueueBalanceDelta(ex, customer: type == 'customer', partyId: pid, delta: d.toDouble());
      }
      return;
    }
    if (op == 'increment_stock' && type == 'product') {
      final d = payload['delta'];
      if (d is num) await enqueueStockDelta(ex, id, d.toDouble());
      return;
    }
    if (op == 'delete') {
      await enqueueDelete(ex, type, await entityIdFor(ex, type, id));
      return;
    }
    switch (type) {
      case 'customer':
        final n = await _localId(ex, 'customers', id, 'customer');
        if (n != null) await enqueueCustomer(ex, n);
      case 'supplier':
        final n = await _localId(ex, 'suppliers', id, 'supplier');
        if (n != null) await enqueueSupplier(ex, n);
      case 'product':
        await enqueueProduct(ex, id);
      case 'sale':
        await enqueueSale(ex, id);
      case 'purchase':
        await enqueuePurchase(ex, id);
      case 'payment':
        final n = await _localId(ex, 'payments', id, 'payment');
        if (n != null) await enqueuePayment(ex, n);
      case 'expense':
        final n = await _localId(ex, 'expenses', id, 'expense');
        if (n != null) await enqueueExpense(ex, n);
      case 'cash_transaction':
        final n = await _localId(ex, 'cash_transactions', id, 'cash_transaction');
        if (n != null) await enqueueCashTransaction(ex, n);
      case 'user':
        await enqueueUser(ex, id.startsWith('user:') ? id.substring(5) : id);
      case 'unit':
        await enqueueUnit(ex, id);
      case 'category':
        await enqueueCategory(ex, id);
      case 'zakat_year':
        final n = await _localId(ex, 'zakat_years', id, 'zakat_year');
        if (n != null) await enqueueZakatYear(ex, n);
      case 'zakat_payment':
        final n = await _localId(ex, 'zakat_payments', id, 'zakat_payment');
        if (n != null) await enqueueZakatPayment(ex, n);
      case 'return':
        final n = await _localId(ex, 'returns', id, 'return');
        if (n != null) await enqueueReturn(ex, n);
      case 'stock_movement':
        final n = await _localId(ex, 'stock_movements', id, 'stock_movement');
        if (n != null) await enqueueStockMovement(ex, n);
      case 'cash_register':
        await (op == 'create_if_absent' ? enqueueCashRegisterCreate(ex, id) : enqueueCashRegister(ex, id));
      case 'shell_customer':
        final n = await _localId(ex, 'shell_customers', id, 'shell_customer');
        if (n != null) await enqueueShellCustomer(ex, n);
      case 'shell_transaction':
        final n = await _localId(ex, 'shell_transactions', id, 'shell_transaction');
        if (n != null) await enqueueShellTransaction(ex, n);
      case 'shop_empty_shell_log':
        final n = await _localId(ex, 'shop_empty_shell_log', id, 'shop_empty_shell_log');
        if (n != null) await enqueueShopEmptyShellLog(ex, n);
      case 'app_setting':
        final v = await _row(ex, 'app_settings', 'key', id);
        if (v != null) await enqueueAppSetting(ex, id, _s(v['value']));
      default:
        break; // anjaan type: kuch nahi (SyncApi.push bhi false lautata)
    }
  }

  /// `id` (numeric string / serverId / `type:N`) => local integer id. Row na mile to null.
  static Future<int?> _localId(DatabaseExecutor ex, String table, String id, String type) async {
    final byServer = await _row(ex, table, 'serverId', id);
    if (byServer != null) return (byServer['id'] as num).toInt();
    final direct = int.tryParse(id);
    final n = direct ?? int.tryParse(id.contains(':') ? id.substring(id.lastIndexOf(RegExp(r'[:-]')) + 1) : '');
    if (n == null) return null;
    final r = await _row(ex, table, 'id', n);
    return r == null ? null : n;
  }

  /// Delete ke liye entity id: row abhi maujood ho to us ki asal (serverId-preferred) id, warna
  /// caller ka `id` agar wo pehle se entity id lagti hai, warna `type:<tag>-<n>`.
  static Future<String> entityIdFor(DatabaseExecutor ex, String type, String id) async {
    switch (type) {
      case 'product':
      case 'unit':
      case 'category':
      case 'cash_register':
      case 'app_setting':
        return id;
      case 'sale':
        return id.startsWith('sale:') ? id : saleEntityId(id);
      case 'purchase':
        return id.startsWith('purchase:') ? id : purchaseEntityId(id);
      case 'user':
        return id.startsWith('user:') ? id : userEntityId(id);
    }
    final table = _tableFor[type];
    if (table == null) return id;
    final byServer = await _row(ex, table, 'serverId', id);
    if (byServer != null) return id;
    final n = int.tryParse(id);
    if (n != null) {
      final r = await _row(ex, table, 'id', n);
      if (r != null) return _own('$type:', r);
      return '$type:${_tag()}-$n';
    }
    return id; // pehle se "<type>:<tag>-<n>" ya foreign serverId
  }

  static const Map<String, String> _tableFor = {
    'customer': 'customers',
    'supplier': 'suppliers',
    'payment': 'payments',
    'expense': 'expenses',
    'cash_transaction': 'cash_transactions',
    'zakat_year': 'zakat_years',
    'zakat_payment': 'zakat_payments',
    'return': 'returns',
    'stock_movement': 'stock_movements',
    'shell_customer': 'shell_customers',
    'shell_transaction': 'shell_transactions',
    'shop_empty_shell_log': 'shop_empty_shell_log',
  };
}
