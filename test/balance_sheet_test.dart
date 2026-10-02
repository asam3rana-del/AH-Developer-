import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/db/balance_sheet_repository.dart';
import 'package:ah_developer_kiryana_store/models/product.dart';

BalanceSheetFigures sheet({
  double cashIn = 0,
  double cashOut = 0,
  double bankIn = 0,
  double bankOut = 0,
  double stock = 0,
  double recv = 0,
  double advSup = 0,
  double pay = 0,
  double advCus = 0,
  double sales = 0,
  double cogs = 0,
  double exp = 0,
}) =>
    buildBalanceSheet(
      cashIn: cashIn,
      cashOut: cashOut,
      bankIn: bankIn,
      bankOut: bankOut,
      stockValue: stock,
      receivables: recv,
      advancePaidToSuppliers: advSup,
      payables: pay,
      advanceFromCustomers: advCus,
      sales: sales,
      cogs: cogs,
      expenses: exp,
    );

typedef Bill = ({String id, String status, double total, double paid});
typedef Pay = ({String reference, String billReference, double amount});

Bill bill(String id, double total, double paid, {String status = 'active'}) =>
    (id: id, status: status, total: total, paid: paid);
Pay pay(double amount, {String ref = 'manual-x', String billRef = ''}) =>
    (reference: ref, billReference: billRef, amount: amount);

void main() {
  test('assets, liabilities and profit add up', () {
    final f = sheet(
        cashIn: 1000, cashOut: 200, bankIn: 500, bankOut: 100, stock: 300, recv: 150, advSup: 50, pay: 400, advCus: 20,
        sales: 2000, cogs: 1200, exp: 100);
    expect(f.cashInHand, 800);
    expect(f.bankBalance, 400);
    expect(f.totalAssets, 800 + 400 + 300 + 150 + 50);
    expect(f.totalLiabilities, 420);
    expect(f.netProfit, 700); // (2000-1200)-100
    expect(f.capital, f.totalAssets - f.totalLiabilities - 700);
  });

  test('Liabilities + Capital always equals Assets (balancing figure)', () {
    final f = sheet(cashIn: 77, stock: 13.5, recv: 9, pay: 4, sales: 50, cogs: 70, exp: 3);
    expect(f.totalLiabilitiesAndCapital, closeTo(f.totalAssets, 1e-9));
  });

  test('negative cash or bank is flagged; tiny rounding noise is not', () {
    expect(sheet(cashIn: 10, cashOut: 20).cashOrBankNegative, isTrue);
    expect(sheet(bankIn: 10, bankOut: 20).cashOrBankNegative, isTrue);
    expect(sheet(cashIn: 10, cashOut: 10.005).cashOrBankNegative, isFalse);
  });

  test('stock value divides cost by smallest-unit factor (not stock * cost)', () {
    // 1 carton = 12 pcs, cost Rs 1200 per carton, stock 24 pcs => 24 * 100 = 2400 (not 24 * 1200)
    final p = Product(
      barcode: '1',
      name: 'Soap',
      unit: 'carton',
      secondaryUnit: 'pcs',
      secondaryUnitQty: 12,
      cost: 1200,
      stock: 24,
    );
    expect(p.smallestUnitFactor(), 12);
    expect(stockValueAtCost([p]), 2400);
  });

  test('true balance = unreturned (total-paid) minus stand-alone payments', () {
    final l = PartyLedger(
      storedBalance: 0,
      bills: [bill('A', 1000, 400), bill('B', 500, 500, status: 'returned')],
      payments: [pay(100)],
    );
    expect(trueBalance(l), 500); // 600 owed - 100 paid separately
  });

  test('payment already inside a bill is not subtracted twice', () {
    final l = PartyLedger(
      storedBalance: 0,
      bills: [bill('A', 1000, 400)],
      payments: [pay(150, billRef: 'A'), pay(50, ref: 'A')],
    );
    expect(trueBalance(l), 600);
  });

  test('bill-linked payment of a RETURNED bill is still not subtracted (Kotlin fix)', () {
    final l = PartyLedger(
      storedBalance: 0,
      bills: [bill('A', 1000, 1000, status: 'returned')],
      payments: [pay(300, billRef: 'A')],
    );
    expect(trueBalance(l), 0);
  });

  test('drift counts only parties whose stored balance differs', () {
    final ok = PartyLedger(storedBalance: 600, bills: [bill('A', 1000, 400)], payments: const []);
    final bad = PartyLedger(storedBalance: 0, bills: [bill('B', 1000, 400)], payments: const []);
    expect(countBalanceDrift([ok, bad]), 1);
    expect(countBalanceDrift([ok]), 0);
  });
}
