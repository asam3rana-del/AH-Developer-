import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/db/dashboard_repository.dart';
import 'package:ah_developer_kiryana_store/models/misc_entities.dart';
import 'package:ah_developer_kiryana_store/models/product.dart';

Product prod(String name, {String tag = ''}) => Product(barcode: name, name: name, searchTag: tag, salePrice: 10);

User user(String name, String role, {bool active = true}) =>
    User(username: name, displayName: name, role: role, passwordHash: 'x', active: active);

void main() {
  group('dashboardColumns (Kotlin: 2 phone / 3 tablet portrait / 4 bara tablet)', () {
    test('breakpoints', () {
      expect(dashboardColumns(360), 2);
      expect(dashboardColumns(599.9), 2);
      expect(dashboardColumns(600), 3);
      expect(dashboardColumns(899.9), 3);
      expect(dashboardColumns(900), 4);
      expect(dashboardColumns(1280), 4);
    });
  });

  group('dashboardAmount', () {
    test('Rs %.2f', () {
      expect(dashboardAmount(0), 'Rs 0.00');
      expect(dashboardAmount(1234.5), 'Rs 1234.50');
    });
    test('tap-to-hide', () {
      expect(dashboardAmount(1234.5, hidden: true), 'Rs ••••••');
    });
  });

  group('dashboardSearch', () {
    final all = [prod('Basmati Rice 5kg'), prod('Sugar 1kg', tag: 'cheeni'), prod('Rice Flour'), prod('Salt')];

    test('khali / sirf space query = kuch nahi', () {
      expect(dashboardSearch(all, ''), isEmpty);
      expect(dashboardSearch(all, '   '), isEmpty);
    });
    test('har lafz name + searchTag mein hona chahiye', () {
      expect(dashboardSearch(all, 'rice').map((p) => p.name), ['Basmati Rice 5kg', 'Rice Flour']);
      expect(dashboardSearch(all, 'cheeni').map((p) => p.name), ['Sugar 1kg']);
      expect(dashboardSearch(all, '5kg basmati').map((p) => p.name), ['Basmati Rice 5kg']);
    });
    test('Kotlin take(6)', () {
      final many = [for (var i = 0; i < 10; i++) prod('Item $i')];
      expect(dashboardSearch(many, 'item'), hasLength(6));
      expect(dashboardSearch(many, 'item', limit: 3), hasLength(3));
    });
  });

  group('todayRange / profit', () {
    test('aaj ka midnight se agle midnight - 1ms', () {
      final now = DateTime(2026, 9, 29, 15, 30);
      final r = todayRange(now);
      expect(r.start, DateTime(2026, 9, 29).millisecondsSinceEpoch);
      expect(r.end, DateTime(2026, 9, 30).millisecondsSinceEpoch - 1);
    });
    test('profit = sale (discount ke baad) - COGS', () {
      expect(dashboardProfit(1000, 800), 200);
      expect(dashboardProfit(500, 650), -150); // nuqsan bhi dikhna chahiye
    });
  });

  group('syncPendingMessage', () {
    test('0 => label chhupa hua', () {
      expect(syncPendingMessage(0, urdu: false), isNull);
      expect(syncPendingMessage(-1, urdu: true), isNull);
    });
    test('English / Urdu', () {
      expect(syncPendingMessage(3, urdu: false), '⚠ 3 change(s) not yet synced to cloud — tap to check Sync History');
      expect(syncPendingMessage(3, urdu: true), contains('3'));
      expect(syncPendingMessage(3, urdu: true), contains('کلاؤڈ'));
    });
  });

  group('role rules', () {
    test('profit card sirf admin', () {
      expect(showsProfitCard('admin'), isTrue);
      expect(showsProfitCard('manager'), isFalse);
      expect(showsProfitCard('cashier'), isFalse);
    });
    test('logout tile sirf manager / cashier (admin Settings se)', () {
      expect(showsLogoutTile('admin'), isFalse);
      expect(showsLogoutTile('manager'), isTrue);
      expect(showsLogoutTile('cashier'), isTrue);
    });
    test('avatar rang: admin navy, manager blue, baqi orange', () {
      expect(roleColorValue('admin'), 0xFF0D1B4C);
      expect(roleColorValue('manager'), 0xFF2F6FED);
      expect(roleColorValue('cashier'), 0xFFFF8A00);
    });
  });

  group('Quick Switch', () {
    test('sirf active users', () {
      final list = [user('a', 'admin'), user('b', 'cashier', active: false), user('c', 'manager')];
      expect(switchableUsers(list).map((u) => u.username), ['a', 'c']);
    });

    group('checkSwitchPassword', () {
      test('hashed: verify ka nateeja hi faislah, migration nahi', () {
        final good = checkSwitchPassword(typed: 'pw', stored: 'pbkdf2\$..', storedIsHashed: true, hashedMatches: true);
        expect(good.ok, isTrue);
        expect(good.needsMigration, isFalse);
        final bad = checkSwitchPassword(typed: 'pw', stored: 'pbkdf2\$..', storedIsHashed: true, hashedMatches: false);
        expect(bad.ok, isFalse);
        expect(bad.needsMigration, isFalse);
      });
      test('purani plain-text: barabar ho to manzoor + hash mein badlo', () {
        final r = checkSwitchPassword(typed: 'admin123', stored: 'admin123', storedIsHashed: false, hashedMatches: false);
        expect(r.ok, isTrue);
        expect(r.needsMigration, isTrue);
      });
      test('plain-text ghalat password: na manzoor, migration nahi', () {
        final r = checkSwitchPassword(typed: 'nope', stored: 'admin123', storedIsHashed: false, hashedMatches: false);
        expect(r.ok, isFalse);
        expect(r.needsMigration, isFalse);
      });
    });
  });
}
