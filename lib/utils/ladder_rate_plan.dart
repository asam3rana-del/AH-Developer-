import '../models/product.dart';

/// Ek rate/qty ka badlaav: purani -> nayi qeemat (dialog mein dikhane aur apply karne ke liye).
class LadderRateChange {
  final String labelEn;
  final String labelUr;
  final double oldValue;
  final double newValue;
  const LadderRateChange(this.labelEn, this.labelUr, this.oldValue, this.newValue);
}

/// Unit ladder badalne (jaise ctn/outer/dabbi se sirf outer/dabbi) par rates ka plan.
///
/// Cost aur sab rates PRIMARY unit ke hisaab se save hote hain. Primary unit badle to
/// `rate / purani factor * nayi factor` (factor = primary mein sab se chhoti unit ki ginti) naya rate hai,
/// aur bulk min qty ulti taraf (qty / (nayi factor / purani factor)).
///
/// Sirf wo fields badalti hain jo user ne form mein khud nahi chhuin (form ki value == purani saved value),
/// aur sirf tab jab sab se chhoti unit wahi rahe (warna conversion ka koi pakka hisab nahi: [convertible] false).
class LadderRatePlan {
  /// false => sab se chhoti unit badal gayi / factor maloom nahi: rates khud check karne hongi.
  final bool convertible;
  final List<LadderRateChange> changes;
  final double ratio; // nayi factor / purani factor
  final double? _cost;
  final double? _sale;
  final double? _wholesale;
  final double? _shopkeeper;
  final double? _bulk;
  final double? _wBulk;
  final double? _bulkQty;
  final double? _wBulkQty;

  const LadderRatePlan._(
    this.convertible,
    this.changes,
    this.ratio,
    this._cost,
    this._sale,
    this._wholesale,
    this._shopkeeper,
    this._bulk,
    this._wBulk,
    this._bulkQty,
    this._wBulkQty,
  );

  static double _round2(double v) => (v * 100).round() / 100;

  /// null = koi rate badalne ki zaroorat nahi (ladder wahi hai, ya primary ki ginti barabar hai).
  static LadderRatePlan? build(Product existing, Product draft) {
    if (!rescaleStockForLadderChange(existing, draft).changed) return null;

    final sameSmallest = existing.smallestUnitName().trim().toLowerCase() ==
        draft.smallestUnitName().trim().toLowerCase();
    final oldF = existing.smallestUnitFactor();
    final newF = draft.smallestUnitFactor();
    if (!sameSmallest || oldF <= 0 || newF <= 0) {
      return const LadderRatePlan._(false, [], 1.0, null, null, null, null, null, null, null, null);
    }
    if ((newF - oldF).abs() < 1e-9) return null; // primary ki ginti barabar: rates wahi theek hain

    final ratio = newF / oldF;
    final changes = <LadderRateChange>[];

    double? rate(String en, String ur, double typed, double saved) {
      if (saved <= 0 || typed != saved) return null; // khali ya user ne khud likhi
      final v = _round2(saved * ratio);
      if (v == saved) return null;
      changes.add(LadderRateChange(en, ur, saved, v));
      return v;
    }

    double? qty(String en, String ur, double typed, double saved) {
      if (saved <= 0 || typed != saved) return null;
      final v = _round2(saved / ratio);
      if (v <= 0 || v == saved) return null;
      changes.add(LadderRateChange(en, ur, saved, v));
      return v;
    }

    final cost = rate('Purchase rate', 'خریداری ریٹ', draft.cost, existing.cost);
    final sale = rate('Retail sale rate', 'ریٹیل ریٹ', draft.salePrice, existing.salePrice);
    final wholesale = rate('Wholesale sale rate', 'ہول سیل ریٹ', draft.wholesalePrice, existing.wholesalePrice);
    final shopkeeper = rate('Shopkeeper rate', 'دکاندار ریٹ', draft.shopkeeperPrice, existing.shopkeeperPrice);
    final bulk = rate('Bulk rate', 'بلک ریٹ', draft.bulkPrice, existing.bulkPrice);
    final wBulk = rate('Wholesale bulk rate', 'ہول سیل بلک ریٹ', draft.wholesaleBulkPrice, existing.wholesaleBulkPrice);
    final bulkQty = qty('Bulk min qty', 'بلک کم از کم مقدار', draft.bulkMinQty, existing.bulkMinQty);
    final wBulkQty = qty('Wholesale bulk min qty', 'ہول سیل بلک کم از کم مقدار', draft.wholesaleBulkMinQty,
        existing.wholesaleBulkMinQty);

    if (changes.isEmpty) return null;
    return LadderRatePlan._(true, changes, ratio, cost, sale, wholesale, shopkeeper, bulk, wBulk, bulkQty, wBulkQty);
  }

  /// [p] (form se bana draft) par plan ke naye rates/qty laga kar wapas deta hai.
  Product apply(Product p) => p.copyWith(
        cost: _cost,
        salePrice: _sale,
        wholesalePrice: _wholesale,
        shopkeeperPrice: _shopkeeper,
        bulkPrice: _bulk,
        wholesaleBulkPrice: _wBulk,
        bulkMinQty: _bulkQty,
        wholesaleBulkMinQty: _wBulkQty,
      );
}
