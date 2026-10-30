import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

import '../models/return_entry.dart';

import 'stock_ledger.dart';

/// Ports the Room schema from Database.kt table-for-table so data shape
/// stays identical to the Android app (useful if you ever need to import/
/// export between them, and keeps Firestore sync payloads consistent).
///
/// DB version starts at 1 here since this is a fresh Flutter DB file (not a
/// migration of the existing Android SQLite file). If you later decide to
/// import the existing IBTISAAM Kiryana Store data, add an import routine
/// rather than trying to open the old .db file directly with a different
/// schema version.
class AppDatabase {
  AppDatabase._();
  static final AppDatabase instance = AppDatabase._();

  static const _dbName = 'ah_developer_kiryana_store.db';
  static const _dbVersion = 34;

  Database? _db;

  /// Backup/Restore (Phase 11) ko chahiye: schema version aur DB ka path.
  static int get schemaVersion => _dbVersion;
  static String get databaseFileName => _dbName;

  Future<Database> get database async {
    _db ??= await _open();
    return _db!;
  }

  /// Live DB file ka poora path (file abhi bani na ho tab bhi).
  Future<String> get databasePath async => join(await getDatabasesPath(), _dbName);

  /// Kotlin `PRAGMA wal_checkpoint(FULL)` — backup se pehle WAL ka data main file mein.
  Future<void> checkpointWal() async {
    final db = await database;
    await db.rawQuery('PRAGMA wal_checkpoint(FULL)');
  }

  /// Kotlin `PosDatabase.closeInstance()` — restore se pehle. Agla `database` call dobara kholega.
  Future<void> close() async {
    final db = _db;
    _db = null;
    if (db != null && db.isOpen) await db.close();
  }

  Future<Database> _open() async {
    final dir = await getDatabasesPath();
    final path = join(dir, _dbName);
    return openDatabase(
      path,
      version: _dbVersion,
      onConfigure: (db) async => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    final batch = db.batch();

    batch.execute('''
      CREATE TABLE units (
        name TEXT PRIMARY KEY NOT NULL
      )
    ''');

    batch.execute('''
      CREATE TABLE categories (
        name TEXT PRIMARY KEY NOT NULL
      )
    ''');

    batch.execute('''
      CREATE TABLE products (
        barcode TEXT PRIMARY KEY NOT NULL,
        name TEXT NOT NULL,
        category TEXT NOT NULL DEFAULT '',
        cost REAL NOT NULL DEFAULT 0,
        salePrice REAL NOT NULL DEFAULT 0,
        stock REAL NOT NULL DEFAULT 0,
        reorderLevel REAL NOT NULL DEFAULT 0,
        expiry TEXT NOT NULL DEFAULT '',
        unit TEXT NOT NULL DEFAULT 'pcs',
        unitSize INTEGER NOT NULL DEFAULT 1,
        unitNote TEXT NOT NULL DEFAULT '',
        secondaryUnit TEXT NOT NULL DEFAULT '',
        secondaryUnitQty REAL NOT NULL DEFAULT 0,
        wholesalePrice REAL NOT NULL DEFAULT 0,
        shopkeeperPrice REAL NOT NULL DEFAULT 0,
        ratesAt INTEGER NOT NULL DEFAULT 0,
        bulkPrice REAL NOT NULL DEFAULT 0,
        bulkMinQty REAL NOT NULL DEFAULT 0,
        wholesaleBulkPrice REAL NOT NULL DEFAULT 0,
        wholesaleBulkMinQty REAL NOT NULL DEFAULT 0,
        openingStock REAL NOT NULL DEFAULT 0,
        tertiaryUnit TEXT NOT NULL DEFAULT '',
        tertiaryUnitQty REAL NOT NULL DEFAULT 0,
        updatedAt INTEGER NOT NULL DEFAULT 0,
        dirty INTEGER NOT NULL DEFAULT 1,
        searchTag TEXT NOT NULL DEFAULT '',
        defaultUnitIndex INTEGER NOT NULL DEFAULT -1,
        quickSaleDefaultUnitIndex INTEGER NOT NULL DEFAULT -1
      )
    ''');

    batch.execute('''
      CREATE TABLE customers (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        phone TEXT NOT NULL DEFAULT '',
        creditLimit REAL NOT NULL DEFAULT 0,
        openingBalance REAL NOT NULL DEFAULT 0,
        balance REAL NOT NULL DEFAULT 0,
        stuckBalance REAL NOT NULL DEFAULT 0,
        rateType TEXT NOT NULL DEFAULT '',
        dueDays INTEGER NOT NULL DEFAULT 0,
        kind TEXT NOT NULL DEFAULT '',
        returnDate INTEGER NOT NULL DEFAULT 0,
        returnEntries TEXT NOT NULL DEFAULT '',
        returnLog TEXT NOT NULL DEFAULT '',
        serverId TEXT,
        updatedAt INTEGER NOT NULL DEFAULT 0,
        dirty INTEGER NOT NULL DEFAULT 1
      )
    ''');

    batch.execute('''
      CREATE TABLE suppliers (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        phone TEXT NOT NULL DEFAULT '',
        openingBalance REAL NOT NULL DEFAULT 0,
        balance REAL NOT NULL DEFAULT 0,
        serverId TEXT,
        updatedAt INTEGER NOT NULL DEFAULT 0,
        dirty INTEGER NOT NULL DEFAULT 1
      )
    ''');

    batch.execute('''
      CREATE TABLE sales (
        invoice TEXT PRIMARY KEY NOT NULL,
        customerId INTEGER,
        subtotal REAL NOT NULL,
        discount REAL NOT NULL,
        tax REAL NOT NULL,
        total REAL NOT NULL,
        paid REAL NOT NULL,
        paymentMethod TEXT NOT NULL,
        saleType TEXT NOT NULL DEFAULT 'retail',
        createdAt INTEGER NOT NULL,
        status TEXT NOT NULL DEFAULT 'active',
        updatedAt INTEGER NOT NULL DEFAULT 0,
        dirty INTEGER NOT NULL DEFAULT 1,
        dueDate INTEGER NOT NULL DEFAULT 0,
        customerServerId TEXT
      )
    ''');

    batch.execute('''
      CREATE TABLE sale_items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        invoice TEXT NOT NULL,
        barcode TEXT NOT NULL,
        product TEXT NOT NULL,
        qty REAL NOT NULL,
        unit TEXT NOT NULL DEFAULT '',
        unitPrice REAL NOT NULL,
        cost REAL NOT NULL,
        amount REAL NOT NULL,
        conversionFactor REAL NOT NULL DEFAULT 0,
        pendingQty REAL NOT NULL DEFAULT 0,
        pendingEst REAL NOT NULL DEFAULT 0,
        backfillLog TEXT NOT NULL DEFAULT ''
      )
    ''');

    batch.execute('''
      CREATE TABLE payments (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        reference TEXT NOT NULL,
        partyType TEXT NOT NULL,
        partyId INTEGER,
        amount REAL NOT NULL,
        method TEXT NOT NULL,
        note TEXT NOT NULL DEFAULT '',
        createdAt INTEGER NOT NULL,
        serverId TEXT,
        updatedAt INTEGER NOT NULL DEFAULT 0,
        dirty INTEGER NOT NULL DEFAULT 1,
        billReference TEXT NOT NULL DEFAULT '',
        partyServerId TEXT
      )
    ''');

    batch.execute('''
      CREATE TABLE purchases (
        billNo TEXT PRIMARY KEY NOT NULL,
        supplierId INTEGER,
        total REAL NOT NULL,
        paid REAL NOT NULL,
        createdAt INTEGER NOT NULL,
        subtotal REAL NOT NULL DEFAULT 0,
        discount REAL NOT NULL DEFAULT 0,
        status TEXT NOT NULL DEFAULT 'active',
        updatedAt INTEGER NOT NULL DEFAULT 0,
        dirty INTEGER NOT NULL DEFAULT 1,
        dueDate INTEGER NOT NULL DEFAULT 0,
        supplierInvoiceNo TEXT NOT NULL DEFAULT '',
        supplierServerId TEXT
      )
    ''');

    batch.execute('''
      CREATE TABLE purchase_items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        billNo TEXT NOT NULL,
        barcode TEXT NOT NULL,
        qty REAL NOT NULL,
        unitCost REAL NOT NULL,
        amount REAL NOT NULL,
        unit TEXT NOT NULL DEFAULT '',
        conversionFactor REAL NOT NULL DEFAULT 0,
        itemName TEXT NOT NULL DEFAULT '',
        retailRate REAL NOT NULL DEFAULT 0,
        wholesaleRate REAL NOT NULL DEFAULT 0,
        shopkeeperRate REAL NOT NULL DEFAULT 0
      )
    ''');

    batch.execute('''
      CREATE TABLE returns (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        reference TEXT NOT NULL,
        type TEXT NOT NULL,
        barcode TEXT NOT NULL,
        qty REAL NOT NULL,
        amount REAL NOT NULL,
        createdAt INTEGER NOT NULL,
        serverId TEXT,
        updatedAt INTEGER NOT NULL DEFAULT 0,
        dirty INTEGER NOT NULL DEFAULT 1
      )
    ''');

    batch.execute('''
      CREATE TABLE users (
        username TEXT PRIMARY KEY NOT NULL,
        displayName TEXT NOT NULL,
        role TEXT NOT NULL,
        passwordHash TEXT NOT NULL,
        active INTEGER NOT NULL DEFAULT 1,
        phone TEXT NOT NULL DEFAULT '',
        permissions TEXT NOT NULL DEFAULT ''
      )
    ''');

    batch.execute('''
      CREATE TABLE audit (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        username TEXT NOT NULL,
        action TEXT NOT NULL,
        reference TEXT NOT NULL DEFAULT '',
        details TEXT NOT NULL DEFAULT '',
        createdAt INTEGER NOT NULL
      )
    ''');

    batch.execute('''
      CREATE TABLE expenses (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        category TEXT NOT NULL,
        description TEXT NOT NULL,
        amount REAL NOT NULL,
        method TEXT NOT NULL DEFAULT 'cash',
        createdAt INTEGER NOT NULL,
        serverId TEXT,
        updatedAt INTEGER NOT NULL DEFAULT 0,
        dirty INTEGER NOT NULL DEFAULT 1
      )
    ''');

    batch.execute('''
      CREATE TABLE held_bills (
        holdId TEXT PRIMARY KEY NOT NULL,
        payload TEXT NOT NULL,
        createdAt INTEGER NOT NULL
      )
    ''');

    batch.execute('''
      CREATE TABLE cash_transactions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        type TEXT NOT NULL,
        method TEXT NOT NULL,
        amount REAL NOT NULL,
        reason TEXT NOT NULL DEFAULT '',
        reference TEXT NOT NULL DEFAULT '',
        createdAt INTEGER NOT NULL,
        serverId TEXT,
        updatedAt INTEGER NOT NULL DEFAULT 0,
        dirty INTEGER NOT NULL DEFAULT 1
      )
    ''');

    batch.execute('''
      CREATE TABLE cash_register (
        date TEXT PRIMARY KEY NOT NULL,
        openingCash REAL NOT NULL DEFAULT 0,
        closingCash REAL NOT NULL DEFAULT 0,
        openingBank REAL NOT NULL DEFAULT 0,
        closingBank REAL NOT NULL DEFAULT 0,
        closed INTEGER NOT NULL DEFAULT 0
      )
    ''');

    batch.execute('''
      CREATE TABLE app_settings (
        key TEXT PRIMARY KEY NOT NULL,
        value TEXT NOT NULL
      )
    ''');

    batch.execute('''
      CREATE TABLE sync_queue (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        entityType TEXT NOT NULL,
        entityId TEXT NOT NULL,
        operation TEXT NOT NULL,
        payloadJson TEXT NOT NULL,
        createdAt INTEGER NOT NULL,
        syncedAt INTEGER,
        retryCount INTEGER NOT NULL DEFAULT 0,
        lastError TEXT
      )
    ''');

    for (final sql in [..._zakatTablesSql, ..._shellTablesSql, ..._stockMovementsSql, ..._rentTablesSql, ..._workerTablesSql, ..._shopRentTablesSql, ..._utilityBillTablesSql]) {
      batch.execute(sql);
    }

    // Seed defaults — mirrors the Kotlin app's first-run defaults.
    batch.execute(_recycleBinSql);

    batch.insert('categories', {'name': 'General'});
    batch.insert('units', {'name': 'pcs'});

    await batch.commit(noResult: true);
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    // Add ALTER TABLE / migration steps here as the schema evolves, the
    // same way MIGRATION_23_24 / MIGRATION_24_25 work in the Kotlin app.
    if (oldVersion < 3) {
      // v3: manual default-unit overrides (Kotlin MIGRATION_40_41 / _41_42).
      // Existing rows get -1 = Auto, so nothing changes for old products.
      await _addColumnIfMissing(
          db, 'products', 'defaultUnitIndex', 'INTEGER NOT NULL DEFAULT -1');
      await _addColumnIfMissing(
          db, 'products', 'quickSaleDefaultUnitIndex', 'INTEGER NOT NULL DEFAULT -1');
    }
    if (oldVersion < 4) {
      // v4: sale_items freeze "smallest units per 1 unit" at sale time so a
      // later edit/return/delete reverses the SAME qty even if the product's
      // unit ladder was changed afterwards (Kotlin SaleItem.conversionFactor).
      // 0 = never captured (old rows) -> fall back to the product's current ladder.
      await _addColumnIfMissing(
          db, 'sale_items', 'conversionFactor', 'REAL NOT NULL DEFAULT 0');
    }
    if (oldVersion < 5) {
      // v5: a payment can be linked to one bill (Kotlin Payment.billReference).
      await _addColumnIfMissing(
          db, 'payments', 'billReference', "TEXT NOT NULL DEFAULT ''");
    }
    if (oldVersion < 6) {
      // v6: which drawer an expense was paid from (Kotlin Expense.method, MIGRATION_41_42).
      // Old rows are implicitly 'cash', same as Android.
      await _addColumnIfMissing(db, 'expenses', 'method', "TEXT NOT NULL DEFAULT 'cash'");
    }
    if (oldVersion < 7) {
      // v7: Zakat tracker (Kotlin zakat_years / zakat_payments / zakat_month_plans).
      // Fresh tables, no data migration needed.
      for (final sql in _zakatTablesSql) {
        await db.execute(sql);
      }
    }
    if (oldVersion < 8) {
      // v8: Bottle Shell Ledger (Kotlin shell_customers / shell_transactions / shop_empty_shell_log).
      for (final sql in _shellTablesSql) {
        await db.execute(sql);
      }
    }
    if (oldVersion < 9) {
      // v9: Customer.stuckBalance (Kotlin MIGRATION "Stuck Balance": plain ADD COLUMN, default 0).
      await _addColumnIfMissing(db, 'customers', 'stuckBalance', 'REAL NOT NULL DEFAULT 0');
    }
    if (oldVersion < 10) {
      // v10: Due Date Reminders (Kotlin MIGRATION_29_30 sales.dueDate + MIGRATION_42_43 purchases.dueDate).
      // Plain ADD COLUMN, purani rows 0 = "date set nahi".
      await _addColumnIfMissing(db, 'sales', 'dueDate', 'INTEGER NOT NULL DEFAULT 0');
      await _addColumnIfMissing(db, 'purchases', 'dueDate', 'INTEGER NOT NULL DEFAULT 0');
    }
    if (oldVersion < 11) {
      // v11: stock_movements ledger (Kotlin MIGRATION_26_27 + 37_38 sync columns). Pehle se maujood
      // stock ke liye ek OPENING_STOCK row (StockLedger.backfillOpening) taake ledger sum == stock.
      for (final sql in _stockMovementsSql) {
        await db.execute(sql);
      }
      await StockLedger.backfillOpening(db);
    }
    if (oldVersion < 12) {
      // v12: Purchase edit (Kotlin PurchaseActivity edit mode) — supplier ka invoice no. aur purchase_items par
      // frozen conversionFactor / item naam / retail + wholesale rate. Purani rows: 0 / '' = "captured nahi".
      await _addColumnIfMissing(db, 'purchases', 'supplierInvoiceNo', "TEXT NOT NULL DEFAULT ''");
      await _addColumnIfMissing(db, 'purchase_items', 'conversionFactor', 'REAL NOT NULL DEFAULT 0');
      await _addColumnIfMissing(db, 'purchase_items', 'itemName', "TEXT NOT NULL DEFAULT ''");
      await _addColumnIfMissing(db, 'purchase_items', 'retailRate', 'REAL NOT NULL DEFAULT 0');
      await _addColumnIfMissing(db, 'purchase_items', 'wholesaleRate', 'REAL NOT NULL DEFAULT 0');
    }
    if (oldVersion < 13) {
      // v13: returns ledger sync columns (Kotlin ReturnLine.serverId/updatedAt/dirty) — pull ke returns
      // loop ko idempotent (findByServerId) banane ke liye. Purani rows: serverId NULL, dirty=1.
      await _addColumnIfMissing(db, 'returns', 'serverId', 'TEXT');
      await _addColumnIfMissing(db, 'returns', 'updatedAt', 'INTEGER NOT NULL DEFAULT 0');
      await _addColumnIfMissing(db, 'returns', 'dirty', 'INTEGER NOT NULL DEFAULT 1');
    }
    if (oldVersion < 14) {
      // v14: pull par party (customer/supplier) local DB mein na mile to bhi cloud ki portable pehchan
      // (serverId) mehfooz rahe — party baad mein aaye to `relinkOrphanedParties` (sync_apply.dart)
      // rows ko jod de. Pehle partyId/customerId/supplierId NULL reh kar row ledger/Fix Balances se
      // hamesha ke liye bahar ho jati thi.
      await _addColumnIfMissing(db, 'payments', 'partyServerId', 'TEXT');
      await _addColumnIfMissing(db, 'sales', 'customerServerId', 'TEXT');
      await _addColumnIfMissing(db, 'purchases', 'supplierServerId', 'TEXT');
    }
    if (oldVersion < 15) {
      // v15: item-wise bulk rate (retail grahak jab bulkMinQty tak khareedey to bulkPrice).
      await _addColumnIfMissing(db, 'products', 'bulkPrice', 'REAL NOT NULL DEFAULT 0');
      await _addColumnIfMissing(db, 'products', 'bulkMinQty', 'REAL NOT NULL DEFAULT 0');
    }
    if (oldVersion < 16) {
      // v16: wholesale mode ka apna bulk rate (wholesaleBulkMinQty tak khareedey to wholesaleBulkPrice).
      await _addColumnIfMissing(db, 'products', 'wholesaleBulkPrice', 'REAL NOT NULL DEFAULT 0');
      await _addColumnIfMissing(db, 'products', 'wholesaleBulkMinQty', 'REAL NOT NULL DEFAULT 0');
    }
    if (oldVersion < 18) {
      // v18: Shopkeeper rate (item ka teesra rate) + customer ka rate-type tag.
      await _addColumnIfMissing(db, 'products', 'shopkeeperPrice', 'REAL NOT NULL DEFAULT 0');
      await _addColumnIfMissing(db, 'customers', 'rateType', "TEXT NOT NULL DEFAULT ''");
    }
    if (oldVersion < 19) {
      // v19: retail/wholesale rate ki effective date (purani date ki purchase naya rate na bigade).
      await _addColumnIfMissing(db, 'products', 'ratesAt', 'INTEGER NOT NULL DEFAULT 0');
    }
    if (oldVersion < 20) {
      // v20: Daily Rent — customer ka roz ka fixed rent (sirf is device ka setting; bills sync hote hain).
      for (final sql in _rentTablesSql) {
        await db.execute(sql);
      }
    }
    if (oldVersion < 21) {
      // v21: purchase line par Shopkeeper rate (0 = product ka shopkeeper rate nahi badla). Purani rows 0.
      await _addColumnIfMissing(db, 'purchase_items', 'shopkeeperRate', 'REAL NOT NULL DEFAULT 0');
    }
    if (oldVersion < 22) {
      // v22: customer ki default payment muddat (din). 0 = koi nahi. Udhaar bill par due date khud lagti hai.
      await _addColumnIfMissing(db, 'customers', 'dueDays', 'INTEGER NOT NULL DEFAULT 0');
    }
    if (oldVersion < 23) {
      // v23: Workers — hazri/chhutti, advance aur salary ka record (is device ka; expense + cash sync hote hain).
      for (final sql in _workerTablesSql) {
        await db.execute(sql);
      }
    }
    if (oldVersion < 24) {
      // v24: Workers sync — serverId/updatedAt (v23 mein bane tables ke liye; naye tables mein pehle se hain).
      await _addColumnIfMissing(db, 'workers', 'serverId', 'TEXT');
      await _addColumnIfMissing(db, 'workers', 'updatedAt', 'INTEGER NOT NULL DEFAULT 0');
      await _addColumnIfMissing(db, 'worker_attendance', 'updatedAt', 'INTEGER NOT NULL DEFAULT 0');
      await _addColumnIfMissing(db, 'worker_advances', 'serverId', 'TEXT');
      await _addColumnIfMissing(db, 'worker_advances', 'updatedAt', 'INTEGER NOT NULL DEFAULT 0');
      await _addColumnIfMissing(db, 'worker_salary_payments', 'serverId', 'TEXT');
      await _addColumnIfMissing(db, 'worker_salary_payments', 'expenseServerId', 'TEXT');
      await _addColumnIfMissing(db, 'worker_salary_payments', 'updatedAt', 'INTEGER NOT NULL DEFAULT 0');
    }
    if (oldVersion < 25) {
      // v25: Shop Rents — kiraye ki dukaneen, mahana rent, advance.
      for (final sql in _shopRentTablesSql) {
        await db.execute(sql);
      }
    }
    if (oldVersion < 26) {
      // v26: Shop Rents sync — serverId/updatedAt (v25 mein bane tables ke liye; naye tables mein pehle se hain).
      await _addColumnIfMissing(db, 'shop_rents', 'serverId', 'TEXT');
      await _addColumnIfMissing(db, 'shop_rents', 'updatedAt', 'INTEGER NOT NULL DEFAULT 0');
      await _addColumnIfMissing(db, 'shop_rent_ledger', 'serverId', 'TEXT');
      await _addColumnIfMissing(db, 'shop_rent_ledger', 'expenseServerId', 'TEXT');
      await _addColumnIfMissing(db, 'shop_rent_ledger', 'cashServerId', 'TEXT');
      await _addColumnIfMissing(db, 'shop_rent_ledger', 'updatedAt', 'INTEGER NOT NULL DEFAULT 0');
    }
    if (oldVersion < 27) {
      // v27: Utility Bills — bijli/gas/pani/internet jaise mahana bills aur unki payment (abhi sirf is device ka).
      for (final sql in _utilityBillTablesSql) {
        await db.execute(sql);
      }
    }
    if (oldVersion < 28) {
      // v28: Utility Bills sync — serverId/updatedAt (v27 mein bane tables ke liye; naye tables mein pehle se hain).
      await _addColumnIfMissing(db, 'utility_bills', 'serverId', 'TEXT');
      await _addColumnIfMissing(db, 'utility_bill_payments', 'serverId', 'TEXT');
      await _addColumnIfMissing(db, 'utility_bill_payments', 'expenseServerId', 'TEXT');
      await _addColumnIfMissing(db, 'utility_bill_payments', 'updatedAt', 'INTEGER NOT NULL DEFAULT 0');
    }
    if (oldVersion < 29) {
      // v29: Customer par Amanat / Loan tag + wapsi ki tarikh (sirf label/reminder; balance ka hisaab nahi badalta).
      await _addColumnIfMissing(db, 'customers', 'kind', "TEXT NOT NULL DEFAULT ''");
      await _addColumnIfMissing(db, 'customers', 'returnDate', 'INTEGER NOT NULL DEFAULT 0');
    }
    if (oldVersion < 30) {
      // v30: Recycle Bin (delete hue records wapas lane ke liye).
      await db.execute(_recycleBinSql);
    }
    if (oldVersion < 31) {
      // v31: Amanat / Loan ki alag alag entries (ek customer kai bar loan/amanat le sakta hai).
      await _addColumnIfMissing(db, 'customers', 'returnEntries', "TEXT NOT NULL DEFAULT ''");
    }
    if (oldVersion < 32) {
      // v32: Amanat / Loan log (given / recovered / adjusted) — party ledger / statement mein dikhane ke liye.
      // Maujooda entries se 'given' rows banti hain (asal raqam maloom nahi => bachi hui raqam). Balance nahi chhedta.
      await _addColumnIfMissing(db, 'customers', 'returnLog', "TEXT NOT NULL DEFAULT ''");
      final rows = await db.query('customers',
          columns: ['id', 'kind', 'returnEntries'], where: "returnEntries IS NOT NULL AND returnEntries != ''");
      for (final r in rows) {
        final entries = decodeReturnEntries(r['returnEntries'] as String?);
        if (entries.isEmpty) continue;
        final kind = (r['kind'] as String?) == 'amanat' ? 'amanat' : 'loan';
        await db.update('customers', {'returnLog': encodeReturnLog(backfillReturnLog(kind, entries))},
            where: 'id = ?', whereArgs: [r['id']]);
      }
    }
    if (oldVersion < 33) {
      // v33: minus stock / cost 0 par bani sale line ki cost "pending" (costPending): pendingQty = abhi tak
      // purchase se na dhaki hui qty (smallest units), pendingEst = us hisse ki andaza shuda cost jo `cost`
      // mein shamil hai, backfillLog = kin purchase bills se kitni cost bhari gayi (reverse ke liye, JSON).
      await _addColumnIfMissing(db, 'sale_items', 'pendingQty', 'REAL NOT NULL DEFAULT 0');
      await _addColumnIfMissing(db, 'sale_items', 'pendingEst', 'REAL NOT NULL DEFAULT 0');
      await _addColumnIfMissing(db, 'sale_items', 'backfillLog', "TEXT NOT NULL DEFAULT ''");
    }
    if (oldVersion < 34) {
      // v34: per-user access rules (JSON overrides, khali = role ke default). Users ke saath sync hota hai.
      await _addColumnIfMissing(db, 'users', 'permissions', "TEXT NOT NULL DEFAULT ''");
    }
  }

  /// v30: Recycle Bin — delete hone wale record ka poora snapshot (JSON). Sirf is device par; sync nahi hota.
  static const _recycleBinSql = '''
      CREATE TABLE IF NOT EXISTS recycle_bin (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        kind TEXT NOT NULL,
        refKey TEXT NOT NULL DEFAULT '',
        title TEXT NOT NULL DEFAULT '',
        subtitle TEXT NOT NULL DEFAULT '',
        amount REAL NOT NULL DEFAULT 0,
        deletedBy TEXT NOT NULL DEFAULT '',
        deletedAt INTEGER NOT NULL DEFAULT 0,
        dataJson TEXT NOT NULL DEFAULT '{}'
      )
    ''';

  /// Utility Bills (v27, sync v28): mahana bills (bijli, gas, pani, internet, mobile...) ki list aur har mahine ki
  /// payment. `dueDay` = mahine ki tarikh (1-31; chhote mahine mein aakhri din). `utility_bill_payments` mein ek bill
  /// ka ek mahina (`month` = YYYY-MM) sirf ek baar. `expenseId` = payment ke saath bani Expense (undo par wo bhi
  /// hat'ti hai). Dono tables sync hote hain (`serverId` + `updatedAt`); payment `expenseServerId` se Expense se judti hai.
  static const _utilityBillTablesSql = <String>[
    '''
      CREATE TABLE IF NOT EXISTS utility_bills (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        kind TEXT NOT NULL DEFAULT 'other',
        dueDay INTEGER NOT NULL,
        avgAmount REAL NOT NULL DEFAULT 0,
        reminder INTEGER NOT NULL DEFAULT 1,
        active INTEGER NOT NULL DEFAULT 1,
        createdAt INTEGER NOT NULL DEFAULT 0,
        updatedAt INTEGER NOT NULL DEFAULT 0,
        serverId TEXT
      )
    ''',
    '''
      CREATE TABLE IF NOT EXISTS utility_bill_payments (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        billId INTEGER NOT NULL,
        month TEXT NOT NULL,
        amount REAL NOT NULL,
        method TEXT NOT NULL DEFAULT 'cash',
        note TEXT NOT NULL DEFAULT '',
        expenseId INTEGER,
        expenseServerId TEXT,
        paidAt INTEGER NOT NULL,
        serverId TEXT,
        updatedAt INTEGER NOT NULL DEFAULT 0,
        UNIQUE (billId, month)
      )
    ''',
  ];

  /// Workers: profile, roz ki hazri, advance, aur mahine ki salary ka record. Sab sync hote hain
  /// (`serverId` + `updatedAt`); hazri ki chabi (workerId, day) khud hi unique hai.
  static const _workerTablesSql = <String>[
    '''
      CREATE TABLE IF NOT EXISTS workers (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        phone TEXT NOT NULL DEFAULT '',
        payType TEXT NOT NULL DEFAULT 'monthly',
        rate REAL NOT NULL DEFAULT 0,
        active INTEGER NOT NULL DEFAULT 1,
        createdAt INTEGER NOT NULL DEFAULT 0,
        serverId TEXT,
        updatedAt INTEGER NOT NULL DEFAULT 0
      )
    ''',
    '''
      CREATE TABLE IF NOT EXISTS worker_attendance (
        workerId INTEGER NOT NULL,
        day TEXT NOT NULL,
        status TEXT NOT NULL,
        updatedAt INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (workerId, day)
      )
    ''',
    '''
      CREATE TABLE IF NOT EXISTS worker_advances (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        workerId INTEGER NOT NULL,
        amount REAL NOT NULL,
        method TEXT NOT NULL DEFAULT 'cash',
        note TEXT NOT NULL DEFAULT '',
        createdAt INTEGER NOT NULL,
        serverId TEXT,
        updatedAt INTEGER NOT NULL DEFAULT 0
      )
    ''',
    '''
      CREATE TABLE IF NOT EXISTS worker_salary_payments (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        workerId INTEGER NOT NULL,
        month TEXT NOT NULL,
        earned REAL NOT NULL,
        advanceCut REAL NOT NULL,
        net REAL NOT NULL,
        method TEXT NOT NULL DEFAULT 'cash',
        expenseId INTEGER,
        expenseServerId TEXT,
        createdAt INTEGER NOT NULL,
        serverId TEXT,
        updatedAt INTEGER NOT NULL DEFAULT 0,
        UNIQUE (workerId, month)
      )
    ''',
  ];

  /// Shop Rents (v25, sync v26): jo dukaneen hum kiraye par lete hain — har dukaan, uska mahana rent (saal baad
  /// badalne ke liye terms), aur ledger (charge / payment / advance / applied). Dukaan (terms samet) aur ledger
  /// sab devices par sync hote hain (`serverId` + `updatedAt`); asal paisa Expense + Cash rows se jata hai
  /// jo pehle hi sync hoti hain (ledger unse `expenseServerId` / `cashServerId` se judta hai).
  static const _shopRentTablesSql = <String>[
    '''
      CREATE TABLE IF NOT EXISTS shop_rents (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        shopName TEXT NOT NULL,
        landlord TEXT NOT NULL DEFAULT '',
        phone TEXT NOT NULL DEFAULT '',
        dueDay INTEGER NOT NULL DEFAULT 1,
        startYm TEXT NOT NULL,
        autoApply INTEGER NOT NULL DEFAULT 1,
        active INTEGER NOT NULL DEFAULT 1,
        note TEXT NOT NULL DEFAULT '',
        createdAt INTEGER NOT NULL,
        serverId TEXT,
        updatedAt INTEGER NOT NULL DEFAULT 0
      )
    ''',
    '''
      CREATE TABLE IF NOT EXISTS shop_rent_terms (
        shopId INTEGER NOT NULL,
        fromYm TEXT NOT NULL,
        monthlyRent REAL NOT NULL,
        PRIMARY KEY (shopId, fromYm)
      )
    ''',
    '''
      CREATE TABLE IF NOT EXISTS shop_rent_ledger (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        shopId INTEGER NOT NULL,
        kind TEXT NOT NULL,
        ym TEXT NOT NULL DEFAULT '',
        amount REAL NOT NULL,
        method TEXT NOT NULL DEFAULT 'cash',
        note TEXT NOT NULL DEFAULT '',
        expenseId INTEGER,
        cashId INTEGER,
        createdAt INTEGER NOT NULL,
        serverId TEXT,
        expenseServerId TEXT,
        cashServerId TEXT,
        updatedAt INTEGER NOT NULL DEFAULT 0
      )
    ''',
    'CREATE INDEX IF NOT EXISTS index_shop_rent_ledger_shop ON shop_rent_ledger (shopId, kind, ym)',
    "CREATE UNIQUE INDEX IF NOT EXISTS index_shop_rent_charge ON shop_rent_ledger (shopId, ym) WHERE kind = 'charge'",
  ];

  /// Daily Rent setting: customer ka roz ka rent aur kis din se. Customers table se alag rakha
  /// taake customer sync / pull is ko na mitaye.
  static const _rentTablesSql = <String>[
    '''
      CREATE TABLE IF NOT EXISTS customer_rent (
        customerId INTEGER PRIMARY KEY NOT NULL,
        dailyRent REAL NOT NULL,
        startDay INTEGER NOT NULL
      )
    ''',
  ];

  static const _stockMovementsSql = <String>[
    '''
      CREATE TABLE IF NOT EXISTS stock_movements (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        barcode TEXT NOT NULL,
        type TEXT NOT NULL,
        qty REAL NOT NULL,
        unit TEXT NOT NULL DEFAULT '',
        cost REAL NOT NULL DEFAULT 0,
        reference TEXT NOT NULL DEFAULT '',
        note TEXT NOT NULL DEFAULT '',
        createdAt INTEGER NOT NULL,
        serverId TEXT,
        updatedAt INTEGER NOT NULL DEFAULT 0,
        dirty INTEGER NOT NULL DEFAULT 1
      )
    ''',
    'CREATE INDEX IF NOT EXISTS index_stock_movements_barcode ON stock_movements (barcode)',
  ];

  static const _shellTablesSql = <String>[
    '''
      CREATE TABLE IF NOT EXISTS shell_customers (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        phone TEXT NOT NULL DEFAULT '',
        shellsOwed INTEGER NOT NULL DEFAULT 0,
        createdAt INTEGER NOT NULL,
        serverId TEXT,
        updatedAt INTEGER NOT NULL DEFAULT 0,
        dirty INTEGER NOT NULL DEFAULT 1
      )
    ''',
    '''
      CREATE TABLE IF NOT EXISTS shell_transactions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        customerId INTEGER NOT NULL,
        type TEXT NOT NULL,
        qty INTEGER NOT NULL,
        note TEXT NOT NULL DEFAULT '',
        createdAt INTEGER NOT NULL,
        serverId TEXT,
        updatedAt INTEGER NOT NULL DEFAULT 0,
        dirty INTEGER NOT NULL DEFAULT 1
      )
    ''',
    'CREATE INDEX IF NOT EXISTS index_shell_transactions_customerId ON shell_transactions(customerId)',
    '''
      CREATE TABLE IF NOT EXISTS shop_empty_shell_log (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        delta INTEGER NOT NULL,
        reason TEXT NOT NULL,
        note TEXT NOT NULL DEFAULT '',
        createdAt INTEGER NOT NULL,
        serverId TEXT,
        updatedAt INTEGER NOT NULL DEFAULT 0,
        dirty INTEGER NOT NULL DEFAULT 1
      )
    ''',
  ];

  static const _zakatTablesSql = <String>[
    '''
      CREATE TABLE IF NOT EXISTS zakat_years (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        startDate INTEGER NOT NULL,
        endDate INTEGER NOT NULL,
        assetsSnapshot REAL NOT NULL,
        totalPayable REAL NOT NULL,
        currency TEXT NOT NULL DEFAULT 'Rs',
        calendarType TEXT NOT NULL DEFAULT 'islamic',
        createdAt INTEGER NOT NULL,
        serverId TEXT,
        updatedAt INTEGER NOT NULL DEFAULT 0,
        dirty INTEGER NOT NULL DEFAULT 1
      )
    ''',
    '''
      CREATE TABLE IF NOT EXISTS zakat_payments (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        zakatYearId INTEGER NOT NULL,
        amount REAL NOT NULL,
        method TEXT NOT NULL DEFAULT 'cash',
        note TEXT NOT NULL DEFAULT '',
        category TEXT NOT NULL DEFAULT '',
        paymentDate INTEGER NOT NULL,
        createdAt INTEGER NOT NULL,
        serverId TEXT,
        updatedAt INTEGER NOT NULL DEFAULT 0,
        dirty INTEGER NOT NULL DEFAULT 1
      )
    ''',
    '''
      CREATE TABLE IF NOT EXISTS zakat_month_plans (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        zakatYearId INTEGER NOT NULL,
        monthIndex INTEGER NOT NULL,
        payableAmount REAL NOT NULL,
        note TEXT NOT NULL DEFAULT '',
        createdAt INTEGER NOT NULL,
        updatedAt INTEGER NOT NULL DEFAULT 0,
        dirty INTEGER NOT NULL DEFAULT 1
      )
    ''',
  ];

  /// Safe ALTER TABLE: skips if the column already exists (e.g. a device that
  /// got the column from an earlier test build), so upgrade never crashes.
  Future<void> _addColumnIfMissing(
      Database db, String table, String column, String definition) async {
    final info = await db.rawQuery('PRAGMA table_info($table)');
    final exists = info.any((row) => row['name'] == column);
    if (!exists) {
      await db.execute('ALTER TABLE $table ADD COLUMN $column $definition');
    }
  }
}
