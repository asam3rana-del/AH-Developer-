import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../db/user_repository.dart';
import '../screens/backup_export_screen.dart';
import '../screens/login_screen.dart';
import '../services/app_lock.dart';
import '../services/session.dart';
import '../theme/app_theme.dart';
import '../theme/theme_manager.dart';
import '../utils/loc.dart';
import 'license_codec.dart';
import 'license_config.dart';
import 'license_service.dart';

/// License ki halat + Device ID + key daalne ki jagah.
/// - License band ho to [LicenseGate] isay poori app ki jagah dikhata hai (back nahi).
/// - Chalte license mein Settings > License se khulti hai (renew / key badalna).
class LicenseScreen extends StatefulWidget {
  const LicenseScreen({super.key});

  @override
  State<LicenseScreen> createState() => _LicenseScreenState();
}

class _LicenseScreenState extends State<LicenseScreen> {
  final _keyCtrl = TextEditingController();
  bool _busy = false;
  String? _error;
  String _shop = '';

  @override
  void initState() {
    super.initState();
    UserRepository.instance.getSetting('shop_name').then((v) {
      if (mounted) setState(() => _shop = v?.trim() ?? '');
    });
  }

  @override
  void dispose() {
    _keyCtrl.dispose();
    super.dispose();
  }

  String _date(int day) {
    final d = dateFromDay(day);
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
  }

  String _planName(LicensePlan p) => switch (p) {
        LicensePlan.lifetime => Loc.t('Lifetime', 'لائف ٹائم'),
        LicensePlan.yearly => Loc.t('Yearly', 'سالانہ'),
        LicensePlan.monthly => Loc.t('Monthly', 'ماہانہ'),
        LicensePlan.days => Loc.t('Custom', 'مخصوص دن'),
      };

  ({String title, String body, Color fg, Color bg, IconData icon}) _status(LicenseState s) {
    final p = ThemeManager.palette;
    switch (s.status) {
      case LicenseStatus.active:
        final l = s.license!;
        return (
          title: Loc.t('License active', 'لائسنس فعال ہے'),
          body: l.isLifetime
              ? '${_planName(l.plan)} — ${Loc.t('no expiry', 'کبھی ختم نہیں')}'
              : '${_planName(l.plan)} — ${Loc.t('valid till', 'تک')} ${_date(l.expiryDay - 1)}  (${s.daysLeft} ${Loc.t('days left', 'دن باقی')})',
          fg: p.flatTealFg,
          bg: p.flatTealBg,
          icon: Icons.verified,
        );
      case LicenseStatus.trial:
        return (
          title: Loc.t('Free trial', 'مفت ٹرائل'),
          body: '${s.daysLeft} ${Loc.t('days left — enter a license key to keep using Hanna POS.', 'دن باقی — Hanna POS چلانے کے لیے لائسنس کی ڈالیں۔')}',
          fg: p.flatAmberFg,
          bg: p.flatAmberBg,
          icon: Icons.hourglass_top,
        );
      case LicenseStatus.expired:
        return (
          title: Loc.t('License expired', 'لائسنس ختم ہو گیا'),
          body: '${Loc.t('Expired on', 'ختم ہوا')} ${_date(s.license!.expiryDay)}. ${Loc.t('Send your Device ID to renew.', 'تجدید کے لیے اپنی ڈیوائس آئی ڈی بھیجیں۔')}',
          fg: p.red,
          bg: p.red.withValues(alpha: 0.10),
          icon: Icons.lock_clock,
        );
      case LicenseStatus.trialOver:
        return (
          title: Loc.t('Free trial is over', 'مفت ٹرائل ختم'),
          body: Loc.t('Send your Device ID to ${LicenseConfig.vendorName} to get a license key.',
              'لائسنس کی کے لیے اپنی ڈیوائس آئی ڈی ${LicenseConfig.vendorName} کو بھیجیں۔'),
          fg: p.red,
          bg: p.red.withValues(alpha: 0.10),
          icon: Icons.lock_outline,
        );
      case LicenseStatus.blocked:
        return (
          title: Loc.t('License blocked', 'لائسنس بند کر دیا گیا'),
          body: Loc.t('This device\'s license was turned off by ${LicenseConfig.vendorName}. Please contact them.',
              'اس ڈیوائس کا لائسنس ${LicenseConfig.vendorName} نے بند کیا ہے۔ ان سے رابطہ کریں۔'),
          fg: p.red,
          bg: p.red.withValues(alpha: 0.10),
          icon: Icons.block,
        );
      case LicenseStatus.clockTampered:
        return (
          title: Loc.t('Wrong date / time', 'تاریخ / وقت غلط ہے'),
          body: Loc.t('This device\'s date was moved back. Set the correct date and time, then reopen the app.',
              'اس ڈیوائس کی تاریخ پیچھے کی گئی ہے۔ درست تاریخ اور وقت سیٹ کریں، پھر ایپ دوبارہ کھولیں۔'),
          fg: p.red,
          bg: p.red.withValues(alpha: 0.10),
          icon: Icons.event_busy,
        );
    }
  }

  String _errorText(String code) => switch (code) {
        'other_device' => Loc.t('This key is for another device. Send THIS Device ID to get the right key.',
            'یہ کی کسی اور ڈیوائس کی ہے۔ درست کی کے لیے یہی ڈیوائس آئی ڈی بھیجیں۔'),
        'expired' => Loc.t('This key has already expired.', 'یہ کی پہلے ہی ختم ہو چکی ہے۔'),
        _ => Loc.t('Key is not valid — copy the whole key exactly as sent.', 'کی درست نہیں — پوری کی ویسے ہی کاپی کریں جیسے بھیجی گئی۔'),
      };

  Future<void> _activate() async {
    final k = _keyCtrl.text.trim();
    if (k.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await LicenseService.instance.activate(k);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = err == null ? null : _errorText(err);
    });
    if (err == null) {
      _keyCtrl.clear();
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(Loc.t('License activated. Thank you!', 'لائسنس فعال ہو گیا۔ شکریہ!'))));
    }
  }

  Future<void> _paste() async {
    final d = await Clipboard.getData(Clipboard.kTextPlain);
    if (d?.text != null) _keyCtrl.text = d!.text!.trim();
  }

  Future<void> _copyId() async {
    await Clipboard.setData(ClipboardData(text: LicenseService.instance.deviceCode));
    if (mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(Loc.t('Device ID copied', 'ڈیوائس آئی ڈی کاپی ہو گئی'))));
    }
  }

  Future<void> _whatsApp() async {
    final text = Uri.encodeComponent(
        'Hanna POS license\nDevice ID: ${LicenseService.instance.deviceCode}${_shop.isEmpty ? '' : '\nShop: $_shop'}');
    final n = LicenseConfig.vendorWhatsApp;
    final uri = Uri.parse(n.isEmpty ? 'https://wa.me/?text=$text' : 'https://wa.me/$n?text=$text');
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  Future<void> _online() async {
    setState(() => _busy = true);
    final ok = await LicenseService.instance.checkOnline(force: true);
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
        content: Text(ok
            ? Loc.t('Checked online.', 'آن لائن چیک ہو گیا۔')
            : Loc.t('Could not check online (no internet?).', 'آن لائن چیک نہیں ہو سکا (انٹرنیٹ نہیں؟)'))));
  }

  Future<void> _logout() async {
    await Session.clear();
    AppLock.navigatorKey.currentState
        ?.pushAndRemoveUntil(MaterialPageRoute<void>(builder: (_) => const LoginScreen()), (_) => false);
  }

  @override
  Widget build(BuildContext context) {
    final p = ThemeManager.palette;
    final canPop = Navigator.of(context).canPop();
    return Scaffold(
      backgroundColor: p.bg,
      appBar: canPop
          ? AppBar(
              backgroundColor: p.navy,
              foregroundColor: Colors.white,
              title: Text(Loc.t('License', 'لائسنس')),
            )
          : null,
      body: SafeArea(
        child: ValueListenableBuilder<LicenseState>(
          valueListenable: LicenseService.instance.state,
          builder: (context, s, _) {
            final st = _status(s);
            final blocked = !s.usable;
            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
                  children: [
                    // Brand
                    Row(children: [
                      Container(
                        width: 52,
                        height: 52,
                        decoration: BoxDecoration(color: const Color(0xFF0B2545), borderRadius: BorderRadius.circular(14)),
                        child: const Icon(Icons.point_of_sale, color: AppTheme.gold, size: 28),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('Hanna POS', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: p.textDark)),
                          Text('${Loc.t('by', 'از')} ${LicenseConfig.vendorName}', style: TextStyle(color: p.textMuted)),
                        ]),
                      ),
                    ]),
                    const SizedBox(height: 20),

                    // Halat
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(color: st.bg, borderRadius: BorderRadius.circular(16)),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Icon(st.icon, color: st.fg, size: 28),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(st.title, style: TextStyle(color: st.fg, fontSize: 17, fontWeight: FontWeight.w800)),
                            const SizedBox(height: 4),
                            Text(st.body, style: TextStyle(color: st.fg, height: 1.35)),
                            if (s.keyProblem != null) ...[
                              const SizedBox(height: 6),
                              Text(_errorText(s.keyProblem!), style: TextStyle(color: st.fg, fontSize: 12.5)),
                            ],
                          ]),
                        ),
                      ]),
                    ),
                    const SizedBox(height: 16),

                    // Device ID
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(Loc.t('DEVICE ID', 'ڈیوائس آئی ڈی'),
                              style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 0.6, color: p.textMuted)),
                          const SizedBox(height: 6),
                          SelectableText(
                            LicenseService.instance.deviceCode,
                            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: 1.5, color: p.textDark, fontFamily: 'monospace'),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            Loc.t('Send this ID to ${LicenseConfig.vendorName}. The key works only on this device.',
                                'یہ آئی ڈی ${LicenseConfig.vendorName} کو بھیجیں۔ کی صرف اسی ڈیوائس پر چلے گی۔'),
                            style: TextStyle(fontSize: 12.5, color: p.textMuted),
                          ),
                          const SizedBox(height: 12),
                          Wrap(spacing: 10, runSpacing: 10, children: [
                            OutlinedButton.icon(onPressed: _copyId, icon: const Icon(Icons.copy, size: 18), label: Text(Loc.t('Copy', 'کاپی'))),
                            FilledButton.icon(
                              onPressed: _whatsApp,
                              style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1FA855)),
                              icon: const Icon(Icons.send, size: 18),
                              label: Text(Loc.t('Send on WhatsApp', 'واٹس ایپ پر بھیجیں')),
                            ),
                          ]),
                        ]),
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Key
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          Text(Loc.t('LICENSE KEY', 'لائسنس کی'),
                              style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 0.6, color: p.textMuted)),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _keyCtrl,
                            minLines: 3,
                            maxLines: 5,
                            textCapitalization: TextCapitalization.characters,
                            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                            decoration: InputDecoration(
                              hintText: 'HP1-XXXX-XXXX-…',
                              errorText: _error,
                              errorMaxLines: 3,
                              suffixIcon: IconButton(
                                tooltip: Loc.t('Paste', 'پیسٹ'),
                                icon: const Icon(Icons.content_paste),
                                onPressed: _paste,
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          FilledButton(
                            onPressed: _busy ? null : _activate,
                            style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
                            child: _busy
                                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                : Text(Loc.t('ACTIVATE', 'فعال کریں')),
                          ),
                          if (LicenseService.instance.onlineConfigured) ...[
                            const SizedBox(height: 8),
                            TextButton.icon(
                              onPressed: _busy ? null : _online,
                              icon: const Icon(Icons.cloud_sync_outlined),
                              label: Text(Loc.t('Check online', 'آن لائن چیک کریں')),
                            ),
                          ],
                        ]),
                      ),
                    ),

                    if (blocked && Session.isLoggedIn) ...[
                      const SizedBox(height: 12),
                      if (Session.isAdmin || Session.isManager)
                        OutlinedButton.icon(
                          onPressed: () => Navigator.of(context)
                              .push(MaterialPageRoute<void>(builder: (_) => const BackupExportScreen())),
                          icon: const Icon(Icons.save_outlined),
                          label: Text(Loc.t('Backup / export your data', 'اپنے ڈیٹا کا بیک اپ / ایکسپورٹ')),
                        ),
                      const SizedBox(height: 8),
                      TextButton.icon(
                        onPressed: _logout,
                        icon: const Icon(Icons.logout),
                        label: Text(Loc.t('Logout', 'لاگ آؤٹ')),
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
