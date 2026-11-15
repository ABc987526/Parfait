import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/auth/account_store.dart';
import '../../core/platform/desktop_window_channel.dart';
import '../../core/settings/app_settings.dart';
import '../../core/settings/settings_controller.dart';
import '../../l10n/context.dart';
import '../layout/form_factor.dart';
import '../motion/app_overlays.dart';
import '../navigation/forward_history.dart';
import '../navigation/keyboard_back.dart';
import '../navigation/routes.dart';
import '../person_avatar.dart';
import '../pull_to_refresh.dart';
import '../theme/func_semantic_tokens.dart';
import '../widgets/replica_switch_tile.dart';
import '../widgets/settings/persist_settings.dart';
import 'desktop_title_bar.dart';

/// Unified height of the desktop top command bar replacing the double overlay
/// + page top-bar chrome.
const double kDesktopCommandBarHeight = 48.0;

const _preHomePrefixes = ['/welcome', '/login'];
const _preHomeExact = {'', '/', '/splash', '/user-agreement'};

bool _isPreHomePath(String path) {
  if (_preHomeExact.contains(path)) return true;
  for (final prefix in _preHomePrefixes) {
    if (path == prefix || path.startsWith('$prefix/')) return true;
  }
  return false;
}

/// Announces to descendant chrome widgets (`ShellRail`, `HeaderSearch`,
/// `HeaderRefresh`, search bars) that an outer [DesktopCommandBar] already owns
/// top-level navigation, search, refresh, and sidebar toggling.
class DesktopCommandBarScope extends InheritedWidget {
  const DesktopCommandBarScope({
    super.key,
    required this.active,
    required super.child,
  });

  final bool active;

  static bool isActiveOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<DesktopCommandBarScope>()
          ?.active ??
      false;

  @override
  bool updateShouldNotify(DesktopCommandBarScope oldWidget) =>
      active != oldWidget.active;
}

/// Projects a contextual page action widget (e.g. search filters) into the
/// trailing action slot of [DesktopCommandBar] while this subtree belongs to
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

/// Persistent `48dp` desktop chrome strip rendered above route content on
/// Windows, macOS, and Linux.
class DesktopCommandBar extends ConsumerStatefulWidget {
  const DesktopCommandBar({
    super.key,
    required this.settings,
    required this.router,
  });

  final AppSettings settings;
  final GoRouter router;

  @override
  ConsumerState<DesktopCommandBar> createState() => _DesktopCommandBarState();
}

class _DesktopCommandBarState extends ConsumerState<DesktopCommandBar> {
  final GlobalKey _leftDragKey = GlobalKey();
  final GlobalKey _rightDragKey = GlobalKey();
  final GlobalKey _maximizeKey = GlobalKey();
  final GlobalKey _searchPillKey = GlobalKey();
  final GlobalKey _filterButtonKey = GlobalKey();
  final GlobalKey _accountButtonKey = GlobalKey();

  bool _regionMeasurePending = false;
  bool _rebuildPending = false;
  String? _lastRegionSignature;
  bool _searchOpening = false;

  @override
  void initState() {
    super.initState();
    widget.router.routerDelegate.addListener(_onRouterChanged);
    DesktopCommandActionsAnchor.addListener(_onAnchorChanged);
  }

  @override
  void didUpdateWidget(DesktopCommandBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.router != widget.router) {
      oldWidget.router.routerDelegate.removeListener(_onRouterChanged);
      widget.router.routerDelegate.addListener(_onRouterChanged);
    }
  }

  @override
  void dispose() {
    widget.router.routerDelegate.removeListener(_onRouterChanged);
    DesktopCommandActionsAnchor.removeListener(_onAnchorChanged);
    super.dispose();
  }

  void _scheduleRebuild() {
    if (!mounted) return;
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.persistentCallbacks ||
        phase == SchedulerPhase.midFrameMicrotasks) {
      if (_rebuildPending) return;
      _rebuildPending = true;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        _rebuildPending = false;
        if (mounted) setState(() {});
      });
      return;
    }
    setState(() {});
  }

  void _onRouterChanged() => _scheduleRebuild();

  void _onAnchorChanged() => _scheduleRebuild();

  BuildContext? _navContext() {
    final overlayContext = widget
        .router
        .routerDelegate
        .navigatorKey
        .currentState
        ?.overlay
        ?.context;
    if (overlayContext != null && overlayContext.mounted) return overlayContext;
    final navigatorContext =
        widget.router.routerDelegate.navigatorKey.currentContext;
    if (navigatorContext != null && navigatorContext.mounted) {
      return navigatorContext;
    }
    return null;
  }

  Rect? _globalRectOf(GlobalKey key) {
    final renderObject = key.currentContext?.findRenderObject();
    if (renderObject is! RenderBox ||
        !renderObject.attached ||
        !renderObject.hasSize) {
      return null;
    }
    return renderObject.localToGlobal(Offset.zero) & renderObject.size;
  }

  void _scheduleRegionPublish(
    DesktopWindowActions? actions,
    DesktopChromeMetrics? chrome,
  ) {
    if (actions == null || chrome == null || _regionMeasurePending) return;
    _regionMeasurePending = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _regionMeasurePending = false;
      if (!mounted) return;
      final currentChrome = DesktopChromeMetrics.maybeOf(context);
      final currentActions =
          currentChrome?.actions ??
          DesktopWindowScope.maybeOf(context)?.actions;
      if (currentActions == null || currentChrome == null) return;

      final regions = <DesktopTitleBarRegion>[];
      if (!currentChrome.isFullScreen && !currentChrome.usesSystemTitleBar) {
        final leftRect = _globalRectOf(_leftDragKey);
        if (leftRect != null && !leftRect.isEmpty) {
          regions.add(DesktopTitleBarRegion(rect: leftRect, kind: 'caption'));
        }
        final rightRect = _globalRectOf(_rightDragKey);
        if (rightRect != null && !rightRect.isEmpty) {
          regions.add(DesktopTitleBarRegion(rect: rightRect, kind: 'caption'));
        }
        if (currentChrome.showCustomButtons) {
          final maxRect = _globalRectOf(_maximizeKey);
          if (maxRect != null && !maxRect.isEmpty) {
            regions.add(DesktopTitleBarRegion(rect: maxRect, kind: 'maximize'));
          }
        }
      }
      final signature = [
        for (final r in regions)
          '${r.kind}:${r.rect.left.toStringAsFixed(1)},'
              '${r.rect.top.toStringAsFixed(1)},'
              '${r.rect.right.toStringAsFixed(1)},'
              '${r.rect.bottom.toStringAsFixed(1)}',
      ].join(';');
      if (signature == _lastRegionSignature) return;
      _lastRegionSignature = signature;
      final publishWithHeight = currentActions.onRegionsWithHeightChanged;
      if (publishWithHeight != null) {
        publishWithHeight(regions, kDesktopCommandBarHeight);
      } else {
        currentActions.onRegionsChanged(regions);
      }
    });
  }

  Future<void> _openSearch(Uri currentUri) async {
    if (_searchOpening) return;
    final navContext = _navContext();
    if (navContext == null) return;
    _searchOpening = true;
    try {
      final activeQuery = searchResultsQueryFromUri(currentUri);
      if (activeQuery != null) {
        await editSearchFromResults(
          navContext,
          anchor: () => _globalRectOf(_searchPillKey),
          keyword: activeQuery.keyword,
          type: activeQuery.type,
        );
      } else {
        await openSearchInput(
          navContext,
          anchor: () => _globalRectOf(_searchPillKey),
        );
      }
    } finally {
      _searchOpening = false;
    }
  }

  Future<void> _toggleRail(bool nextExpanded) async {
    final navContext = _navContext();
    if (navContext != null) {
      await persistSettings(
        navContext,
        () => ref.read(settingsProvider.notifier).setRailExpanded(nextExpanded),
      );
    } else {
      await ref.read(settingsProvider.notifier).setRailExpanded(nextExpanded);
    }
  }

  Future<void> _openFilterPopover() async {
    final navContext = _navContext();
    final anchorContext = _filterButtonKey.currentContext;
    if (navContext == null) return;
    await showAppAdaptivePopover<void>(
      context: navContext,
      anchorContext: anchorContext,
      minWidth: 260,
      maxWidth: 300,
      maxHeight: 240,
      useRootNavigator: true,
      builder: (popoverContext) => Consumer(
        builder: (popoverContext, popRef, _) {
          final l10n = popoverContext.l10n;
          final settings =
              popRef.watch(settingsProvider).value ?? widget.settings;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ReplicaSwitchTile(
                key: const Key('desktop-command-filter-r18'),
                title: Text(l10n.blockR18),
                value: settings.enableLocalBlockR18,
                onTap: () => unawaited(
                  persistSettings(
                    popoverContext,
                    () => popRef
                        .read(settingsProvider.notifier)
                        .setLocalBlockR18(!settings.enableLocalBlockR18),
                  ),
                ),
              ),
              const Divider(height: 1),
              ReplicaSwitchTile(
                key: const Key('desktop-command-filter-ai'),
                title: Text(l10n.blockAI),
                value: settings.enableLocalBlockAI,
                onTap: () => unawaited(
                  persistSettings(
                    popoverContext,
                    () => popRef
                        .read(settingsProvider.notifier)
                        .setLocalBlockAI(!settings.enableLocalBlockAI),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _openAccountPopover() async {
    final navContext = _navContext();
    final anchorContext = _accountButtonKey.currentContext;
    if (navContext == null) return;
    await showAppAdaptivePopover<void>(
      context: navContext,
      anchorContext: anchorContext,
      minWidth: 260,
      maxWidth: 320,
      maxHeight: 360,
      useRootNavigator: true,
      builder: (popoverContext) => Consumer(
        builder: (popoverContext, popRef, _) {
          final l10n = popoverContext.l10n;
          final state = popRef.watch(accountStoreProvider).value;
          final accounts = state?.accounts ?? const [];
          final currentId = state?.current?.id;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  FuncSpacing.lg,
                  FuncSpacing.md,
                  FuncSpacing.lg,
                  FuncSpacing.xs,
                ),
                child: Text(
                  l10n.accountSignedIn,
                  style: Theme.of(popoverContext).textTheme.labelMedium
                      ?.copyWith(
                        color: Theme.of(
                          popoverContext,
                        ).colorScheme.onSurfaceVariant,
                      ),
                ),
              ),
              if (accounts.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: FuncSpacing.lg,
                    vertical: FuncSpacing.md,
                  ),
                  child: Text(l10n.noAccounts),
                )
              else
                for (final account in accounts)
                  ListTile(
                    key: Key('desktop-command-account-${account.id}'),
                    dense: true,
                    leading: PersonAvatar(
                      imageUrl: account.profileImageUrl,
                      radius: 14,
                    ),
                    title: Text(
                      account.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '@${account.userId}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: account.id == currentId
                        ? Icon(
                            Icons.check,
                            color: Theme.of(popoverContext).colorScheme.primary,
                          )
                        : null,
                    onTap: () {
                      Navigator.of(popoverContext).pop();
                      if (account.id != currentId) {
                        unawaited(
                          popRef
                              .read(accountStoreProvider.notifier)
                              .switchAccount(account.id),
                        );
                      }
                    },
                  ),
              const Divider(height: 1),
              ListTile(
                key: const Key('desktop-command-account-settings'),
                dense: true,
                leading: const Icon(Icons.manage_accounts_outlined),
                title: Text(l10n.accountSettings),
                onTap: () {
                  Navigator.of(popoverContext).pop();
                  if (navContext.mounted) {
                    unawaited(openAccountSettings(navContext));
                  }
                },
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final chrome = DesktopChromeMetrics.maybeOf(context);
    final actions =
        chrome?.actions ?? DesktopWindowScope.maybeOf(context)?.actions;
    final hostMetrics =
        chrome?.hostMetrics ?? DesktopWindowPlatformMetrics.fallback;
    _scheduleRegionPublish(actions, chrome);

    final uri = liveRouterUri(widget.router);
    final isPreHome = _isPreHomePath(uri.path);
    final windowSize = MediaQuery.sizeOf(context);
    final form = FormFactor.of(context);
    final settings = ref.watch(settingsProvider).value ?? widget.settings;
    final showRailToggle =
        !isPreHome &&
        form.hasRail(windowSize.width) &&
        form.canToggleRail(windowSize.width, height: windowSize.height);
    final railExpanded = form.railExpanded(
      windowSize.width,
      choice: settings.railExpanded,
      height: windowSize.height,
    );
    final history = ForwardHistoryStack.ofRouter(widget.router);
    final leadingInset = chrome?.leadingInset ?? 0;
    final showSimulatedTrafficLights =
        chrome?.showSimulatedTrafficLights ?? false;
    final showCustomButtons = chrome?.showCustomButtons ?? false;

    final searchQuery = searchResultsQueryFromUri(uri);
    final keywordText = searchQuery?.keyword.trim() ?? '';
    final contextAction = isPreHome
        ? null
        : DesktopCommandActionsAnchor.activeAction();
    final currentAccount = ref.watch(accountStoreProvider).value?.current;

    const iconConstraints = BoxConstraints(minWidth: 34, minHeight: 34);
    const iconPadding = EdgeInsets.all(FuncSpacing.xs);

    return Material(
      key: const Key('desktop-command-bar'),
      color: colors.surface,
      child: Container(
        height: kDesktopCommandBarHeight,
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: colors.outlineVariant.withValues(alpha: 0.55),
            ),
          ),
        ),
        child: Row(
          children: [
            if (leadingInset > 0)
              SizedBox(
                width: leadingInset,
                height: kDesktopCommandBarHeight,
                child: showSimulatedTrafficLights
                    ? const SimulatedMacTrafficLights(
                        height: kDesktopCommandBarHeight,
                      )
                    : null,
              ),
            if (!isPreHome) ...[
              const SizedBox(width: FuncSpacing.xs),
              if (showRailToggle)
                _commandIconButton(
                  context,
                  key: const Key('desktop-command-rail-toggle'),
                  constraints: iconConstraints,
                  padding: iconPadding,
                  iconSize: 20,
                  tooltip: railExpanded ? l10n.railCollapse : l10n.railExpand,
                  onPressed: () => unawaited(_toggleRail(!railExpanded)),
                  icon: Icon(railExpanded ? Icons.menu_open : Icons.menu),
                ),
              ValueListenableBuilder<ForwardHistoryState>(
                valueListenable: history.stateListenable,
                builder: (context, historyState, _) => Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _commandIconButton(
                      context,
                      key: const Key('desktop-command-back'),
                      constraints: iconConstraints,
                      padding: iconPadding,
                      iconSize: 19,
                      tooltip: l10n.navBack,
                      onPressed: historyState.canGoBack
                          ? () => unawaited(history.goBack())
                          : null,
                      icon: const Icon(Icons.arrow_back),
                    ),
                    _commandIconButton(
                      context,
                      key: const Key('desktop-command-forward'),
                      constraints: iconConstraints,
                      padding: iconPadding,
                      iconSize: 19,
                      tooltip: l10n.navForward,
                      onPressed: historyState.canGoForward
                          ? () => unawaited(history.goForward())
                          : null,
                      icon: const Icon(Icons.arrow_forward),
                    ),
                  ],
                ),
              ),
              _commandIconButton(
                context,
                key: const Key('desktop-command-refresh'),
                constraints: iconConstraints,
                padding: iconPadding,
                iconSize: 19,
                tooltip: l10n.refresh,
                onPressed: () => PullToRefresh.triggerActive(_navContext()),
                icon: const Icon(Icons.refresh),
              ),
            ],
            Expanded(
              child: _DragSpacer(key: _leftDragKey, actions: actions),
            ),
            if (!isPreHome)
              Flexible(
                flex: 3,
                fit: FlexFit.loose,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: math.min(440, windowSize.width * 0.45),
                  ),
                  child: SearchShortcutAnchor(
                    onTrigger: () => unawaited(_openSearch(uri)),
                    child: _SearchCommandPill(
                      key: _searchPillKey,
                      hint: l10n.searchHint,
                      keyword: keywordText,
                      reverseTooltip: l10n.searchReverseImage,
                      onTapPill: () => unawaited(_openSearch(uri)),
                      onTapReverse: () {
                        final navContext = _navContext();
                        if (navContext != null) {
                          unawaited(openReverseImageSearch(navContext));
                        }
                      },
                    ),
                  ),
                ),
              ),
            Expanded(
              child: _DragSpacer(key: _rightDragKey, actions: actions),
            ),
            if (!isPreHome) ...[
              if (contextAction != null) ...[
                contextAction,
                const SizedBox(width: FuncSpacing.xs),
              ],
              KeyedSubtree(
                key: _filterButtonKey,
                child: _commandIconButton(
                  context,
                  key: const Key('desktop-command-filter'),
                  constraints: iconConstraints,
                  padding: iconPadding,
                  iconSize: 19,
                  tooltip: l10n.commandContentFilter,
                  onPressed: () => unawaited(_openFilterPopover()),
                  icon: const Icon(Icons.tune_outlined),
                ),
              ),
              KeyedSubtree(
                key: _accountButtonKey,
                child: _maybeWrapTooltip(
                  context,
                  message: l10n.commandSwitchAccount,
                  child: InkWell(
                    key: const Key('desktop-command-account'),
                    customBorder: const CircleBorder(),
                    onTap: () => unawaited(_openAccountPopover()),
                    child: Padding(
                      padding: const EdgeInsets.all(FuncSpacing.xs),
                      child: Semantics(
                        button: true,
                        label: l10n.commandSwitchAccount,
                        child: PersonAvatar(
                          imageUrl: currentAccount?.profileImageUrl,
                          radius: 13,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              SizedBox(
                width: showCustomButtons ? FuncSpacing.xs : FuncSpacing.sm,
              ),
            ],
            if (showCustomButtons)
              DesktopWindowCaptionButtons(
                height: kDesktopCommandBarHeight,
                isMaximized: chrome?.isMaximized ?? false,
                isActive: chrome?.isActive ?? true,
                nativeHoveredButton: hostMetrics.hoveredButton,
                nativePressedButton: hostMetrics.pressedButton,
                maximizeKey: _maximizeKey,
                actions: actions,
                brightnessListenable: null,
              ),
          ],
        ),
      ),
    );
  }
}

class _DragSpacer extends StatelessWidget {
  const _DragSpacer({super.key, required this.actions});

  final DesktopWindowActions? actions;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: actions == null ? null : (_) => actions!.onStartDragging(),
      onDoubleTap: actions?.onTitleBarDoubleClick,
      child: const SizedBox(height: kDesktopCommandBarHeight),
    );
  }
}

class _SearchCommandPill extends StatelessWidget {
  const _SearchCommandPill({
    super.key,
    required this.hint,
    required this.keyword,
    required this.reverseTooltip,
    required this.onTapPill,
    required this.onTapReverse,
  });

  final String hint;
  final String keyword;
  final String reverseTooltip;
  final VoidCallback onTapPill;
  final VoidCallback onTapReverse;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final hasKeyword = keyword.isNotEmpty;

    return Semantics(
      button: true,
      label: hasKeyword ? keyword : hint,
      child: Material(
        key: const Key('desktop-command-search-pill'),
        color: colors.surfaceContainerHighest.withValues(alpha: 0.72),
        borderRadius: FuncShape.pill,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTapPill,
          child: SizedBox(
            height: 34,
            child: Row(
              children: [
                const SizedBox(width: FuncSpacing.md),
                Icon(Icons.search, size: 17, color: colors.onSurfaceVariant),
                const SizedBox(width: FuncSpacing.sm),
                Expanded(
                  child: Text(
                    hasKeyword ? keyword : hint,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: hasKeyword
                          ? colors.onSurface
                          : colors.onSurfaceVariant,
                    ),
                  ),
                ),
                _commandIconButton(
                  context,
                  key: const Key('desktop-command-reverse-search'),
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                  padding: const EdgeInsets.all(FuncSpacing.xs),
                  iconSize: 17,
                  tooltip: reverseTooltip,
                  onPressed: onTapReverse,
                  icon: const Icon(Icons.photo_camera_outlined),
                ),
                const SizedBox(width: FuncSpacing.xxs),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Command bar buttons mount in `MaterialApp.router(builder: ...)` above
/// `Router`'s `Overlay`; only wire Material tooltips when an `Overlay` exists,
/// mirroring `DesktopWindowCaptionButtons` semantics fallback.
Widget _commandIconButton(
  BuildContext context, {
  required Key key,
  required BoxConstraints constraints,
  required EdgeInsetsGeometry padding,
  required double iconSize,
  required String tooltip,
  required VoidCallback? onPressed,
  required Widget icon,
}) {
  final hasOverlay = Overlay.maybeOf(context) != null;
  final button = IconButton(
    key: key,
    constraints: constraints,
    padding: padding,
    iconSize: iconSize,
    tooltip: hasOverlay ? tooltip : null,
    onPressed: onPressed,
    icon: icon,
  );
  return hasOverlay ? button : Semantics(tooltip: tooltip, child: button);
}

Widget _maybeWrapTooltip(
  BuildContext context, {
  required String message,
  required Widget child,
}) {
  if (Overlay.maybeOf(context) != null) {
    return Tooltip(message: message, child: child);
  }
  return child;
}
