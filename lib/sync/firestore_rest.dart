import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:shared_preferences/shared_preferences.dart';

import 'cloud_config_store.dart';

/// PC (Windows) ka Firebase — Firebase ke C++ SDK ke BAGHAIR, seedha Google ke REST API se.
///
/// Kyun: Windows par `cloud_firestore` / `firebase_auth` ka C++ SDK sync ke dauran app ko gira deta tha
/// (Event Viewer: 0xe06d7363, KERNELBASE.dll). Yahan sirf `dart:io` HttpClient hai — koi native code nahi,
/// koi ghalti app nahi giraati (sab Dart exception ban kar sync ke catch mein jati hai).
///
/// Wahi Firebase project, wahi security rules (`request.auth.uid` + `branch_members`), wahi documents —
/// mobile (SDK) aur PC (REST) ek hi data parhte / likhte hain.
///
///  * Auth: Identity Toolkit `accounts:signUp` (anonymous) + Secure Token refresh. UID / refresh token
///    SharedPreferences mein (project ke hisaab se) — PC ki "Device ID" yahi UID hai.
///  * Firestore: documents GET, `runQuery`, `commit` preconditions ke saath (takrao par 5 dafa
///    dobara).

/// REST ki ghalti — `code` Firebase SDK jaisa ('permission-denied', 'unavailable', 'resource-exhausted'...),
/// taake `isNetworkError` / `isQuotaError` / `isPermissionDenied` wahi kaam karein.
class RestFirebaseException implements Exception {
  final String code;
  final String message;
  final int status;
  const RestFirebaseException(this.code, this.message, [this.status = 0]);

  @override
  String toString() => '[$code] $message';
}

/// gRPC status (REST error.status) -> SDK jaisa code.
String restCodeFromStatus(String? status, int http) {
  switch (status) {
    case 'PERMISSION_DENIED':
      return 'permission-denied';
    case 'NOT_FOUND':
      return 'not-found';
    case 'ABORTED':
      return 'aborted';
    case 'FAILED_PRECONDITION':
      return 'failed-precondition';
    case 'RESOURCE_EXHAUSTED':
      return 'resource-exhausted';
    case 'UNAUTHENTICATED':
      return 'unauthenticated';
    case 'UNAVAILABLE':
      return 'unavailable';
    case 'DEADLINE_EXCEEDED':
      return 'deadline-exceeded';
    case 'INVALID_ARGUMENT':
      return 'invalid-argument';
    case 'ALREADY_EXISTS':
      return 'already-exists';
  }
  if (http == 401) return 'unauthenticated';
  if (http == 403) return 'permission-denied';
  if (http == 404) return 'not-found';
  if (http == 409) return 'aborted';
  if (http == 429) return 'resource-exhausted';
  if (http >= 500) return 'unavailable';
  return 'unknown';
}

/// Identity Toolkit ka message ("OPERATION_NOT_ALLOWED : ...") -> code.
String authCodeFromMessage(String message) {
  final m = message.split(' ').first.trim().toUpperCase();
  switch (m) {
    case 'OPERATION_NOT_ALLOWED':
      return 'operation-not-allowed';
    case 'ADMIN_ONLY_OPERATION':
      return 'admin-restricted-operation';
    case 'TOKEN_EXPIRED':
    case 'INVALID_REFRESH_TOKEN':
    case 'USER_NOT_FOUND':
    case 'USER_DISABLED':
    case 'INVALID_GRANT_TYPE':
      return 'user-token-invalid';
    case 'TOO_MANY_ATTEMPTS_TRY_LATER':
      return 'resource-exhausted';
  }
  if (m.startsWith('API_KEY') || m.contains('API KEY')) return 'invalid-api-key';
  return 'auth-error';
}

// ------------------------------------------------------------------ value codec

final RegExp _simpleField = RegExp(r'^[A-Za-z_][A-Za-z_0-9]*$');

/// Firestore field path ka ek hissa: saada naam waisa hi, warna backtick mein (`a-b`).
String quoteFieldSegment(String s) =>
    _simpleField.hasMatch(s) ? s : '`${s.replaceAll(r'\', r'\\').replaceAll('`', r'\`')}`';

/// Dart -> Firestore REST `Value`.
Map<String, Object?> encodeValue(Object? v) {
  if (v == null) return {'nullValue': null};
  if (v is bool) return {'booleanValue': v};
  if (v is int) return {'integerValue': v.toString()};
  if (v is double) {
    if (v.isNaN) return {'doubleValue': 'NaN'};
    if (v.isInfinite) return {'doubleValue': v > 0 ? 'Infinity' : '-Infinity'};
    return {'doubleValue': v};
  }
  if (v is num) return {'doubleValue': v.toDouble()};
  if (v is String) return {'stringValue': v};
  if (v is DateTime) return {'timestampValue': v.toUtc().toIso8601String()};
  if (v is List) return {'arrayValue': {'values': [for (final e in v) encodeValue(e)]}};
  if (v is Map) {
    return {
      'mapValue': {'fields': {for (final e in v.entries) e.key.toString(): encodeValue(e.value)}}
    };
  }
  return {'stringValue': v.toString()};
}

Map<String, Object?> encodeFields(Map<String, Object?> map) => {for (final e in map.entries) e.key: encodeValue(e.value)};

/// Firestore REST `Value` -> Dart (SDK ki `data()` jaisa: int / double / String / bool / List / Map).
/// Timestamp -> millis (int); app ke documents mein waqt waise bhi millis (int) hai.
Object? decodeValue(Object? raw) {
  if (raw is! Map) return null;
  if (raw.containsKey('nullValue')) return null;
  if (raw.containsKey('booleanValue')) return raw['booleanValue'] == true;
  if (raw.containsKey('integerValue')) {
    final x = raw['integerValue'];
    return x is num ? x.toInt() : int.tryParse(x.toString()) ?? 0;
  }
  if (raw.containsKey('doubleValue')) {
    final x = raw['doubleValue'];
    if (x is num) return x.toDouble();
    switch (x.toString()) {
      case 'NaN':
        return double.nan;
      case 'Infinity':
        return double.infinity;
      case '-Infinity':
        return double.negativeInfinity;
    }
    return double.tryParse(x.toString()) ?? 0.0;
  }
  if (raw.containsKey('stringValue')) return raw['stringValue']?.toString() ?? '';
  if (raw.containsKey('timestampValue')) {
    final t = DateTime.tryParse(raw['timestampValue'].toString());
    return t?.millisecondsSinceEpoch;
  }
  if (raw.containsKey('bytesValue')) return base64Decode(raw['bytesValue'].toString());
  if (raw.containsKey('referenceValue')) return raw['referenceValue']?.toString();
  if (raw.containsKey('geoPointValue')) return Map<String, Object?>.from(raw['geoPointValue'] as Map);
  if (raw.containsKey('arrayValue')) {
    final vals = (raw['arrayValue'] as Map?)?['values'];
    return vals is List ? [for (final e in vals) decodeValue(e)] : <Object?>[];
  }
  if (raw.containsKey('mapValue')) {
    final f = (raw['mapValue'] as Map?)?['fields'];
    return f is Map ? decodeFields(f) : <String, Object?>{};
  }
  return null;
}

Map<String, Object?> decodeFields(Map fields) =>
    {for (final e in fields.entries) e.key.toString(): decodeValue(e.value)};

/// `SetOptions(merge: true)` jaisa: har leaf ka field path (nested map ke andar tak). Khali map khud ek
/// path (warna wo field kabhi likha hi na jata).
List<String> mergeFieldPaths(Map<String, Object?> map, [String prefix = '']) {
  final out = <String>[];
  map.forEach((k, v) {
    final path = prefix.isEmpty ? quoteFieldSegment(k) : '$prefix.${quoteFieldSegment(k)}';
    if (v is Map && v.isNotEmpty) {
      out.addAll(mergeFieldPaths(Map<String, Object?>.from(v), path));
    } else {
      out.add(path);
    }
  });
  return out;
}

// ------------------------------------------------------------------ documents

class RestDoc {
  final String id;
  final bool exists;
  final Map<String, Object?>? _data;

  /// Server ka `updateTime` (RFC3339) — transaction precondition ke liye. Na ho to null.
  final String? updateTime;
  const RestDoc(this.id, this.exists, this._data, [this.updateTime]);

  /// SDK `DocumentSnapshot.data()` jaisa (na ho to null).
  Map<String, Object?>? data() => _data;

  static RestDoc fromJson(Map json) {
    final name = json['name']?.toString() ?? '';
    final id = Uri.decodeComponent(name.split('/').last);
    final f = json['fields'];
    return RestDoc(id, true, f is Map ? decodeFields(f) : <String, Object?>{}, json['updateTime']?.toString());
  }
}

/// Transaction ke andar (phone ke Firebase SDK jaisa "optimistic" tareeqa):
/// reads aam GET se, aur har likhe gaye document par commit ke waqt precondition lagti hai — document
/// tab bhi waisa hi ho jaisa parha tha (updateTime wahi, ya tab bhi maujood na ho). Beech mein kisi aur ne
/// badla to commit FAILED_PRECONDITION deta hai aur poori body dobara chalti hai.
///
/// FIX: pehle `:beginTransaction` istemal hota tha — Firebase Auth (rules wale) user ke liye server use
/// "Missing or insufficient permissions" se rad kar deta hai, is liye PC ka har push ruk jata tha
/// (pull chalta rehta tha kyunke wo transaction nahi karta).
class RestTx {
  RestTx._(this._fs, this.project);
  final FirestoreRest _fs;
  final String project;
  final List<Map<String, Object?>> writes = [];

  /// docName -> parhte waqt ka updateTime ('' = maujood nahi tha).
  final Map<String, String> _seen = {};
  final Set<String> _guarded = {};

  Future<RestDoc> get(String collection, String docId) async {
    try {
      final d = await _fs.getDoc(collection, docId);
      _seen[_fs.docName(project, collection, docId)] = d.exists ? (d.updateTime ?? '') : '';
      return d;
    } on RestFirebaseException catch (e) {
      // Sync History mein saaf likha aaye ke parhne mein ruka (kis document par).
      throw RestFirebaseException(e.code, '${e.message} [read $collection/$docId]', e.status);
    }
  }

  /// `tx.set(ref, map, SetOptions(merge: true))` (merge) ya `SetOptions(mergeFields: [...])`.
  void set(String collection, String docId, Map<String, Object?> map, {bool merge = false, List<String>? mergeFields}) {
    final w = _fs.updateWrite(project, collection, docId, map, merge: merge, mergeFields: mergeFields);
    final name = _fs.docName(project, collection, docId);
    final seen = _seen[name];
    // Precondition sirf pehli write par (usi commit ki doosri write ke waqt document badal chuka hota hai).
    if (seen != null && _guarded.add(name)) {
      w['currentDocument'] = seen.isEmpty ? {'exists': false} : {'updateTime': seen};
    }
    writes.add(w);
  }
}

/// Ek query filter (`where`).
class RestFilter {
  final String field;
  final String op; // EQUAL, GREATER_THAN, ...
  final Object? value;
  const RestFilter(this.field, this.op, this.value);

  Map<String, Object?> toJson() => {
        'fieldFilter': {
          'field': {'fieldPath': field},
          'op': op,
          'value': encodeValue(value),
        }
      };
}

/// PC ka Firestore + anonymous Auth client (REST). Ek project (Cloud Sync Setup) ke liye.
class FirestoreRest {
  FirestoreRest._();
  static final FirestoreRest instance = FirestoreRest._();

  static const Duration requestTimeout = Duration(seconds: 30);

  /// Tests badal sakte hain.
  HttpClient Function() httpClientFactory = () => HttpClient()
    ..connectionTimeout = const Duration(seconds: 20)
    ..idleTimeout = const Duration(seconds: 30)
    ..maxConnectionsPerHost = 6;

  /// Ek hi client (keep-alive): har request par naya TLS connection bohat dheema tha (pull 90 sec timeout).
  HttpClient? _client;
  HttpClient get _http => _client ??= httpClientFactory();

  String? _idToken;
  int _idTokenExpiresAt = 0; // ms
  String? _tokenProject;

  // -------------------------------------------------------------- config

  Future<CloudConfig> _config() async {
    final c = await CloudConfigStore.get();
    if (c == null || c.projectId.trim().isEmpty || c.apiKey.trim().isEmpty) {
      throw const RestFirebaseException('no-project', 'Firebase project is not set (Cloud Sync Setup)');
    }
    return c;
  }

  String _base(String projectId) =>
      'https://firestore.googleapis.com/v1/projects/${Uri.encodeComponent(projectId)}/databases/(default)/documents';

  String docName(String projectId, String collection, String docId) =>
      'projects/$projectId/databases/(default)/documents/$collection/$docId';

  static String _prefKey(String projectId, String what) => 'rest_auth.$projectId.$what';

  // -------------------------------------------------------------- auth

  /// Is PC ki Device ID (anonymous UID) — pehli kamyab sign-in se pehle null. Kabhi naya sign-in nahi.
  Future<String?> currentUid() async {
    try {
      final c = await CloudConfigStore.get();
      if (c == null) return null;
      final p = await SharedPreferences.getInstance();
      return p.getString(_prefKey(c.projectId, 'uid'));
    } catch (_) {
      return null;
    }
  }

  /// Valid ID token (zaroorat ho to refresh / pehli dafa anonymous sign-up).
  ///
  /// Ek waqt mein sirf EK sign-in / refresh (lock): pehle Cloud Sync Setup (Device ID) aur sync ek saath
  /// sign-up karte the — do alag anonymous users ban jate, PC ek ki ID dikhata aur doosre se likhta
  /// (branch_members mein ID daalne ke baad bhi "permission denied").
  Future<String> idToken({bool forceRefresh = false}) {
    // 401 ke baad: purana token yaad se nikal do, taake chalti (ya agli) call naya token laye.
    if (forceRefresh) _idTokenExpiresAt = 0;
    final running = _inflight;
    if (running != null) return running;
    final f = _idTokenLocked(forceRefresh).whenComplete(() => _inflight = null);
    _inflight = f;
    return f;
  }

  Future<String>? _inflight;

  Future<String> _idTokenLocked(bool forceRefresh) async {
    final c = await _config();
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!forceRefresh && _tokenProject == c.projectId && _idToken != null && now < _idTokenExpiresAt - 60000) {
      return _idToken!;
    }
    final p = await SharedPreferences.getInstance();
    final refresh = p.getString(_prefKey(c.projectId, 'refresh'));
    if (refresh != null && refresh.isNotEmpty) {
      try {
        final r = await _postForm(
          Uri.parse('https://securetoken.googleapis.com/v1/token?key=${Uri.encodeComponent(c.apiKey)}'),
          {'grant_type': 'refresh_token', 'refresh_token': refresh},
        );
        _remember(c.projectId, r['id_token'] as String, int.tryParse('${r['expires_in']}') ?? 3600);
        final newRefresh = r['refresh_token']?.toString();
        if (newRefresh != null && newRefresh.isNotEmpty) await p.setString(_prefKey(c.projectId, 'refresh'), newRefresh);
        final uid = r['user_id']?.toString();
        if (uid != null && uid.isNotEmpty) await p.setString(_prefKey(c.projectId, 'uid'), uid);
        return _idToken!;
      } on RestFirebaseException catch (e) {
        // User mit gaya (Firebase "auto clean-up") / token bekaar: naya anonymous user banana hoga —
        // nayi Device ID ko branch_members mein dobara daalna parega. Baqi ghaltiyan (internet) aage.
        if (e.code != 'user-token-invalid') rethrow;
        await p.remove(_prefKey(c.projectId, 'refresh'));
        await p.remove(_prefKey(c.projectId, 'uid'));
      }
    }
    final r = await _postJson(
      Uri.parse('https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=${Uri.encodeComponent(c.apiKey)}'),
      {'returnSecureToken': true},
      auth: false,
    );
    final token = r['idToken']?.toString();
    final uid = r['localId']?.toString();
    if (token == null || uid == null) throw const RestFirebaseException('auth-error', 'Anonymous sign-in: no token');
    await p.setString(_prefKey(c.projectId, 'uid'), uid);
    final rt = r['refreshToken']?.toString();
    if (rt != null) await p.setString(_prefKey(c.projectId, 'refresh'), rt);
    _remember(c.projectId, token, int.tryParse('${r['expiresIn']}') ?? 3600);
    return token;
  }

  void _remember(String project, String token, int expiresInSec) {
    _tokenProject = project;
    _idToken = token;
    _idTokenExpiresAt = DateTime.now().millisecondsSinceEpoch + expiresInSec * 1000;
  }

  // -------------------------------------------------------------- http

  Future<Map<String, Object?>> _postForm(Uri uri, Map<String, String> form) async {
    final body = form.entries.map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}').join('&');
    final res = await _raw('POST', uri, body: body, contentType: 'application/x-www-form-urlencoded', token: null);
    return _asMap(res, isAuth: true);
  }

  Future<Map<String, Object?>> _postJson(Uri uri, Object body, {bool auth = true}) async {
    final res = await _send('POST', uri, body: jsonEncode(body), auth: auth, isAuthApi: !auth);
    return res is Map ? Map<String, Object?>.from(res) : <String, Object?>{};
  }

  /// Token ke saath request; UNAUTHENTICATED par ek dafa token refresh karke dobara.
  Future<Object?> _send(String method, Uri uri, {String? body, bool auth = true, bool isAuthApi = false}) async {
    var token = auth ? await idToken() : null;
    for (var attempt = 0;; attempt++) {
      final res = await _raw(method, uri, body: body, contentType: 'application/json', token: token);
      if (res.status == 401 && auth && attempt == 0) {
        token = await idToken(forceRefresh: true);
        continue;
      }
      return _decode(res, isAuth: isAuthApi);
    }
  }

  Map<String, Object?> _asMap(_RawRes res, {bool isAuth = false}) {
    final v = _decode(res, isAuth: isAuth);
    return v is Map ? Map<String, Object?>.from(v) : <String, Object?>{};
  }

  Object? _decode(_RawRes res, {bool isAuth = false}) {
    Object? json;
    try {
      json = res.body.isEmpty ? null : jsonDecode(res.body);
    } catch (_) {
      json = null;
    }
    if (res.status >= 200 && res.status < 300) return json;
    var message = 'HTTP ${res.status}';
    String? status;
    final err = json is Map ? json['error'] : (json is List && json.isNotEmpty && json.first is Map ? json.first['error'] : null);
    if (err is Map) {
      message = err['message']?.toString() ?? message;
      status = err['status']?.toString();
    }
    final code = isAuth ? authCodeFromMessage(message) : restCodeFromStatus(status, res.status);
    throw RestFirebaseException(code == 'auth-error' ? restCodeFromStatus(status, res.status) : code, message, res.status);
  }

  Future<_RawRes> _raw(String method, Uri uri, {String? body, required String contentType, String? token}) async {
    final client = _http;
    try {
      final req = await client.openUrl(method, uri).timeout(requestTimeout);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (token != null) req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      if (body != null) {
        final bytes = utf8.encode(body);
        req.headers.set(HttpHeaders.contentTypeHeader, '$contentType; charset=utf-8');
        req.contentLength = bytes.length;
        req.add(bytes);
      }
      final res = await req.close().timeout(requestTimeout);
      final text = await res.transform(utf8.decoder).join().timeout(requestTimeout);
      return _RawRes(res.statusCode, text);
    } on TimeoutException {
      _resetClient();
      throw const RestFirebaseException('deadline-exceeded', 'Request timed out (slow / no internet)');
    } on SocketException catch (e) {
      _resetClient();
      throw RestFirebaseException('unavailable', 'No internet: ${e.message}');
    } on HandshakeException catch (e) {
      _resetClient();
      throw RestFirebaseException('unavailable', 'Secure connection failed (check PC date/time): ${e.message}');
    } on HttpException catch (e) {
      _resetClient();
      throw RestFirebaseException('unavailable', 'Connection error: ${e.message}');
    }
  }

  /// Network ghalti ke baad purane (shayad toote) connections chhor kar naya client.
  void _resetClient() {
    final c = _client;
    _client = null;
    try {
      c?.close(force: true);
    } catch (_) {}
  }

  // -------------------------------------------------------------- firestore

  String _docUrl(String project, String collection, String docId) =>
      '${_base(project)}/${Uri.encodeComponent(collection)}/${Uri.encodeComponent(docId)}';

  /// Ek document (na ho => exists:false).
  Future<RestDoc> getDoc(String collection, String docId, {String? transaction}) async {
    final c = await _config();
    final q = transaction == null ? '' : '?transaction=${Uri.encodeQueryComponent(transaction)}';
    try {
      final r = await _send('GET', Uri.parse('${_docUrl(c.projectId, collection, docId)}$q'));
      return r is Map ? RestDoc.fromJson(r) : RestDoc(docId, false, null);
    } on RestFirebaseException catch (e) {
      if (e.code == 'not-found') return RestDoc(docId, false, null);
      rethrow;
    }
  }

  /// `collection.where(...).where(...).limit(n).get()` — sirf ek collection (subcollections nahi).
  Future<List<RestDoc>> query(String collection, List<RestFilter> filters, {int? limit}) async {
    final c = await _config();
    final where = filters.isEmpty
        ? null
        : filters.length == 1
            ? filters.first.toJson()
            : {
                'compositeFilter': {'op': 'AND', 'filters': [for (final f in filters) f.toJson()]}
              };
    final body = {
      'structuredQuery': {
        'from': [
          {'collectionId': collection}
        ],
        if (where != null) 'where': where,
        if (limit != null) 'limit': limit,
      }
    };
    final r = await _send('POST', Uri.parse('${_base(c.projectId)}:runQuery'), body: jsonEncode(body));
    final out = <RestDoc>[];
    if (r is List) {
      for (final item in r) {
        if (item is Map && item['document'] is Map) out.add(RestDoc.fromJson(item['document'] as Map));
      }
    }
    return out;
  }

  /// Commit ke liye ek "update" write (merge / mergeFields / poora replace).
  Map<String, Object?> updateWrite(String project, String collection, String docId, Map<String, Object?> map,
      {bool merge = false, List<String>? mergeFields}) {
    final List<String>? mask = mergeFields != null
        ? [for (final f in mergeFields) f.split('.').map(quoteFieldSegment).join('.')]
        : (merge ? mergeFieldPaths(map) : null);
    // mergeFields: sirf wahi fields bhejo (baqi map mein hon to bhi). Nested mask ke liye poora map theek hai.
    return {
      'update': {'name': docName(project, collection, docId), 'fields': encodeFields(map)},
      if (mask != null) 'updateMask': {'fieldPaths': mask},
    };
  }

  /// Document mitana (commit write).
  Map<String, Object?> deleteWrite(String project, String collection, String docId) =>
      {'delete': docName(project, collection, docId)};

  /// Maujooda project ID (Cloud Sync Setup) — writes ke document names ke liye.
  Future<String> projectId() async => (await _config()).projectId;

  /// Writes (transaction ke baghair ya saath) ek commit mein.
  Future<void> commit(List<Map<String, Object?>> writes, {String? transaction}) async {
    final c = await _config();
    if (writes.isEmpty && transaction == null) return;
    await _send('POST', Uri.parse('${_base(c.projectId)}:commit'),
        body: jsonEncode({'writes': writes, if (transaction != null) 'transaction': transaction}));
  }

  /// `runTransaction` jaisa: body padhti hai, writes jama karti hai, phir ek commit (preconditions ke saath).
  /// Takrao (FAILED_PRECONDITION / ABORTED) par body dobara — zyada se zyada 5 dafa, thore wagfe se.
  Future<T> runTransaction<T>(Future<T> Function(RestTx tx) body) async {
    final c = await _config();
    final rnd = math.Random();
    for (var attempt = 1;; attempt++) {
      final tx = RestTx._(this, c.projectId);
      final result = await body(tx);
      if (tx.writes.isEmpty) return result;
      try {
        await commit(tx.writes);
        return result;
      } on RestFirebaseException catch (e) {
        final conflict = e.code == 'aborted' || e.code == 'failed-precondition';
        if (!conflict || attempt >= 5) {
          // Likhne mein ruka: kaun sa document aur kaun se fields (rules ki jaanch ke liye).
          final what = [
            for (final w in tx.writes)
              if (w['update'] is Map)
                '${((w['update'] as Map)['name'] ?? '').toString().split('/documents/').last}'
                    ' branchId=${decodeValue(((w['update'] as Map)['fields'] as Map?)?['branchId'])}'
          ].join('; ');
          throw RestFirebaseException(e.code, '${e.message} [write $what]', e.status);
        }
        await Future<void>.delayed(Duration(milliseconds: 200 * attempt + rnd.nextInt(300)));
      }
    }
  }

  /// Naya document (auto id) — crash report jaisi cheezon ke liye.
  Future<void> addDoc(String collection, Map<String, Object?> map) async {
    final c = await _config();
    await _send('POST', Uri.parse('${_base(c.projectId)}/${Uri.encodeComponent(collection)}'),
        body: jsonEncode({'fields': encodeFields(map)}));
  }
}

class _RawRes {
  final int status;
  final String body;
  const _RawRes(this.status, this.body);
}
