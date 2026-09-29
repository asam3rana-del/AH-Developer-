import 'package:flutter/material.dart';

import '../services/session.dart';
import '../theme/theme_manager.dart';
import '../utils/loc.dart';
import 'purchase_history_screen.dart';
import 'sale_history_screen.dart';

/// Kaunsi history dikhani hai (Kotlin `EXTRA_MODE`: MODE_SALES / MODE_PURCHASES).
enum HistoryMode { sales, purchases }

/// Mirrors HistoryActivity.kt.
///
/// Kotlin mein ye purani combined screen hai: `EXTRA_MODE` ke saath sirf Sale ya sirf Purchase
/// History (seedha list), aur bina mode ke SALES / PURCHASES tabs wala fallback.
/// Flutter mein dono lists ke dedicated screens pehle se hain (Sale History: `SaleHistoryScreen`,
/// Purchase History: `PurchaseHistoryScreen` — Return/Delete/profit wahi admin-only rules aur
/// wahi atomic transactions), isliye ye screen sirf router hai — business logic dobara nahi likhi.
///
/// Role: Sale tab sab roles ke liye (profit + Edit/Return/Delete sirf admin, SaleHistoryScreen ke andar);
/// Purchase tab sirf admin (PurchaseHistoryScreen ka RoleGuard; tab cashier/manager ko dikhta hi nahi).
///
/// Farq (Kotlin se): Kotlin ke `row()` mein bill/invoice number nahi dikhta tha, yahan dono dedicated
/// screens ka apna (behtar) layout hai. Purchase detail se "Edit" abhi Flutter mein nahi
/// (PORT_STATUS Phase 2 — edit-saved-purchase baaki).
class HistoryScreen extends StatefulWidget {
  /// null => combined SALES / PURCHASES tabs (Kotlin fallback).
  final HistoryMode? mode;
  const HistoryScreen({super.key, this.mode});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  bool _showingSales = true;
  // Purchase tab pehli baar khulne par hi banta hai (Kotlin ki tarah sirf zaroorat par load).
  bool _purchasesBuilt = false;

  AppPalette get _p => ThemeManager.palette;

  @override
  void initState() {
    super.initState();
    _showingSales = widget.mode != HistoryMode.purchases;
    _purchasesBuilt = !_showingSales;
  }

  void _select(bool sales) {
    setState(() {
      _showingSales = sales;
      if (!sales) _purchasesBuilt = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    // Single-purpose mode: koi tab switcher nahi, taake ek tile se doosri list na khul jaye.
    if (widget.mode == HistoryMode.sales) return const SaleHistoryScreen();
    if (widget.mode == HistoryMode.purchases) return const PurchaseHistoryScreen();

    final admin = Session.isAdmin;
    // Cashier/manager ke liye sirf Sales (Purchase admin-only) — tab bar ki zaroorat nahi.
    if (!admin) return const SaleHistoryScreen();

    return Scaffold(
      body: IndexedStack(
        index: _showingSales ? 0 : 1,
        children: [
          const SaleHistoryScreen(),
          if (_purchasesBuilt) const PurchaseHistoryScreen() else const SizedBox.shrink(),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Container(
          margin: const EdgeInsets.fromLTRB(12, 6, 12, 10),
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: _p.cardWhite,
            border: Border.all(color: _p.border),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(children: [
            _pill(Loc.t('SALES', 'سیلز'), _showingSales, _p.flatBlueFg, () => _select(true)),
            _pill(Loc.t('PURCHASES', 'خریداریاں'), !_showingSales, _p.flatTealFg, () => _select(false)),
          ]),
        ),
      ),
    );
  }

  Widget _pill(String label, bool active, Color activeColor, VoidCallback onTap) => Expanded(
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 12),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: active ? activeColor : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: active ? Colors.white : _p.textMuted,
              ),
            ),
          ),
        ),
      );
}
