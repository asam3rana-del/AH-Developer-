/// Ek hi jagah: cost PRIMARY unit ka rate hota hai, stock SMALLEST unit mein — is liye
/// cost per smallest unit = cost / smallestUnitFactor. Pehle ye hisaab 9 jagah alag alag likha tha
/// (ek mein bhi factor bhoolne se bills par ghalat / inflated cost aata tha — Capstan ctn waqia).
///
/// Safety: factor <= 0 ya NaN => cost wahi (primary rate); cost NaN / infinite / negative => 0.
double costPerSmallestOf(double cost, double factor) {
  if (!cost.isFinite || cost < 0) return 0.0;
  if (!factor.isFinite || factor <= 0) return cost;
  return cost / factor;
}
