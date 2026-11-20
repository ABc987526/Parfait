import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Ordered work ids a pushed detail route can page through — the same
/// list the grid shows, handed over via `IllustRouteExtra.pagerSource`.
/// Opening a work from a feed keeps the
/// feed's ordering, so swiping sideways moves to the previous/next work
/// without returning to the grid.
///
/// The grid's State owns the instance so it survives rebuilds; [update]
/// is called whenever the feed publishes a new id list, and [onNearEnd]
/// is the feed's `loadMore` — the pager calls it when the user swipes
/// close to the end, which is how paged detail keeps growing.
class IllustPagerSource extends ChangeNotifier {
  List<int> _ids = const [];

  /// Work ids in feed order.
  List<int> get ids => _ids;

  /// Feed-side "fetch the next page" hook. Feeds without a continuation
  /// leave it null and the pager stops at the last work.
  VoidCallback? onNearEnd;

  /// Grids publish a fresh list on every rebuild — a load-more phase flip
  /// included — so only a changed order notifies: each notify re-seats the
  /// open pager.
  void update(List<int> ids) {
    if (identical(ids, _ids) || listEquals(ids, _ids)) return;
    _ids = List.unmodifiable(ids);
    notifyListeners();
  }

  /// The grid's built cards by work id, for [aimHomeFlight].
  final _cards = <int, ({BuildContext context, VoidCallback rebuild})>{};

  /// The work whose card the pager's image must not fly back to.
  int? _grounded;

  void attachCard(int id, BuildContext context, VoidCallback rebuild) =>
      _cards[id] = (context: context, rebuild: rebuild);

  void detachCard(int id, BuildContext context) {
    if (identical(_cards[id]?.context, context)) _cards.remove(id);
  }

  /// Whether the card of [id] may take the image flying back from the
  /// pager.
  bool cardFlies(int id) => id != _grounded;

  /// Called by the pager as it turns to [id]: a back flight lands on the
  /// card only while some of it is on screen. Hero pairs by tag alone, so
  /// a card built in the cache extent off screen would otherwise pull the
  /// image off the edge (TRANS-09). Decided here, not at the pop: the back
  /// gesture collects its Heroes the moment it starts.
  void aimHomeFlight(int id) => _ground(_cardOnScreen(id) ? null : id);

  /// The pager closed: every card flies again.
  void clearHomeFlight() => _ground(null);

  void _ground(int? id) {
    if (id == _grounded) return;
    final previous = _grounded;
    _grounded = id;
    for (final changed in [previous, id]) {
      if (changed != null) _cards[changed]?.rebuild();
    }
  }

  bool _cardOnScreen(int id) {
    final card = _cards[id]?.context;
    final box = card?.findRenderObject();
    if (card == null || box is! RenderBox || !box.hasSize) return false;
    // Every enclosing scroll view clips the card: the feed, and a row or a
    // page it sits in.
    for (
      var scrollable = card.findAncestorStateOfType<ScrollableState>();
      scrollable != null;
      scrollable = scrollable.context.findAncestorStateOfType<ScrollableState>()
    ) {
      final viewport = scrollable.context.findRenderObject();
      if (viewport is! RenderBox || !viewport.hasSize) continue;
      final rect = MatrixUtils.transformRect(
        box.getTransformTo(viewport),
        Offset.zero & box.size,
      );
      if (!rect.overlaps(Offset.zero & viewport.size)) return false;
    }
    return true;
  }
}

/// Exposes the enclosing grid's [IllustPagerSource] to the cards it
/// builds. The lookup is deliberately non-subscribing: a card only reads
/// the reference at tap time, so id-list churn must not rebuild cards.
class IllustPagerScope extends InheritedWidget {
  const IllustPagerScope({
    super.key,
    required this.source,
    required super.child,
  });

  final IllustPagerSource source;

  static IllustPagerSource? maybeOf(BuildContext context) {
    final element = context
        .getElementForInheritedWidgetOfExactType<IllustPagerScope>();
    return element == null ? null : (element.widget as IllustPagerScope).source;
  }

  @override
  bool updateShouldNotify(IllustPagerScope oldWidget) =>
      source != oldWidget.source;
}

/// A work's card under an [IllustPagerScope]: it registers with the
/// scope's pager so the image flies back to it only while some of it is
/// on screen. Outside a scope it is [child] alone.
class IllustPagerAnchor extends StatefulWidget {
  const IllustPagerAnchor({
    super.key,
    required this.illustId,
    required this.child,
  });

  final int illustId;
  final Widget child;

  @override
  State<IllustPagerAnchor> createState() => _IllustPagerAnchorState();
}

class _IllustPagerAnchorState extends State<IllustPagerAnchor> {
  IllustPagerSource? _source;

  @override
  void initState() {
    super.initState();
    _source = IllustPagerScope.maybeOf(context)
      ?..attachCard(widget.illustId, context, _rebuild);
  }

  @override
  void didUpdateWidget(IllustPagerAnchor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.illustId != oldWidget.illustId) {
      _source
        ?..detachCard(oldWidget.illustId, context)
        ..attachCard(widget.illustId, context, _rebuild);
    }
  }

  @override
  void dispose() {
    _source?.detachCard(widget.illustId, context);
    super.dispose();
  }

  void _rebuild() => setState(() {});

  @override
  Widget build(BuildContext context) => switch (_source) {
    final source? => HeroMode(
      enabled: source.cardFlies(widget.illustId),
      child: widget.child,
    ),
    null => widget.child,
  };
}
