import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../../../app/layout/app_breakpoints.dart';
import '../../../../app/navigation/home_shell_metrics.dart';
import '../../../../app/theme/func_semantic_tokens.dart';

/// Frames wide flat detail routes (`>= 960x600`) inside a scrimmed modal card
/// over the live feed while keeping [child]'s state anchored across resizes
/// via a persistent [GlobalKey].
class DetailOverlayFrame extends StatefulWidget {
  const DetailOverlayFrame({super.key, required this.child});

  final Widget child;

  @override
  State<DetailOverlayFrame> createState() => _DetailOverlayFrameState();
}

class _DetailOverlayFrameState extends State<DetailOverlayFrame> {
  final _childKey = GlobalKey();
  int? _scrimPointer;
  bool _popping = false;

  Future<void> _dismissOverlay() async {
    if (_popping || !mounted) return;
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return;
    _popping = true;
    try {
      await Navigator.maybePop(context);
    } finally {
      if (mounted && (ModalRoute.of(context)?.isCurrent ?? true)) {
        _popping = false;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final content = KeyedSubtree(key: _childKey, child: widget.child);
    final outerSize = HomeShellChrome.contentSizeOf(context);
    final canPop = Navigator.maybeOf(context)?.canPop() ?? false;
    final bounded =
        canPop && AppBreakpoints.useBoundedDetailOverlayOf(context, outerSize);
    if (!bounded) return content;

    final tokens = FuncSemanticTokens.of(context);
    final outerChrome = HomeShellChrome.maybeOf(context);
    final outerMedia = MediaQuery.of(context);

    return Stack(
      fit: StackFit.expand,
      children: [
        Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (event) => _scrimPointer = event.pointer,
          onPointerUp: (event) {
            if (_scrimPointer == event.pointer) {
              _scrimPointer = null;
              unawaited(_dismissOverlay());
            }
          },
          onPointerCancel: (event) {
            if (_scrimPointer == event.pointer) {
              _scrimPointer = null;
            }
          },
          child: GestureDetector(
            key: const ValueKey('detail-overlay-scrim'),
            behavior: HitTestBehavior.opaque,
            onTap: () => unawaited(_dismissOverlay()),
            child: const ColoredBox(color: Color(0x990C0B0E)),
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: FuncSpacing.lg,
              vertical: FuncSpacing.md,
            ),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1680),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final cardSize = Size(
                      constraints.maxWidth,
                      constraints.maxHeight,
                    );
                    final framedChild = MediaQuery(
                      data: outerMedia
                          .copyWith(size: cardSize)
                          .removePadding(
                            removeTop: true,
                            removeBottom: true,
                            removeLeft: true,
                            removeRight: true,
                          ),
                      child: outerChrome == null
                          ? content
                          : HomeShellChrome(
                              bottomBarExtent: 0,
                              railExtent: 0,
                              bottomBarVisibleExtent:
                                  outerChrome.bottomBarVisibleExtent,
                              bottomBarVisibility:
                                  outerChrome.bottomBarVisibility,
                              onBranchRootScroll:
                                  outerChrome.onBranchRootScroll,
                              child: content,
                            ),
                    );
                    return DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: FuncShape.dialog,
                        border: Border.all(color: tokens.brandHairline),
                        boxShadow: tokens.layerLift,
                      ),
                      child: ClipRRect(
                        borderRadius: FuncShape.dialog,
                        child: framedChild,
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
