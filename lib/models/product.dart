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
  final double openingStock;
  final String tertiaryUnit;
  final double tertiaryUnitQty;
  final int updatedAt;
  final bool dirty;

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
    this.openingStock = 0.0,
    this.tertiaryUnit = '',
    this.tertiaryUnitQty = 0.0,
    this.updatedAt = 0,
    this.dirty = true,
  });

  Product copyWith({
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
      openingStock: openingStock ?? this.openingStock,
      tertiaryUnit: tertiaryUnit ?? this.tertiaryUnit,
      tertiaryUnitQty: tertiaryUnitQty ?? this.tertiaryUnitQty,
      updatedAt: updatedAt ?? this.updatedAt,
      dirty: dirty ?? this.dirty,
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
        'openingStock': openingStock,
        'tertiaryUnit': tertiaryUnit,
        'tertiaryUnitQty': tertiaryUnitQty,
        'updatedAt': updatedAt,
        'dirty': dirty ? 1 : 0,
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
        openingStock: (m['openingStock'] as num?)?.toDouble() ?? 0.0,
        tertiaryUnit: (m['tertiaryUnit'] as String?) ?? '',
        tertiaryUnitQty: (m['tertiaryUnitQty'] as num?)?.toDouble() ?? 0.0,
        updatedAt: (m['updatedAt'] as num?)?.toInt() ?? 0,
        dirty: (m['dirty'] as int?) == 1,
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

  /// A new product's opening stock must resolve to a whole smallest-unit
  /// qty unless the smallest unit is fractional (Gram/ml) — mirrors
  /// isValidSmallestQty() used by ProductActivity's save validation.
  bool isValidSmallestQty(double smallestQty) {
    final smallest = smallestUnitName().trim().toLowerCase();
    final fractional = {'gram', 'grams', 'g', 'gm', 'ml', 'milliliter', 'millilitre'};
    if (fractional.contains(smallest)) return true;
    return smallestQty == smallestQty.roundToDouble();
  }

  /// Human-readable "12 box (144 pcs)" style breakdown — mirrors
  /// formatStockBreakdown() in Database.kt.
  String formatStockBreakdown() {
    final ladder = unitLadder();
    if (ladder.length == 1) {
      return '${_trimNum(stock)} $unit';
    }
    final primaryTier = ladder.last;
    final wholePrimary = (stock / primaryTier.smallestPerUnit).floor();
    final remainderSmallest = stock - (wholePrimary * primaryTier.smallestPerUnit);

    final parts = <String>[];
    if (wholePrimary > 0) parts.add('$wholePrimary $unit');

    if (ladder.length == 3 && remainderSmallest > 0) {
      final secondaryTier = ladder[1];
      final wholeSecondary = (remainderSmallest / secondaryTier.smallestPerUnit).floor();
      final finalRemainder = remainderSmallest - (wholeSecondary * secondaryTier.smallestPerUnit);
      if (wholeSecondary > 0) parts.add('$wholeSecondary $secondaryUnit');
      if (finalRemainder > 0) parts.add('${_trimNum(finalRemainder)} ${ladder[0].unit}');
    } else if (remainderSmallest > 0) {
      parts.add('${_trimNum(remainderSmallest)} ${ladder[0].unit}');
    }

    if (parts.isEmpty) return '0 $unit';
    return parts.join(' ');
  }
}

String _trimNum(double value) {
  if (value == value.truncateToDouble()) return value.toInt().toString();
  return value.toString();
}
