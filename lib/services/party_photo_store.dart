import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Customer / supplier ki tasveer. Sirf IS device par (app ki documents folder mein `party_photos/`):
/// na DB badalta hai, na sync hota hai (Firebase Spark par Storage nahi). File ka naam hi record hai:
/// `c_<customerId>_<time>.jpg` / `s_<supplierId>_<time>.jpg`. Tasveer 800px tak chhoti karke save hoti hai.
/// Note: DB backup mein tasveerein shamil nahi; doosre phone par nahi jatin.
class PartyPhotoStore {
  PartyPhotoStore._();
  static final PartyPhotoStore instance = PartyPhotoStore._();

  /// Tasveer badalne par barhta hai — avatar widgets sun kar dobara banate hain.
  final ValueNotifier<int> changes = ValueNotifier<int>(0);

  final Map<String, String> _index = {};
  Future<void>? _loading;

  static final _nameRe = RegExp(r'^([cs])_(\d+)_(\d+)\.jpg$');

  Future<Directory> _dir() async {
    final base = await getApplicationDocumentsDirectory();
    final d = Directory(p.join(base.path, 'party_photos'));
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  String _key(bool customer, int id) => '${customer ? 'c' : 's'}$id';

  /// Pehli baar folder padh kar index banata hai (baad mein memory se).
  Future<void> ensureLoaded() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final best = <String, (int, String)>{};
      for (final e in (await _dir()).listSync()) {
        if (e is! File) continue;
        final m = _nameRe.firstMatch(p.basename(e.path));
        if (m == null) continue;
        final k = '${m.group(1)}${m.group(2)}';
        final ts = int.parse(m.group(3)!);
        if (!best.containsKey(k) || ts > best[k]!.$1) best[k] = (ts, e.path);
      }
      _index
        ..clear()
        ..addEntries(best.entries.map((e) => MapEntry(e.key, e.value.$2)));
    } catch (_) {
      // Folder na padh sake => koi tasveer nahi dikhegi; app chalti rahe.
    }
  }

  /// Index load hone ke baad hi bharosemand. Tasveer nahi to null.
  String? pathFor(bool customer, int id) => _index[_key(customer, id)];

  /// Camera / gallery se tasveer le kar save karta hai. Cancel ya masla => null.
  Future<String?> pick(ImageSource source, {required bool customer, required int id}) async {
    final picker = ImagePicker();
    XFile? x = await picker.pickImage(source: source, maxWidth: 800, maxHeight: 800, imageQuality: 80);
    // Android kam RAM wale phone par camera khulte hi app ko band kar sakta hai; tab tasveer yahan
    // "lost data" mein hoti hai. Pehle isi se wapas lo.
    if (x == null && defaultTargetPlatform == TargetPlatform.android) {
      try {
        final lost = await picker.retrieveLostData();
        if (!lost.isEmpty && lost.file != null) x = lost.file;
      } catch (_) {}
    }
    if (x == null) return null;
    await ensureLoaded();
    final dir = await _dir();
    final prefix = customer ? 'c' : 's';
    final dest = File(p.join(dir.path, '${prefix}_${id}_${DateTime.now().millisecondsSinceEpoch}.jpg'));
    await File(x.path).copy(dest.path);
    await _deleteOld(customer, id, keep: dest.path);
    _index[_key(customer, id)] = dest.path;
    changes.value++;
    return dest.path;
  }

  Future<void> remove({required bool customer, required int id}) async {
    await ensureLoaded();
    await _deleteOld(customer, id);
    _index.remove(_key(customer, id));
    changes.value++;
  }

  Future<void> _deleteOld(bool customer, int id, {String? keep}) async {
    try {
      final prefix = '${customer ? 'c' : 's'}_${id}_';
      for (final e in (await _dir()).listSync()) {
        if (e is File && p.basename(e.path).startsWith(prefix) && e.path != keep) {
          await e.delete();
        }
      }
    } catch (_) {}
  }
}
