import 'package:flutter/material.dart';

import '../services/session.dart';
import '../theme/app_colors.dart';
import '../utils/loc.dart';
import '../widgets/premium_header.dart';
import '../widgets/role_guard.dart';
import 'balance_sheet_screen.dart';
import 'cash_register_screen.dart';
import 'cash_screen.dart';
import 'day_book_screen.dart';
import 'expense_screen.dart';
import 'item_search_screen.dart';
import 'login_screen.dart';
import 'payments_screen.dart';
import 'product_screen.dart';
import 'purchase_screen.dart';
import 'sale_screen.dart';
import 'settings_screen.dart';
import 'shell_ledger_screen.dart';
import 'user_management_screen.dart';
import 'zakat_screen.dart';

class _Tile {
  final String en, ur, subEn, subUr;
  final IconData icon;
  final Color color;
  final Set<String> roles;
  final Widget Function()? open; // null => abhi port nahi hua
  const _Tile(this.en, this.ur, this.subEn, this.subUr, this.icon, this.color, this.roles, this.open);
}

/// Mirrors MainActivity.kt — role-based QUICK ACTIONS.
/// Jo screens abhi port nahi hui unke tiles "jald aa raha hai" dikhate hain;
/// har phase ke baad `open:` bhar dein.
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  static const _all = {'admin', 'manager', 'cashier'};
  static const _am = {'admin', 'manager'};
  static const _admin = {'admin'};

  List<_Tile> get _tiles => [
        _Tile('Sale', 'سیل', 'Start a new sale', 'نئی سیل شروع کریں', Icons.shopping_cart, AppColors.purple, _all, () => const SaleScreen()),
        _Tile('Rate Search', 'ریٹ سرچ', 'Item rates in seconds', 'آئٹم کے ریٹ فوراً', Icons.price_check, AppColors.teal, _all, () => const ItemSearchScreen()),
        const _Tile('Quick Sale', 'کوئیک سیل', 'Fast single-item sale', 'ایک آئٹم کی تیز سیل', Icons.timer, AppColors.purple, _all, null),
        _Tile('Purchase', 'خریداری', 'Record a purchase', 'خریداری درج کریں', Icons.inventory, AppColors.red, _admin,
            () => const RoleGuard(allowed: _admin, child: PurchaseScreen())),
        _Tile('Cash', 'کیش', 'Cash in / cash out', 'کیش اِن / آؤٹ', Icons.account_balance_wallet, AppColors.amber, _all, () => const CashScreen()),
        _Tile('Cash Register', 'کیش رجسٹر', 'Daily till open & close', 'روزانہ رجسٹر کھولیں / بند کریں', Icons.point_of_sale, AppColors.amber, _all, () => const CashRegisterScreen()),
        _Tile('Expenses', 'اخراجات', 'Track business spending', 'کاروباری اخراجات', Icons.receipt_long, AppColors.red, _all, () => const ExpenseScreen()),
        _Tile('Payments', 'ادائیگیاں', 'Receive or make a payment', 'رقم وصول یا ادا کریں', Icons.account_balance, AppColors.teal, _all, () => const PaymentsScreen()),
        const _Tile('Customers & Suppliers', 'گاہک اور سپلائر', 'Manage ledgers & dues', 'کھاتے اور بقایا', Icons.people, Color(0xFFEC4899), _all, null),
        const _Tile('Low Stock', 'کم اسٹاک', 'Items needing restock', 'دوبارہ منگوانے والی اشیاء', Icons.warning_amber, AppColors.red, _all, null),
        _Tile('Products', 'پروڈکٹس', 'Products, categories & units', 'پروڈکٹس، کیٹیگریز اور یونٹس', Icons.list_alt, AppColors.blue, _admin,
            () => const RoleGuard(allowed: _admin, child: ProductScreen())),
        const _Tile('Backup', 'بیک اپ', 'Export data (CSV + PDF)', 'ڈیٹا ایکسپورٹ', Icons.save, AppColors.blue, _am, null),
        _Tile('Users', 'یوزرز', 'Add, update, remove staff', 'اسٹاف مینیج کریں', Icons.manage_accounts, AppColors.purple, _admin, () => const UserManagementScreen()),
        _Tile('Settings', 'سیٹنگز', 'Shop, login & language', 'دکان، لاگ اِن اور زبان', Icons.settings, AppColors.navy, _all, () => const SettingsScreen()),
        // Kotlin opens Balance Sheet from Reports (Phase 9). Reports isn't ported yet, so it
        // lives here for now — move it under Reports then.
        _Tile('Balance Sheet', 'بیلنس شیٹ', 'Assets, liabilities & capital', 'اثاثے، واجبات اور سرمایہ', Icons.assessment, AppColors.blue, _am,
            () => const RoleGuard(allowed: _am, child: BalanceSheetScreen())),
        _Tile('Zakat', 'زکوٰۃ', 'Ramadan-to-Ramadan tracker', 'رمضان تا رمضان حساب', Icons.volunteer_activism, AppColors.teal, _am,
            () => const RoleGuard(allowed: _am, child: ZakatScreen())),
        _Tile('Shell Ledger', 'شیل لیجر', 'Bottles given & shells back', 'بھری بوتلیں اور واپس شیل', Icons.repeat, AppColors.amber, _all,
            () => const ShellLedgerScreen()),
        _Tile('Day book', 'روزنامچہ', 'View daily ledger', 'روزانہ کھاتہ', Icons.menu_book, AppColors.teal, _all, () => const DayBookScreen()),
      ];

  Future<void> _logout() async {
    await Session.clear();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const LoginScreen()), (_) => false);
  }

  void _tap(_Tile t) {
    if (t.open == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(Loc.t('Coming soon', 'جلد آ رہا ہے'))));
      return;
    }
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => t.open!()));
  }

  @override
  Widget build(BuildContext context) {
    final tiles = _tiles.where((t) => t.roles.contains(Session.role)).toList();
    final roleLabel = Session.role[0].toUpperCase() + Session.role.substring(1);
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            PremiumHeader(
              title: '${Loc.t('Welcome', 'خوش آمدید')}, ${Session.displayName}',
              subtitle: '$roleLabel ${Loc.t('Panel', 'پینل')}',
              actionLabel: Loc.isUrdu ? 'English' : 'اردو',
              actionEmoji: '🌐',
              onActionTap: () => Loc.setLanguage(Loc.isUrdu ? 'en' : 'ur'),
            ),
            Text(Loc.t('QUICK ACTIONS', 'فوری کام'),
                style: const TextStyle(fontSize: 12, letterSpacing: 1.2, fontWeight: FontWeight.bold, color: AppColors.textMuted)),
            const SizedBox(height: 10),
            GridView.count(
              crossAxisCount: MediaQuery.of(context).size.width > 700 ? 4 : 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 1.25,
              children: [
                for (final t in tiles)
                  InkWell(
                    borderRadius: BorderRadius.circular(18),
                    onTap: () => _tap(t),
                    child: Ink(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: AppColors.cardWhite,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        CircleAvatar(radius: 18, backgroundColor: t.color.withOpacity(0.15), child: Icon(t.icon, color: t.color, size: 20)),
                        const Spacer(),
                        Text(Loc.t(t.en, t.ur), maxLines: 2, overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontWeight: FontWeight.bold, color: t.open == null ? AppColors.textMuted : AppColors.textDark)),
                        Text(Loc.t(t.subEn, t.subUr), maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 11, color: AppColors.textMuted)),
                      ]),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 18),
            OutlinedButton.icon(
              onPressed: _logout,
              icon: const Icon(Icons.logout, color: AppColors.red),
              label: Text(Loc.t('Logout', 'لاگ آؤٹ'), style: const TextStyle(color: AppColors.red)),
            ),
          ],
        ),
      ),
    );
  }
}
