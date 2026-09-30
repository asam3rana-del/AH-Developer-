import 'package:flutter/material.dart';

import '../theme/theme_manager.dart';

/// Mirrors MenuRow.kt — shared "menu row" design: pastel circle mein icon + label + chevron/trailing.
/// Dashboard / Settings / baaki screens sab yahi use karein taake rows ek jaise dikhein.
/// Rang default mein `ThemeManager.palette` se aate hain (dark mode chalta rahe).

/// Rang ko safed ki taraf halka karta hai (Kotlin `lightenHex`, factor 0.82).
Color lightenColor(Color c, [double factor = 0.82]) => Color.lerp(c, Colors.white, factor)!;

/// Pastel circle badge + beech mein tinted icon (Kotlin `iconBadge`).
/// [bg] na diya jaye to [color] ka lighten kiya hua rang.
class IconBadge extends StatelessWidget {
  final IconData icon;
  final Color color;
  final Color? bg;
  final double size;
  final double iconSize;

  const IconBadge({super.key, required this.icon, required this.color, this.bg, this.size = 44, this.iconSize = 20});

  @override
  Widget build(BuildContext context) {
    // Dark mode: safed-ki-taraf lighten se chamakta hua halka circle banta tha — wahan card ke rang mein
    // [color] ki halki jhalak milate hain, taake badge dark card par bhi jaisa hi lage.
    final dark = ThemeManager.isDark.value;
    final fill = bg ?? (dark ? Color.lerp(ThemeManager.palette.cardWhite, color, 0.22)! : lightenColor(color));
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(shape: BoxShape.circle, color: fill),
      child: Icon(icon, size: iconSize, color: color),
    );
  }
}

/// Safed rounded/bordered card jis ke andar row baithti hai (Kotlin `premiumRowCard`).
class PremiumRowCard extends StatelessWidget {
  final Widget child;
  final Color? cardColor;
  final Color? borderColor;
  final VoidCallback? onTap;

  const PremiumRowCard({super.key, required this.child, this.cardColor, this.borderColor, this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = ThemeManager.palette;
    final radius = BorderRadius.circular(18);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Material(
        color: cardColor ?? p.cardWhite,
        elevation: 1.5,
        shadowColor: Colors.black26,
        shape: RoundedRectangleBorder(borderRadius: radius, side: BorderSide(color: borderColor ?? p.border)),
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 17), child: child),
        ),
      ),
    );
  }
}

/// Simple non-expanding row: icon badge + label (+ chevron ya trailing text).
class MenuRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool showChevron;
  final String? trailingText;
  final Color? textColor;
  final Color? iconColor;
  final Color? chevronColor;
  final Color? cardColor;
  final Color? borderColor;
  final IconData? chevronIcon; // link rows ke liye Icons.chevron_right
  final VoidCallback onTap;

  const MenuRow({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.showChevron = false,
    this.trailingText,
    this.textColor,
    this.iconColor,
    this.chevronColor,
    this.cardColor,
    this.borderColor,
    this.chevronIcon,
  });

  @override
  Widget build(BuildContext context) {
    final p = ThemeManager.palette;
    final chev = chevronColor ?? p.teal;
    return PremiumRowCard(
      cardColor: cardColor,
      borderColor: borderColor,
      onTap: onTap,
      child: Row(children: [
        IconBadge(icon: icon, color: iconColor ?? p.teal),
        const SizedBox(width: 16),
        Expanded(
          child: Text(label, style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold, color: textColor ?? p.textDark)),
        ),
        if (trailingText != null)
          Text(trailingText!, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: chev))
        else if (showChevron)
          Icon(chevronIcon ?? Icons.keyboard_arrow_down, size: 18, color: chev),
      ]),
    );
  }
}

/// Row jis par tap karne se [target] khulta/band hota hai; chevron 180° ghoomta hai.
class ExpandableMenuRow extends StatefulWidget {
  final IconData icon;
  final String label;
  final String? subtitle;
  final Widget target;
  final bool initiallyExpanded;
  final Color? iconColor;
  final Color? textColor;
  final Color? subtitleColor;
  final Color? chevronColor;
  final Color? cardColor;
  final Color? borderColor;

  const ExpandableMenuRow({
    super.key,
    required this.icon,
    required this.label,
    required this.target,
    this.subtitle,
    this.initiallyExpanded = false,
    this.iconColor,
    this.textColor,
    this.subtitleColor,
    this.chevronColor,
    this.cardColor,
    this.borderColor,
  });

  @override
  State<ExpandableMenuRow> createState() => _ExpandableMenuRowState();
}

class _ExpandableMenuRowState extends State<ExpandableMenuRow> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final p = ThemeManager.palette;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      PremiumRowCard(
        cardColor: widget.cardColor,
        borderColor: widget.borderColor,
        onTap: () => setState(() => _expanded = !_expanded),
        child: Row(children: [
          IconBadge(icon: widget.icon, color: widget.iconColor ?? p.navy),
          const SizedBox(width: 16),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(widget.label,
                  style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold, color: widget.textColor ?? p.textDark)),
              if (widget.subtitle != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(widget.subtitle!, style: TextStyle(fontSize: 11, color: widget.subtitleColor ?? p.textMuted)),
                ),
            ]),
          ),
          AnimatedRotation(
            turns: _expanded ? 0.5 : 0,
            duration: const Duration(milliseconds: 180),
            child: Icon(Icons.keyboard_arrow_down, size: 18, color: widget.chevronColor ?? p.teal),
          ),
        ]),
      ),
      if (_expanded) widget.target,
    ]);
  }
}
