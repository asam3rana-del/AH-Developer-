import 'package:flutter_test/flutter_test.dart';
import 'package:ah_developer_kiryana_store/models/return_entry.dart';

void main() {
  ReturnEntry e(int id, double a, {int rd = 0, int d = 0}) => ReturnEntry(id: id, amount: a, returnDate: rd, date: d);

  test('FIFO: sab se purani wapsi ki tarikh pehle', () {
    final r = settleEntriesFifo([e(1, 100, rd: 200), e(2, 50, rd: 100)], 60);
    expect(r.settled, 60);
    expect(r.remaining.map((x) => x.id), [1]); // entry 2 (purani date) poori gayi
    expect(returnEntriesTotal(r.remaining), 90);
  });

  test('poori entry settle ho to list se nikal jati hai', () {
    final r = settleEntriesFifo([e(1, 100), e(2, 50, rd: 5)], 50);
    expect(r.remaining.map((x) => x.id), [1]);
    expect(r.settled, 50);
  });

  test('zyada raqam kul tak hi settle hoti hai', () {
    final r = settleEntriesFifo([e(1, 100)], 500);
    expect(r.settled, 100);
    expect(r.remaining, isEmpty);
  });
}
