import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/data_feed_binding.dart';

/// Shows a composition element's live data-feed value (see FeedRules).
/// [builder] gets the value, or [fallback] (the element's saved text/source)
/// until the feed has loaded or when the cell is empty.
class FeedBound extends StatefulWidget {
  final FeedBinding binding;
  final String elementId;
  final String fallback;
  final Widget Function(String value) builder;

  const FeedBound({
    super.key,
    required this.binding,
    required this.elementId,
    required this.fallback,
    required this.builder,
  });

  @override
  State<FeedBound> createState() => _FeedBoundState();
}

class _FeedBoundState extends State<FeedBound> {
  StreamSubscription<Object?>? _sub;
  Timer? _cycle;
  Object? _feed;
  int? _index;

  String get _prefKey => 'sgx_feed_${widget.elementId}_${widget.binding.feedId}';

  @override
  void initState() {
    super.initState();
    _feed = DataFeedStore.instance.latest(widget.binding.feedId);
    _sub = DataFeedStore.instance.watch(widget.binding.feedId).listen((feed) {
      if (!mounted) return;
      setState(() => _feed = feed);
    });
    unawaited(_startCycle());
  }

  Future<void> _startCycle() async {
    final b = widget.binding;
    int? remembered;
    if (!b.enableCycleReset) {
      try {
        remembered = (await SharedPreferences.getInstance()).getInt(_prefKey);
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() => _index = FeedRules.startIndex(b, remembered));
    if (b.fixedRow != null) return;
    _cycle = Timer.periodic(Duration(seconds: b.cycleSeconds), (_) async {
      if (!mounted || _feed == null || _index == null) return;
      final next = FeedRules.next(_feed, b, _index!);
      setState(() => _index = next);
      if (!b.enableCycleReset) {
        try {
          await (await SharedPreferences.getInstance()).setInt(_prefKey, next);
        } catch (_) {}
      }
    });
  }

  @override
  void dispose() {
    _cycle?.cancel();
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final value = _feed == null || _index == null
        ? ''
        : FeedRules.valueAt(_feed, widget.binding, _index!);
    final shown = value.isEmpty ? widget.fallback : value;
    // Keyed by value so widgets that read their text once rebuild on change.
    return KeyedSubtree(key: ValueKey(shown), child: widget.builder(shown));
  }
}
