import '../models/product.dart';

/// Bill ka rate-type: Retail / Wholesale / Shopkeeper (bilkul kam margin wala rate).
/// Customer par `rateType` tag ('' = bill ke sale type ke mutabiq) lagta hai.
enum RateMode { retail, wholesale, shopkeeper }

RateMode rateModeFromString(String? s) {
  switch ((s ?? '').trim().toLowerCase()) {
    case 'wholesale':
      return RateMode.wholesale;
    case 'shopkeeper':
      return RateMode.shopkeeper;
    default:
      return RateMode.retail;
  }
}

String rateModeName(RateMode m) => m.name; // 'retail' | 'wholesale' | 'shopkeeper'

/// Item ka primary-unit rate is mode ke liye. Shopkeeper rate set na ho to wholesale rate.
double basePriceFor(Product p, RateMode m) {
  switch (m) {
    case RateMode.retail:
      return p.salePrice;
    case RateMode.wholesale:
      return p.wholesalePrice;
    case RateMode.shopkeeper:
      return p.shopkeeperPrice > 0 ? p.shopkeeperPrice : p.wholesalePrice;
  }
}
