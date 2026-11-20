import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/platform/desktop_window_channel.dart';
import 'desktop_title_bar.dart';

/// Returns the global bounding [Rect] of the render box attached to [key],
/// or `null` when not yet attached or sized.
Rect? globalRectOfKey(GlobalKey key) {
  final renderObject = key.currentContext?.findRenderObject();
  if (renderObject is! RenderBox ||
      !renderObject.attached ||
      !renderObject.hasSize) {
    return null;
  }
  return renderObject.localToGlobal(Offset.zero) & renderObject.size;
}

/// Coalesces post-frame Win32 non-client hit-region measurement and publishes
/// deduplicated region signatures to [DesktopWindowActions].
///
/// Shared by `DesktopCommandBar`, `DesktopWindowFrame`, and
/// `DesktopFallbackWindowChrome` so all three publish identical signature
/// formats and clean up on hide or dispose.
class DesktopTitleBarRegionPublisher {
  bool _measurePending = false;
  String? _lastSignature;
  DesktopWindowActions? _lastActions;

  /// Schedules one post-frame measurement using [resolve], which returns the
  /// active actions, hit regions, and optional title-bar height (or `null` to
  /// skip publishing).
  void schedulePublish(
    DesktopWindowActions? actions, {
    required bool Function() isMounted,
    required ({
      DesktopWindowActions actions,
      List<DesktopTitleBarRegion> regions,
      double? titleBarHeight,
    })?
    Function()
    resolve,
  }) {
    _lastActions = actions;
    if (actions == null || _measurePending) return;
    _measurePending = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _measurePending = false;
      if (!isMounted()) return;
      final snapshot = resolve();
      if (snapshot == null) return;
      _lastActions = snapshot.actions;
      final signature = _signatureOf(snapshot.regions);
      if (signature == _lastSignature) return;
      _lastSignature = signature;
      final publishWithHeight = snapshot.actions.onRegionsWithHeightChanged;
      final height = snapshot.titleBarHeight;
      if (publishWithHeight != null && height != null) {
        publishWithHeight(snapshot.regions, height);
      } else {
        snapshot.actions.onRegionsChanged(snapshot.regions);
      }
    });
  }

  /// Drops the cached signature without publishing (used when another chrome
  /// layer such as `DesktopCommandBar` owns region publishing).
  void resetSignature() {
    _lastSignature = null;
  }

  /// Publishes empty regions if this publisher previously published non-empty
  /// or tracked regions.
  void clear([DesktopWindowActions? overrideActions]) {
    if (_lastSignature == null) return;
    _lastSignature = null;
    final actions = overrideActions ?? _lastActions;
    if (actions == null) return;
    final publishWithHeight = actions.onRegionsWithHeightChanged;
    if (publishWithHeight != null) {
      publishWithHeight(const [], 0);
    } else {
      actions.onRegionsChanged(const []);
    }
  }

  /// Helper to add a non-empty keyed region to [out].
  static void addRegion(
    List<DesktopTitleBarRegion> out,
    GlobalKey key,
    String kind,
  ) {
    final rect = globalRectOfKey(key);
    if (rect != null && !rect.isEmpty) {
      out.add(DesktopTitleBarRegion(rect: rect, kind: kind));
    }
  }

  static String _signatureOf(List<DesktopTitleBarRegion> regions) => [
    for (final r in regions)
      '${r.kind}:${r.rect.left.toStringAsFixed(1)},'
          '${r.rect.top.toStringAsFixed(1)},'
          '${r.rect.right.toStringAsFixed(1)},'
          '${r.rect.bottom.toStringAsFixed(1)}',
  ].join(';');
}
