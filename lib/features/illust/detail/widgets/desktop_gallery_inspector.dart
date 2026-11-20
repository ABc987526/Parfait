import 'dart:async' show unawaited;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../../app/motion/hero_transition.dart';
import '../../../../app/motion/motion_tokens.dart';
import '../../../../app/motion/state_fade.dart';
import '../../../../app/navigation/home_shell_metrics.dart';
import '../../../../app/navigation/routes.dart';
import '../../../../app/theme/func_semantic_tokens.dart';
import '../../../../app/widgets/feed/desktop_inspector_scope.dart';
import '../../../../core/entity/illust_entity.dart';
import '../../../../core/settings/app_settings.dart';
import '../../../../core/settings/settings_controller.dart';
import '../detail_page_activity.dart';
import '../illust_detail_page.dart';

/// Shared Hero scope for artworks displayed inside [DesktopGalleryInspector]
/// so its images never share a Hero tag with the left gallery grid.
const String desktopInspectorHeroScope = 'desktop-inspector';

/// Non-modal right inspector panel (**Desktop Detail Option A**): keeps the live
/// masonry gallery scrollable on the left while embedding a width-constrained
/// full [IllustDetailPage] beside it so view history, multi-page browsing,
/// ugoira playback, tags, comments, related works, and actions stay complete.
class DesktopGalleryInspector extends StatelessWidget {
  const DesktopGalleryInspector({
    super.key,
    required this.target,
    required this.onClose,
    required this.onOpenStage,
    this.panelWidth = width,
    this.backController,
    this.active = true,
  });

  static const double width = 540;

  final DesktopInspectorTarget target;
  final VoidCallback onClose;
  final ValueChanged<IllustEntity> onOpenStage;
  final double panelWidth;
  final IllustEmbeddedBackController? backController;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final outerChrome = HomeShellChrome.maybeOf(context);
    final outerMedia = MediaQuery.of(context);
    final tokens = FuncSemanticTokens.of(context);
    final entity = target.entity;

    return DecoratedBox(
      key: const Key('desktop-gallery-inspector'),
      decoration: BoxDecoration(
        color: tokens.surface,
        border: BorderDirectional(
          start: BorderSide(color: tokens.brandHairline),
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final height = constraints.hasBoundedHeight
              ? constraints.maxHeight
              : outerMedia.size.height;
          final framed = MediaQuery(
            data: outerMedia
                .copyWith(size: Size(panelWidth, height))
                .removePadding(
                  removeTop: true,
                  removeBottom: true,
                  removeLeft: true,
                  removeRight: true,
                ),
            child: outerChrome == null
                ? _buildDetail(entity)
                : HomeShellChrome(
                    bottomBarExtent: 0,
                    railExtent: 0,
                    bottomBarVisibleExtent: outerChrome.bottomBarVisibleExtent,
                    bottomBarVisibility: outerChrome.bottomBarVisibility,
                    onBranchRootScroll: outerChrome.onBranchRootScroll,
                    child: _buildDetail(entity),
                  ),
          );
          return NotificationListener<ScrollNotification>(
            onNotification: (_) => true,
            child: DetailPageActivity(
              active: active,
              child: StateFade(
                kind: entity.id,
                child: KeyedSubtree(key: ValueKey(entity.id), child: framed),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildDetail(IllustEntity entity) => IllustDetailPage(
    illustId: entity.id,
    initialEntity: entity,
    heroScope: desktopInspectorHeroScope,
    heroImageUrl: target.heroImageUrl,
    heroImageDecodeWidth: target.heroImageDecodeWidth,
    embeddedInspector: true,
    onCloseInspector: onClose,
    onOpenFullStage: onOpenStage,
    embeddedBackController: backController,
  );
}

/// Reusable desktop master-detail host: wraps any illust gallery [child] with
/// [DesktopInspectorScope], animates the `420–520dp` [DesktopGalleryInspector]
/// open/closed alongside it when [DesktopDetailMode.inspector] is active, and
/// intercepts `Esc` / mouse back via [PopScope] before the outer shell pops or
/// switches branches.
class DesktopInspectableGallery extends ConsumerStatefulWidget {
  const DesktopInspectableGallery({
    super.key,
    required this.child,
    this.enabled = true,
    this.active = true,
  });

  final Widget child;

  /// Caller gate (for example, disabled while multi-select management is on).
  final bool enabled;

  /// Whether the active view currently renders illust/manga cards. Switching to
  /// non-illust tabs (`novel`, `user`) closes any open inspector automatically.
  final bool active;

  @override
  ConsumerState<DesktopInspectableGallery> createState() =>
      _DesktopInspectableGalleryState();
}

class _DesktopInspectableGalleryState
    extends ConsumerState<DesktopInspectableGallery>
    with SingleTickerProviderStateMixin {
  final _selectedId = ValueNotifier<int?>(null);
  final _backController = IllustEmbeddedBackController();
  late final AnimationController _panelController = AnimationController(
    vsync: this,
    value: 0,
  );

  DesktopInspectorTarget? _selected;
  DesktopInspectorTarget? _rendered;
  bool _snapCloseScheduled = false;

  @override
  void didUpdateWidget(DesktopInspectableGallery oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((!widget.enabled || !widget.active) &&
        (_selected != null || _rendered != null)) {
      _snapCloseSync();
    }
  }

  @override
  void dispose() {
    _panelController.dispose();
    _selectedId.dispose();
    super.dispose();
  }

  void _snapCloseSync() {
    _selected = null;
    _rendered = null;
    _selectedId.value = null;
    _panelController.value = 0;
  }

  void _scheduleSnapClose() {
    if (_snapCloseScheduled) return;
    _snapCloseScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _snapCloseScheduled = false;
      if (!mounted || (_selected == null && _rendered == null)) return;
      setState(_snapCloseSync);
    });
  }

  void _open(DesktopInspectorTarget target) {
    if (!mounted) return;
    setState(() {
      _selected = target;
      _rendered = target;
      _selectedId.value = target.entity.id;
    });
    final (duration, curve) = MotionTokens.springCurve(
      context,
      MotionSpring.spatialFast,
    );
    if (duration == Duration.zero || !TickerMode.valuesOf(context).enabled) {
      _panelController.value = 1;
      return;
    }
    unawaited(_panelController.animateTo(1, duration: duration, curve: curve));
  }

  void _close() {
    if (_selected == null) return;
    setState(() {
      _selected = null;
      _selectedId.value = null;
    });
    final (duration, curve) = MotionTokens.springCurve(
      context,
      MotionSpring.spatialFast,
    );
    if (duration == Duration.zero || !TickerMode.valuesOf(context).enabled) {
      setState(() {
        _rendered = null;
        _panelController.value = 0;
      });
      return;
    }
    unawaited(
      _panelController.animateBack(0, duration: duration, curve: curve).then((
        _,
      ) {
        if (!mounted || _selected != null) return;
        if (_panelController.isDismissed) {
          setState(() => _rendered = null);
        }
      }),
    );
  }

  void _openFullStage(
    DesktopInspectorTarget target,
    IllustEntity latestEntity,
  ) {
    if (target.heroImageUrl != null) {
      noteHeroCardOpened(
        context,
        illustHeroTag(target.heroScope, latestEntity.id),
      );
    }
    unawaited(
      openIllust(
        context,
        latestEntity.id,
        initialEntity: latestEntity,
        heroScope: target.heroScope,
        heroImageUrl: target.heroImageUrl,
        heroImageDecodeWidth: target.heroImageDecodeWidth,
        pagerSource: target.pagerSource,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<DesktopDetailMode>(desktopDetailModeProvider, (_, mode) {
      if (mode != DesktopDetailMode.inspector &&
          (_selected != null || _rendered != null)) {
        setState(_snapCloseSync);
      }
    });
    final detailMode = ref.watch(desktopDetailModeProvider);
    final modeEnabled =
        widget.enabled &&
        widget.active &&
        canUseDesktopInspector(context, detailMode);

    return LayoutBuilder(
      builder: (context, constraints) {
        final canInspect =
            modeEnabled && constraints.maxWidth >= desktopInspectorHostMinWidth;
        if (!canInspect && (_selected != null || _rendered != null)) {
          _scheduleSnapClose();
        }
        final inspectorWidth = (constraints.maxWidth * 0.40).clamp(
          420.0,
          520.0,
        );
        final tickerActive = TickerMode.valuesOf(context).enabled;
        final routeCurrent = ModalRoute.of(context)?.isCurrent ?? true;
        final isPanelOpen = canInspect && _selected != null;

        final panel = canInspect && _rendered != null
            ? AnimatedBuilder(
                animation: _panelController,
                child: HeroMode(
                  enabled: isPanelOpen && tickerActive,
                  child: SizedBox(
                    width: inspectorWidth,
                    child: DesktopGalleryInspector(
                      target: _rendered!,
                      panelWidth: inspectorWidth,
                      active: isPanelOpen && tickerActive && routeCurrent,
                      backController: _backController,
                      onClose: _close,
                      onOpenStage: (latest) =>
                          _openFullStage(_rendered!, latest),
                    ),
                  ),
                ),
                builder: (context, child) {
                  final progress = _panelController.value.clamp(0.0, 1.0);
                  return IgnorePointer(
                    ignoring: !isPanelOpen,
                    child: ClipRect(
                      child: Align(
                        alignment: AlignmentDirectional.topStart,
                        widthFactor: progress,
                        child: Opacity(opacity: progress, child: child),
                      ),
                    ),
                  );
                },
              )
            : null;

        return PopScope(
          canPop: !isPanelOpen || !routeCurrent || !tickerActive,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            if (_backController.handleBack()) return;
            _close();
          },
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: DesktopInspectorScope(
                  enabled: canInspect,
                  selectedId: _selectedId,
                  onInspect: _open,
                  child: widget.child,
                ),
              ),
              ?panel,
            ],
          ),
        );
      },
    );
  }
}
