import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';

import 'desktop_title_bar.dart';

/// Unified height of the desktop architectural command header when it owns the
/// custom window title bar (Windows / macOS).
const double kDesktopCommandBarHeight = 48.0;

/// Compact height of the desktop command toolbar when the OS already draws a
/// native system title bar (e.g. Linux GTK HeaderBar / X11 WM frame).
const double kDesktopCompactCommandBarHeight = 40.0;

/// Effective rendered height of the desktop command bar for [chrome].
double desktopCommandBarHeightFor(DesktopChromeMetrics? chrome) =>
    (chrome?.usesSystemTitleBar ?? false)
    ? kDesktopCompactCommandBarHeight
    : kDesktopCommandBarHeight;

/// Coordinates temporary immersive hiding of the desktop command bar (e.g.
/// while a dark fullscreen media viewer occupies the root navigator) without
/// tearing down [DesktopCommandBarScope] for the shell routes underneath.
class DesktopCommandBarController {
  final Set<Object> _hiddenOwners = <Object>{};
  final ValueNotifier<bool> _hidden = ValueNotifier<bool>(false);
  bool _disposed = false;
  bool _notifyScheduled = false;

  ValueListenable<bool> get hidden => _hidden;

  void setHidden(Object owner, bool value) {
    if (_disposed) return;
    final changed = value
        ? _hiddenOwners.add(owner)
        : _hiddenOwners.remove(owner);
    if (!changed) return;
    final next = _hiddenOwners.isNotEmpty;
    if (_hidden.value == next) return;
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.idle ||
        phase == SchedulerPhase.postFrameCallbacks) {
      _hidden.value = next;
      return;
    }
    if (_notifyScheduled) return;
    _notifyScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _notifyScheduled = false;
      if (_disposed) return;
      final target = _hiddenOwners.isNotEmpty;
      if (_hidden.value != target) _hidden.value = target;
    });
  }

  void dispose() {
    _disposed = true;
    _hiddenOwners.clear();
    _hidden.dispose();
  }
}

/// Announces to descendant chrome widgets (`ShellRail`, `HeaderSearch`,
/// `HeaderRefresh`, search bars) that an outer `DesktopCommandBar` already owns
/// top-level navigation, search, refresh, and sidebar toggling.
class DesktopCommandBarScope extends InheritedWidget {
  const DesktopCommandBarScope({
    super.key,
    required this.active,
    this.controller,
    required super.child,
  });

  final bool active;
  final DesktopCommandBarController? controller;

  static bool isActiveOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<DesktopCommandBarScope>()
          ?.active ??
      false;

  static DesktopCommandBarController? controllerOf(BuildContext context) =>
      context
          .getInheritedWidgetOfExactType<DesktopCommandBarScope>()
          ?.controller;

  @override
  bool updateShouldNotify(DesktopCommandBarScope oldWidget) =>
      active != oldWidget.active || controller != oldWidget.controller;
}

/// Projects a contextual page action widget (e.g. search filters) into the
/// trailing action slot of `DesktopCommandBar` while this subtree belongs to
/// the active branch and current top route.
class DesktopCommandActionsAnchor extends StatefulWidget {
  const DesktopCommandActionsAnchor({
    super.key,
    required this.action,
    required this.child,
  });

  final Widget? action;
  final Widget child;

  static final List<_DesktopCommandActionsAnchorState> _anchors = [];
  static final Set<VoidCallback> _listeners = {};
  static bool _notifyScheduled = false;

  static void addListener(VoidCallback listener) => _listeners.add(listener);

  static void removeListener(VoidCallback listener) =>
      _listeners.remove(listener);

  static Widget? activeAction() {
    for (var i = _anchors.length - 1; i >= 0; i--) {
      final anchor = _anchors[i];
      if (anchor._isEligible()) return anchor.widget.action;
    }
    return null;
  }

  static void _scheduleNotify() {
    if (_notifyScheduled || _listeners.isEmpty) return;
    _notifyScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _notifyScheduled = false;
      for (final listener in List<VoidCallback>.of(_listeners)) {
        listener();
      }
    });
  }

  @override
  State<DesktopCommandActionsAnchor> createState() =>
      _DesktopCommandActionsAnchorState();
}

class _DesktopCommandActionsAnchorState
    extends State<DesktopCommandActionsAnchor> {
  bool _isEligible() {
    if (!mounted || widget.action == null) return false;
    if (!TickerMode.getValuesNotifier(context).value.enabled) return false;
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return false;
    return true;
  }

  @override
  void initState() {
    super.initState();
    DesktopCommandActionsAnchor._anchors.add(this);
    DesktopCommandActionsAnchor._scheduleNotify();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    TickerMode.valuesOf(context);
    ModalRoute.of(context);
    DesktopCommandActionsAnchor._scheduleNotify();
  }

  @override
  void didUpdateWidget(DesktopCommandActionsAnchor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.action != widget.action) {
      DesktopCommandActionsAnchor._scheduleNotify();
    }
  }

  @override
  void dispose() {
    DesktopCommandActionsAnchor._anchors.remove(this);
    DesktopCommandActionsAnchor._scheduleNotify();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
