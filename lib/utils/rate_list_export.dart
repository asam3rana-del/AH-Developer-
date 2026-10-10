import 'dart:io';

import 'package:intl/intl.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../backup/downloads_copy.dart';
import '../models/product.dart';

/// Public Downloads ke andar folder (Kotlin: "IBTISAAM Rate Lists").
const String rateListFolder = 'IBTISAAM Rate Lists';

/// Pehla column Code (barcode) hai. Shopkeeper Rate sab se aakhir mein (purane column positions na badlein).
const List<String> rateListHeader = [
  "Code (don't edit)", 'Name', 'Category', 'Unit',
  'Wholesale Rate', 'Retail Rate',
  '2nd Unit', '1 Unit = Qty (2nd Unit)',
  '3rd Unit', '1 (2nd Unit) = Qty (3rd Unit)',
  'Shopkeeper Rate',
];

String _esc(String s) => '"${s.replaceAll('"', '""')}"';

String _num(double v) {
  if (v == v.roundToDouble()) return v.round().toString();
  return v.toString();
}

/// Pure: CSV text (UTF-8 BOM ke saath, taa-ke Excel Urdu/English naam sahi dikhaye).
/// Naam ke hisaab se sorted. 
String buildRateListCsv(List<Product> products) {
  final sorted = [...products]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  final b = StringBuffer('\uFEFF')..writeln(rateListHeader.join(','));
  for (final pr in sorted) {
    b.writeln([
      _esc(pr.barcode),
      _esc(pr.name),
      _esc(pr.category),
      _esc(pr.unit),
      _num(pr.wholesalePrice),
      _num(pr.salePrice),
      _esc(pr.secondaryUnit),
      pr.secondaryUnit.trim().isNotEmpty ? _num(pr.secondaryUnitQty) : '',
      _esc(pr.tertiaryUnit),
      pr.tertiaryUnit.trim().isNotEmpty ? _num(pr.tertiaryUnitQty) : '',
      pr.shopkeeperPrice > 0 ? _num(pr.shopkeeperPrice) : '',
    ].join(','));
  }
  return b.toString();
}

/// CSV file likhta hai, public Downloads/IBTISAAM Rate Lists mein copy karta hai (best-effort),
/// phir spreadsheet app mein seedha kholta hai; koi app na mile to Share sheet. File lauta deta hai.
Future<File> exportRateList(List<Product> products, {DateTime? now}) async {
  final stamp = DateFormat('yyyy-MM-dd_HH-mm').format(now ?? DateTime.now());
  final fileName = 'IBTISAAM_Rate_List_$stamp.csv';
  final dir = Directory(p.join((await getTemporaryDirectory()).path, rateListFolder));
  if (!await dir.exists()) await dir.create(recursive: true);
  final file = File(p.join(dir.path, fileName));
  await file.writeAsString(buildRateListCsv(products), flush: true);

  await DownloadsCopy.copy(file, folder: rateListFolder, fileName: fileName);

  final res = await OpenFilex.open(file.path, type: 'text/csv');
  if (res.type != ResultType.done) {
    await Share.shareXFiles([XFile(file.path)], subject: 'IBTISAAM Rate List');
  }
  return file;
}
