import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

/// Mirrors `premiumCard()` in ProductActivity.kt: white rounded card with an
/// optional colored two-tone gradient accent strip along the top edge.
class PremiumCard extends StatelessWidget {
  final Widget child;
  final Color? accentTop;
  final EdgeInsetsGeometry padding;

  const PremiumCard({
    super.key,
    required this.child,
    this.accentTop,
    this.padding = const EdgeInsets.all(20),
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: AppColors.cardWhite,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AppColors.border, width: 1.2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.06),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (accentTop != null)
            Container(
              height: 5,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [accentTop!, AppColors.fade(accentTop!)],
                ),
              ),
            ),
          Padding(padding: padding, child: child),
        ],
      ),
    );
  }
}

/// Mirrors `badgeIcon()`: a small round colored gradient badge with an emoji
/// / icon centered inside, with a soft shadow.
class BadgeIcon extends StatelessWidget {
  final String emoji;
  final Color color;
  final double size;

  const BadgeIcon({super.key, required this.emoji, required this.color, this.size = 30});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [color, AppColors.fadeDark(color)],
        ),
        boxShadow: [
          BoxShadow(color: color.withOpacity(0.35), blurRadius: 6, offset: const Offset(0, 2)),
        ],
      ),
      child: Text(emoji, style: const TextStyle(fontSize: 14)),
    );
  }
}

/// Mirrors `sectionLabel()`: badge + uppercase bold label, used as each
/// card's header.
class SectionLabel extends StatelessWidget {
  final String emoji;
  final String label;
  final Color accent;

  const SectionLabel({super.key, required this.emoji, required this.label, required this.accent});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        children: [
          BadgeIcon(emoji: emoji, color: accent),
          const SizedBox(width: 10),
          Text(
            label.toUpperCase(),
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: AppColors.textDark,
              letterSpacing: 0.4,
            ),
          ),
        ],
      ),
    );
  }
}

/// Mirrors `premiumLabeledField()`: colored round badge + a small persistent
/// uppercase label ABOVE the input, so the field's meaning never disappears
/// once it has a value in it.
class PremiumLabeledField extends StatelessWidget {
  final String emoji;
  final String label;
  final Color accent;
  final TextEditingController controller;
  final TextInputType keyboardType;
  final String hint;
  final TextInputAction textInputAction;
  final ValueChanged<String>? onChanged;
  final FocusNode? focusNode;
  final VoidCallback? onSubmitted;

  const PremiumLabeledField({
    super.key,
    required this.emoji,
    required this.label,
    required this.accent,
    required this.controller,
    this.keyboardType = const TextInputType.numberWithOptions(decimal: true),
    this.hint = '0.00',
    this.textInputAction = TextInputAction.next,
    this.onChanged,
    this.focusNode,
    this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.fieldFill,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border, width: 1.2),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          BadgeIcon(emoji: emoji, color: accent, size: 38),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label.toUpperCase(),
                  style: TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.bold,
                    color: accent,
                    letterSpacing: 0.4,
                  ),
                ),
                TextField(
                  controller: controller,
                  focusNode: focusNode,
                  keyboardType: keyboardType,
                  textInputAction: textInputAction,
                  onChanged: onChanged,
                  onSubmitted: (_) => onSubmitted?.call(),
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textDark,
                  ),
                  decoration: InputDecoration(
                    hintText: hint,
                    hintStyle: TextStyle(color: AppColors.textMuted, fontWeight: FontWeight.normal),
                    isDense: true,
                    contentPadding: EdgeInsets.zero,
                    border: InputBorder.none,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Mirrors `gradientBg()` used on Save/Delete/action buttons: diagonal
/// two-color gradient pill with white bold text.
class GradientButton extends StatelessWidget {
  final String label;
  final String? emoji;
  final Color start;
  final Color end;
  final VoidCallback onTap;
  final double radius;
  final EdgeInsetsGeometry padding;

  const GradientButton({
    super.key,
    required this.label,
    this.emoji,
    required this.start,
    required this.end,
    required this.onTap,
    this.radius = 30,
    this.padding = const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(radius),
        onTap: onTap,
        child: Ink(
          padding: padding,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [start, end],
            ),
            borderRadius: BorderRadius.circular(radius),
            boxShadow: [
              BoxShadow(color: start.withOpacity(0.35), blurRadius: 6, offset: const Offset(0, 2)),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (emoji != null) ...[Text(emoji!, style: const TextStyle(fontSize: 13)), const SizedBox(width: 6)],
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 12.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
