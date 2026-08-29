/// Mirrors `data class Category` (table: categories, PK: name).
class Category {
  final String name;
  const Category(this.name);
  Map<String, Object?> toMap() => {'name': name};
  factory Category.fromMap(Map<String, Object?> m) => Category(m['name'] as String);
}

/// Mirrors `data class UnitType` (table: units, PK: name).
class UnitType {
  final String name;
  const UnitType(this.name);
  Map<String, Object?> toMap() => {'name': name};
  factory UnitType.fromMap(Map<String, Object?> m) => UnitType(m['name'] as String);
}
