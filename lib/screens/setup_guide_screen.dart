import 'package:flutter/material.dart';

import '../db/cash_repository.dart';
import '../db/user_repository.dart';
import '../services/payment_info.dart';
import '../theme/theme_manager.dart';
import '../utils/input_validation.dart';
import '../utils/loc.dart';
import 'balance_sheet_screen.dart';
import 'items_screen.dart';
import 'party_dashboard_screen.dart';

/// Nayi dukaan ka setup guide (admin): 5 qadam, har qadam app ki maujooda screen / repository istemal karta hai —
/// koi naya data model nahi.
///  1. Dukaan ki maloomat (naam, malik, phone, reminders ki payment details)
///  2. Shuru ka paisa: galla + bank => Cash In "Owner Capital" (ek hi dafa; dobara par poochta hai)
///  3. Customers / suppliers aur un ka purana baqi (Opening Balance)
///  4. Items: opening stock, sahi cost, expiry
///  5. Balance Sheet se milaana
class SetupGuideScreen extends StatefulWidget {
  const SetupGuideScreen({super.key});

  @override
  State<SetupGuideScreen> createState() => _SetupGuideScreenState();
}

class _SetupGuideScreenState extends State<SetupGuideScreen> {
  static const openingDoneKey = 'setup_opening_money_done';

  final _repo = UserRepository.instance;
  final _shopName = TextEditingController();
  final _owner = TextEditingController();
  final _phone = TextEditingController();
  final _payInfo = TextEditingController();
  final _cash = TextEditingController();
  final _bank = TextEditingController();
  int _step = 0;
  bool _openingDone = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in [_shopName, _owner, _phone, _payInfo, _cash, _bank]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final name = await _repo.getSetting('shop_name') ?? '';
    final owner = await _repo.getSetting('shop_owner') ?? '';
    final phone = await _repo.getSetting('shop_phone') ?? '';
    final pay = await PaymentInfo.load();
    final done = await _repo.getSetting(openingDoneKey) == '1';
    if (!mounted) return;
    setState(() {
      _shopName.text = name;
      _owner.text = owner;
      _phone.text = phone;
      _payInfo.text = pay;
      _openingDone = done;
    });
  }

  void _toast(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _saveShop() async {
    if (_shopName.text.trim().isEmpty) {
      _toast(Loc.t('Enter the shop name', 'دکان کا نام لکھیں'));
      return;
    }
    await _repo.setSetting('shop_name', _shopName.text.trim());
    await _repo.setSetting('shop_owner', _owner.text.trim());
    await _repo.setSetting('shop_phone', _phone.text.trim());
    await PaymentInfo.save(_payInfo.text);
    _toast(Loc.t('Saved', 'محفوظ ہو گیا'));
    if (mounted) setState(() => _step = 1);
  }

  Future<void> _saveOpening() async {
    final cash = _cash.text.trim().isEmpty ? 0.0 : parseMoneyOrWarn(context, _cash.text, 'Cash in drawer', 'گلے میں کیش');
    if (cash == null) return;
    final bank = _bank.text.trim().isEmpty ? 0.0 : parseMoneyOrWarn(context, _bank.text, 'Bank balance', 'بینک بیلنس');
    if (bank == null) return;
    if (cash <= 0 && bank <= 0) {
      if (mounted) setState(() => _step = 2);
      return;
    }
    if (_openingDone) {
      final again = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(Loc.t('Opening money already entered', 'ابتدائی رقم پہلے درج ہو چکی')),
          content: Text(Loc.t(
              'Entering again will ADD to cash / bank. Only continue if this is extra money you put in.',
              'دوبارہ درج کرنے سے کیش / بینک میں مزید جمع ہوگا۔ صرف تب جاری رکھیں جب یہ اضافی رقم ہو۔')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(Loc.t('Cancel', 'منسوخ کریں'))),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(Loc.t('Add anyway', 'پھر بھی جمع کریں'))),
          ],
        ),
      );
      if (again != true) return;
    }
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      if (cash > 0) {
        await CashRepository.instance.save(
            type: 'IN', amount: cash, method: 'cash', category: CashCategories.ownerCapital, note: 'Opening cash');
      }
      if (bank > 0) {
        await CashRepository.instance.save(
            type: 'IN', amount: bank, method: 'bank', category: CashCategories.ownerCapital, note: 'Opening bank');
      }
      await _repo.setSetting(openingDoneKey, '1');
      _cash.clear();
      _bank.clear();
      _toast(Loc.t('Opening money saved as Owner Capital', 'ابتدائی رقم Owner Capital میں محفوظ'));
      if (mounted) setState(() {
        _openingDone = true;
        _step = 2;
      });
    } catch (e) {
      _toast(e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _open(Widget screen) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));

  InputDecoration _deco(String label, {String? hint}) => InputDecoration(
        labelText: label,
        hintText: hint,
        filled: true,
        fillColor: ThemeManager.palette.fieldFill,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      );

  Widget _gap() => const SizedBox(height: 10);

  Widget _next(String label, VoidCallback? onPressed) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: FilledButton(onPressed: onPressed, child: Text(label)),
      );

  @override
  Widget build(BuildContext context) {
    final p = ThemeManager.palette;
    return Scaffold(
      backgroundColor: p.bg,
      appBar: AppBar(
        backgroundColor: p.navy,
        foregroundColor: Colors.white,
        title: Text(Loc.t('Shop setup guide', 'دکان سیٹ اپ گائیڈ')),
      ),
      body: Stepper(
        currentStep: _step,
        onStepTapped: (i) => setState(() => _step = i),
        controlsBuilder: (_, __) => const SizedBox.shrink(),
        steps: [
          Step(
            title: Text(Loc.t('Shop details', 'دکان کی معلومات')),
            isActive: _step >= 0,
            content: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              TextField(controller: _shopName, decoration: _deco(Loc.t('Shop name', 'دکان کا نام'))),
              _gap(),
              TextField(controller: _owner, decoration: _deco(Loc.t('Owner name', 'مالک کا نام'))),
              _gap(),
              TextField(
                  controller: _phone,
                  keyboardType: TextInputType.phone,
                  decoration: _deco(Loc.t('Shop phone', 'دکان کا فون'))),
              _gap(),
              TextField(
                controller: _payInfo,
                minLines: 2,
                maxLines: 4,
                decoration: _deco(Loc.t('Payment details for reminders (optional)', 'یاد دہانی میں ادائیگی کی تفصیل (اختیاری)'),
                    hint: 'Raast ID / JazzCash / Bank IBAN'),
              ),
              _next(Loc.t('SAVE & NEXT', 'محفوظ کریں اور آگے'), _saveShop),
            ]),
          ),
          Step(
            title: Text(Loc.t('Opening money', 'ابتدائی رقم')),
            subtitle: _openingDone ? Text(Loc.t('Entered', 'درج ہو چکی'), style: TextStyle(color: p.teal)) : null,
            isActive: _step >= 1,
            content: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(
                Loc.t('Count the cash in the drawer and check the bank. Both are saved once as Cash In → Owner Capital.',
                    'گلے کا کیش گنیں اور بینک دیکھیں۔ دونوں ایک بار Cash In ← Owner Capital میں محفوظ ہوں گے۔'),
                style: TextStyle(color: p.textMuted, fontSize: 12.5),
              ),
              _gap(),
              TextField(
                  controller: _cash,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: _deco(Loc.t('Cash in drawer (Rs)', 'گلے میں کیش (روپے)'))),
              _gap(),
              TextField(
                  controller: _bank,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: _deco(Loc.t('Bank balance (Rs, 0 if none)', 'بینک بیلنس (روپے، نہ ہو تو 0)'))),
              _next(Loc.t('SAVE & NEXT', 'محفوظ کریں اور آگے'), _busy ? null : _saveOpening),
            ]),
          ),
          Step(
            title: Text(Loc.t('Customers & suppliers', 'کسٹمرز اور سپلائرز')),
            isActive: _step >= 2,
            content: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(
                Loc.t(
                    'Add each party with its old balance in "Opening Balance" (customer owes you = plus; you owe supplier = plus on supplier).',
                    'ہر پارٹی بنائیں اور اس کا پرانا بقایا "Opening Balance" میں لکھیں۔'),
                style: TextStyle(color: p.textMuted, fontSize: 12.5),
              ),
              _gap(),
              OutlinedButton.icon(
                onPressed: () => _open(const PartyDashboardScreen()),
                icon: const Icon(Icons.people_outline),
                label: Text(Loc.t('OPEN CUSTOMERS & SUPPLIERS', 'کسٹمرز اور سپلائرز کھولیں')),
              ),
              _next(Loc.t('NEXT', 'آگے'), () => setState(() => _step = 3)),
            ]),
          ),
          Step(
            title: Text(Loc.t('Items & stock', 'آئٹمز اور اسٹاک')),
            isActive: _step >= 3,
            content: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(
                Loc.t(
                    'For each item: count the shelf, enter Opening Stock and the correct Cost (wrong cost = wrong profit). '
                        'Add an Expiry date where needed. Start with your 20–30 best sellers.',
                    'ہر آئٹم: شیلف گنیں، Opening Stock اور درست Cost لکھیں (غلط لاگت = غلط منافع)۔ '
                        'ضرورت ہو تو Expiry date لگائیں۔ سب سے زیادہ بکنے والے 20–30 آئٹمز سے شروع کریں۔'),
                style: TextStyle(color: p.textMuted, fontSize: 12.5),
              ),
              _gap(),
              OutlinedButton.icon(
                onPressed: () => _open(const ItemsScreen()),
                icon: const Icon(Icons.inventory_2_outlined),
                label: Text(Loc.t('OPEN ITEMS', 'آئٹمز کھولیں')),
              ),
              _next(Loc.t('NEXT', 'آگے'), () => setState(() => _step = 4)),
            ]),
          ),
          Step(
            title: Text(Loc.t('Check the Balance Sheet', 'بیلنس شیٹ چیک کریں')),
            isActive: _step >= 4,
            content: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(
                Loc.t(
                    'Cash in Hand = drawer, Bank = bank app, Stock ≈ shelf × cost, Receivable / Payable = your old khata book. '
                        'If all four match, the shop is ready.',
                    'Cash in Hand = گلا، Bank = بینک ایپ، Stock ≈ شیلف × لاگت، Receivable / Payable = پرانی کھاتہ بک۔ '
                        'چاروں مل جائیں تو دکان تیار ہے۔'),
                style: TextStyle(color: p.textMuted, fontSize: 12.5),
              ),
              _gap(),
              OutlinedButton.icon(
                onPressed: () => _open(const BalanceSheetScreen()),
                icon: const Icon(Icons.account_balance_outlined),
                label: Text(Loc.t('OPEN BALANCE SHEET', 'بیلنس شیٹ کھولیں')),
              ),
              _next(Loc.t('DONE', 'مکمل'), () => Navigator.of(context).pop()),
            ]),
          ),
        ],
      ),
    );
  }
}
