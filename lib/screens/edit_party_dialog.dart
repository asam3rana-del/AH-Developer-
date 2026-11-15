import 'package:flutter/material.dart';

import '../db/party_repository.dart';
import '../models/party.dart';
import '../models/pay_schedule.dart';
import '../services/session.dart';
import '../utils/input_validation.dart';
import '../utils/loc.dart';
import '../widgets/contact_pick_button.dart';

/// Customer / Supplier ka POORA edit dialog (naam, phone, credit limit, opening balance, stuck, rate type,
/// due days, payment day). Party list ke Edit button aur Party Details ke ✏️ dono yahi kholte hain —
/// pehle Party Details ka pencil sirf naam badalta tha, opening balance waghera ke liye wapas list par
/// ja kar card ka Edit dhoondna padta tha (2-3 qadam).
///
/// Save ho jaye to `true` (caller reload kare); cancel / ghalat input / duplicate naam par `false`.

InputDecoration _dlgDeco(String label, {String? error}) =>
    InputDecoration(labelText: label, errorText: error, isDense: true);

/// 0 => khali field; warna bina faltu ".0" ke (27710.0 => 27710).
String _num(double v) {
  if (v == 0.0) return '';
  return v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();
}

void _toast(BuildContext context, String msg) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg)));
}

String _dupNameMsg(String name) => Loc.t(
    '"$name" already exists. Add something to tell them apart, e.g. "$name (Mohalla)".',
    '"$name" پہلے سے موجود ہے۔ فرق کے لیے کچھ ساتھ لکھیں، مثلاً "$name (محلہ)"۔');

Future<bool> showEditCustomerDialog(BuildContext context, Customer c) async {
  final canEditStuck = Session.isAdminOrManager;
  final name = TextEditingController(text: c.name);
  final phone = TextEditingController(text: c.phone);
  final limit = TextEditingController(text: _num(c.creditLimit));
  final opening = TextEditingController(text: _num(c.openingBalance));
  final stuck = canEditStuck ? TextEditingController(text: _num(c.stuckBalance)) : null;
  const money = TextInputType.numberWithOptions(decimal: true);
  var rateType = c.rateType;
  final dueDays = TextEditingController(text: c.dueDays > 0 ? c.dueDays.toString() : '');
  var paySchedule = payScheduleChoices.contains(c.paySchedule) ? c.paySchedule : '';

  var nameError = false;
  try {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(Loc.t('Edit Customer', 'کسٹمر میں ترمیم کریں')),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                  controller: name,
                  decoration: _dlgDeco(Loc.t('Name', 'نام'),
                      error: nameError ? Loc.t('Name is required', 'نام ضروری ہے') : null)),
              const SizedBox(height: 10),
              TextField(
                  controller: phone,
                  keyboardType: TextInputType.phone,
                  decoration: _dlgDeco(Loc.t('Phone', 'فون')).copyWith(suffixIcon: ContactPickButton(phone: phone))),
              const SizedBox(height: 10),
              TextField(controller: limit, keyboardType: money, decoration: _dlgDeco(Loc.t('Credit Limit', 'کریڈٹ لیمٹ'))),
              const SizedBox(height: 10),
              TextField(
                  controller: opening,
                  keyboardType: money,
                  decoration: _dlgDeco(Loc.t('Opening Balance (empty = 0)', 'ابتدائی بیلنس (خالی = 0)'))),
              if (stuck != null) ...[
                const SizedBox(height: 10),
                TextField(
                    controller: stuck,
                    keyboardType: money,
                    decoration: _dlgDeco(Loc.t('Stuck Balance (optional)', 'اسٹک بیلنس (اختیاری)'))),
              ],
              if (canEditStuck) ...[
                const SizedBox(height: 10),
                // Rate-type: sale mein is customer ko chunte hi rate khud isi hisab se lagta hai.
                DropdownButtonFormField<String>(
                  value: const ['', 'retail', 'wholesale', 'shopkeeper'].contains(rateType) ? rateType : '',
                  isExpanded: true,
                  decoration: _dlgDeco(Loc.t('Rate Type', 'ریٹ کی قسم')),
                  items: [
                    DropdownMenuItem(value: '', child: Text(Loc.t('Follow bill (default)', 'بل کے مطابق (ڈیفالٹ)'))),
                    DropdownMenuItem(value: 'retail', child: Text(Loc.t('Retail', 'ریٹیل'))),
                    DropdownMenuItem(value: 'wholesale', child: Text(Loc.t('Wholesale', 'ہول سیل'))),
                    DropdownMenuItem(value: 'shopkeeper', child: Text(Loc.t('Shopkeeper (lowest margin)', 'دکاندار (کم ترین مارجن)'))),
                  ],
                  onChanged: (v) => setLocal(() => rateType = v ?? ''),
                ),
                const SizedBox(height: 10),
                // Default muddat: udhaar bill par due date = bill date + itne din (sale mein badal sakte hain).
                TextField(
                    controller: dueDays,
                    keyboardType: TextInputType.number,
                    decoration: _dlgDeco(Loc.t('Payment due in (days) — optional', 'ادائیگی کی مدت (دن) — اختیاری'))),
                const SizedBox(height: 10),
                // Payment ka din: Wasooli Autopilot usi din is customer ko aaj ki list mein upar laata hai.
                DropdownButtonFormField<String>(
                  value: paySchedule,
                  isExpanded: true,
                  decoration: _dlgDeco(Loc.t('Payment day (when they have money)', 'ادائیگی کا دن (جب پیسے ہوں)')),
                  items: [
                    for (final v in payScheduleChoices)
                      DropdownMenuItem(value: v, child: Text(payScheduleLabel(v, urdu: Loc.isUrdu))),
                  ],
                  onChanged: (v) => setLocal(() => paySchedule = v ?? ''),
                ),
              ],
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(Loc.t('Cancel', 'منسوخ کریں'))),
            TextButton(
              onPressed: () {
                if (name.text.trim().isEmpty) {
                  setLocal(() => nameError = true);
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

    if (ok != true || !context.mounted) return false;

    // Ghalat raqam => warning + save ruk jaye. Khali = 0 (limit / opening / stuck hata do).
    final limitValue = parseMoneyOrWarn(context, limit.text, 'Credit Limit', 'کریڈٹ حد');
    if (limitValue == null) return false;
    final openingValue = parseMoneyOrWarn(context, opening.text, 'Opening Balance', 'ابتدائی بیلنس');
    if (openingValue == null) return false;
    double? stuckValue;
    if (stuck != null) {
      stuckValue = parseMoneyOrWarn(context, stuck.text, 'Stuck Balance', 'پھنسا ہوا بیلنس');
      if (stuckValue == null) return false;
    }

    final res = await PartyRepository.instance.editCustomer(
      c,
      name: name.text,
      phone: phone.text,
      creditLimit: limitValue,
      openingBalance: openingValue,
      stuckBalance: stuckValue, // null (cashier) => purana stuck barqarar
      rateType: canEditStuck ? rateType : null, // cashier rate-type nahi badal sakta
      dueDays: canEditStuck ? (int.tryParse(dueDays.text.trim()) ?? 0).clamp(0, 365) : null,
      paySchedule: canEditStuck ? paySchedule : null, // cashier nahi badal sakta
    );
    if (!context.mounted) return res == SavePartyResult.success;
    if (res == SavePartyResult.duplicateName) {
      _toast(context, _dupNameMsg(name.text.trim()));
      return false;
    }
    if (res == SavePartyResult.nameRequired) {
      _toast(context, Loc.t('Name is required', 'نام ضروری ہے'));
      return false;
    }
    _toast(context, Loc.t('Updated', 'اپ ڈیٹ ہو گیا'));
    return true;
  } catch (e) {
    _toast(context, e.toString());
    return false;
  } finally {
    name.dispose();
    phone.dispose();
    limit.dispose();
    opening.dispose();
    stuck?.dispose();
    dueDays.dispose();
  }
}

Future<bool> showEditSupplierDialog(BuildContext context, Supplier s) async {
  final name = TextEditingController(text: s.name);
  final phone = TextEditingController(text: s.phone);
  final opening = TextEditingController(text: _num(s.openingBalance));
  var nameError = false;
  try {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(Loc.t('Edit Supplier', 'سپلائر میں ترمیم کریں')),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                  controller: name,
                  decoration: _dlgDeco(Loc.t('Name', 'نام'),
                      error: nameError ? Loc.t('Name is required', 'نام ضروری ہے') : null)),
              const SizedBox(height: 10),
              TextField(
                  controller: phone,
                  keyboardType: TextInputType.phone,
                  decoration: _dlgDeco(Loc.t('Phone', 'فون')).copyWith(suffixIcon: ContactPickButton(phone: phone))),
              const SizedBox(height: 10),
              TextField(
                  controller: opening,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: _dlgDeco(Loc.t('Opening Balance (empty = 0)', 'ابتدائی بیلنس (خالی = 0)'))),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(Loc.t('Cancel', 'منسوخ کریں'))),
            TextButton(
              onPressed: () {
                if (name.text.trim().isEmpty) {
                  setLocal(() => nameError = true);
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

    if (ok != true || !context.mounted) return false;
    final openingValue = parseMoneyOrWarn(context, opening.text, 'Opening Balance', 'ابتدائی بیلنس');
    if (openingValue == null) return false;

    final res = await PartyRepository.instance.editSupplier(
      s,
      name: name.text,
      phone: phone.text,
      openingBalance: openingValue,
    );
    if (!context.mounted) return res == SavePartyResult.success;
    if (res == SavePartyResult.duplicateName) {
      _toast(context, _dupNameMsg(name.text.trim()));
      return false;
    }
    if (res == SavePartyResult.nameRequired) {
      _toast(context, Loc.t('Name is required', 'نام ضروری ہے'));
      return false;
    }
    _toast(context, Loc.t('Updated', 'اپ ڈیٹ ہو گیا'));
    return true;
  } catch (e) {
    _toast(context, e.toString());
    return false;
  } finally {
    name.dispose();
    phone.dispose();
    opening.dispose();
  }
}
