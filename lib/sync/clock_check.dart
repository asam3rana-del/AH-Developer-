import 'dart:io';

/// Phone / PC ki ghadi sahi hai? (Sync se pehle.)
///
/// Sync "kaun sa record naya hai" device ki apni ghadi (`updatedAt`) se tay karta hai. Kisi device ki tareekh
/// aage ho (2030) to us ka har record hamesha "sab se naya" ban jata — baad ki sahi edits aur deletes rad hote.
/// Peeche ho to us ki nayi edits "purani" gini jati hain aur cloud par nahi lagtin (PC 13 ghante peeche wala masla).
///
/// Ilaaj: Google ke server ka waqt (HTTPS jawab ka `Date` header — Firestore ka koi read / quota nahi lagta) se
/// milao; farq [maxSkew] se zyada ho to sync roko aur saaf batao. Net na ho / header na mile to rokte nahi.
class ClockCheck {
  ClockCheck._();

  /// Itna farq chalta hai (ghadi ki aam susti / thori der). Is se zyada = sync band.
  static const Duration maxSkew = Duration(hours: 1);

  /// Ek dafa naapa hua farq kitni der yaad rahe (har sync par network call na ho).
  static const Duration cacheFor = Duration(minutes: 30);

  /// Server ka abhi ka waqt (UTC millis) ya null. Tests ise badal dete hain.
  static Future<int?> Function() serverNow = _httpDate;

  /// Device ka waqt. Tests ise badal dete hain.
  static int Function() deviceNow = () => DateTime.now().millisecondsSinceEpoch;

  static int? _skew; // device - server (ms)
  static int _measuredAt = 0;

  static void resetForTest() {
    _skew = null;
    _measuredAt = 0;
  }

  /// device − server (ms). Na naap saken to null.
  static Future<int?> skewMs() async {
    final now = deviceNow();
    if (_skew != null && (now - _measuredAt).abs() < cacheFor.inMilliseconds) return _skew;
    final server = await serverNow();
    if (server == null) return null;
    _skew = deviceNow() - server;
    _measuredAt = deviceNow();
    return _skew;
  }

  /// Ghadi bahut ghalat ho to user ke liye paigham, warna null.
  static Future<String?> problem() async {
    final s = await skewMs();
    if (s == null || s.abs() <= maxSkew.inMilliseconds) return null;
    _skew = null; // user theek kare to agli sync foran dobara naape
    final hours = (s.abs() / 3600000).toStringAsFixed(s.abs() >= 36000000 ? 0 : 1);
    final dir = s > 0 ? 'aage' : 'peeche';
    return 'Is device ki tareekh / waqt ghalat hai ($hours ghante $dir). Sync rok di gayi taake doosre devices ka '
        'hisaab kharab na ho. Settings > Date & time mein "Automatic" on karein (time zone: Pakistan), phir Sync Now.';
  }

  static Future<int?> _httpDate() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      final req = await client.headUrl(Uri.parse('https://firestore.googleapis.com/')).timeout(const Duration(seconds: 4));
      final res = await req.close().timeout(const Duration(seconds: 4));
      await res.drain<void>();
      final d = res.headers.date;
      return d?.toUtc().millisecondsSinceEpoch;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }
}
