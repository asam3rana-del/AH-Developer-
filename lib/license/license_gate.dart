import 'package:flutter/material.dart';

import '../services/app_lock.dart';
import '../services/session.dart';
import '../theme/theme_manager.dart';
import '../utils/loc.dart';
import 'license_screen.dart';
import 'license_service.dart';

/// Poori app ka license darwaza (MaterialApp.builder mein, Navigator ke gird).
/// - License band (trial / muddat khatam, blocked, ghari peeche): login ke baad sirf [LicenseScreen]
///   (backup + logout ke saath). Peeche ki app chhupi (Offstage), focus / shortcuts bhi band.
/// - Login screen hamesha khulti hai (admin login kar ke backup le sake).
/// - Muddat qareeb ho to upar patli patti (tap => License screen).
class LicenseGate extends StatefulWidget {
  const LicenseGate({super.key, required this.child});
  final Widget child;

  @override
  State<LicenseGate> createState() => _LicenseGateState();
}

class _LicenseGateState extends State<LicenseGate> {
  bool _scheduled = false;

  @override
  void initState() {
    super.initState();
    LicenseService.instance.state.addListener(_onChange);
    AppLock.instance.loginScreenShown.addListener(_onChange);
  }

  @override
  void dispose() {
    LicenseService.instance.state.removeListener(_onChange);
    AppLock.instance.loginScreenShown.removeListener(_onChange);
    super.dispose();
  }

  /// Notifier build / dispose ke beech bhi badal sakte hain — rebuild agle frame par.
  void _onChange() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _openLicense() {
    AppLock.navigatorKey.currentState?.push(MaterialPageRoute<void>(builder: (_) => const LicenseScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final s = LicenseService.instance.state.value;
    final signedIn = Session.isLoggedIn && !AppLock.instance.onLoginScreen;
    final locked = signedIn && !s.usable;
    final warn = signedIn && !locked && s.expiringSoon;
    final mq = MediaQuery.of(context);

    // expand: Offstage ho to bhi Stack poori jagah le (warna License screen 0x0 par).
    return Stack(fit: StackFit.expand, children: [
      // Asal app — dhancha hamesha ek jaisa (Navigator ki state na toote).
      KeyedSubtree(
        key: const ValueKey('license-app'),
        child: Offstage(
          offstage: locked,
          child: TickerMode(
            enabled: !locked,
            child: ExcludeFocus(
              excluding: locked,
              child: Column(children: [
                warn ? _Banner(state: s, onTap: _openLicense) : const SizedBox.shrink(),
                Expanded(
                  child: MediaQuery(
                    data: warn ? mq.removePadding(removeTop: true) : mq,
                    child: widget.child,
                  ),
                ),
              ]),
            ),
          ),
        ),
      ),
      if (locked)
        Positioned.fill(
          child: Navigator(
            onGenerateRoute: (_) => MaterialPageRoute<void>(builder: (_) => const LicenseScreen()),
          ),
        ),
    ]);
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.state, required this.onTap});
  final LicenseState state;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = ThemeManager.palette;
    final d = state.daysLeft ?? 0;
    final trial = state.status == LicenseStatus.trial;
    final text = trial
        ? Loc.t('Free trial: $d day(s) left — tap to activate license', 'مفت ٹرائل: $d دن باقی — لائسنس فعال کرنے کے لیے دبائیں')
        : Loc.t('License ends in $d day(s) — tap to renew', 'لائسنس $d دن میں ختم — تجدید کے لیے دبائیں');
    return Material(
      color: d <= 2 ? p.red : p.flatAmberFg,
      child: SafeArea(
        bottom: false,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(children: [
              const Icon(Icons.info_outline, color: Colors.white, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Text(text,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13)),
              ),
              const Icon(Icons.chevron_right, color: Colors.white),
            ]),
          ),
        ),
      ),
    );
  }
}
