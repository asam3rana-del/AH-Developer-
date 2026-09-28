import 'package:flutter/material.dart';

import '../theme/theme_manager.dart';
import '../utils/loc.dart';

/// Mirrors Numerickeypad.kt — neeche se khulne wala custom keypad (0-9, decimal, backspace, Done).
/// System keyboard ki jagah Quantity / Rate / Discount / Amount Paid jaise fields ke liye.
///
/// Ek hi cheez zaroori hai: controller ki value keypad se badalti hai to `onChanged` chalta hai
/// (Flutter ka TextField.onChanged programmatic badlav par nahi chalta), taake live totals /
/// stock preview bilkul pehle ki tarah update hon.
///
/// `NumericKeypad.show(context, qtyController, allowDecimal: true, onChanged: (_) => _recalc());`
/// ya seedha `NumericKeypadField(controller: qty, ...)` widget.
class NumericKeypad {
  NumericKeypad._();

  static Future<void> show(
    BuildContext context,
    TextEditingController controller, {
    bool allowDecimal = true,
    String? label,
    ValueChanged<String>? onChanged,
    VoidCallback? onDone,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.35),
      builder: (sheetContext) => _KeypadSheet(
        controller: controller,
        allowDecimal: allowDecimal,
        label: label,
        onChanged: onChanged,
        onDone: () {
          Navigator.of(sheetContext).pop();
          onDone?.call();
        },
      ),
    );
  }
}

class _KeypadSheet extends StatelessWidget {
  final TextEditingController controller;
  final bool allowDecimal;
  final String? label;
  final ValueChanged<String>? onChanged;
  final VoidCallback onDone;

  const _KeypadSheet({
    required this.controller,
    required this.allowDecimal,
    required this.label,
    required this.onChanged,
    required this.onDone,
  });

  (int, int) _selection(TextEditingValue v) {
    final len = v.text.length;
    var s = v.selection.start;
    var e = v.selection.end;
    if (s < 0 || e < 0) {
      s = len;
      e = len;
    }
    return s < e ? (s, e) : (e, s);
  }

  void _insert(String chars) {
    final v = controller.value;
    final (lo, hi) = _selection(v);
    final text = v.text.replaceRange(lo, hi, chars);
    controller.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: lo + chars.length));
    onChanged?.call(text);
  }

  void _backspace() {
    final v = controller.value;
    final (lo, hi) = _selection(v);
    String text;
    int offset;
    if (lo != hi) {
      text = v.text.replaceRange(lo, hi, '');
      offset = lo;
    } else if (lo > 0) {
      text = v.text.replaceRange(lo - 1, lo, '');
      offset = lo - 1;
    } else {
      return;
    }
    controller.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: offset));
    onChanged?.call(text);
  }

  Widget _key(AppPalette p, String text, VoidCallback? onTap, {bool enabled = true}) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: SizedBox(
          height: 56,
          child: enabled
              ? Material(
                  color: p.fieldFill,
                  borderRadius: BorderRadius.circular(14),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: onTap,
                    child: Center(
                      child: Text(text, style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: p.textDark)),
                    ),
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = ThemeManager.palette;
    final accent = p.flatBlueFg;
    final onAccent = ThemeData.estimateBrightnessForColor(accent) == Brightness.dark ? Colors.white : Colors.black;

    Widget row(List<Widget> keys) => Row(children: keys);

    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
        decoration: BoxDecoration(
          color: p.cardWhite,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // Field ka label + live value, taake keyboard ke baghair "andhere mein" typing na ho.
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 0, 6, 14),
            child: Row(children: [
              Expanded(child: Text(label ?? '', style: TextStyle(fontSize: 12, color: p.textMuted))),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: controller,
                builder: (_, v, __) => Text(v.text.isEmpty ? '0' : v.text,
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: accent)),
              ),
            ]),
          ),
          row([for (final d in ['1', '2', '3']) _key(p, d, () => _insert(d))]),
          row([for (final d in ['4', '5', '6']) _key(p, d, () => _insert(d))]),
          row([for (final d in ['7', '8', '9']) _key(p, d, () => _insert(d))]),
          row([
            _key(p, '.', () {
              if (!controller.text.contains('.')) _insert('.');
            }, enabled: allowDecimal),
            _key(p, '0', () => _insert('0')),
            _key(p, '⌫', _backspace),
          ]),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: Material(
              color: accent,
              borderRadius: BorderRadius.circular(14),
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: onDone,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  child: Center(
                    child: Text('✓  ${Loc.t('Done', 'ٹھیک ہے')}',
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: onAccent)),
                  ),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

/// `EditText.useNumericKeypad()` ka Flutter roop: system keyboard band, tap par custom keypad.
class NumericKeypadField extends StatelessWidget {
  final TextEditingController controller;
  final bool allowDecimal;
  final String? label;
  final InputDecoration? decoration;
  final TextStyle? style;
  final FocusNode? focusNode;
  final bool enabled;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onDone;

  const NumericKeypadField({
    super.key,
    required this.controller,
    this.allowDecimal = true,
    this.label,
    this.decoration,
    this.style,
    this.focusNode,
    this.enabled = true,
    this.onChanged,
    this.onDone,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      focusNode: focusNode,
      enabled: enabled,
      style: style,
      readOnly: true,
      showCursor: true,
      keyboardType: TextInputType.none,
      decoration: decoration ?? InputDecoration(labelText: label),
      onTap: () => NumericKeypad.show(
        context,
        controller,
        allowDecimal: allowDecimal,
        label: label ?? decoration?.labelText ?? decoration?.hintText,
        onChanged: onChanged,
        onDone: onDone,
      ),
    );
  }
}
