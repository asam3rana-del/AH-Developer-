import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_info.dart';
import '../screens/about_screen.dart';
import '../theme/theme_manager.dart';
import '../utils/loc.dart';

/// Hanna Software Series ka "About" card (Hanna Fitness jaisa): logo, naam, version,
/// Hanna Solutions · Asam Hameed, aur WhatsApp support ka button.
/// [showMore] = neeche "Privacy, support & delete data" (About screen) ka link.
class HannaAboutCard extends StatelessWidget {
  const HannaAboutCard({super.key, this.showMore = true});
  final bool showMore;

  static const _brandGold = Color(0xFFC08A1E); // safed par parhne layak Hanna gold

  Future<void> _whatsApp(BuildContext context) async {
    var ok = false;
    try {
      ok = await launchUrl(Uri.parse('https://wa.me/${AppInfo.supportWhatsAppIntl}'), mode: LaunchMode.externalApplication);
    } catch (_) {}
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(Loc.t('Could not open WhatsApp', 'واٹس ایپ نہیں کھل سکا'))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = ThemeManager.palette;
    final build = AppInfo.build.isEmpty ? '' : ' (${AppInfo.build})';
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: p.cardWhite,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: p.border),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 10, offset: const Offset(0, 3))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              boxShadow: [BoxShadow(color: p.navy.withValues(alpha: 0.25), blurRadius: 12, offset: const Offset(0, 5))],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: Image.asset('assets/images/hanna_pos_icon.png', width: 68, height: 68, filterQuality: FilterQuality.medium),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(AppInfo.appName, style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800, color: p.textDark)),
              const SizedBox(height: 3),
              Text('${AppInfo.tagline} · v${AppInfo.version}$build', style: TextStyle(fontSize: 14, color: p.textMuted)),
              const SizedBox(height: 3),
              Text('${AppInfo.business} · ${AppInfo.developer}',
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: _brandGold)),
            ]),
          ),
        ]),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: () => _whatsApp(context),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            side: BorderSide(color: p.border, width: 1.3),
          ),
          icon: const Icon(Icons.support_agent, color: Color(0xFF1FA855)),
          label: Text('${Loc.t('WhatsApp support', 'واٹس ایپ سپورٹ')} ${AppInfo.supportPhone}',
              style: TextStyle(color: p.textDark, fontWeight: FontWeight.w700, fontSize: 15)),
        ),
        if (showMore)
          TextButton(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AboutScreen())),
            child: Text(Loc.t('Privacy policy · Call / Email · Delete my data', 'پرائیویسی پالیسی · کال / ای میل · ڈیٹا ختم کروانا')),
          ),
      ]),
    );
  }
}
