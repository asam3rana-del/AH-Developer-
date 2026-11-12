import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/services/payment_info.dart';
import 'package:ah_developer_kiryana_store/sync/sync_queue_helper.dart';

void main() {
  final base = Uri.parse('https://wa.me/923001234567?text=${Uri.encodeComponent('Ali sahib, baqi Rs 2,500 hai.')}');

  test('Empty info: link unchanged', () {
    expect(PaymentInfo.appendToWhatsApp(base, ''), base);
    expect(PaymentInfo.appendToWhatsApp(base, '   '), base);
  });

  test('Info is added under the reminder text, original kept', () {
    final u = PaymentInfo.appendToWhatsApp(base, 'Raast ID: 03001234567\nJazzCash: 03001234567 (Asam)');
    expect(u.host, 'wa.me');
    expect(u.path, '/923001234567');
    final text = u.queryParameters['text']!;
    expect(text.startsWith('Ali sahib, baqi Rs 2,500 hai.'), isTrue);
    expect(text, contains('Raast ID: 03001234567'));
    expect(text, contains('JazzCash: 03001234567 (Asam)'));
    expect(text.indexOf('Raast'), greaterThan(text.indexOf('Ali sahib')));
  });

  test('Special characters survive (+, &, Urdu)', () {
    final u = PaymentInfo.appendToWhatsApp(base, 'Bank: Meezan & HBL +92 / میزان');
    expect(u.queryParameters['text'], contains('Bank: Meezan & HBL +92 / میزان'));
  });

  test('Non-WhatsApp links are left alone', () {
    final tel = Uri(scheme: 'tel', path: '03001234567');
    expect(PaymentInfo.appendToWhatsApp(tel, 'Raast ID: 1'), tel);
  });

  test('payment_info syncs to other phones', () {
    expect(SyncQueueHelper.isSyncedAppSettingKey(PaymentInfo.settingKey), isTrue);
  });
}
