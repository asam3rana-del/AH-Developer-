import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/sync/sync_repository.dart';
import 'package:ah_developer_kiryana_store/sync/sync_worker.dart';

/// Phase 10: SyncWorker — Kotlin `doWork` / `syncNowOnce` (REPLACE) / `triggerNow` (KEEP) /
/// `schedulePeriodic` (KEEP) ka rawaiyya.
SyncResult _ok({int pushed = 0, int customers = 0}) =>
    SyncResult(pushedCount: pushed, failedCount: 0, pulledOk: true, customersReceived: customers);

void main() {
  final w = SyncWorker.instance;
  var runs = 0;
  var online = true;
  late Completer<SyncResult>? gate;

  setUp(() {
    runs = 0;
    online = true;
    gate = null;
    w.cancelPeriodic();
    w.isOnline = () async => online;
    w.nowMs = () => DateTime.now().millisecondsSinceEpoch;
    w.runSync = () async {
      runs++;
      final g = gate;
      if (g != null) return g.future;
      return _ok(pushed: 2);
    };
    w.lastOutcome.value = null;
  });

  tearDown(() => w.cancelPeriodic());

  test('doWork: pulledOk => success + summary; lastOutcome set; isRunning wapas false', () async {
    final o = await w.syncNowOnce();
    expect(o.success, isTrue);
    expect(o.summary, 'Sent 2');
    expect(w.lastOutcome.value, same(o));
    expect(w.isRunning.value, isFalse);
  });

  test('pulledOk false => failure + "Sync failed: ..." (Result.failure(output))', () async {
    w.runSync = () async => const SyncResult(pushedCount: 0, failedCount: 0, pulledOk: false, error: 'boom');
    final o = await w.syncNowOnce();
    expect(o.success, isFalse);
    expect(o.summary, 'Sync failed: boom');
  });

  test('syncNow throw kare => "Sync failed: <msg>", crash nahi', () async {
    w.runSync = () async => throw Exception('kaboom');
    final o = await w.syncNowOnce();
    expect(o.success, isFalse);
    expect(o.summary, 'Sync failed: kaboom');
    expect(w.isRunning.value, isFalse);
  });

  test('offline: triggerNow kuch nahi chalata; syncNowOnce foran failure, runSync nahi', () async {
    online = false;
    await w.triggerNow();
    expect(runs, 0);
    final o = await w.syncNowOnce();
    expect(o.success, isFalse);
    expect(o.summary, contains('no internet'));
    expect(runs, 0);
  });

  test('triggerNow = KEEP: sync chal rahi ho to no-op (retry-storm FIX)', () async {
    gate = Completer<SyncResult>();
    final first = w.triggerNow();
    await Future<void>.delayed(Duration.zero);
    expect(w.isRunning.value, isTrue);
    await w.triggerNow();
    await w.triggerNow();
    expect(runs, 1);
    gate!.complete(_ok());
    await first;
    expect(runs, 1);
  });

  test('syncNowOnce chalti hui ko cancel nahi karta; uske baad taaza run (REPLACE ka Dart rup)', () async {
    gate = Completer<SyncResult>();
    final bg = w.triggerNow();
    await Future<void>.delayed(Duration.zero);
    final manual = w.syncNowOnce();
    await Future<void>.delayed(Duration.zero);
    expect(runs, 1); // abhi sirf pehli chal rahi hai — do saath nahi
    final g = gate!;
    gate = null;
    g.complete(_ok());
    await bg;
    final o = await manual;
    expect(runs, 2);
    expect(o.summary, 'Sent 2');
  });

  test('do manual taps ek saath: sequentially, kabhi overlap nahi', () async {
    var concurrent = 0;
    var maxConcurrent = 0;
    w.runSync = () async {
      runs++;
      concurrent++;
      if (concurrent > maxConcurrent) maxConcurrent = concurrent;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      concurrent--;
      return _ok();
    };
    await Future.wait([w.syncNowOnce(), w.syncNowOnce(), w.triggerNow()]);
    expect(maxConcurrent, 1);
    expect(runs, greaterThanOrEqualTo(2));
  });

  testWidgets('schedulePeriodic: har periodicInterval par ek sync; dobara bulane par duplicate nahi (KEEP)', (tester) async {
    w.schedulePeriodic();
    w.schedulePeriodic();
    expect(w.isScheduled, isTrue);
    await tester.pump(SyncWorker.periodicInterval);
    expect(runs, 1);
    await tester.pump(SyncWorker.periodicInterval);
    expect(runs, 2);
    w.cancelPeriodic();
    expect(w.isScheduled, isFalse);
    await tester.pump(SyncWorker.periodicInterval);
    expect(runs, 2);
  });

  testWidgets('resume par sync sirf tab jab pichli 1 min se purani ho; paused par 30 s se purani ho', (tester) async {
    var t = 100 * 60 * 1000;
    w.nowMs = () => t;
    w.schedulePeriodic();
    await w.syncNowOnce(); // lastFinishedAt = t
    expect(runs, 1);
    t += 20 * 1000;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(runs, 1); // 20 s — abhi zaroorat nahi
    t += 2 * 60 * 1000;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    expect(runs, 2);
    // background jate waqt: abhi abhi sync hui hai to dobara nahi; 30 s baad ho jaye.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(runs, 2);
    t += 45 * 1000;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed); // pehle wapas aao
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    await tester.pump();
    expect(runs, 3);
  });
}
