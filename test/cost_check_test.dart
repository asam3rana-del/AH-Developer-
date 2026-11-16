import 'package:flutter_test/flutter_test.dart';
import 'package:ah_developer_kiryana_store/db/cost_check_repository.dart';

void main() {
  test('average cost close to last purchase is fine', () {
    expect(isCostDrifted(9370, 9370), isFalse);
    expect(isCostDrifted(9500, 9370), isFalse);
    expect(isCostDrifted(9000, 9370), isFalse);
  });

  test('average cost far above last purchase is drifted (sale shows loss)', () {
    // صوفی گھی: avg 1152/kg x 16 vs last 585.63/kg x 16
    expect(isCostDrifted(18432, 9370), isTrue);
  });

  test('average cost far below last purchase is drifted', () {
    expect(isCostDrifted(4000, 9370), isTrue);
    expect(isCostDrifted(0, 9370), isTrue);
  });

  test('no purchase rate = nothing to compare', () {
    expect(isCostDrifted(18432, 0), isFalse);
    expect(isCostDrifted(18432, double.nan), isFalse);
  });
}
