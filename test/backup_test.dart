import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/backup/backup_crypto.dart';
import 'package:ah_developer_kiryana_store/backup/backup_export.dart';
import 'package:ah_developer_kiryana_store/backup/backup_password_store.dart';
import 'package:ah_developer_kiryana_store/models/product.dart';

/// Phase 11 tests. Fixtures asli Java JCE (jaisa Android BackupCrypto.kt: PBKDF2WithHmacSHA256 +
/// AES/GCM/NoPadding, aur purana AES/CBC/PKCS5) se bane hain — is liye Dart <-> Android format ka
/// seedha saboot hain.
const _password = 'Test-Passw0rd \u00e9'; // non-ASCII: UTF-8 password handling bhi check hoti hai
const _javaIbb1 = 'SUJCMQECAwQFBgcICQoLDA0ODxBlZmdoaWprbG1ub3BN7Ft+ychCBrwdBqtEa8kRVn1dv2XeLyliFxTnn8GJ4QxYQwtcdZPBdSSSNPM3gGI=';
const _javaLegacy = 'SUJBS1YwMDEyMzQ1Njc4OTo7PD0+P0BBlpeYmZqbnJ2en6ChoqOkpZC1AULUw4fTx7q+NmsmjwuCiy8r3tU6Jvk7Hx8CdesfnMLBqOZngtLHsQtGO8FWCw==';
final _plain = Uint8List.fromList(latin1.encode('SQLite format 3\u0000hello backup 123'));

void main() {
  group('BackupCrypto (IBB1, Android compatible)', () {
    test('Java/Android se bani IBB1 file Dart mein decrypt hoti hai', () async {
      final out = await BackupCrypto.decryptBytes(base64Decode(_javaIbb1), _password);
      expect(out, _plain);
    });

    test('Java se bani purani IBAKV001 (CBC) file decrypt hoti hai', () async {
      final out = await BackupCrypto.decryptLegacyCbc(base64Decode(_javaLegacy), _password);
      expect(out, _plain);
    });

    test('Dart encrypt -> layout Android jaisa: magic + salt16 + iv12 + ct + tag16', () async {
      final enc = await BackupCrypto.encryptBytes(_plain, _password);
      expect(enc.sublist(0, 4), BackupCrypto.magic);
      expect(String.fromCharCodes(enc.sublist(0, 4)), 'IBB1');
      expect(enc.length, 4 + 16 + 12 + _plain.length + 16);
      expect(await BackupCrypto.decryptBytes(enc, _password), _plain);
    });

    test('har backup ka salt/iv alag hota hai', () async {
      final a = await BackupCrypto.encryptBytes(_plain, _password);
      final b = await BackupCrypto.encryptBytes(_plain, _password);
      expect(a.sublist(4, 32), isNot(b.sublist(4, 32)));
    });

    test('ghalat password => BackupCryptoException', () async {
      expect(
        () => BackupCrypto.decryptBytes(base64Decode(_javaIbb1), 'wrong-password'),
        throwsA(isA<BackupCryptoException>()),
      );
    });

    test('tamper / kharab file => BackupCryptoException (GCM tag)', () async {
      final enc = Uint8List.fromList(await BackupCrypto.encryptBytes(_plain, _password));
      enc[enc.length - 20] ^= 0x01; // ciphertext ka ek bit
      expect(() => BackupCrypto.decryptBytes(enc, _password), throwsA(isA<BackupCryptoException>()));
    });

    test('magic ghalat / bahut chhoti file => BackupCryptoException', () async {
      expect(() => BackupCrypto.decryptBytes(Uint8List.fromList([1, 2, 3, 4, 5]), _password),
          throwsA(isA<BackupCryptoException>()));
      final trunc = base64Decode(_javaIbb1).sublist(0, 30);
      expect(() => BackupCrypto.decryptBytes(trunc, _password), throwsA(isA<BackupCryptoException>()));
    });

    test('legacy: ghalat password => BackupCryptoException', () async {
      expect(() => BackupCrypto.decryptLegacyCbc(base64Decode(_javaLegacy), 'nope-nope'),
          throwsA(isA<BackupCryptoException>()));
    });
  });

  group('BackupPasswordStore', () {
    test('random password 16 alnum, har baar alag', () {
      final a = BackupPasswordStore.generateRandomPassword();
      final b = BackupPasswordStore.generateRandomPassword();
      expect(a.length, 16);
      expect(RegExp(r'^[A-Za-z0-9]{16}$').hasMatch(a), isTrue);
      expect(a, isNot(b));
      expect(BackupPasswordStore.minLength, 8);
    });
  });

  group('BackupExport CSV', () {
    Product prod() => Product.fromMap({
          'barcode': '111',
          'name': 'Sugar, "Fine"',
          'category': 'Grocery',
          'cost': 100.0,
          'salePrice': 120.0,
          'stock': 12.0,
          'unit': 'pcs',
        });

    BackupData data() => BackupData(
          dayBook: const [DayBookRow(1700000000000, 'Sale', 'INV-1', 'Walk-in', 500, 400, 'active')],
          sales: const [BillRow(1700000000000, 'INV-1', 'Walk-in', 500, 400, 'active')],
          purchases: const [],
          customers: const [PartyRow(1, 'Ali', '0300', 10, 250.5, 3)],
          customerLedgers: const {
            1: [BillRow(1700000000000, 'INV-1', '', 500, 400, 'active')],
          },
          suppliers: const [PartyRow(2, 'Bilal', '0311', 0, 99, 0)],
          supplierLedgers: const {},
          products: [prod()],
          expenses: const [ExpenseRow(1700000000000, 'Rent', 'Shop, rent', 1000)],
          cashTx: const [CashRow(1700000000000, 'IN', 'cash', 400, 'sale')],
          totals: const BackupTotals(
              totalSales: 500, totalPurchases: 0, totalExpenses: 1000, receivables: 250.5, payables: 99, stockValue: 1200),
        );

    test('csvEscape: comma / quote / newline', () {
      expect(BackupExport.csvEscape('plain'), 'plain');
      expect(BackupExport.csvEscape('a,b'), '"a,b"');
      expect(BackupExport.csvEscape('say "hi"'), '"say ""hi"""');
      expect(BackupExport.csvEscape('l1\nl2'), '"l1\nl2"');
    });

    test('sab sections aur 2-decimal raqam, UTF-8 BOM', () {
      final csv = BackupExport.buildCsv(data());
      expect(csv.startsWith('\uFEFF'), isTrue);
      for (final s in [
        'BUSINESS SUMMARY', 'DAY BOOK', 'SALES', 'PURCHASES', 'CUSTOMERS', 'CUSTOMER LEDGERS',
        'SUPPLIERS', 'SUPPLIER LEDGERS', 'PRODUCTS & STOCK', 'EXPENSES', 'CASH / BANK TRANSACTIONS',
      ]) {
        expect(csv, contains('=== $s ==='));
      }
      expect(csv, contains('Total Sales (period),500.00'));
      expect(csv, contains('Stock Value (current),1200.00'));
      expect(csv, contains('Ali,0300,10.00,250.50,3.00'));
      expect(csv, contains('Customer:,Ali'));
      expect(csv, contains('"Sugar, ""Fine"""'));
      expect(csv, contains('"Shop, rent"'));
    });

    test('rangeText: all-time vs range', () {
      expect(BackupExport.rangeText(0, kAllTimeEnd), 'All Time');
      final s = DateTime(2026, 1, 5).millisecondsSinceEpoch;
      final e = DateTime(2026, 1, 9, 23, 59).millisecondsSinceEpoch;
      expect(BackupExport.rangeText(s, e), '05 Jan 2026  -  09 Jan 2026');
    });
  });
}
