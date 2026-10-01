/// Kotlin `ItemsActivity.parseCsvLine` + `importRateListCsv` ka pure hissa.
/// Rate List CSV (Excel/Sheets mein edit hone ke baad) wapas parhna: har row ek product ki
/// unit / wholesale / retail / 2nd + 3rd unit. Product "Code" (barcode) column se match hota hai.

/// Ek CSV line ko fields mein todta hai; double-quote wale field mein comma ya "" (escaped quote) ho sakta hai.
List<String> parseCsvLine(String line) {
  final fields = <String>[];
  final cur = StringBuffer();
  var inQuotes = false;
  var i = 0;
  while (i < line.length) {
    final ch = line[i];
    if (inQuotes && ch == '"' && i + 1 < line.length && line[i + 1] == '"') {
      cur.write('"');
      i++;
    } else if (ch == '"') {
      inQuotes = !inQuotes;
    } else if (ch == ',' && !inQuotes) {
      fields.add(cur.toString());
      cur.clear();
    } else {
      cur.write(ch);
    }
    i++;
  }
  fields.add(cur.toString());
  return fields;
}

/// CSV ki ek data row. `null` field = "CSV mein khali/ghalat — product ki maujooda value rakho"
/// (Kotlin: `toDoubleOrNull() ?: existing...`). Secondary/tertiary unit khali ho to khali hi lagta hai (Kotlin jaisa).
class RateListRow {
  final String barcode;
  final String? unit;
  final double? wholesale;
  final double? retail;
  final String secondaryUnit;
  final double secondaryUnitQty;
  final String tertiaryUnit;
  final double tertiaryUnitQty;
  const RateListRow({
    required this.barcode,
    this.unit,
    this.wholesale,
    this.retail,
    this.secondaryUnit = '',
    this.secondaryUnitQty = 0.0,
    this.tertiaryUnit = '',
    this.tertiaryUnitQty = 0.0,
  });
}

/// Poori CSV text -> rows. Pehli line header hai (skip); khali lines, 6 se kam columns ya khali Code wali rows skip.
/// UTF-8 BOM (Excel) hata diya jata hai. Quoted field ke andar newline Kotlin ki tarah support nahi (line-by-line).
List<RateListRow> parseRateListCsv(String text) {
  final lines = text.replaceFirst('\uFEFF', '').split(RegExp(r'\r\n|\r|\n'));
  final rows = <RateListRow>[];
  for (final raw in lines.skip(1)) {
    if (raw.trim().isEmpty) continue;
    final f = parseCsvLine(raw.replaceFirst('\uFEFF', ''));
    if (f.length < 6) continue;
    final barcode = f[0].trim();
    if (barcode.isEmpty) continue;
    String at(int i) => i < f.length ? f[i].trim() : '';
    final unit = at(3);
    rows.add(RateListRow(
      barcode: barcode,
      unit: unit.isEmpty ? null : unit,
      wholesale: double.tryParse(at(4)),
      retail: double.tryParse(at(5)),
      secondaryUnit: at(6),
      secondaryUnitQty: double.tryParse(at(7)) ?? 0.0,
      tertiaryUnit: at(8),
      tertiaryUnitQty: double.tryParse(at(9)) ?? 0.0,
    ));
  }
  return rows;
}

/// "Updated N product(s)[, M not found (Code column changed?)]" — Kotlin ka toast text.
String rateListImportMessage(int updated, int notFound) => notFound == 0
    ? 'Updated $updated product(s)'
    : 'Updated $updated product(s), $notFound not found (Code column changed?)';
