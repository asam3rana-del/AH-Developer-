/// Dart port of `data class Product` (Database.kt) plus the 3-tier unit
/// conversion helpers (`unitLadder`, `toSmallestUnits`, `fromSmallestUnits`,
/// `smallestUnitName`, `formatStockBreakdown`, `isValidSmallestQty`).
/// Table name: products. Primary key: barcode.
class Product {
  final String barcode;
  final String name;
  final String category;
  final double cost;
  final double salePrice;
  final double stock;
  final double reorderLevel;
  final String expiry;
  final String unit;
  final int unitSize;
  final String unitNote;
  final String secondaryUnit;
  final double secondaryUnitQty;
  final double wholesalePrice;
  /// Shopkeeper (bilkul kam margin) rate, primary unit par. 0 = set nahi => wholesale rate istemal hota hai.
  final double shopkeeperPrice;
  /// Retail grahak ke liye bulk rate (0 = nahi) aur kam az kam miqdar (primary unit mein; 0 = nahi).
  final double bulkPrice;
  final double bulkMinQty;
  final double wholesaleBulkPrice;
  final double wholesaleBulkMinQty;
  final double openingStock;
  final String tertiaryUnit;
  final double tertiaryUnitQty;
  final int updatedAt;
  final bool dirty;

  final String searchTag;

  /// Manual default-unit override for the Sale screen: index into the
  /// product's unit list as shown in Sale (0 = primary, 1 = secondary,
  /// 2 = tertiary). -1 = Auto (see `autoDefaultUnitIndexFor`). Mirrors
  /// Product.defaultUnitIndex in Database.kt.
  final int defaultUnitIndex;

  /// Same idea as [defaultUnitIndex] but used only by the Quick Sale dialog.
  /// Mirrors Product.quickSaleDefaultUnitIndex in Database.kt.
  final int quickSaleDefaultUnitIndex;

  const Product({
    required this.barcode,
    required this.name,
    this.category = '',
    this.cost = 0.0,
    this.salePrice = 0.0,
    this.stock = 0.0,
    this.reorderLevel = 0.0,
    this.expiry = '',
    this.unit = 'pcs',
    this.unitSize = 1,
    this.unitNote = '',
    this.secondaryUnit = '',
    this.secondaryUnitQty = 0.0,
    this.wholesalePrice = 0.0,
    this.shopkeeperPrice = 0.0,
    this.bulkPrice = 0.0,
    this.bulkMinQty = 0.0,
    this.wholesaleBulkPrice = 0.0,
    this.wholesaleBulkMinQty = 0.0,
    this.openingStock = 0.0,
    this.tertiaryUnit = '',
    this.tertiaryUnitQty = 0.0,
    this.updatedAt = 0,
    this.dirty = true,
    this.searchTag = '',
    this.defaultUnitIndex = -1,
    this.quickSaleDefaultUnitIndex = -1,
  });

  Product copyWith({
    String? searchTag,
    int? defaultUnitIndex,
    int? quickSaleDefaultUnitIndex,
    String? barcode,
    String? name,
    String? category,
    double? cost,
    double? salePrice,
    double? stock,
    double? reorderLevel,
    String? expiry,
    String? unit,
    int? unitSize,
    String? unitNote,
    String? secondaryUnit,
    double? secondaryUnitQty,
    double? wholesalePrice,
    double? shopkeeperPrice,
    double? bulkPrice,
    double? bulkMinQty,
    double? wholesaleBulkPrice,
    double? wholesaleBulkMinQty,
    double? openingStock,
    String? tertiaryUnit,
    double? tertiaryUnitQty,
    int? updatedAt,
    bool? dirty,
  }) {
    return Product(
      barcode: barcode ?? this.barcode,
      name: name ?? this.name,
      category: category ?? this.category,
      cost: cost ?? this.cost,
      salePrice: salePrice ?? this.salePrice,
      stock: stock ?? this.stock,
      reorderLevel: reorderLevel ?? this.reorderLevel,
      expiry: expiry ?? this.expiry,
      unit: unit ?? this.unit,
      unitSize: unitSize ?? this.unitSize,
      unitNote: unitNote ?? this.unitNote,
      secondaryUnit: secondaryUnit ?? this.secondaryUnit,
      secondaryUnitQty: secondaryUnitQty ?? this.secondaryUnitQty,
      wholesalePrice: wholesalePrice ?? this.wholesalePrice,
      shopkeeperPrice: shopkeeperPrice ?? this.shopkeeperPrice,
      bulkPrice: bulkPrice ?? this.bulkPrice,
      bulkMinQty: bulkMinQty ?? this.bulkMinQty,
      wholesaleBulkPrice: wholesaleBulkPrice ?? this.wholesaleBulkPrice,
      wholesaleBulkMinQty: wholesaleBulkMinQty ?? this.wholesaleBulkMinQty,
      openingStock: openingStock ?? this.openingStock,
      tertiaryUnit: tertiaryUnit ?? this.tertiaryUnit,
      tertiaryUnitQty: tertiaryUnitQty ?? this.tertiaryUnitQty,
      updatedAt: updatedAt ?? this.updatedAt,
      dirty: dirty ?? this.dirty,
        searchTag: searchTag ?? this.searchTag,
        defaultUnitIndex: defaultUnitIndex ?? this.defaultUnitIndex,
        quickSaleDefaultUnitIndex: quickSaleDefaultUnitIndex ?? this.quickSaleDefaultUnitIndex,
    );
  }

  Map<String, Object?> toMap() => {
        'barcode': barcode,
        'name': name,
        'category': category,
        'cost': cost,
        'salePrice': salePrice,
        'stock': stock,
        'reorderLevel': reorderLevel,
        'expiry': expiry,
        'unit': unit,
        'unitSize': unitSize,
        'unitNote': unitNote,
        'secondaryUnit': secondaryUnit,
        'secondaryUnitQty': secondaryUnitQty,
        'wholesalePrice': wholesalePrice,
        'shopkeeperPrice': shopkeeperPrice,
        'bulkPrice': bulkPrice,
        'bulkMinQty': bulkMinQty,
        'wholesaleBulkPrice': wholesaleBulkPrice,
        'wholesaleBulkMinQty': wholesaleBulkMinQty,
        'openingStock': openingStock,
        'tertiaryUnit': tertiaryUnit,
        'tertiaryUnitQty': tertiaryUnitQty,
        'updatedAt': updatedAt,
        'dirty': dirty ? 1 : 0,
        'searchTag': searchTag,
        'defaultUnitIndex': defaultUnitIndex,
        'quickSaleDefaultUnitIndex': quickSaleDefaultUnitIndex,
      };

  factory Product.fromMap(Map<String, Object?> m) => Product(
        barcode: m['barcode'] as String,
        name: m['name'] as String,
        category: (m['category'] as String?) ?? '',
        cost: (m['cost'] as num?)?.toDouble() ?? 0.0,
        salePrice: (m['salePrice'] as num?)?.toDouble() ?? 0.0,
        stock: (m['stock'] as num?)?.toDouble() ?? 0.0,
        reorderLevel: (m['reorderLevel'] as num?)?.toDouble() ?? 0.0,
        expiry: (m['expiry'] as String?) ?? '',
        unit: (m['unit'] as String?) ?? 'pcs',
        unitSize: (m['unitSize'] as num?)?.toInt() ?? 1,
        unitNote: (m['unitNote'] as String?) ?? '',
        secondaryUnit: (m['secondaryUnit'] as String?) ?? '',
        secondaryUnitQty: (m['secondaryUnitQty'] as num?)?.toDouble() ?? 0.0,
        wholesalePrice: (m['wholesalePrice'] as num?)?.toDouble() ?? 0.0,
        shopkeeperPrice: (m['shopkeeperPrice'] as num?)?.toDouble() ?? 0.0,
        bulkPrice: (m['bulkPrice'] as num?)?.toDouble() ?? 0.0,
        bulkMinQty: (m['bulkMinQty'] as num?)?.toDouble() ?? 0.0,
        wholesaleBulkPrice: (m['wholesaleBulkPrice'] as num?)?.toDouble() ?? 0.0,
        wholesaleBulkMinQty: (m['wholesaleBulkMinQty'] as num?)?.toDouble() ?? 0.0,
        openingStock: (m['openingStock'] as num?)?.toDouble() ?? 0.0,
        tertiaryUnit: (m['tertiaryUnit'] as String?) ?? '',
        tertiaryUnitQty: (m['tertiaryUnitQty'] as num?)?.toDouble() ?? 0.0,
        updatedAt: (m['updatedAt'] as num?)?.toInt() ?? 0,
        dirty: (m['dirty'] as int?) == 1,
        searchTag: (m['searchTag'] as String?) ?? '',
        defaultUnitIndex: (m['defaultUnitIndex'] as num?)?.toInt() ?? -1,
        quickSaleDefaultUnitIndex: (m['quickSaleDefaultUnitIndex'] as num?)?.toInt() ?? -1,
      );
}

/// One tier of a product's unit ladder — mirrors ProductUnitTier in
/// Database.kt.
class ProductUnitTier {
  final String unit;
  final double smallestPerUnit;
  const ProductUnitTier(this.unit, this.smallestPerUnit);
}

bool _sameUnit(String a, String b) =>
    a.trim().isNotEmpty &&
    b.trim().isNotEmpty &&
    a.trim().toLowerCase() == b.trim().toLowerCase();

extension ProductUnitLogic on Product {
  /// Ordered ladder of this product's units, SMALLEST first. Mirrors
  /// Product.unitLadder() in Database.kt exactly (including the graceful
  /// degrade when tertiary is set without a valid secondary).
  List<ProductUnitTier> unitLadder() {
    final hasSecondary = secondaryUnit.trim().isNotEmpty && secondaryUnitQty > 0;
    final hasTertiary =
        hasSecondary && tertiaryUnit.trim().isNotEmpty && tertiaryUnitQty > 0;

    if (!hasSecondary) {
      return [ProductUnitTier(unit, 1.0)];
    }
    if (!hasTertiary) {
      return [
        ProductUnitTier(secondaryUnit, 1.0),
        ProductUnitTier(unit, secondaryUnitQty),
      ];
    }
    return [
      ProductUnitTier(tertiaryUnit, 1.0),
      ProductUnitTier(secondaryUnit, tertiaryUnitQty),
      ProductUnitTier(unit, secondaryUnitQty * tertiaryUnitQty),
    ];
  }

  double smallestUnitFactor() => unitLadder().last.smallestPerUnit;

  double smallestPerSecondary() {
    for (final t in unitLadder()) {
      if (_sameUnit(t.unit, secondaryUnit)) return t.smallestPerUnit;
    }
    return 1.0;
  }

  /// How many smallest-units make up one [unitName]. Mirrors
  /// `smallestPerUnitOf()` in Database.kt.
  double smallestPerUnitOf(String unitName) {
    for (final t in unitLadder()) {
      if (_sameUnit(t.unit, unitName)) return t.smallestPerUnit;
    }
    return 1.0;
  }

  /// Converts a rate/price entered per [fromUnit] into the equivalent rate
  /// per the product's PRIMARY unit (e.g. Rs per pcs -> Rs per carton).
  /// Mirrors `toPrimaryUnitRate()` in Database.kt.
  double toPrimaryUnitRate(double entered, String fromUnit) {
    final perFromUnit = smallestPerUnitOf(fromUnit);
    if (perFromUnit <= 0) return entered;
    return entered * (smallestUnitFactor() / perFromUnit);
  }

  /// Reverse of [toPrimaryUnitRate]: converts a primary-unit rate down to
  /// [chosenUnit]. Mirrors `fromPrimaryUnitRate()` in Database.kt.
  double fromPrimaryUnitRate(double mainRate, String chosenUnit) {
    final perChosenUnit = smallestPerUnitOf(chosenUnit);
    final factor = perChosenUnit > 0 ? smallestUnitFactor() / perChosenUnit : 1.0;
    return factor > 0 ? mainRate / factor : mainRate;
  }

  String smallestUnitName() => unitLadder().first.unit;

  /// Converts [qty] entered in [enteredUnit] into the product's
  /// smallest-unit basis (the same basis `stock` is stored in).
  double toSmallestUnits(double qty, String enteredUnit) {
    final ladder = unitLadder();
    ProductUnitTier tier = ladder.last;
    for (final t in ladder) {
      if (_sameUnit(t.unit, enteredUnit)) {
        tier = t;
        break;
      }
    }
    return qty * tier.smallestPerUnit;
  }

  /// Reverse of [toSmallestUnits].
  double fromSmallestUnits(double smallestQty, String targetUnit) {
    final ladder = unitLadder();
    ProductUnitTier tier = ladder.last;
    for (final t in ladder) {
      if (_sameUnit(t.unit, targetUnit)) {
        tier = t;
        break;
      }
    }
    return tier.smallestPerUnit > 0 ? smallestQty / tier.smallestPerUnit : smallestQty;
  }

  /// True agar is product ki sab se chhoti unit continuous/weight/volume hai
  /// (Gram, ml, kg, litre, tola, maund...) aur is liye fractional stock rakh sakti hai.
  /// Mirrors Product.isFractionalUnit() in Database.kt.
  bool isFractionalUnit() =>
      _fractionalUnitNames.contains(smallestUnitName().trim().toLowerCase());

  /// A product's qty (already converted via [toSmallestUnits]) must be a whole
  /// number unless the smallest unit is fractional — mirrors
  /// isValidSmallestQty() in Database.kt.
  bool isValidSmallestQty(double smallestQty) {
    if (isFractionalUnit()) return true;
    return (smallestQty - smallestQty.roundToDouble()).abs() < 0.0001;
  }

  /// Human-readable stock breakdown, e.g. "1 carton 2 box 1 pcs" — mirrors
  /// formatStockBreakdown() in Database.kt (same unitLadder, largest -> smallest;
  /// smallest tier fractional ho sakti hai, 3 decimals tak; zero stock par
  /// sab se chhoti unit: "0 pcs").
  String formatStockBreakdown() {
    final ladder = unitLadder();
    if (ladder.length == 1) return '${_trimZero(stock)} ${ladder[0].unit}';

    final largestToSmallest = ladder.reversed.toList();
    // Minus stock bhi dikhao ("-4 Kg"), warna multi-unit item par "0 Gram" nazar aata aur masla chhup jata.
    final negative = stock < 0;
    var remaining = stock.abs();
    final parts = <String>[];

    for (var i = 0; i < largestToSmallest.length; i++) {
      final tier = largestToSmallest[i];
      final isSmallestTier = i == largestToSmallest.length - 1;
      if (isSmallestTier) {
        if (remaining > 0) parts.add('${_trimZero(remaining)} ${tier.unit}');
      } else {
        final count = (remaining / tier.smallestPerUnit).floorToDouble();
        remaining -= count * tier.smallestPerUnit;
        if (count > 0) parts.add('${count.toInt()} ${tier.unit}');
      }
    }

    if (parts.isEmpty) return '0 ${smallestUnitName()}';
    return '${negative ? '-' : ''}${parts.join(' ')}';
  }
}

const Set<String> _fractionalUnitNames = {
  'gram', 'grams', 'gm', 'g', 'kg', 'kilogram', 'kilograms',
  'ml', 'milliliter', 'millilitre', 'litre', 'liter', 'l',
  'tola', 'maund',
};

/// Kotlin `trimZero()`: poora number ho to bina decimal, warna 3 decimals tak
/// (0.30000000000000004 -> "0.3").
String _trimZero(double value) {
  if (value == value.roundToDouble()) return value.toInt().toString();
  var t = value.toStringAsFixed(3);
  t = t.replaceFirst(RegExp(r'0+$'), '');
  t = t.replaceFirst(RegExp(r'\.$'), '');
  return t;
}

/// Unit ladder badalne par stock ka natija — [rescaleStockForLadderChange].
class StockRescale {
  final bool changed;
  final double stock;
  final double openingStock;
  const StockRescale(this.changed, this.stock, this.openingStock);
}

/// Kotlin ProductActivity.saveProduct "unit-ladder rescale bug" fix: `stock`/`openingStock`
/// sab se chhoti unit ki raw ginti hain. Edit mein secondary/tertiary/primary badle to
/// PURANA stock pehle purani primary unit mein likha jata hai, phir NAYI ladder ki sab se
/// chhoti unit mein (warna 6 Petti achanak 6 Pcs ban jata hai). Ladder na badli ho to
/// stock jaisa tha waisa.
StockRescale rescaleStockForLadderChange(Product existing, Product newDraft) {
  double q(String unit, double qty) => unit.trim().isEmpty ? 0.0 : qty;
  final changed = existing.unit != newDraft.unit ||
      existing.secondaryUnit != newDraft.secondaryUnit ||
      q(existing.secondaryUnit, existing.secondaryUnitQty) !=
          q(newDraft.secondaryUnit, newDraft.secondaryUnitQty) ||
      existing.tertiaryUnit != newDraft.tertiaryUnit ||
      q(existing.tertiaryUnit, existing.tertiaryUnitQty) !=
          q(newDraft.tertiaryUnit, newDraft.tertiaryUnitQty);
  if (!changed) return StockRescale(false, existing.stock, existing.openingStock);

  final oldPrimaryStock = existing.fromSmallestUnits(existing.stock, existing.unit);
  final oldPrimaryOpening = existing.fromSmallestUnits(existing.openingStock, existing.unit);
  return StockRescale(
    true,
    newDraft.toSmallestUnits(oldPrimaryStock, existing.unit),
    newDraft.toSmallestUnits(oldPrimaryOpening, existing.unit),
  );
}

extension ProductSearch on Product {
  /// Mirrors Product.matchesQuery() in Database.kt: har typed lafz
  /// `name + searchTag` mein kahin hona chahiye (koi bhi tarteeb).
  bool matchesQuery(String query) {
    final q = query.trim();
    if (q.isEmpty) return true;
    final haystack = '$name $searchTag'.toLowerCase();
    final terms = q.toLowerCase().split(RegExp(r'\s+')).where((t) => t.isNotEmpty);
    return terms.every(haystack.contains);
  }
}
