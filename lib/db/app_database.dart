import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

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
  static const _dbVersion = 5;

  Database? _db;

  Future<Database> get database async {
    _db ??= await _open();
    return _db!;
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
        dirty INTEGER NOT NULL DEFAULT 1
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
        conversionFactor REAL NOT NULL DEFAULT 0
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
        billReference TEXT NOT NULL DEFAULT ''
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
        dirty INTEGER NOT NULL DEFAULT 1
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
        unit TEXT NOT NULL DEFAULT ''
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
        createdAt INTEGER NOT NULL
      )
    ''');

    batch.execute('''
      CREATE TABLE users (
        username TEXT PRIMARY KEY NOT NULL,
        displayName TEXT NOT NULL,
        role TEXT NOT NULL,
        passwordHash TEXT NOT NULL,
        active INTEGER NOT NULL DEFAULT 1,
        phone TEXT NOT NULL DEFAULT ''
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

    // Seed defaults — mirrors the Kotlin app's first-run defaults.
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
  }

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
