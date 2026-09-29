import '../models/misc_entities.dart';
import '../models/product.dart';
import '../services/session.dart';
import '../utils/password_hasher.dart';
import 'app_database.dart';
import 'party_dashboard_repository.dart';
import 'reports_repository.dart' show ReportPeriod, reportRangeFor;
import 'user_repository.dart';

/// Ports the data side of MainActivity.kt (dashboard).
///
/// Maths / faislay PURE functions mein hain — test/dashboard_test.dart.

// ───────────────────────── pure helpers ─────────────────────────

/// Kotlin dashboardColumns(): phone 2, tablet portrait 3, bara tablet / landscape 4.
int dashboardColumns(double widthDp) => widthDp >= 900 ? 4 : (widthDp >= 600 ? 3 : 2);

/// Kotlin "Rs %.2f" ya tap-to-hide par "Rs ••••••".
String dashboardAmount(double v, {bool hidden = false}) => hidden ? 'Rs ••••••' : 'Rs ${v.toStringAsFixed(2)}';

/// Live search: matchesQuery (name + searchTag), pehle [limit] (Kotlin take(6)). Khali query = kuch nahi.
List<Product> dashboardSearch(List<Product> all, String query, {int limit = 6}) {
  final q = query.trim();
  if (q.isEmpty) return const [];
  return all.where((p) => p.matchesQuery(q)).take(limit).toList();
}

/// Aaj ke [start, end] (Kotlin startOfDay .. +24h; DST-safe: agla midnight - 1ms).
({int start, int end}) todayRange(DateTime now) {
  final r = reportRangeFor(ReportPeriod.today, now);
  return (start: r.start, end: r.end);
}

/// Aaj ka profit = aaj ki sale (discount ke baad) - COGS (Kotlin FIX: pehle discount ignore hota tha).
double dashboardProfit(double sale, double cogs) => sale - cogs;

/// Sync pending label; 0 => null (label chhupa hua).
String? syncPendingMessage(int count, {required bool urdu}) {
  if (count <= 0) return null;
  return urdu
      ? '⚠ $count تبدیلیاں ابھی کلاؤڈ پر نہیں پہنچیں — چیک کرنے کے لیے ٹیپ کریں'
      : '⚠ $count change(s) not yet synced to cloud — tap to check Sync History';
}

/// Dashboard ke stat cards kis role ko dikhte hain.
bool showsProfitCard(String role) => role == 'admin';

/// Logout tile dashboard par sirf manager/cashier ko (admin Settings se — Kotlin jaisa).
bool showsLogoutTile(String role) => role == 'manager' || role == 'cashier';

/// Quick Switch: sirf active users, current user list mein rehta hai (magar tap nahi hota).
List<User> switchableUsers(List<User> all) => all.where((u) => u.active).toList();

/// Role ka avatar rang (Kotlin quickSwitchRow): admin navy, manager blue, baaki orange.
int roleColorValue(String role) => role == 'admin' ? 0xFF0D1B4C : (role == 'manager' ? 0xFF2F6FED : 0xFFFF8A00);

/// Kotlin askPasswordForSwitch(): hashed => verify; purani plain-text => barabar hone par manzoor.
/// [needsMigration] true ho to caller password ko hash karke save kare (Kotlin enqueueUser).
({bool ok, bool needsMigration}) checkSwitchPassword({
  required String typed,
  required String stored,
  required bool storedIsHashed,
  required bool hashedMatches,
}) {
  if (storedIsHashed) return (ok: hashedMatches, needsMigration: false);
  final ok = stored == typed;
  return (ok: ok, needsMigration: ok);
}

// ───────────────────────── data ─────────────────────────

class DashboardTotals {
  final double sale;

  /// null => is role ko profit nahi dikhta (data layer par bhi rokta hai).
  final double? profit;
  const DashboardTotals(this.sale, this.profit);
}

class DashboardRepository {
  DashboardRepository._();
  static final DashboardRepository instance = DashboardRepository._();

  Future<double> _scalar(String sql, List<Object?> args) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.rawQuery(sql, args);
    if (rows.isEmpty) return 0.0;
    return (rows.first.values.first as num?)?.toDouble() ?? 0.0;
  }

  /// Aaj ki sale (sab roles) aur profit (sirf admin). Returned bills bahar.
  Future<DashboardTotals> todayTotals({DateTime? now}) async {
    final r = todayRange(now ?? DateTime.now());
    final args = [r.start, r.end];
    final sale = await _scalar(
        "SELECT COALESCE(SUM(total),0) FROM sales WHERE createdAt BETWEEN ? AND ? AND status!='returned'", args);
    if (!showsProfitCard(Session.role)) return DashboardTotals(sale, null);
    final cogs = await _scalar(
        'SELECT COALESCE(SUM(si.cost),0) FROM sale_items si JOIN sales s ON si.invoice=s.invoice '
        "WHERE s.createdAt BETWEEN ? AND ? AND s.status!='returned'",
        args);
    return DashboardTotals(sale, dashboardProfit(sale, cogs));
  }

  /// You'll Get / You'll Give — Party Dashboard jaisi hi live-ledger closings (partyTotals).
  Future<({double toGet, double toGive})> partyTotalsNow() async {
    final rows = await PartyDashboardRepository.instance.loadParties();
    return partyTotals(rows);
  }

  /// sync_queue mein abhi tak na bheji hui rows (syncedAt NULL).
  Future<int> pendingSyncCount() async {
    final db = await AppDatabase.instance.database;
    final rows = await db.rawQuery('SELECT COUNT(*) FROM sync_queue WHERE syncedAt IS NULL');
    return (rows.first.values.first as num?)?.toInt() ?? 0;
  }

  Future<String> shopName() async => (await UserRepository.instance.getSetting('shop_name'))?.trim() ?? '';

  Future<List<Product>> loadProducts() async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query('products', orderBy: 'name COLLATE NOCASE ASC');
    return rows.map(Product.fromMap).toList();
  }

  Future<List<User>> activeUsers() async => switchableUsers(await UserRepository.instance.all());

  /// Quick Switch ka password check. Purani plain-text password theek nikle to hash mein badal deta hai.
  Future<bool> verifySwitchPassword(User user, String typed) async {
    final hashed = PasswordHasher.isHashed(user.passwordHash);
    final matches = hashed ? await PasswordHasher.verify(typed, user.passwordHash) : false;
    final r = checkSwitchPassword(typed: typed, stored: user.passwordHash, storedIsHashed: hashed, hashedMatches: matches);
    if (r.ok && r.needsMigration) {
      await UserRepository.instance.upsert(User(
        username: user.username,
        displayName: user.displayName,
        role: user.role,
        passwordHash: await PasswordHasher.hash(typed),
        active: user.active,
        phone: user.phone,
      ));
    }
    return r.ok;
  }

  /// Kotlin completeQuickSwitch(): session badlo (username + role + displayName).
  Future<void> completeSwitch(User user) => Session.start(user);
}
