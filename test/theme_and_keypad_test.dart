import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/theme/theme_manager.dart';
import 'package:ah_developer_kiryana_store/widgets/menu_row.dart';
import 'package:ah_developer_kiryana_store/widgets/numeric_keypad.dart';

void main() {
  test('lightenColor moves toward white like Kotlin lightenHex(0.82)', () {
    final c = lightenColor(const Color(0xFF0F9B8E));
    // 0.82 ke saath: red = 15 + 240*0.82 ~ 212, green = 155 + 100*0.82 ~ 237 (sirf asli rang se bohat halka).
    expect(c.red, inInclusiveRange(210, 214));
    expect(c.green, inInclusiveRange(235, 239));
    expect(c.red, greaterThan(0x0F));
  });

  test('palette follows dark flag', () {
    ThemeManager.isDark.value = false;
    expect(ThemeManager.palette.bg, ThemeManager.light.bg);
    ThemeManager.isDark.value = true;
    expect(ThemeManager.palette.bg, ThemeManager.dark.bg);
    ThemeManager.isDark.value = false;
  });

  test('migrated palette: dark mode ke text/icon rang card par dikhte hain', () {
    for (final pal in [ThemeManager.light, ThemeManager.dark]) {
      expect(pal.navyInk, isNot(pal.cardWhite));
      expect(pal.textMuted, isNot(pal.cardWhite));
    }
    // Dark mein navyInk halka hona chahiye (navy header ka rang text ke tor par nahi).
    expect(ThemeManager.dark.navyInk.computeLuminance(), greaterThan(0.3));
    expect(ThemeManager.dark.navy.computeLuminance(), lessThan(0.1));
  });

  testWidgets('keypad inserts digits, one decimal point, backspace, and fires onChanged', (tester) async {
    final c = TextEditingController();
    final seen = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (ctx) => Scaffold(
          body: TextButton(
            onPressed: () => NumericKeypad.show(ctx, c, onChanged: seen.add),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('1'));
    await tester.tap(find.text('2'));
    await tester.tap(find.text('.'));
    await tester.tap(find.text('.')); // doosra decimal ignore
    await tester.tap(find.text('5'));
    expect(c.text, '12.5');

    await tester.tap(find.text('⌫'));
    expect(c.text, '12.');
    expect(seen.last, '12.');
  });
}
