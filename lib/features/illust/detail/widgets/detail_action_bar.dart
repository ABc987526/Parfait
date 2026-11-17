import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../../app/motion/scroll_hide.dart';
import '../../../../app/motion/state_icon_switcher.dart';
import '../../../../app/theme/func_semantic_tokens.dart';
import '../../../../app/widgets/bookmark_switch_button.dart';
import '../../../../app/widgets/prompt_anchor.dart';
import '../../../../core/download/download_providers.dart';
import '../../../../core/entity/illust_entity.dart';
import '../../../../core/illust/illust_download_controller.dart';
import '../../../../l10n/context.dart';

/// The detail page's compact floating actions in thumb reach, centered at the
/// bottom edge: download and bookmark on an opaque lifted capsule
/// (`DETAIL-09`), avoiding frosted text smearing while sitting cleanly below
/// the author card.
class DetailActionBar extends StatefulWidget {
  const DetailActionBar({
    super.key,
    required this.entity,
    required this.visibility,
    required this.onDownload,
  });

  /// Height of the compact capsule itself: a 48dp button and its padding.
  static const double height = 56;

  /// Gap between the capsule and the bottom safe edge.
  static const double margin = FuncSpacing.lg;

  /// What the bar covers at the screen bottom while shown; the page pads
  /// its scroll end by this so the last content can clear it.
  static double restingExtent(BuildContext context) =>
      height + margin + MediaQuery.paddingOf(context).bottom;

  final IllustEntity entity;
  final Animation<double> visibility;
  final VoidCallback onDownload;

  @override
  State<DetailActionBar> createState() => _DetailActionBarState();
}

class _DetailActionBarState extends State<DetailActionBar> {
  /// The height the bar covers right now, for the prompt anchor.
  final _visibleExtent = ValueNotifier<double>(0);
  double _restingExtent = 0;

  @override
  void initState() {
    super.initState();
    widget.visibility.addListener(_publish);
  }

  @override
  void didUpdateWidget(covariant DetailActionBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.visibility, widget.visibility)) {
      oldWidget.visibility.removeListener(_publish);
      widget.visibility.addListener(_publish);
    }
  }

  @override
  void dispose() {
    widget.visibility.removeListener(_publish);
    _visibleExtent.dispose();
    super.dispose();
  }

  void _publish() =>
      _visibleExtent.value = _restingExtent * widget.visibility.value;

  @override
  Widget build(BuildContext context) {
    _restingExtent = DetailActionBar.restingExtent(context);
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    // Written during build: the anchor only relayouts on it.
    _publish();
    final tokens = FuncSemanticTokens.of(context);
    final capsule = DecoratedBox(
      decoration: ShapeDecoration(
        shape: const StadiumBorder(),
        shadows: tokens.layerLift,
      ),
      child: _toolbar(tokens),
    );
    return _host(context, bottomInset, capsule);
  }

  Widget _toolbar(FuncSemanticTokens tokens) {
    return Material(
      color: tokens.surface,
      shape: StadiumBorder(side: BorderSide(color: tokens.brandHairline)),
      child: Padding(
        padding: const EdgeInsets.all(FuncSpacing.xs),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            DetailDownloadButton(
              entity: widget.entity,
              onPressed: widget.onDownload,
            ),
            const SizedBox(width: FuncSpacing.xs),
            DecoratedBox(
              decoration: ShapeDecoration(
                color: tokens.brandTint,
                shape: CircleBorder(
                  side: BorderSide(color: tokens.brandTintStroke),
                ),
              ),
              child: BookmarkSwitchButton(
                illustId: widget.entity.id,
                title: widget.entity.title,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _host(BuildContext context, double bottomInset, Widget toolbar) {
    return PromptAnchor(
      extent: _visibleExtent,
      child: FadeTransition(
        opacity: ScrollHiddenChrome.opacityOf(widget.visibility),
        child: AnimatedBuilder(
          animation: widget.visibility,
          builder: (context, child) {
            final shown = widget.visibility.value;
            // Hidden means gone for touch and screen readers too.
            return ExcludeSemantics(
              excluding: shown == 0,
              child: IgnorePointer(
                ignoring: shown == 0,
                child: Transform.translate(
                  offset: Offset(0, (1 - shown) * _restingExtent),
                  child: child,
                ),
              ),
            );
          },
          child: SafeArea(
            top: false,
            minimum: EdgeInsets.only(
              bottom: bottomInset + DetailActionBar.margin,
            ),
            child: Align(
              alignment: Alignment.bottomCenter,
              heightFactor: 1,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: FuncSpacing.lg),
                child: toolbar,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Download every page; the icon follows the whole work: a ring while
/// pages are in flight, a check once all are saved, an alert after a
/// failure. It follows the manager's change stream itself, so progress
/// ticks redraw this button rather than the page.
class DetailDownloadButton extends ConsumerStatefulWidget {
  const DetailDownloadButton({
    super.key,
    required this.entity,
    required this.onPressed,
  });

  final IllustEntity entity;
  final VoidCallback onPressed;

  @override
  ConsumerState<DetailDownloadButton> createState() =>
      _DetailDownloadButtonState();
}

class _DetailDownloadButtonState extends ConsumerState<DetailDownloadButton> {
  StreamSubscription<void>? _changes;

  @override
  void initState() {
    super.initState();
    _changes = ref.read(downloadManagerProvider).changes.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    unawaited(_changes?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final save = ref
        .watch(illustDownloadControllerProvider)
        .workStateFor(widget.entity);
    final colors = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    final progress = save.progress;
    return IconButton(
      tooltip: switch (save.state) {
        IllustPageSaveState.none => l10n.downloadAll,
        IllustPageSaveState.downloading => l10n.downloadRunning,
        IllustPageSaveState.exist => l10n.detailDownloaded,
        IllustPageSaveState.error => l10n.downloadFailed,
      },
      onPressed: widget.onPressed,
      icon: StateIconSwitcher(
        value: save.state,
        child: switch (save.state) {
          IllustPageSaveState.downloading => SizedBox.square(
            dimension: 22,
            child: CircularProgressIndicator(
              // Nothing measured yet (queued, unknown length): spin.
              value: progress == null || progress == 0 ? null : progress,
              strokeWidth: 2.5,
            ),
          ),
          IllustPageSaveState.exist => Icon(
            Icons.download_done,
            color: colors.primary,
          ),
          IllustPageSaveState.error => Icon(
            Icons.error_outline,
            color: colors.error,
          ),
          IllustPageSaveState.none => const Icon(Icons.download_outlined),
        },
      ),
    );
  }
}
