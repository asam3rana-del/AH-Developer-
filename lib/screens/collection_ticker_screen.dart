import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../db/collection_autopilot_repository.dart';
import '../models/collection_autopilot.dart';
import '../widgets/permission_guard.dart';

/// LCD / LED board jaisi screen: aaj jin se paisa lena hai un ke naam aur raqam neeche ek line mein chalte rehte hain,
/// beech mein ek ek party bari likhi aati hai. Dukaan ke tablet ko khara kar ke rakh den. Har minute khud refresh hota hai
/// (jis ne aaj reminder bhej diya wo list se hat jata hai, jis ne paisa diya uski raqam kam ho jati hai).
class CollectionTickerScreen extends StatelessWidget {
  const CollectionTickerScreen({super.key});

  @override
  Widget build(BuildContext context) =>
      const PermissionGuard(permission: 'due_reminders', child: _TickerBody());
}

const _ledAmber = Color(0xFFFFB300);
const _ledGreen = Color(0xFF39FF14);
const _ledRed = Color(0xFFFF5252);

final _money = NumberFormat('#,##0');

String _reasonLabel(AutopilotItem it) {
  switch (it.reason) {
    case TouchReason.brokenPromise:
      return 'WADA TOOTA';
    case TouchReason.promiseToday:
      return 'AAJ KA WADA';
    case TouchReason.qistDue:
      return 'QIST DUE';
    case TouchReason.payDay:
      return 'AAJ PAYMENT DIN';
    case TouchReason.followUpDue:
      return 'FOLLOW-UP AAJ';
    case TouchReason.late:
      return it.oldestDays > 0 ? 'LATE ${it.oldestDays} DIN' : 'LATE';
    case TouchReason.dueToday:
      return 'AAJ DUE';
  }
}

class _TickerBody extends StatefulWidget {
  const _TickerBody();

  @override
  State<_TickerBody> createState() => _TickerBodyState();
}

class _TickerBodyState extends State<_TickerBody> {
  AutopilotDay _day = AutopilotDay.empty;
  bool _loaded = false;
  int _spot = 0;
  DateTime _now = DateTime.now();
  Timer? _refresh;
  Timer? _spotTimer;
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _load();
    _refresh = Timer.periodic(const Duration(seconds: 60), (_) => _load());
    _spotTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted) setState(() => _spot++);
    });
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _refresh?.cancel();
    _spotTimer?.cancel();
    _clock?.cancel();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final d = await CollectionAutopilotRepository.instance.today();
      if (!mounted) return;
      setState(() {
        _day = d;
        _loaded = true;
      });
    } catch (_) {
      if (mounted) setState(() => _loaded = true);
    }
  }

  TextStyle _led(double size, Color c, {FontWeight w = FontWeight.w800}) => TextStyle(
        fontSize: size,
        color: c,
        fontWeight: w,
        letterSpacing: 1.5,
        shadows: [Shadow(color: c.withOpacity(0.75), blurRadius: 12)],
      );

  @override
  Widget build(BuildContext context) {
    final q = _day.queue;
    final todo = q.todo;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
          child: Column(children: [
            Row(children: [
              Text('AAJ KI WASOOLI', style: _led(20, _ledAmber)),
              const Spacer(),
              Text(DateFormat('hh:mm:ss a').format(_now), style: _led(18, _ledGreen)),
              IconButton(
                  tooltip: 'Close',
                  icon: const Icon(Icons.close, color: Colors.white54),
                  onPressed: () => Navigator.of(context).maybePop()),
            ]),
            const SizedBox(height: 4),
            Wrap(spacing: 22, runSpacing: 4, children: [
              Text('BAQI ${todo.length}  Rs ${_money.format(q.todoAmount.round())}', style: _led(15, _ledRed)),
              Text('HO CHUKA ${q.done.length}', style: _led(15, _ledAmber)),
              Text('AAJ WASOOL Rs ${_money.format(_day.collectedToday.round())}', style: _led(15, _ledGreen)),
            ]),
            Expanded(child: Center(child: _centre(todo))),
            _tickerBar(todo),
          ]),
        ),
      ),
    );
  }

  Widget _centre(List<AutopilotItem> todo) {
    if (!_loaded) return const CircularProgressIndicator(color: _ledAmber);
    if (todo.isEmpty) {
      return FittedBox(
        fit: BoxFit.scaleDown,
        child: Text('SAB KAAM HO GAYA', style: _led(54, _ledGreen)),
      );
    }
    final it = todo[_spot % todo.length];
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 500),
      child: Column(
        key: ValueKey('${it.party.key}-$_spot'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_reasonLabel(it), style: _led(18, _ledRed)),
          const SizedBox(height: 8),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(it.party.partyName.toUpperCase(), style: _led(64, _ledAmber), textAlign: TextAlign.center),
          ),
          const SizedBox(height: 8),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text('Rs ${_money.format(it.total.round())}', style: _led(54, _ledGreen)),
          ),
          const SizedBox(height: 8),
          Text('${(_spot % todo.length) + 1} / ${todo.length}', style: _led(14, Colors.white54, w: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _tickerBar(List<AutopilotItem> todo) {
    final text = todo.isEmpty
        ? 'AAJ KI WASOOLI MUKAMMAL'
        : todo.map((e) => '${e.party.partyName.toUpperCase()}  Rs ${_money.format(e.total.round())}').join('     ◆     ');
    return Container(
      height: 64,
      decoration: BoxDecoration(
        border: Border.all(color: _ledAmber.withOpacity(0.6), width: 2),
        borderRadius: BorderRadius.circular(10),
      ),
      child: _Marquee(text: text, style: _led(30, _ledAmber), pixelsPerSecond: 90),
    );
  }
}

/// Seedha daayen se baayen chalta hua, bina ruke dohrata hua text (LED board).
class _Marquee extends StatefulWidget {
  final String text;
  final TextStyle style;
  final double pixelsPerSecond;
  const _Marquee({required this.text, required this.style, this.pixelsPerSecond = 80});

  @override
  State<_Marquee> createState() => _MarqueeState();
}

class _MarqueeState extends State<_Marquee> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  double _x = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) {
      if (!mounted) return;
      setState(() => _x = elapsed.inMicroseconds / 1e6 * widget.pixelsPerSecond);
    })
      ..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  double _width(String s) {
    final tp = TextPainter(text: TextSpan(text: s, style: widget.style), textDirection: TextDirection.ltr, maxLines: 1)
      ..layout();
    return tp.width;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final seg = '${widget.text}          ◆          ';
      final segW = _width(seg);
      if (segW <= 0 || !c.maxWidth.isFinite) return const SizedBox.shrink();
      final copies = (c.maxWidth / segW).ceil() + 2;
      final shift = _x % segW;
      return ClipRect(
        child: OverflowBox(
          alignment: Alignment.centerLeft,
          minWidth: 0,
          maxWidth: double.infinity,
          child: Transform.translate(
            offset: Offset(-shift, 0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [for (var i = 0; i < copies; i++) Text(seg, style: widget.style, maxLines: 1, softWrap: false)],
            ),
          ),
        ),
      );
    });
  }
}
