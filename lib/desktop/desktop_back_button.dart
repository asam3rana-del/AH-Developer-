import 'package:flutter/material.dart';

import 'desktop_prefs.dart';

/// PC (Windows) par apne header wali screens (Sale, Purchase, Items, Product…) ke liye back button —
/// phone par system back hota hai, PC par nahi. Sirf PC par aur sirf jab peeche koi screen ho.
/// `maybePop` — screen ka apna "unsaved?" sawal waise hi chalta hai.
class DesktopBackButton extends StatelessWidget {
  const DesktopBackButton({super.key, this.color = Colors.white});
  final Color color;

  @override
  Widget build(BuildContext context) {
    if (!DesktopPrefs.isDesktop) return const SizedBox.shrink();
    final nav = Navigator.maybeOf(context);
    if (nav == null || !nav.canPop()) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 6),
      child: IconButton(
        tooltip: 'Back (Alt + ←)',
        icon: Icon(Icons.arrow_back, color: color),
        onPressed: () => nav.maybePop(),
      ),
    );
  }
}
