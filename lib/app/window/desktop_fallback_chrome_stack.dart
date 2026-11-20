import 'package:flutter/rendering.dart'
    show
        BoxHitTestResult,
        HitTestEntry,
        RenderBox,
        RenderMouseRegion,
        RenderSemanticsAnnotations,
        RenderStack,
        StackParentData;
import 'package:material_ui/material_ui.dart';

/// Custom [Stack] used by `DesktopFallbackWindowChrome` so its translucent
/// top drag/double-tap zone yields hit-testing to interactive controls
/// underneath (such as `ImageViewerPage`'s BackButton beside traffic lights).
class DesktopFallbackChromeStack extends Stack {
  const DesktopFallbackChromeStack({
    super.key,
    required this.hasDragZone,
    super.children,
  }) : super(fit: StackFit.expand);

  final bool hasDragZone;

  @override
  RenderDesktopFallbackChromeStack createRenderObject(BuildContext context) =>
      RenderDesktopFallbackChromeStack(
        hasDragZone: hasDragZone,
        alignment: alignment,
        textDirection: textDirection ?? Directionality.maybeOf(context),
        fit: fit,
        clipBehavior: clipBehavior,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    RenderDesktopFallbackChromeStack renderObject,
  ) {
    renderObject
      ..hasDragZone = hasDragZone
      ..alignment = alignment
      ..textDirection = textDirection ?? Directionality.maybeOf(context)
      ..fit = fit
      ..clipBehavior = clipBehavior;
  }
}

class RenderDesktopFallbackChromeStack extends RenderStack {
  RenderDesktopFallbackChromeStack({
    required bool hasDragZone,
    super.alignment,
    super.textDirection,
    super.fit,
    super.clipBehavior,
  }) : _hasDragZone = hasDragZone;

  bool _hasDragZone;
  bool get hasDragZone => _hasDragZone;
  set hasDragZone(bool value) {
    if (_hasDragZone == value) return;
    _hasDragZone = value;
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    if (!hasDragZone) {
      return defaultHitTestChildren(result, position: position);
    }
    final content = firstChild;
    final dragZone = content == null ? null : childAfter(content);
    var child = lastChild;
    while (child != null) {
      final parentData = child.parentData! as StackParentData;
      // Yield the translucent top drag/double-tap zone to interactive controls
      // (such as ImageViewerPage's BackButton beside macOS traffic lights) so
      // DoubleTapGestureRecognizer never delays or intercepts clicks.
      final skipDrag =
          identical(child, dragZone) &&
          content != null &&
          child.hasSize &&
          (parentData.offset & child.size).contains(position) &&
          _hitsInteractiveChild(content, position);
      if (!skipDrag) {
        final isHit = result.addWithPaintOffset(
          offset: parentData.offset,
          position: position,
          hitTest: (hitResult, transformed) =>
              child!.hitTest(hitResult, position: transformed),
        );
        if (isHit) return true;
      }
      child = parentData.previousSibling;
    }
    return false;
  }

  static bool _hitsInteractiveChild(RenderBox content, Offset position) {
    final contentOffset = (content.parentData! as StackParentData).offset;
    final probe = BoxHitTestResult();
    content.hitTest(probe, position: position - contentOffset);
    for (final HitTestEntry entry in probe.path) {
      final target = entry.target;
      if (target is RenderSemanticsAnnotations) {
        final props = target.properties;
        if (props.enabled != false &&
            (props.button == true ||
                props.link == true ||
                props.textField == true ||
                props.slider == true ||
                props.toggled != null ||
                props.checked != null ||
                props.selected != null)) {
          return true;
        }
      }
      if (target is RenderMouseRegion &&
          target.cursor == SystemMouseCursors.click) {
        return true;
      }
    }
    return false;
  }
}
