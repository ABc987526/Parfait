import 'package:material_ui/material_ui.dart';

import '../theme/func_semantic_tokens.dart';

/// Fades whichever end of a scrollable in [child] has content past it, so an
/// item cut at the edge reads as "more this way" rather than a clipped word or
/// card (H3). A mask, not a painted gradient: tab rows and master panes sit on
/// surfaces whose own backdrop shows through.
class ScrollEdgeFade extends StatefulWidget {
  const ScrollEdgeFade({
    super.key,
    required this.child,
    this.axis = Axis.horizontal,
    this.fadeExtent,
    this.initialBefore = false,
    this.initialAfter = false,
  });

  final Widget child;
  final Axis axis;
  final double? fadeExtent;
  final bool initialBefore;
  final bool initialAfter;

  /// Twice the 24dp gap between tab labels: a narrower fade spent itself
  /// on the sliver of a cut label and read as a hard cut, not a fade.
  static const _defaultFadeExtent = FuncSpacing.xxxl;

  @override
  State<ScrollEdgeFade> createState() => ScrollEdgeFadeState();
}

/// Below this the row counts as resting on its edge.
const _edgeSlop = 0.5;

class ScrollEdgeFadeState extends State<ScrollEdgeFade> {
  late bool _before;
  late bool _after;
  var _verticalReversed = false;
  var _probeScheduled = false;

  /// Whether the leading / trailing edge, in reading order, is faded.
  @visibleForTesting
  (bool, bool) get fades => (_before, _after);

  @override
  void initState() {
    super.initState();
    _before = widget.initialBefore;
    _after = widget.initialAfter;
    _scheduleScrollProbe();
  }

  @override
  void didUpdateWidget(ScrollEdgeFade oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.axis != widget.axis) {
      _before = widget.initialBefore;
      _after = widget.initialAfter;
      _verticalReversed = false;
    }
    _scheduleScrollProbe();
  }

  void _scheduleScrollProbe() {
    if (_probeScheduled) return;
    _probeScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _probeScheduled = false;
      if (!mounted) return;
      _probeScrollable();
    });
  }

  void _probeScrollable() {
    ScrollPosition? match;
    void visit(Element element) {
      if (match != null) return;
      if (element is StatefulElement && element.state is ScrollableState) {
        final position = (element.state as ScrollableState).position;
        if (position.axis == widget.axis) {
          match = position;
          return;
        }
      }
      element.visitChildren(visit);
    }

    (context as Element).visitChildren(visit);
    if (match case final position?) {
      if (position.hasContentDimensions && position.hasPixels) {
        _updateFromMetrics(position);
      }
      return;
    }
    if (_before != widget.initialBefore ||
        _after != widget.initialAfter ||
        _verticalReversed) {
      setState(() {
        _before = widget.initialBefore;
        _after = widget.initialAfter;
        _verticalReversed = false;
      });
    }
  }

  bool _onMetrics(ScrollMetrics metrics, int depth) {
    if (depth != 0 || metrics.axis != widget.axis) return false;
    _updateFromMetrics(metrics);
    return false;
  }

  void _updateFromMetrics(ScrollMetrics metrics) {
    final before = metrics.extentBefore > _edgeSlop;
    final after = metrics.extentAfter > _edgeSlop;
    final verticalReversed =
        widget.axis == Axis.vertical &&
        metrics.axisDirection == AxisDirection.up;
    if (before != _before ||
        after != _after ||
        verticalReversed != _verticalReversed) {
      setState(() {
        _before = before;
        _after = after;
        _verticalReversed = verticalReversed;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final horizontal = widget.axis == Axis.horizontal;
    final (startFade, endFade) = horizontal
        ? switch (Directionality.of(context)) {
            TextDirection.rtl => (_after, _before),
            TextDirection.ltr => (_before, _after),
          }
        : (_verticalReversed ? (_after, _before) : (_before, _after));
    final (begin, end) = horizontal
        ? (Alignment.centerLeft, Alignment.centerRight)
        : (Alignment.topCenter, Alignment.bottomCenter);
    final fadeExtent = widget.fadeExtent ?? ScrollEdgeFade._defaultFadeExtent;
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (notification) =>
          _onMetrics(notification.metrics, notification.depth),
      child: NotificationListener<ScrollUpdateNotification>(
        onNotification: (notification) =>
            _onMetrics(notification.metrics, notification.depth),
        child: ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (bounds) {
            final span = horizontal ? bounds.width : bounds.height;
            final fade = span <= 0 || fadeExtent <= 0
                ? 0.0
                : (fadeExtent / span).clamp(0.0, 0.5);
            const shown = Color(0xFF000000);
            const hidden = Color(0x00000000);
            return LinearGradient(
              begin: begin,
              end: end,
              colors: [
                startFade ? hidden : shown,
                shown,
                shown,
                endFade ? hidden : shown,
              ],
              stops: [0.0, fade, 1.0 - fade, 1.0],
            ).createShader(bounds);
          },
          child: widget.child,
        ),
      ),
    );
  }
}
