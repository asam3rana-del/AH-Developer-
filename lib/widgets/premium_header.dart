import 'package:flutter/material.dart';
import '../theme/theme_manager.dart';

/// Mirrors `buildHeader()` in ProductActivity.kt — navy gradient header with
/// title/subtitle on the left and a "View List" pill on the right.
class PremiumHeader extends StatelessWidget {
  final String title;
  final String subtitle;
  final String? actionLabel;
  final String? actionEmoji;
  final VoidCallback? onActionTap;

  const PremiumHeader({
    super.key,
    required this.title,
    required this.subtitle,
    this.actionLabel,
    this.actionEmoji,
    this.onActionTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 18),
      padding: const EdgeInsets.fromLTRB(22, 18, 18, 18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [ThemeManager.palette.navy, ThemeManager.palette.navyLight],
        ),
        boxShadow: [
          BoxShadow(color: ThemeManager.palette.navyInk.withOpacity(0.35), blurRadius: 10, offset: const Offset(0, 4)),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(color: Colors.white, fontSize: 18.5, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: TextStyle(color: ThemeManager.palette.headerSubtitleColor, fontSize: 11),
                ),
              ],
            ),
          ),
          if (actionLabel != null)
            InkWell(
              borderRadius: BorderRadius.circular(30),
              onTap: onActionTap,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                decoration: BoxDecoration(
                  color: ThemeManager.palette.headerBadgeOverlay,
                  borderRadius: BorderRadius.circular(30),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (actionEmoji != null) ...[
                      Text(actionEmoji!, style: const TextStyle(fontSize: 12)),
                      const SizedBox(width: 4),
                    ],
                    Text(
                      actionLabel!,
                      style: const TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
