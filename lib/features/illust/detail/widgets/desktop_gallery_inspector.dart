import 'package:material_ui/material_ui.dart';

import '../../../../app/motion/state_fade.dart';
import '../../../../app/navigation/home_shell_metrics.dart';
import '../../../../app/theme/func_semantic_tokens.dart';
import '../../../../app/widgets/feed/desktop_inspector_scope.dart';
import '../../../../core/entity/illust_entity.dart';
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
