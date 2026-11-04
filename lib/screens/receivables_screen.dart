import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../db/due_reminders_repository.dart';
import '../models/receivable_aging.dart';
import '../services/collection_actions.dart';
import '../theme/theme_manager.dart';
import '../utils/loc.dart';
import '../widgets/party_avatar.dart';
import '../widgets/permission_guard.dart';
import '../widgets/premium_header.dart';

/// Receivables: customers se kitna lena hai, aur wo paisa KITNE DIN SE phansa hai.
///
///  * Upar kul raqam aur us mein se kitni late hai.
///  * Umar ke dibbe: abhi waqt hai / 1-7 / 8-30 / 31-60 / 60+ din late / tareekh nahi — dibbe par tap karne se
///    sirf us dibbe ki parties dikhti hain.
///  * Sab se bade qarzdar (pehle 10, "sab dikhao" se poori list) — har party par 1 tap WhatsApp / Call /
///    "Paisa mila".
///
/// Hisaab [buildAging] (pure) mein hai; data Due Reminders wala hi ([DueRemindersRepository.dueSales]),
/// is liye Party Dashboard ke "You'll get" se mel khata hai. Sirf Customers (Sales).
class ReceivablesScreen extends StatelessWidget {
  const ReceivablesScreen({super.key});

  @override
  Widget build(BuildContext context) => const PermissionGuard(permission: 'due_reminders', child: _ReceivablesBody());
}

class _ReceivablesBody extends StatefulWidget {
  const _ReceivablesBody();

  @override
  State<_ReceivablesBody> createState() => _ReceivablesBodyState();
}

class _ReceivablesBodyState extends State<_ReceivablesBody> {
  AgingSummary _summary = AgingSummary.empty;
  bool _loading = true;
  String? _error;
  AgingBucket? _filter; // null = sab parties
  bool _showAll = false;

  AppPalette get _p => ThemeManager.palette;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool spinner = true}) async {
    if (spinner && mounted) setState(() => _loading = true);
    try {
      final bills = await DueRemindersRepository.instance.dueSales();
      final summary = buildAging(groupDueByParty(bills));
      if (!mounted) return;
      setState(() {
        _summary = summary;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  String _rs(double v) => 'Rs ${v.round()}';

  String _bucketLabel(AgingBucket b) {
    switch (b) {
      case AgingBucket.notDue:
        return Loc.t('Not due yet', 'ابھی وقت ہے');
      case AgingBucket.late1to7:
        return Loc.t('1–7 days late', '1 سے 7 دن لیٹ');
      case AgingBucket.late8to30:
        return Loc.t('8–30 days late', '8 سے 30 دن لیٹ');
      case AgingBucket.late31to60:
        return Loc.t('31–60 days late', '31 سے 60 دن لیٹ');
      case AgingBucket.late60plus:
        return Loc.t('60+ days late', '60 دن سے زیادہ لیٹ');
      case AgingBucket.noDate:
        return Loc.t('No due date / old balance', 'تاریخ نہیں / پرانا حساب');
    }
  }

  Color _bucketColor(AgingBucket b) {
    switch (b) {
      case AgingBucket.notDue:
        return _p.flatTealFg;
      case AgingBucket.late1to7:
        return _p.flatAmberFg;
      case AgingBucket.late8to30:
        return Colors.deepOrange;
      case AgingBucket.late31to60:
        return _p.red;
      case AgingBucket.late60plus:
        return const Color(0xFF8E0000);
      case AgingBucket.noDate:
        return _p.textMuted;
    }
  }

  String _partyStatus(AgingRow r) {
    if (r.isLate) return Loc.t('${r.maxDaysLate} days late', '${r.maxDaysLate} دن لیٹ');
    if (r.amountIn(AgingBucket.noDate) > 0.009) return Loc.t('No due date', 'تاریخ نہیں');
    return Loc.t('Not due yet', 'ابھی وقت ہے');
  }

  Color _partyColor(AgingRow r) => _bucketColor(r.worst);

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _call(AgingRow r) async {
    try {
      final ok = await launchUrl(Uri(scheme: 'tel', path: r.party.partyPhone.trim()));
      if (!ok) throw Exception('launch failed');
    } catch (_) {
      _toast(Loc.t('Could not open the dialer', 'ڈائلر نہیں کھل سکا'));
    }
  }

  Future<void> _whatsApp(AgingRow r) async {
    if (await sendReminderTo(context, r.party)) _toast(Loc.t('Reminder sent', 'یاد دہانی بھیج دی'));
  }

  Future<void> _receive(AgingRow r) async {
    final id = r.party.partyId;
    if (id == null) return;
    final saved = await receiveFromParty(context, partyId: id, partyName: r.party.partyName, due: r.total);
    if (saved) await _load(spinner: false);
  }

  // ---- widgets -----------------------------------------------------------

  Widget _totalCard() {
    final s = _summary;
    final latePct = (s.lateShare * 100).round();
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _p.cardWhite,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _p.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(Loc.t('Total to collect', 'کل وصولی باقی'),
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: _p.textMuted)),
        const SizedBox(height: 2),
        Text(_rs(s.totalDue), style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: _p.textDark)),
        const SizedBox(height: 2),
        Text(
          s.lateAmount > 0.009
              ? Loc.t('${_rs(s.lateAmount)} is late ($latePct%) • ${s.totalParties} parties',
                  '${_rs(s.lateAmount)} لیٹ ہے ($latePct%) • ${s.totalParties} پارٹیاں')
              : Loc.t('Nothing is late • ${s.totalParties} parties', 'کچھ لیٹ نہیں • ${s.totalParties} پارٹیاں'),
          style: TextStyle(
              fontSize: 13, fontWeight: FontWeight.w600, color: s.lateAmount > 0.009 ? _p.red : _p.flatTealFg),
        ),
      ]),
    );
  }

  Widget _bucketRow(AgingBucket b) {
    final s = _summary;
    final amt = s.amountIn(b);
    final frac = s.totalDue <= 0.009 ? 0.0 : (amt / s.totalDue).clamp(0.0, 1.0).toDouble();
    final color = _bucketColor(b);
    final selected = _filter == b;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: amt <= 0.009
          ? null
          : () => setState(() {
                _filter = selected ? null : b;
                _showAll = false;
              }),
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: selected ? color.withOpacity(0.10) : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: selected ? color : Colors.transparent, width: 1.2),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text(_bucketLabel(b),
                  style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: _p.textDark)),
            ),
            Text(amt <= 0.009 ? '—' : _rs(amt),
                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: amt <= 0.009 ? _p.textMuted : color)),
          ]),
          const SizedBox(height: 5),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: frac,
              minHeight: 8,
              backgroundColor: _p.border.withOpacity(0.5),
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
          if (amt > 0.009)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                  Loc.t('${s.partiesIn(b)} parties • ${(frac * 100).round()}%', '${s.partiesIn(b)} پارٹیاں • ${(frac * 100).round()}%'),
                  style: TextStyle(fontSize: 11.5, color: _p.textMuted)),
            ),
        ]),
      ),
    );
  }

  Widget _circle(IconData icon, Color fg, Color bg, VoidCallback onTap) => InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
          child: Icon(icon, size: 18, color: fg),
        ),
      );

  Widget _partyRow(AgingRow r) {
    final hasPhone = r.party.partyPhone.trim().isNotEmpty;
    final f = _filter;
    final inBucket = f == null ? 0.0 : r.amountIn(f);
    final extra = f != null && (r.total - inBucket).abs() > 0.009
        ? ' • ${Loc.t('${_rs(inBucket)} in this group', 'اس گروپ میں ${_rs(inBucket)}')}'
        : '';
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
      decoration: BoxDecoration(
        color: _p.cardWhite,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _p.border),
      ),
      child: Row(children: [
        PartyAvatar(
          isCustomer: true,
          partyId: r.party.partyId,
          name: r.party.partyName,
          radius: 21,
          onTap: r.party.partyId == null
              ? null
              : () => showPartyPhotoSheet(context, isCustomer: true, partyId: r.party.partyId!),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(r.party.partyName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold, color: _p.textDark)),
            const SizedBox(height: 2),
            Text(_rs(r.total), style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: _p.textDark)),
            Text('${_partyStatus(r)}$extra',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: _partyColor(r))),
          ]),
        ),
        if (hasPhone) ...[
          _circle(Icons.send, const Color(0xFF25D366), const Color(0xFFDDF6E8), () => _whatsApp(r)),
          const SizedBox(width: 6),
          _circle(Icons.phone, _p.flatPurpleFg, _p.flatPurpleBg, () => _call(r)),
        ],
        if (r.party.partyId != null) ...[
          const SizedBox(width: 6),
          _circle(Icons.check, _p.flatTealFg, _p.flatTealBg, () => _receive(r)),
        ],
      ]),
    );
  }

  List<Widget> _partySection() {
    final f = _filter;
    final all = f == null ? _summary.rows : _summary.rowsIn(f);
    const limit = 10;
    final shown = _showAll || all.length <= limit ? all : all.take(limit).toList();
    final title = f == null
        ? Loc.t('Biggest debtors', 'سب سے بڑے قرض دار')
        : _bucketLabel(f);
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(2, 16, 2, 8),
        child: Row(children: [
          Expanded(
            child: Text(title.toUpperCase(),
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 0.6, color: _p.textMuted)),
          ),
          if (f != null)
            InkWell(
              onTap: () => setState(() => _filter = null),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Text(Loc.t('Show all', 'سب دکھائیں'),
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: _p.flatPurpleFg)),
              ),
            ),
        ]),
      ),
      for (final r in shown) _partyRow(r),
      if (!_showAll && all.length > limit)
        TextButton(
          onPressed: () => setState(() => _showAll = true),
          child: Text(Loc.t('Show all ${all.length}', 'سب ${all.length} دکھائیں')),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _p.bg,
      appBar: AppBar(backgroundColor: _p.navy, foregroundColor: Colors.white, elevation: 0),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () => _load(spinner: false),
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 30),
            children: [
              PremiumHeader(
                title: Loc.t('Receivables', 'وصولیاں'),
                subtitle: Loc.t('Who owes you, and for how long', 'کس سے کتنا لینا ہے، اور کب سے'),
              ),
              if (_loading)
                const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))
              else if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 40),
                  child: Text(Loc.t('Could not load: $_error', 'لوڈ نہیں ہو سکا: $_error'),
                      textAlign: TextAlign.center, style: TextStyle(color: _p.red)),
                )
              else if (_summary.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 40),
                  child: Text(Loc.t('Nothing to collect — all credit is paid', 'کوئی بقایا نہیں — سب ادا ہو چکا'),
                      textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: _p.textMuted)),
                )
              else ...[
                _totalCard(),
                const SizedBox(height: 14),
                for (final b in agingBucketOrder)
                  if (b != AgingBucket.noDate || _summary.amountIn(b) > 0.009) _bucketRow(b),
                ..._partySection(),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
