import 'dart:async' show unawaited;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/icons/app_icons.dart';
import '../../../app/layout/card_columns.dart';
import '../../../app/layout/deferred_cache_scroll_view.dart';
import '../../../app/motion/motion_tokens.dart';
import '../../../app/navigation/routes.dart';
import '../../../app/pull_to_refresh.dart';
import '../../../app/theme/func_semantic_tokens.dart';
import '../../../app/theme/func_tokens.dart';
import '../../../app/widgets/app_snack_bar.dart';
import '../../../app/widgets/app_tab_bar.dart';
import '../../../app/widgets/app_top_bar.dart';
import '../../../app/widgets/author_summary.dart';
import '../../../app/widgets/errors/error_details.dart';
import '../../../app/widgets/feed/desktop_inspector_scope.dart';
import '../../../app/widgets/feed/feed_grid.dart';
import '../../../app/widgets/feed/feed_selection.dart';
import '../../../app/widgets/feed/feed_states.dart';
import '../../../app/widgets/feed/illust_card.dart';
import '../../../app/widgets/feed/load_more_listener.dart';
import '../../../app/widgets/func_bottom_nav.dart';
import '../../../app/widgets/home_branch_stack.dart';
import '../../../app/widgets/novel_entry.dart';
import '../../../app/widgets/page_header.dart';
import '../../../app/widgets/skeleton/illust_grid_skeleton.dart';
import '../../../app/widgets/settings/persist_settings.dart';
import '../../../app/widgets/smooth_wheel_scroll.dart';
import '../../../app/widgets/tab_swipe_switcher.dart';
import '../../../app/widgets/user_preview_row.dart';
import '../../../app/window/desktop_command_bar.dart';
import '../../../core/entity/illust_entity.dart';
import '../../../core/entity/illust_store.dart';
import '../../../core/entity/stored_entities.dart';
import '../../../core/settings/app_settings.dart';
import '../../../core/settings/settings_controller.dart';
import '../../../core/illust/recommended_feed_controller.dart';
import '../../../core/illust/recommended_repository.dart';
import '../../../core/navigation/home_destination.dart';
import '../../../core/network/api_error.dart';
import '../../../core/novel/novel_store.dart';
import '../../../core/paging/paged_feed_controller.dart';
import '../../../core/user/user_store.dart';
import '../../../l10n/context.dart';
import '../../../l10n/lookup.dart';

String _recommendedText(BuildContext context, String key) {
  return l10nLookup(context.l10n, key);
}

String _recommendedLabelKey(RecommendedContentType type) => switch (type) {
  RecommendedContentType.illust => 'recommendedIllust',
  RecommendedContentType.manga => 'recommendedManga',
  RecommendedContentType.novel => 'recommendedNovel',
  RecommendedContentType.user => 'recommendedUser',
};

/// Home recommended tab with the beta56 content selector:
/// 插画 / 漫画 / 小说 / 用户. The active type is route-durable
/// (`/recommended?type=`): [initialType] seeds the controller and tab
/// changes echo back through [onTypeChanged]. Each type keeps its own
/// cursor/scroll state via the TabSlideStack, so switching back does not
/// refetch.
/// Grid padding shared by the feed sliver and its first-load skeleton.
const _gridPadding = IllustFeedGrid.defaultPadding;

class RecommendedHomePage extends ConsumerStatefulWidget {
  const RecommendedHomePage({
    super.key,
    this.initialType = RecommendedContentType.illust,
    this.onTypeChanged,
  });

  final RecommendedContentType initialType;
  final ValueChanged<RecommendedContentType>? onTypeChanged;

  @override
  ConsumerState<RecommendedHomePage> createState() =>
      _RecommendedHomePageState();
}

class _RecommendedHomePageState extends ConsumerState<RecommendedHomePage>
    with SingleTickerProviderStateMixin {
  static const _types = RecommendedContentType.values;

  late final TabController _tabController;
  late RecommendedContentType _type;
  final _loaded = <RecommendedContentType>{};
  final _scrollControllers = <RecommendedContentType, ScrollController>{};

  /// One body instance per type, reused across page builds: an identical
  /// widget short-circuits the element update, so the tab hop, route echo
  /// and drag warm-up that rebuild this page mid-swipe no longer rebuild
  /// every loaded feed (and its visible cards) inside the swipe frame.
  final _bodies = <RecommendedContentType, Widget>{};
  final _inspectedId = ValueNotifier<int?>(null);
  IllustEntity? _inspectedEntity;
  bool _suppressRouteEcho = false;
  ReTapChannel? _reTapChannel;
  late BuildContext _notificationContext;

  /// Unused placeholder removed.

  @override
  void initState() {
    super.initState();
    _type = widget.initialType;
    _loaded.add(_type);
    _tabController = TabController(
      length: _types.length,
      vsync: this,
      initialIndex: _types.indexOf(_type),
    )..addListener(_onTabChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final channel = HomeBranchStack.reTapOf(context);
    if (identical(channel, _reTapChannel)) return;
    _reTapChannel?.removeListener(_onBranchReTap);
    _reTapChannel = channel;
    _reTapChannel?.addListener(_onBranchReTap);
  }

  @override
  void didUpdateWidget(RecommendedHomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // context.replace keeps the page key, so a route write lands here as
    // a widget update. Self-echoes carry the current type and no-op; only
    // an externally changed param moves the strip — the controller is
    // never reset.
    final index = _types.indexOf(widget.initialType);
    if (widget.initialType != oldWidget.initialType &&
        index != _tabController.index) {
      // The controller listener would echo this move back through
      // onTypeChanged → context.replace — suppress it: the route already
      // carries this type.
      _suppressRouteEcho = true;
      try {
        _tabController.index = index;
      } finally {
        _suppressRouteEcho = false;
      }
    }
  }

  @override
  void dispose() {
    _reTapChannel?.removeListener(_onBranchReTap);
    _tabController
      ..removeListener(_onTabChanged)
      ..dispose();
    _inspectedId.dispose();
    for (final controller in _scrollControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _onTabChanged() {
    if (_tabController.index == _types.indexOf(_type)) return;
    setState(() {
      _type = _types[_tabController.index];
      _loaded.add(_type);
    });
    announceTabScroll(_notificationContext, _scrollControllerFor(_type));
    if (!_suppressRouteEcho) {
      widget.onTypeChanged?.call(_type);
    }
  }

  /// Branch-level re-tap (bottom bar same-destination tap): the channel
  /// fired after the branch stack popped, so the scroll lands post-frame
  /// on the now-visible root — a vetoed pop leaves a pushed route on top
  /// and `isCurrent` fails the scroll harmlessly.
  void _onBranchReTap() {
    if (_reTapChannel?.branch !=
        BranchRootScope.maybeOf(context)?.branchIndex) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
      reTapScrollToTop(context, _scrollControllerFor(_type));
    });
  }

  ScrollController _scrollControllerFor(RecommendedContentType type) {
    return _scrollControllers.putIfAbsent(
      type,
      () => ScrollController(
        onAttach: (_) {
          if (type == _type) {
            announceTabScroll(_notificationContext, _scrollControllers[type]!);
          }
        },
      ),
    );
  }

  bool _prepareTab(int index) {
    final type = _types[index];
    if (_loaded.contains(type)) return false;
    setState(() => _loaded.add(type));
    return true;
  }

  void _selectCategory(int index) {
    if (index == _tabController.index) {
      reTapScrollToTop(context, _scrollControllerFor(_types[index]));
      return;
    }
    _tabController.animateTo(index);
  }

  void _selectInspected(IllustEntity entity) {
    _inspectedId.value = entity.id;
    setState(() => _inspectedEntity = entity);
  }

  void _clearInspected() {
    _inspectedId.value = null;
    setState(() => _inspectedEntity = null);
  }

  void _openStageFor(IllustEntity entity) {
    unawaited(
      openIllust(
        context,
        entity.id,
        initialEntity: entity,
        heroScope: 'recommended',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final desktopOwned = DesktopCommandBarScope.isActiveOf(context);
    final detailMode = ref.watch(desktopDetailModeProvider);
    final wideInspector =
        desktopOwned &&
        MediaQuery.widthOf(context) >= 1040 &&
        detailMode == DesktopDetailMode.inspector;
    final labels = [
      for (final value in _types)
        _recommendedText(context, _recommendedLabelKey(value)),
    ];
    final tabBody = Builder(
      builder: (context) {
        _notificationContext = context;
        return TabSwipeSwitcher(
          tabController: _tabController,
          prepareTab: _prepareTab,
          child: TabSlideStack(
            controller: _tabController,
            children: [
              for (final type in _types)
                if (_loaded.contains(type))
                  _bodies.putIfAbsent(
                    type,
                    () => _RecommendedFeedView(
                      key: ValueKey(type),
                      type: type,
                      scrollController: _scrollControllerFor(type),
                    ),
                  )
                else
                  const SizedBox.shrink(),
            ],
          ),
        );
      },
    );

    if (!desktopOwned) {
      return Scaffold(
        resizeToAvoidBottomInset: false,
        appBar: AppTopBar(
          titleSpacing: 0,
          actions: const [
            _OffBarSearchAction(),
            HeaderRefresh(),
            HeaderSearch(),
          ],
          title: AppTabBar(
            controller: _tabController,
            onTap: (index) {
              if (!_tabController.indexIsChanging) {
                reTapScrollToTop(context, _scrollControllerFor(_types[index]));
              }
            },
            labels: labels,
          ),
        ),
        body: tabBody,
      );
    }

    final gallery = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _DesktopGalleryHeader(
          tabController: _tabController,
          labels: labels,
          onSelectCategory: _selectCategory,
        ),
        Expanded(child: tabBody),
      ],
    );

    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final inspectorWidth = (constraints.maxWidth * 0.45).clamp(
            440.0,
            560.0,
          );
          final inspected = wideInspector ? _inspectedEntity : null;
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: DesktopInspectorScope(
                  enabled: wideInspector,
                  selectedId: _inspectedId,
                  onInspect: _selectInspected,
                  child: gallery,
                ),
              ),
              if (inspected != null)
                SizedBox(
                  width: inspectorWidth,
                  child: DesktopGalleryInspector(
                    entity: inspected,
                    panelWidth: inspectorWidth,
                    onClose: _clearInspected,
                    onOpenStage: () => _openStageFor(inspected),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// One keyed recommended feed body. Watches [recommendedFeedProvider] and
/// renders the right card shape for the type.
class _RecommendedFeedView extends ConsumerWidget {
  const _RecommendedFeedView({
    super.key,
    required this.type,
    required this.scrollController,
  });

  final RecommendedContentType type;
  final ScrollController scrollController;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = (type: type);
    // Refresh failure keeps the loaded feed and surfaces as a transient
    // prompt with a retry action — the inline tail
    // row it replaced rendered "${feed.loadMoreError}", which the phase
    // copy never populated ("null").
    ref.listen(recommendedFeedProvider(key), (previous, next) {
      final feed = next.asData?.value;
      final wasError = previous?.asData?.value.refreshPhase == FeedPhase.error;
      if (feed == null || feed.refreshPhase != FeedPhase.error || wasError) {
        return;
      }
      final error = ref
          .read(recommendedFeedProvider(key).notifier)
          .consumeRefreshError();
      if (error == null) return;
      showErrorSnackBar(
        context,
        action: context.l10n.recommendedRefreshFailed,
        error: error,
        snackBarAction: PromptAction(
          label: context.l10n.retry,
          onPressed: () =>
              ref.read(recommendedFeedProvider(key).notifier).refresh(),
        ),
      );
    });
    final feedAsync = ref.watch(recommendedFeedProvider(key));

    return feedAsync.when(
      loading: () => IllustGridSkeleton(
        label: context.l10n.contentLoading,
        padding: _gridPadding,
      ),
      error: (error, _) => FeedError(
        title: context.l10n.recommendedLoadFailed,
        error: error,
        retryLabel: context.l10n.retry,
        onRetry: () => ref.invalidate(recommendedFeedProvider(key)),
      ),
      data: (feed) {
        if (feed.showInitialError) {
          return FeedError(
            title: context.l10n.recommendedLoadFailed,
            error: feed.initialError ?? const ApiParseError('unknown error'),
            retryLabel: context.l10n.retry,
            onRetry: () =>
                ref.read(recommendedFeedProvider(key).notifier).retryInitial(),
          );
        }
        if (feed.showInitialSpinner) {
          return IllustGridSkeleton(
            label: context.l10n.contentLoading,
            padding: _gridPadding,
          );
        }
        final controller = ref.read(recommendedFeedProvider(key).notifier);
        // User recommendations are not filtered: an empty page there is
        // not the filters' doing.
        if (feed.isAllHidden && controller.localFilterEnabled) {
          return FeedAllHidden(
            feed: feed,
            onLoadMore: controller.retryLoadMore,
          );
        }
        if (feed.isEmptyAndReady) {
          return FeedEmpty(
            title: context.l10n.recommendedEmpty,
            retryLabel: context.l10n.refresh,
            onRefresh: () =>
                ref.read(recommendedFeedProvider(key).notifier).refresh(),
          );
        }
        return _RecommendedFeedBody(
          type: type,
          feed: feed,
          scrollController: scrollController,
          onRefresh: () =>
              ref.read(recommendedFeedProvider(key).notifier).refresh(),
          onLoadMore: () =>
              ref.read(recommendedFeedProvider(key).notifier).loadMore(),
          onRetryLoadMore: () =>
              ref.read(recommendedFeedProvider(key).notifier).retryLoadMore(),
        );
      },
    );
  }
}

class _RecommendedFeedBody extends ConsumerWidget {
  const _RecommendedFeedBody({
    required this.type,
    required this.feed,
    required this.scrollController,
    required this.onRefresh,
    required this.onLoadMore,
    required this.onRetryLoadMore,
  });

  final RecommendedContentType type;
  final PagedFeedState feed;
  final ScrollController scrollController;
  final Future<void> Function() onRefresh;
  final VoidCallback onLoadMore;
  final VoidCallback onRetryLoadMore;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tail = <Widget>[
      SliverToBoxAdapter(
        child: FeedTail(
          feed: feed,
          onRetry: onRetryLoadMore,
          endMessage: context.l10n.recommendedEnd,
          retryLabel: context.l10n.retry,
        ),
      ),
      const SliverToBoxAdapter(child: FuncNavBarSpacer()),
    ];

    final slivers = switch (type) {
      RecommendedContentType.illust ||
      RecommendedContentType.manga => _illustSlivers(context, ref, tail),
      RecommendedContentType.novel => _novelSlivers(context, ref, tail),
      RecommendedContentType.user => _userSlivers(context, ref, tail),
    };

    final scrollHost = PullToRefresh(
      scrollController: scrollController,
      onRefresh: onRefresh,
      child: LoadMoreListener(
        itemCount: feed.ids.length,
        onLoadMore: onLoadMore,
        child: SmoothWheelScroll(
          // Explicit per-type controller so re-tap can reach the active
          // feed; without it desktop wheel scrolling would own a private
          // controller the channel cannot address.
          controller: scrollController,
          basePhysics: const AlwaysScrollableScrollPhysics(),
          builder: (context, controller, physics) => DeferredCacheScrollView(
            key: PageStorageKey('recommended-${type.name}'),
            physics: physics,
            scrollCacheExtent: kFeedCacheExtent,
            restorationId: 'recommended-${type.name}',
            controller: controller,
            slivers: slivers,
          ),
        ),
      ),
    );
    return switch (type) {
      RecommendedContentType.illust ||
      RecommendedContentType.manga => SelectableFeedHost(child: scrollHost),
      RecommendedContentType.novel || RecommendedContentType.user => scrollHost,
    };
  }

  List<Widget> _illustSlivers(
    BuildContext context,
    WidgetRef ref,
    List<Widget> tail,
  ) {
    final store = ref.watch(illustStoreProvider);
    final entities = store.getAll(feed.ids);
    final heroScope = 'recommended:${type.name}';
    return [
      IllustFeedGrid(
        padding: _gridPadding,
        itemIds: [for (final e in entities) e.id],
        itemCount: entities.length,
        pagerLoadMore: onLoadMore,
        warmTexts: (context, index) =>
            IllustCard.warmTexts(context, entities[index]),
        items: entities,
        itemDeps: heroScope,
        itemBuilder: (context, index) =>
            IllustCard(entity: entities[index], heroScope: heroScope),
      ),
      ...tail,
    ];
  }

  List<Widget> _novelSlivers(
    BuildContext context,
    WidgetRef ref,
    List<Widget> tail,
  ) {
    final novels = ref
        .watch(
          novelStoreProvider.select((store) => StoredEntities(store, feed.ids)),
        )
        .items;
    return [
      SliverPadding(
        padding: const EdgeInsets.only(top: FuncSpacing.sm),
        sliver: SliverCardList(
          itemCount: novels.length,
          firstId: novels.firstOrNull?.id,
          warmTexts: (context, index) =>
              NovelEntry.warmTexts(context, novels[index]),
          items: novels,
          itemBuilder: (context, index) => KeyedSubtree(
            key: ValueKey(novels[index].id),
            child: NovelEntry.compact(entity: novels[index]),
          ),
        ),
      ),
      ...tail,
    ];
  }

  List<Widget> _userSlivers(
    BuildContext context,
    WidgetRef ref,
    List<Widget> tail,
  ) {
    final users = ref
        .watch(
          userStoreProvider.select((store) => StoredEntities(store, feed.ids)),
        )
        .items;
    return [
      SliverPadding(
        padding: const EdgeInsets.only(top: FuncSpacing.sm),
        sliver: SliverCardList(
          itemCount: users.length,
          firstId: users.firstOrNull?.id,
          warmTexts: (context, index) => AuthorSummary.warmTexts(
            context,
            name: users[index].name,
            account: UserPreviewRow.handleOf(users[index]),
          ),
          items: users,
          itemBuilder: (context, index) => KeyedSubtree(
            key: ValueKey(users[index].id),
            child: UserPreviewRow(entity: users[index]),
          ),
        ),
      ),
      ...tail,
    ];
  }
}

/// Search's way in when the user took it off the bar.
class _OffBarSearchAction extends ConsumerWidget {
  const _OffBarSearchAction();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The wide header's own search field is the way in there (R7).
    if (PageHeader.isWide(context)) return const SizedBox.shrink();
    final offBar = ref.watch(
      homeArrangementProvider.select(
        (arrangement) => !arrangement.shown.contains(HomeDestination.search),
      ),
    );
    if (!offBar) return const SizedBox.shrink();
    return IconButton(
      tooltip: context.l10n.searchTitle,
      icon: const Icon(AppIcons.search),
      onPressed: () => openHomeDestination(context, HomeDestination.search),
    );
  }
}

class _DesktopGalleryHeader extends ConsumerWidget {
  const _DesktopGalleryHeader({
    required this.tabController,
    required this.labels,
    required this.onSelectCategory,
  });

  final TabController tabController;
  final List<String> labels;
  final ValueChanged<int> onSelectCategory;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final tokens = FuncSemanticTokens.of(context);
    final density = ref.watch(feedDensityProvider);
    final detailMode = ref.watch(desktopDetailModeProvider);
    final (duration, curve) = MotionTokens.springCurve(
      context,
      MotionSpring.effectsFast,
    );
    final densityChoices = <({FeedDensity value, String label, Key? key})>[
      (
        value: FeedDensity.comfortable,
        label: l10n.feedDensityComfortable,
        key: null,
      ),
      (value: FeedDensity.standard, label: l10n.feedDensityStandard, key: null),
      (value: FeedDensity.compact, label: l10n.feedDensityCompact, key: null),
    ];
    final detailModeChoices =
        <({DesktopDetailMode value, String label, Key? key})>[
          (
            value: DesktopDetailMode.modal,
            label: l10n.desktopDetailModeModal,
            key: const Key('desktop-detail-mode-modal'),
          ),
          (
            value: DesktopDetailMode.inspector,
            label: l10n.desktopDetailModeInspector,
            key: const Key('desktop-detail-mode-inspector'),
          ),
        ];

    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: tokens.brandHairline)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          FuncSpacing.lg,
          FuncSpacing.md,
          FuncSpacing.lg,
          FuncSpacing.sm + FuncSpacing.xxs,
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final showDensity = constraints.maxWidth >= 620;
            final showDetailMode = constraints.maxWidth >= 900;
            return Row(
              children: [
                Text(
                  l10n.homeRecommended,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.3,
                  ),
                ),
                const SizedBox(width: FuncSpacing.lg),
                AnimatedBuilder(
                  animation: tabController,
                  builder: (context, _) {
                    final active = tabController.index;
                    return Wrap(
                      spacing: FuncSpacing.xs,
                      children: [
                        for (var i = 0; i < labels.length; i++)
                          Material(
                            color: FuncTokens.transparent,
                            shape: const StadiumBorder(),
                            child: InkWell(
                              customBorder: const StadiumBorder(),
                              onTap: () => onSelectCategory(i),
                              child: AnimatedContainer(
                                duration: duration,
                                curve: curve,
                                height: 30,
                                alignment: Alignment.center,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: FuncSpacing.md,
                                ),
                                decoration: ShapeDecoration(
                                  shape: StadiumBorder(
                                    side: i == active
                                        ? BorderSide(
                                            color: tokens.brandTintStroke,
                                          )
                                        : BorderSide.none,
                                  ),
                                  color: i == active
                                      ? tokens.brandTint
                                      : FuncTokens.transparent,
                                ),
                                child: Text(
                                  labels[i],
                                  style: theme.textTheme.labelLarge?.copyWith(
                                    fontSize: 13,
                                    fontWeight: i == active
                                        ? FontWeight.w600
                                        : FontWeight.w500,
                                    color: i == active
                                        ? colors.primary
                                        : colors.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
                if (showDensity) ...[
                  const Spacer(),
                  if (showDetailMode) ...[
                    _HeaderSegmentedPill<DesktopDetailMode>(
                      choices: detailModeChoices,
                      selected: detailMode,
                      duration: duration,
                      curve: curve,
                      onSelected: (value) {
                        unawaited(
                          persistSettings(
                            context,
                            () => ref
                                .read(settingsProvider.notifier)
                                .setDesktopDetailMode(value),
                          ),
                        );
                      },
                    ),
                    const SizedBox(width: FuncSpacing.sm),
                  ],
                  _HeaderSegmentedPill<FeedDensity>(
                    choices: densityChoices,
                    selected: density,
                    duration: duration,
                    curve: curve,
                    onSelected: (value) {
                      unawaited(
                        persistSettings(
                          context,
                          () => ref
                              .read(settingsProvider.notifier)
                              .setFeedDensity(value),
                        ),
                      );
                    },
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

class _HeaderSegmentedPill<T> extends StatelessWidget {
  const _HeaderSegmentedPill({
    required this.choices,
    required this.selected,
    required this.duration,
    required this.curve,
    required this.onSelected,
  });

  final List<({T value, String label, Key? key})> choices;
  final T selected;
  final Duration duration;
  final Curve curve;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final tokens = FuncSemanticTokens.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: FuncShape.pill,
        border: Border.all(color: tokens.brandHairline),
      ),
      child: Padding(
        padding: const EdgeInsets.all(FuncSpacing.xxs),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final choice in choices)
              Material(
                color: FuncTokens.transparent,
                shape: const StadiumBorder(),
                child: InkWell(
                  key: choice.key,
                  customBorder: const StadiumBorder(),
                  onTap: () {
                    if (choice.value != selected) {
                      onSelected(choice.value);
                    }
                  },
                  child: AnimatedContainer(
                    duration: duration,
                    curve: curve,
                    height: 26,
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(
                      horizontal: FuncSpacing.sm + FuncSpacing.xxs,
                    ),
                    decoration: ShapeDecoration(
                      shape: StadiumBorder(
                        side: choice.value == selected
                            ? BorderSide(color: tokens.brandTintStroke)
                            : BorderSide.none,
                      ),
                      color: choice.value == selected
                          ? tokens.brandTint
                          : FuncTokens.transparent,
                    ),
                    child: Text(
                      choice.label,
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontSize: 11.5,
                        fontWeight: choice.value == selected
                            ? FontWeight.w600
                            : FontWeight.w500,
                        color: choice.value == selected
                            ? colors.primary
                            : colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
