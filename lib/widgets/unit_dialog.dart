import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../widgets/premium_widgets.dart';

class UnitSelection {
  final String primaryUnit;
  final String secondaryUnit; // 'None' if unused
  final double secondaryQty;
  final String tertiaryUnit; // 'None' if unused
  final double tertiaryQty;

  /// Manual default unit for the Sale screen / Quick Sale dialog, as an index
  /// into [primary, secondary, tertiary] (primary first). -1 = Auto.
  /// See `defaultUnitIndexFor()` in lib/utils/sale_cart.dart.
  final int defaultUnitIndex;
  final int quickSaleDefaultUnitIndex;

  const UnitSelection({
    required this.primaryUnit,
    required this.secondaryUnit,
    required this.secondaryQty,
    required this.tertiaryUnit,
    required this.tertiaryQty,
    this.defaultUnitIndex = -1,
    this.quickSaleDefaultUnitIndex = -1,
  });
}

/// Mirrors `standardUnitQty()` in ProductActivity.kt — auto-fills the
/// obvious conversion (dozen->12 pcs, kg->1000 g, etc.) so the user doesn't
/// have to type it manually for common units.
double? _standardUnitQty(String from, String to) {
  final f = from.trim().toLowerCase();
  final t = to.trim().toLowerCase();
  const gram = {'gram', 'grams', 'g', 'gm'};
  const piece = {'pcs', 'pc', 'piece', 'pieces'};
  const ml = {'ml', 'milliliter', 'millilitre'};
  const kg = {'kg', 'kgs', 'kilogram', 'kilograms'};
  const litre = {'litre', 'liter', 'l', 'ltr'};

  if (f == 'dozen' && piece.contains(t)) return 12.0;
  if (f == 'gross' && t == 'dozen') return 12.0;
  if (f == 'gross' && piece.contains(t)) return 144.0;
  if (kg.contains(f) && gram.contains(t)) return 1000.0;
  if (litre.contains(f) && ml.contains(t)) return 1000.0;
  if (f == 'quintal' && kg.contains(t)) return 100.0;
  if (f == 'ton' && kg.contains(t)) return 1000.0;
  if (f == 'pao' && gram.contains(t)) return 250.0;
  if (kg.contains(f) && t == 'pao') return 4.0;
  return null;
}

String _trimNum(double v) => v == v.truncateToDouble() ? v.toInt().toString() : v.toString();

/// Shows the unit dialog and resolves to a [UnitSelection], or null if
/// cancelled. Mirrors trySaveUnitSelection()'s validation rules exactly.
Future<UnitSelection?> showUnitDialog(
  BuildContext context, {
  required List<String> knownUnits,
  required String initialPrimary,
  required String initialSecondary,
  required double initialSecondaryQty,
  required String initialTertiary,
  required double initialTertiaryQty,
  int initialDefaultUnitIndex = -1,
  int initialQuickSaleDefaultUnitIndex = -1,
}) {
  var chosenDefaultUnitIndex = initialDefaultUnitIndex;
  var chosenQuickSaleDefaultUnitIndex = initialQuickSaleDefaultUnitIndex;

  final primaryCtrl = TextEditingController(text: initialPrimary);
  final secondaryCtrl = TextEditingController(text: initialSecondary == 'None' ? '' : initialSecondary);
  final secondaryQtyCtrl =
      TextEditingController(text: initialSecondaryQty > 0 ? _trimNum(initialSecondaryQty) : '');
  final tertiaryCtrl = TextEditingController(text: initialTertiary == 'None' ? '' : initialTertiary);
  final tertiaryQtyCtrl =
      TextEditingController(text: initialTertiaryQty > 0 ? _trimNum(initialTertiaryQty) : '');

  void autoSecondary() {
    final p = primaryCtrl.text.trim();
    final s = secondaryCtrl.text.trim();
    if (p.isEmpty || s.isEmpty) return;
    final standard = _standardUnitQty(p, s);
    if (standard != null && secondaryQtyCtrl.text.trim().isEmpty) {
      secondaryQtyCtrl.text = _trimNum(standard);
    }
  }

  void autoTertiary() {
    final s = secondaryCtrl.text.trim();
    final t = tertiaryCtrl.text.trim();
    if (s.isEmpty || t.isEmpty) return;
    final standard = _standardUnitQty(s, t);
    if (standard != null && tertiaryQtyCtrl.text.trim().isEmpty) {
      tertiaryQtyCtrl.text = _trimNum(standard);
    }
  }

  return showDialog<UnitSelection>(
    context: context,
    builder: (ctx) {
      String? errorText;
      return StatefulBuilder(
        builder: (ctx, setState) {
          Widget field(TextEditingController c, String hint, {TextInputType? kb}) => Container(
                margin: const EdgeInsets.only(top: 10),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.fieldFill,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.border, width: 1.2),
                ),
                child: TextField(
                  controller: c,
                  keyboardType: kb,
                  onChanged: (_) => setState(() {
                    autoSecondary();
                    autoTertiary();
                  }),
                  decoration: InputDecoration(
                    hintText: hint,
                    hintStyle: TextStyle(color: AppColors.textMuted, fontSize: 13),
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                ),
              );

          // Unit names as Sale shows them: primary first, then secondary, then tertiary.
          List<String> tierNames() {
            final names = <String>[primaryCtrl.text.trim().isEmpty ? '—' : primaryCtrl.text.trim()];
            final sec = secondaryCtrl.text.trim();
            final ter = tertiaryCtrl.text.trim();
            if (sec.isNotEmpty) names.add(sec);
            if (sec.isNotEmpty && ter.isNotEmpty) names.add(ter);
            return names;
          }

          void trySave() {
            final p = primaryCtrl.text.trim();
            var s = secondaryCtrl.text.trim().isEmpty ? 'None' : secondaryCtrl.text.trim();
            var t = tertiaryCtrl.text.trim().isEmpty ? 'None' : tertiaryCtrl.text.trim();
            final sq = double.tryParse(secondaryQtyCtrl.text.trim()) ?? 0.0;
            final tq = double.tryParse(tertiaryQtyCtrl.text.trim()) ?? 0.0;

            if (p.isEmpty) {
              setState(() => errorText = 'Select Primary Unit');
              return;
            }
            if (s != 'None' && s.toLowerCase() == p.toLowerCase()) {
              setState(() => errorText = 'Secondary must be different');
              return;
            }
            if (s != 'None' && sq <= 0) {
              setState(() => errorText = 'Enter secondary quantity');
              return;
            }
            if (t != 'None' && s == 'None') {
              setState(() => errorText = 'Select Secondary first');
              return;
            }
            if (t != 'None' && t.toLowerCase() == s.toLowerCase()) {
              setState(() => errorText = 'Tertiary must be different');
              return;
            }
            if (t != 'None' && tq <= 0) {
              setState(() => errorText = 'Enter tertiary quantity');
              return;
            }
            if (s == 'None') t = 'None';

            // A pinned tier that no longer exists (units were shortened) goes back to Auto.
            final tierCount = 1 + (s != 'None' ? 1 : 0) + (t != 'None' ? 1 : 0);
            final defIdx = (chosenDefaultUnitIndex >= 0 && chosenDefaultUnitIndex < tierCount)
                ? chosenDefaultUnitIndex
                : -1;
            final qsIdx = (chosenQuickSaleDefaultUnitIndex >= 0 && chosenQuickSaleDefaultUnitIndex < tierCount)
                ? chosenQuickSaleDefaultUnitIndex
                : -1;

            Navigator.of(ctx).pop(UnitSelection(
              primaryUnit: p,
              secondaryUnit: s,
              secondaryQty: s == 'None' ? 0.0 : sq,
              tertiaryUnit: t,
              tertiaryQty: t == 'None' ? 0.0 : tq,
              defaultUnitIndex: defIdx,
              quickSaleDefaultUnitIndex: qsIdx,
            ));
          }

          return Dialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
            insetPadding: const EdgeInsets.all(20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420, maxHeight: 620),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(24),
                    decoration: const BoxDecoration(
                      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                      gradient: LinearGradient(colors: [AppColors.navy, AppColors.navyLight]),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 46,
                          height: 46,
                          alignment: Alignment.center,
                          decoration: const BoxDecoration(
                            color: AppColors.headerBadgeOverlay,
                            shape: BoxShape.circle,
                          ),
                          child: const Text('📏', style: TextStyle(fontSize: 20)),
                        ),
                        const SizedBox(width: 14),
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Add Item Unit',
                                  style: TextStyle(color: Colors.white, fontSize: 18.5, fontWeight: FontWeight.bold)),
                              SizedBox(height: 5),
                              Text(
                                "Set how this product's units convert into each other",
                                style: TextStyle(color: AppColors.headerSubtitle, fontSize: 11.5),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(20, 20, 20, 6),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _UnitCard(
                            emoji: '📏',
                            label: 'Primary Unit',
                            accent: AppColors.teal,
                            child: field(primaryCtrl, 'e.g. pcs, kg, box'),
                          ),
                          const SizedBox(height: 16),
                          _UnitCard(
                            emoji: '🔹',
                            label: 'Secondary Unit (optional)',
                            accent: AppColors.blue,
                            child: Column(
                              children: [
                                field(secondaryCtrl, 'Leave blank if not needed'),
                                field(secondaryQtyCtrl, '1 Primary = how many Secondary?',
                                    kb: const TextInputType.numberWithOptions(decimal: true)),
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),
                          _UnitCard(
                            emoji: '🔸',
                            label: 'Tertiary Unit (optional)',
                            accent: AppColors.orange,
                            child: Column(
                              children: [
                                field(tertiaryCtrl, 'Leave blank if not needed'),
                                field(tertiaryQtyCtrl, '1 Secondary = how many Tertiary?',
                                    kb: const TextInputType.numberWithOptions(decimal: true)),
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),
                          _UnitCard(
                            emoji: '✔',
                            label: 'Default Unit for Sale Screen',
                            accent: AppColors.purple,
                            child: _DefaultUnitChips(
                              hint: 'Auto picks it for you. Choose one yourself if you want the Sale screen to always start with a specific unit.',
                              tierNames: tierNames(),
                              selected: chosenDefaultUnitIndex,
                              accent: AppColors.purple,
                              onSelected: (i) => setState(() => chosenDefaultUnitIndex = i),
                            ),
                          ),
                          const SizedBox(height: 16),
                          _UnitCard(
                            emoji: '⚡',
                            label: 'Default Unit for Quick Sale',
                            accent: AppColors.teal,
                            child: _DefaultUnitChips(
                              hint: 'Can differ from the Sale screen default — the smaller unit is often what is sold in Quick Sale.',
                              tierNames: tierNames(),
                              selected: chosenQuickSaleDefaultUnitIndex,
                              accent: AppColors.teal,
                              onSelected: (i) => setState(() => chosenQuickSaleDefaultUnitIndex = i),
                            ),
                          ),
                          if (errorText != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: Text(errorText!, style: const TextStyle(color: AppColors.red, fontSize: 12)),
                            ),
                        ],
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
                    decoration: BoxDecoration(
                      color: AppColors.cardWhite,
                      boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 8, offset: const Offset(0, -2))],
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => Navigator.of(ctx).pop(),
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              side: const BorderSide(color: AppColors.border),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                            ),
                            child: const Text('Cancel', style: TextStyle(color: AppColors.textMuted, fontWeight: FontWeight.bold)),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: GradientButton(
                            label: 'Save',
                            emoji: '✓',
                            start: AppColors.teal,
                            end: AppColors.tealDark,
                            radius: 14,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            onTap: trySave,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
  );
}

class _UnitCard extends StatelessWidget {
  final String emoji;
  final String label;
  final Color accent;
  final Widget child;

  const _UnitCard({required this.emoji, required this.label, required this.accent, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.cardWhite,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border, width: 1.2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              BadgeIcon(emoji: emoji, color: accent),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label.toUpperCase(),
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: AppColors.navy, letterSpacing: 0.3),
                ),
              ),
            ],
          ),
          child,
        ],
      ),
    );
  }
}


/// "Auto | Carton | Dozen | Pcs" chip row. Index -1 = Auto, otherwise an index
/// into [tierNames] (primary first) — same order as `saleUnitChoices()`.
class _DefaultUnitChips extends StatelessWidget {
  final String hint;
  final List<String> tierNames;
  final int selected;
  final Color accent;
  final ValueChanged<int> onSelected;

  const _DefaultUnitChips({
    required this.hint,
    required this.tierNames,
    required this.selected,
    required this.accent,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    // A pinned tier that no longer exists shows as Auto.
    final current = (selected >= 0 && selected < tierNames.length) ? selected : -1;
    final options = <MapEntry<int, String>>[
      const MapEntry(-1, 'Auto'),
      for (var i = 0; i < tierNames.length; i++) MapEntry(i, tierNames[i]),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 10, bottom: 12),
          child: Text(hint, style: const TextStyle(fontSize: 11.5, color: AppColors.textMuted)),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final o in options)
              GestureDetector(
                onTap: () => onSelected(o.key),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                  decoration: BoxDecoration(
                    color: o.key == current ? accent : AppColors.cardWhite,
                    borderRadius: BorderRadius.circular(30),
                    border: Border.all(color: accent),
                  ),
                  child: Text(
                    o.value,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.bold,
                      color: o.key == current ? Colors.white : accent,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}
