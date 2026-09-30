import 'dart:async';

/// Repository ki `watchAll()` ke liye: HAR naya subscriber ko pehle current list milti hai, phir live
/// updates. Pehle source par subscribe karte hain (taake load ke dauran aane wala koi update na chhute),
/// phir list load karke bhejte hain. (Purani `_primed` wali tarkeeb sirf pehle subscriber ko list deti
/// thi — screen dobara khulne par suppliers / items ki list khali reh jati thi.)
Stream<List<T>> watchWithInitial<T>(
  StreamController<List<T>> source,
  Future<List<T>> Function() load,
) {
  late final StreamController<List<T>> out;
  StreamSubscription<List<T>>? sub;
  out = StreamController<List<T>>(
    onListen: () {
      sub = source.stream.listen(out.add, onError: out.addError);
      load().then((rows) {
        if (!out.isClosed) out.add(rows);
      }, onError: (Object e, StackTrace st) {
        if (!out.isClosed) out.addError(e, st);
      });
    },
    onCancel: () async {
      await sub?.cancel();
      sub = null;
    },
  );
  return out.stream;
}
