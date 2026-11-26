import 'package:flutter_test/flutter_test.dart';
import 'package:ah_developer_kiryana_store/sync/firestore_rest.dart';

void main() {
  group('FirestoreRest value codec (PC sync)', () {
    test('round trip keeps int / double / string / bool / null / list / map', () {
      final input = <String, Object?>{
        'i': 42,
        'd': 12.5,
        'whole': 100.0,
        's': 'Ali Mobiles',
        'b': true,
        'n': null,
        'list': [1, 'x', 2.5],
        'appliedOps': {'dev-1-123': 1700000000000, 'dev-2-9': 5},
      };
      final enc = encodeFields(input);
      expect(enc['i'], {'integerValue': '42'});
      expect(enc['whole'], {'doubleValue': 100.0});
      final dec = decodeFields(enc);
      expect(dec['i'], 42);
      expect(dec['i'], isA<int>());
      expect(dec['d'], 12.5);
      expect(dec['whole'], isA<double>());
      expect(dec['s'], 'Ali Mobiles');
      expect(dec['b'], true);
      expect(dec.containsKey('n'), isTrue);
      expect(dec['n'], isNull);
      expect(dec['list'], [1, 'x', 2.5]);
      expect(dec['appliedOps'], {'dev-1-123': 1700000000000, 'dev-2-9': 5});
    });

    test('REST integerValue string and timestamp decode', () {
      expect(decodeValue({'integerValue': '1700000000000'}), 1700000000000);
      expect(decodeValue({'timestampValue': '2026-11-24T10:00:00Z'}),
          DateTime.utc(2026, 11, 24, 10).millisecondsSinceEpoch);
      expect(decodeValue({'doubleValue': 'NaN'}), isNaN);
    });

    test('merge field paths quote odd names and go into nested maps', () {
      expect(quoteFieldSegment('updatedAt'), 'updatedAt');
      expect(quoteFieldSegment('dev-1-2'), '`dev-1-2`');
      final paths = mergeFieldPaths({
        'name': 'x',
        'meta': {'a-b': 1, 'c': 2},
        'empty': <String, Object?>{},
      });
      expect(paths, containsAll(['name', 'meta.`a-b`', 'meta.c', 'empty']));
      expect(paths.length, 4);
    });

    test('error codes map like the Firebase SDK', () {
      expect(restCodeFromStatus('PERMISSION_DENIED', 403), 'permission-denied');
      expect(restCodeFromStatus(null, 429), 'resource-exhausted');
      expect(restCodeFromStatus('ABORTED', 409), 'aborted');
      expect(restCodeFromStatus(null, 503), 'unavailable');
      expect(authCodeFromMessage('OPERATION_NOT_ALLOWED : sign-in disabled'), 'operation-not-allowed');
      expect(authCodeFromMessage('TOKEN_EXPIRED'), 'user-token-invalid');
    });

    test('filters build REST fieldFilter json', () {
      final f = const RestFilter('branchId', 'EQUAL', 'rana-ayann').toJson();
      expect(f, {
        'fieldFilter': {
          'field': {'fieldPath': 'branchId'},
          'op': 'EQUAL',
          'value': {'stringValue': 'rana-ayann'},
        }
      });
    });
  });
}
