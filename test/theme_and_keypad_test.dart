import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/theme/theme_manager.dart';
import 'package:ah_developer_kiryana_store/widgets/menu_row.dart';
import 'package:ah_developer_kiryana_store/widgets/numeric_keypad.dart';

void main() {
  test('lightenColor moves toward white like Kotlin lightenHex(0.82)', () {
    final c = lightenColor(const Color(0xFF0F9B8E));
    expect(c.red, greaterThan(0xE0));
    expect(c.green, greaterThan(0xF0));
  });

  test('palette follows dark flag', () {
    ThemeManager.isDark.value = false;
    expect(ThemeManager.palette.bg, ThemeManager.light.bg);
    ThemeManager.isDark.value = true;
    expect(ThemeManager.palette.bg, ThemeManager.dark.bg);
    ThemeManager.isDark.value = false;
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
