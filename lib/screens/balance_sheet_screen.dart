import 'package:flutter/material.dart';

import '../db/balance_sheet_repository.dart';
import '../theme/theme_manager.dart';
import '../utils/loc.dart';

/// Mirrors BalanceSheetActivity.kt — Assets = Liabilities + Capital, built from
/// data the app already tracks. All-time figures.
///
/// Admin / Manager only: wrap in `RoleGuard(allowed: {'admin','manager'}, ...)`
/// (BalanceSheetRepository.load() checks the role again).
class BalanceSheetScreen extends StatefulWidget {
  const BalanceSheetScreen({super.key});

  @override
  State<BalanceSheetScreen> createState() => _BalanceSheetScreenState();
}

class _BalanceSheetScreenState extends State<BalanceSheetScreen> {
  BalanceSheetData? _data;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await BalanceSheetRepository.instance.load();
      if (!mounted) return;
      setState(() {
        _data = d;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = ThemeManager.palette;
    final d = _data;
    return Scaffold(
      backgroundColor: p.bg,
      body: Column(children: [
        _header(p),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 32),
              children: [
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: p.red)),
                  )
                else if (d == null)
                  const Padding(padding: EdgeInsets.symmetric(vertical: 60), child: Center(child: CircularProgressIndicator()))
                else
                  ..._sheet(p, d),
              ],
            ),
          ),
        ),
      ]),
    );
  }

  // Header colour: p.flatBlueFg in Kotlin is a pale blue in dark mode, so the
  // header uses p.navy (white text stays readable in both themes).
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
          child: const Icon(Icons.account_balance, color: Colors.white, size: 18),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(Loc.t('Balance Sheet', 'بیلنس شیٹ'),
                style: const TextStyle(color: Colors.white, fontSize: 18.5, fontWeight: FontWeight.bold)),
            Text(Loc.t('As of today \u2022 all-time figures', 'آج تک \u2022 تمام وقت کے اعداد و شمار'),
                style: TextStyle(color: p.headerSubtitleColor, fontSize: 11)),
          ]),
        ),
      ]),
    );
  }

  List<Widget> _sheet(AppPalette p, BalanceSheetData d) {
    final f = d.figures;
    final warnings = <String>[
      if (d.customersDrifted > 0 || d.suppliersDrifted > 0)
        Loc.t(
          '${d.customersDrifted} customer(s) and ${d.suppliersDrifted} supplier(s) have a stored balance that does not match their bills/payments \u2014 run Fix Balances.',
          '${d.customersDrifted} کسٹمر اور ${d.suppliersDrifted} سپلائر کا بیلنس ان کے بلوں/ادائیگیوں سے میل نہیں کھاتا \u2014 Fix Balances چلائیں۔',
        ),
      if (f.cashOrBankNegative)
        Loc.t(
          'Cash or Bank is negative \u2014 an opening balance was probably never entered (add it once as a Cash In entry) or an entry is wrong.',
          'کیش یا بینک منفی ہے \u2014 غالباً ابتدائی رقم درج نہیں ہوئی (ایک بار کیش ان میں لکھیں) یا کوئی انٹری غلط ہے۔',
        ),
    ];

    return [
      _sectionHeader(p, Loc.t('ASSETS', 'اثاثے')),
      _card(p, [
        _row(p, Loc.t('Cash in Hand', 'نقد رقم'), f.cashInHand),
        _row(p, Loc.t('Bank Balance', 'بینک بیلنس'), f.bankBalance),
        _row(p, Loc.t('Stock in Hand (at cost)', 'اسٹاک (لاگت پر)'), f.stockValue),
        _row(p, Loc.t('Accounts Receivable', 'قابل وصول رقم'), f.receivables),
        if (f.advancePaidToSuppliers > 0)
          _row(p, Loc.t('Advance Paid to Suppliers', 'سپلائرز کو ایڈوانس'), f.advancePaidToSuppliers),
        _divider(p),
        _row(p, Loc.t('Total Assets', 'کل اثاثے'), f.totalAssets, bold: true),
      ]),
      const SizedBox(height: 16),
      _sectionHeader(p, Loc.t('LIABILITIES', 'واجبات')),
      _card(p, [
        _row(p, Loc.t('Accounts Payable', 'قابل ادائیگی رقم'), f.payables),
        if (f.advanceFromCustomers > 0)
          _row(p, Loc.t('Advance from Customers', 'کسٹمرز سے ایڈوانس'), f.advanceFromCustomers),
        _divider(p),
        _row(p, Loc.t('Total Liabilities', 'کل واجبات'), f.totalLiabilities, bold: true),
      ]),
      const SizedBox(height: 16),
      _sectionHeader(p, Loc.t('CAPITAL / EQUITY', 'سرمایہ')),
      _card(p, [
        _row(p, Loc.t('Net Profit (all-time)', 'خالص منافع (تمام وقت)'), f.netProfit),
        _row(p, Loc.t('Capital (calculated)', 'سرمایہ (حساب شدہ)'), f.capital),
        _divider(p),
        _row(p, Loc.t('Total Liabilities + Capital', 'کل واجبات + سرمایہ'), f.totalLiabilitiesAndCapital, bold: true),
      ]),
      if (warnings.isNotEmpty) ...[
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 4, 6, 8),
          child: Text('\u26A0 ${warnings.join('\n\n\u26A0 ')}', style: TextStyle(fontSize: 12.5, color: p.red)),
        ),
      ],
      const SizedBox(height: 10),
      Padding(
        padding: const EdgeInsets.fromLTRB(6, 4, 6, 20),
        child: Text(
          Loc.t(
            "Note: Capital is a calculated balancing figure (Total Assets \u2212 Total Liabilities \u2212 Net Profit), since owner's injected capital isn't entered separately in this app.",
            'نوٹ: سرمایہ ایک حساب شدہ balancing figure ہے، کیونکہ مالک کا لگایا گیا سرمایہ اس ایپ میں الگ سے درج نہیں ہوتا۔',
          ),
          style: TextStyle(fontSize: 11.5, color: p.textMuted),
        ),
      ),
    ];
  }

  Widget _sectionHeader(AppPalette p, String t) => Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 10),
        child: Text(t, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: p.textMuted)),
      );

  Widget _card(AppPalette p, List<Widget> children) => Container(
        padding: const EdgeInsets.fromLTRB(22, 14, 22, 12),
        decoration: BoxDecoration(
          color: p.cardWhite,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: p.border),
        ),
        child: Column(children: children),
      );

  Widget _divider(AppPalette p) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Divider(height: 2, thickness: 1, color: p.border),
      );

  Widget _row(AppPalette p, String label, double amount, {bool bold = false}) {
    final color = amount < 0 ? p.red : (bold ? p.flatBlueFg : p.textDark);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Expanded(
          child: Text(label,
              style: TextStyle(
                fontSize: bold ? 15 : 13.5,
                fontWeight: bold ? FontWeight.bold : FontWeight.normal,
                color: bold ? p.textDark : p.textMuted,
              )),
        ),
        const SizedBox(width: 8),
        Text('Rs ${amount.toStringAsFixed(2)}',
            style: TextStyle(fontSize: bold ? 16 : 13.5, fontWeight: bold ? FontWeight.bold : FontWeight.normal, color: color)),
      ]),
    );
  }
}
