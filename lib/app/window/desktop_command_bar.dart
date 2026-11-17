import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
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
import '../theme/func_tokens.dart';
import '../widgets/replica_switch_tile.dart';
import '../widgets/settings/persist_settings.dart';
import 'desktop_title_bar.dart';

/// Unified height of the desktop architectural command header.
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

/// Coordinates temporary immersive hiding of [DesktopCommandBar] (e.g. while
/// a dark fullscreen media viewer occupies the root navigator) without tearing
/// down [DesktopCommandBarScope] for the shell routes underneath.
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
/// `HeaderRefresh`, search bars) that an outer [DesktopCommandBar] already owns
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
  final GlobalKey _captionButtonsKey = GlobalKey();
  final GlobalKey _searchPillKey = GlobalKey();
  final GlobalKey _filterButtonKey = GlobalKey();
  final GlobalKey _accountButtonKey = GlobalKey();
  final Object _filterMenuGroup = Object();
  final Object _accountMenuGroup = Object();

  bool _regionMeasurePending = false;
  bool _rebuildPending = false;
  String? _lastRegionSignature;
  DesktopWindowActions? _lastActions;
  bool _searchOpening = false;
  bool _filterMenuOpen = false;
  bool _accountMenuOpen = false;

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
    final actions = _lastActions;
    if (actions != null && _lastRegionSignature != null) {
      final publishWithHeight = actions.onRegionsWithHeightChanged;
      if (publishWithHeight != null) {
        publishWithHeight(const [], 0);
      } else {
        actions.onRegionsChanged(const []);
      }
    }
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
    _lastActions = actions;
    if (actions == null || chrome == null || _regionMeasurePending) return;
    _regionMeasurePending = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _regionMeasurePending = false;
      if (!mounted) return;
      final currentChrome = DesktopChromeMetrics.maybeOf(context);
      final currentActions =
          currentChrome?.actions ??
          DesktopWindowScope.maybeOf(context)?.actions;
      _lastActions = currentActions;
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
          final buttonsRect = _globalRectOf(_captionButtonsKey);
          if (buttonsRect != null && !buttonsRect.isEmpty) {
            regions.add(
              DesktopTitleBarRegion(rect: buttonsRect, kind: 'buttons'),
            );
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

  Future<void> _openAnchoredMenu({
    required GlobalKey anchorKey,
    required Object groupId,
    required double minWidth,
    required double maxWidth,
    required double maxHeight,
    required WidgetBuilder builder,
  }) async {
    final navContext = _navContext();
    if (navContext == null) return;
    final overlayObject = Navigator.of(
      navContext,
      rootNavigator: true,
    ).overlay?.context.findRenderObject();
    if (overlayObject is! RenderBox || !overlayObject.hasSize) return;
    final initialAnchor =
        _globalRectOf(anchorKey) ??
        Rect.fromLTWH(
          overlayObject.size.width - FuncSpacing.xxl,
          0,
          0,
          kDesktopCommandBarHeight,
        );
    await showAppPanel<void>(
      context: navContext,
      barrierLabel: MaterialLocalizations.of(
        navContext,
      ).modalBarrierDismissLabel,
      barrierColor: FuncTokens.transparent,
      useRootNavigator: true,
      builder: (panelContext) => _CommandAnchoredMenuLayer(
        overlay: overlayObject,
        initialAnchor: initialAnchor,
        anchorOf: () => _globalRectOf(anchorKey),
        groupId: groupId,
        minWidth: minWidth,
        maxWidth: maxWidth,
        maxHeight: maxHeight,
        child: builder(panelContext),
      ),
    );
  }

  Future<void> _openFilterPopover() async {
    final navContext = _navContext();
    if (navContext == null) return;
    if (_filterMenuOpen) {
      await Navigator.of(navContext, rootNavigator: true).maybePop();
      return;
    }
    _filterMenuOpen = true;
    try {
      await _openAnchoredMenu(
        anchorKey: _filterButtonKey,
        groupId: _filterMenuGroup,
        minWidth: 240,
        maxWidth: 288,
        maxHeight: 240,
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
    } finally {
      _filterMenuOpen = false;
    }
  }

  Future<void> _openAccountPopover() async {
    final navContext = _navContext();
    if (navContext == null) return;
    if (_accountMenuOpen) {
      await Navigator.of(navContext, rootNavigator: true).maybePop();
      return;
    }
    _accountMenuOpen = true;
    try {
      await _openAnchoredMenu(
        anchorKey: _accountButtonKey,
        groupId: _accountMenuGroup,
        minWidth: 260,
        maxWidth: 320,
        maxHeight: 360,
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
                              color: Theme.of(
                                popoverContext,
                              ).colorScheme.primary,
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
                    if (liveRouterUri(widget.router).path !=
                        '/settings/account') {
                      widget.router.go('/settings/account');
                    }
                  },
                ),
              ],
            );
          },
        ),
      );
    } finally {
      _accountMenuOpen = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final l10n = context.l10n;
    final tokens = FuncSemanticTokens.of(context);
    final chrome = DesktopChromeMetrics.maybeOf(context);
    final actions =
        chrome?.actions ?? DesktopWindowScope.maybeOf(context)?.actions;
    final hostMetrics =
        chrome?.hostMetrics ?? DesktopWindowPlatformMetrics.fallback;
    _scheduleRegionPublish(actions, chrome);

    final uri = liveRouterUri(widget.router);
    final isPreHome = _isPreHomePath(uri.path);
    final windowSize = MediaQuery.sizeOf(context);
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
    final form = FormFactor.of(context);
    final canToggleRail = form.canToggleRail(
      windowSize.width,
      height: windowSize.height,
    );
    final railChoice =
        ref.watch(railExpandedProvider) ?? widget.settings.railExpanded;
    final railExpanded = form.railExpanded(
      windowSize.width,
      height: windowSize.height,
      choice: railChoice,
    );
    final searchWidth = (windowSize.width * 0.27).clamp(210.0, 360.0);

    const iconConstraints = BoxConstraints(minWidth: 30, minHeight: 30);
    const iconPadding = EdgeInsets.all(FuncSpacing.xs);

    return Material(
      key: const Key('desktop-command-bar'),
      color: colors.surfaceContainerLow,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: tokens.brandHairline)),
        ),
        child: SizedBox(
          height: kDesktopCommandBarHeight,
          child: Stack(
            fit: StackFit.expand,
            clipBehavior: Clip.none,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
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
                  const SizedBox(width: FuncSpacing.md),
                  if (!isPreHome) ...[
                    if (canToggleRail) ...[
                      _commandIconButton(
                        context,
                        key: const Key('desktop-command-rail-toggle'),
                        constraints: iconConstraints,
                        padding: iconPadding,
                        iconSize: 18,
                        tooltip: railExpanded
                            ? l10n.railCollapse
                            : l10n.railExpand,
                        onPressed: () => unawaited(
                          persistSettings(
                            context,
                            () => ref
                                .read(settingsProvider.notifier)
                                .setRailExpanded(!railExpanded),
                          ),
                        ),
                        icon: Icon(railExpanded ? Icons.menu_open : Icons.menu),
                      ),
                      const SizedBox(width: FuncSpacing.xs),
                    ],
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: tokens.brandTintWeak,
                        borderRadius: FuncShape.pill,
                        border: Border.all(color: tokens.brandHairline),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: FuncSpacing.sm + FuncSpacing.xxs,
                          vertical: FuncSpacing.xs,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Image.asset(
                              'assets/branding/parfait_icon.png',
                              width: 15,
                              height: 15,
                              excludeFromSemantics: true,
                            ),
                            const SizedBox(width: FuncSpacing.xs),
                            Text(
                              'Parfait',
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: colors.primary,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -0.2,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: FuncSpacing.sm),
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
                            iconSize: 17,
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
                            iconSize: 17,
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
                      iconSize: 17,
                      tooltip: l10n.refresh,
                      onPressed: () =>
                          PullToRefresh.triggerActive(_navContext()),
                      icon: const Icon(Icons.refresh),
                    ),
                  ],
                  Expanded(
                    child: _DragSpacer(key: _leftDragKey, actions: actions),
                  ),
                  if (!isPreHome)
                    SizedBox(
                      width: searchWidth,
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
                  Expanded(
                    child: _DragSpacer(key: _rightDragKey, actions: actions),
                  ),
                  if (!isPreHome) ...[
                    if (contextAction != null) ...[
                      contextAction,
                      const SizedBox(width: FuncSpacing.xxs),
                    ],
                    TapRegion(
                      groupId: _filterMenuGroup,
                      child: KeyedSubtree(
                        key: _filterButtonKey,
                        child: _commandIconButton(
                          context,
                          key: const Key('desktop-command-filter'),
                          constraints: iconConstraints,
                          padding: iconPadding,
                          iconSize: 18,
                          tooltip: l10n.commandContentFilter,
                          onPressed: () => unawaited(_openFilterPopover()),
                          icon: const Icon(Icons.shield_outlined),
                        ),
                      ),
                    ),
                    const SizedBox(width: FuncSpacing.xxs),
                    TapRegion(
                      groupId: _accountMenuGroup,
                      child: KeyedSubtree(
                        key: _accountButtonKey,
                        child: _maybeWrapTooltip(
                          context,
                          message: l10n.commandSwitchAccount,
                          child: InkWell(
                            key: const Key('desktop-command-account'),
                            customBorder: const CircleBorder(),
                            onTap: () => unawaited(_openAccountPopover()),
                            child: Padding(
                              padding: const EdgeInsets.all(FuncSpacing.xxs),
                              child: Semantics(
                                button: true,
                                label: l10n.commandSwitchAccount,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: colors.primary.withValues(
                                        alpha: 0.48,
                                      ),
                                      width: 1.5,
                                    ),
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.all(
                                      FuncSpacing.xxs,
                                    ),
                                    child: PersonAvatar(
                                      imageUrl: currentAccount?.profileImageUrl,
                                      radius: 12,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                  SizedBox(
                    width: showCustomButtons ? 138.0 + 8.0 : FuncSpacing.md,
                  ),
                ],
              ),
              if (showCustomButtons)
                Positioned(
                  top: 0,
                  right: 0,
                  bottom: 0,
                  child: KeyedSubtree(
                    key: _captionButtonsKey,
                    child: DesktopWindowCaptionButtons(
                      height: kDesktopCommandBarHeight,
                      isMaximized: chrome?.isMaximized ?? false,
                      isActive: chrome?.isActive ?? true,
                      nativeHoveredButton: hostMetrics.hoveredButton,
                      nativePressedButton: hostMetrics.pressedButton,
                      maximizeKey: _maximizeKey,
                      actions: actions,
                      brightnessListenable: null,
                    ),
                  ),
                ),
            ],
          ),
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

    final tokens = FuncSemanticTokens.of(context);
    final shortcutLabel = defaultTargetPlatform == TargetPlatform.macOS
        ? '⌘K'
        : 'Ctrl K';
    return Semantics(
      button: true,
      label: hasKeyword ? keyword : hint,
      child: Material(
        key: const Key('desktop-command-search-pill'),
        color: colors.surfaceContainer,
        shape: RoundedRectangleBorder(
          borderRadius: FuncShape.pill,
          side: BorderSide(color: tokens.brandHairline),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTapPill,
          child: SizedBox(
            height: 32,
            child: Row(
              children: [
                const SizedBox(width: FuncSpacing.md),
                Icon(Icons.search, size: 15, color: colors.onSurfaceVariant),
                const SizedBox(width: FuncSpacing.sm),
                Expanded(
                  child: Text(
                    hasKeyword ? keyword : hint,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: hasKeyword
                          ? colors.onSurface
                          : colors.onSurfaceVariant,
                    ),
                  ),
                ),
                if (!hasKeyword)
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: colors.surfaceContainerHigh,
                      borderRadius: FuncShape.badge,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: FuncSpacing.xs,
                        vertical: FuncSpacing.xxs,
                      ),
                      child: Text(
                        shortcutLabel,
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontWeight: FontWeight.w500,
                          color: tokens.contentSecondary,
                        ),
                      ),
                    ),
                  ),
                _commandIconButton(
                  context,
                  key: const Key('desktop-command-reverse-search'),
                  constraints: const BoxConstraints(
                    minWidth: 30,
                    minHeight: 30,
                  ),
                  padding: const EdgeInsets.all(FuncSpacing.xs),
                  iconSize: 16,
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

class _CommandAnchoredMenuLayer extends StatefulWidget {
  const _CommandAnchoredMenuLayer({
    required this.overlay,
    required this.initialAnchor,
    required this.anchorOf,
    required this.groupId,
    required this.minWidth,
    required this.maxWidth,
    required this.maxHeight,
    required this.child,
  });

  final RenderBox overlay;
  final Rect initialAnchor;
  final Rect? Function() anchorOf;
  final Object groupId;
  final double minWidth;
  final double maxWidth;
  final double maxHeight;
  final Widget child;

  @override
  State<_CommandAnchoredMenuLayer> createState() =>
      _CommandAnchoredMenuLayerState();
}

class _CommandAnchoredMenuLayerState extends State<_CommandAnchoredMenuLayer> {
  Size? _viewSize;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final size = MediaQuery.sizeOf(context);
    if (size == _viewSize) return;
    _viewSize = size;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final globalAnchor = widget.anchorOf() ?? widget.initialAnchor;
    final localTopLeft = widget.overlay.attached
        ? widget.overlay.globalToLocal(globalAnchor.topLeft)
        : globalAnchor.topLeft;
    final localAnchor = localTopLeft & globalAnchor.size;
    final colors = Theme.of(context).colorScheme;
    final route = ModalRoute.of(context);

    return CustomSingleChildLayout(
      delegate: _CommandMenuLayoutDelegate(
        anchor: localAnchor,
        textDirection: Directionality.of(context),
        minWidth: widget.minWidth,
        maxWidth: widget.maxWidth,
        maxHeight: widget.maxHeight,
      ),
      child: TapRegion(
        groupId: widget.groupId,
        onTapOutside: (_) {
          if (route?.isCurrent ?? false) {
            Navigator.of(context).pop();
          }
        },
        child: Material(
          color: colors.surfaceContainerHigh,
          surfaceTintColor: FuncTokens.transparent,
          elevation: 4,
          shape: RoundedRectangleBorder(
            borderRadius: FuncShape.card,
            side: BorderSide(
              color: colors.outlineVariant.withValues(alpha: 0.6),
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: MediaQuery.removePadding(
            context: context,
            removeTop: true,
            removeBottom: true,
            removeLeft: true,
            removeRight: true,
            child: SingleChildScrollView(
              primary: false,
              padding: const EdgeInsets.symmetric(vertical: FuncSpacing.xs),
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}

class _CommandMenuLayoutDelegate extends SingleChildLayoutDelegate {
  const _CommandMenuLayoutDelegate({
    required this.anchor,
    required this.textDirection,
    required this.minWidth,
    required this.maxWidth,
    required this.maxHeight,
  });

  final Rect anchor;
  final TextDirection textDirection;
  final double minWidth;
  final double maxWidth;
  final double maxHeight;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final availableWidth = math.max(
      0.0,
      constraints.maxWidth - FuncSpacing.sm * 2,
    );
    final availableHeight = math.max(
      0.0,
      constraints.maxHeight - FuncSpacing.sm * 2,
    );
    final cappedMaxWidth = math.min(maxWidth, availableWidth);
    return BoxConstraints(
      minWidth: math.min(minWidth, cappedMaxWidth),
      maxWidth: cappedMaxWidth,
      maxHeight: math.min(maxHeight, availableHeight),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    const edge = FuncSpacing.sm;
    final maxDx = math.max(edge, size.width - edge - childSize.width);
    final maxDy = math.max(
      FuncSpacing.xs,
      size.height - edge - childSize.height,
    );
    final rawX = textDirection == TextDirection.rtl
        ? anchor.left
        : anchor.right - childSize.width;
    final rawY = math.max(FuncSpacing.xs, anchor.bottom + FuncSpacing.xs);
    return Offset(rawX.clamp(edge, maxDx), rawY.clamp(FuncSpacing.xs, maxDy));
  }

  @override
  bool shouldRelayout(_CommandMenuLayoutDelegate oldDelegate) =>
      anchor != oldDelegate.anchor ||
      textDirection != oldDelegate.textDirection ||
      minWidth != oldDelegate.minWidth ||
      maxWidth != oldDelegate.maxWidth ||
      maxHeight != oldDelegate.maxHeight;
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
