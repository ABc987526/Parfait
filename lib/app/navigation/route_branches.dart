part of 'routes.dart';

List<RouteBase> _searchRoutes(
  RouteObserver<ModalRoute<dynamic>> observer, {
  required String prefix,
}) {
  return [
    GoRoute(
      path: '${prefix}input',
      pageBuilder: (context, state) {
        // The docked panel narrowing hands over its session — the text as
        // typed and the filter drafts — as the location's extra (R10).
        final draft = state.extra;
        final carried = draft is SearchInputDraft ? draft : null;
        return _page(
          context,
          state,
          observer,
          SearchInputPage(
            initialKeyword:
                carried?.keyword ?? state.uri.queryParameters['q'] ?? '',
            initialType:
                carried?.type ??
                searchTypeFromQuery(state.uri.queryParameters['type']),
            initialIllustFilters: carried?.illustFilters,
            initialNovelFilters: carried?.novelFilters,
            onTypeChanged: (keyword, type) =>
                replaceSearchInput(context, keyword: keyword, type: type),
          ),
        );
      },
    ),
    GoRoute(
      path: '${prefix}results',
      pageBuilder: (context, state) => _page(
        context,
        state,
        observer,
        SearchResultPage(
          query: searchQueryFromState(state),
          onTypeChanged: (query) => replaceSearchResults(context, query),
        ),
      ),
    ),
  ];
}

List<RouteBase> _commonBranchRoutes(
  RouteObserver<ModalRoute<dynamic>> branchObserver, {
  required GlobalKey<NavigatorState> rootNavigatorKey,
  required RouteObserver<ModalRoute<dynamic>> rootObserver,
  bool includeSearch = true,
  bool includeAppPages = false,
}) {
  final routes = <RouteBase>[
    GoRoute(
      path: 'illust/:illustId',
      pageBuilder: (context, state) {
        final extra = state.extra;
        final illustId = _pathId(state, 'illustId');
        if (extra is IllustRouteExtra) {
          // A card inside a paged feed hands over the feed's work list:
          // the detail becomes a horizontal pager across it. Ids missing from the list — deep links, restored
          // routes — fall back to the single-work page.
          final source = extra.pagerSource;
          if (source != null && source.ids.contains(illustId)) {
            return _page(
              context,
              state,
              branchObserver,
              DetailOverlayFrame(
                child: _RememberedIllust(
                  builder: (_, remember) => IllustDetailPagerPage(
                    source: source,
                    initialIllustId: illustId,
                    heroScope: extra.heroScope,
                    heroImageUrl: extra.heroImageUrl,
                    heroImageDecodeWidth: extra.heroImageDecodeWidth,
                    onActiveChanged: remember,
                  ),
                ),
              ),
              sharedElement: extra.heroImageUrl != null,
              boundedOverlayOnWide: true,
            );
          }
          return _page(
            context,
            state,
            branchObserver,
            DetailOverlayFrame(
              child: _RememberedIllust(
                builder: (_, _) => IllustDetailPage(
                  illustId: illustId,
                  initialEntity: extra.entity,
                  heroScope: extra.heroScope,
                  heroImageUrl: extra.heroImageUrl,
                  heroImageDecodeWidth: extra.heroImageDecodeWidth,
                ),
              ),
            ),
            sharedElement: extra.heroImageUrl != null,
            boundedOverlayOnWide: true,
          );
        }
        // A restored route has lost its extra, pager source included: it
        // opens the work the pager last settled on.
        return _page(
          context,
          state,
          branchObserver,
          DetailOverlayFrame(
            child: _RememberedIllust(
              builder: (remembered, _) => IllustDetailPage(
                illustId: remembered ?? illustId,
                initialEntity: remembered == null && extra is IllustEntity
                    ? extra
                    : null,
              ),
            ),
          ),
          boundedOverlayOnWide: true,
        );
      },
      routes: [
        GoRoute(
          path: 'viewer/:page',
          parentNavigatorKey: rootNavigatorKey,
          pageBuilder: (context, state) {
            final quality = ViewQuality.fromCode(
              state.uri.queryParameters['quality'],
            );
            final extra = state.extra is ImageViewerRouteExtra
                ? state.extra! as ImageViewerRouteExtra
                : null;
            return _page(
              context,
              state,
              rootObserver,
              _ImageViewerRoute(
                illustId: _pathId(state, 'illustId'),
                page: int.parse(state.pathParameters['page']!),
                quality: quality,
                extra: extra,
              ),
              sharedElement: extra?.heroScope != null,
              // The dark stage covers the page below by itself.
              sharedElementBackdrop: false,
            );
          },
        ),
        GoRoute(
          path: 'comments',
          pageBuilder: (context, state) => _page(
            context,
            state,
            branchObserver,
            CommentsPage(workId: _pathId(state, 'illustId')),
          ),
        ),
        GoRoute(
          path: 'comments/:rootCommentId',
          pageBuilder: (context, state) => _page(
            context,
            state,
            branchObserver,
            CommentRepliesPage(
              workId: _pathId(state, 'illustId'),
              rootCommentId: _pathId(state, 'rootCommentId'),
              rootComment: state.extra is CommentEntity
                  ? state.extra! as CommentEntity
                  : null,
            ),
          ),
        ),
      ],
    ),
    GoRoute(
      path: 'user/:userId',
      pageBuilder: (context, state) => _page(
        context,
        state,
        branchObserver,
        UserPage(userId: _pathId(state, 'userId')),
      ),
    ),
    GoRoute(
      path: 'series/:seriesId',
      pageBuilder: (context, state) => _page(
        context,
        state,
        branchObserver,
        IllustSeriesPage(seriesId: _pathId(state, 'seriesId')),
      ),
    ),
    GoRoute(
      path: 'novel-series/:seriesId',
      pageBuilder: (context, state) => _page(
        context,
        state,
        branchObserver,
        NovelSeriesFeedPage(seriesId: _pathId(state, 'seriesId')),
      ),
    ),
    GoRoute(
      path: 'spotlight',
      pageBuilder: (context, state) =>
          _page(context, state, branchObserver, const SpotlightFeedPage()),
    ),
    GoRoute(
      path: 'spotlight/article/:articleId',
      pageBuilder: (context, state) => _page(
        context,
        state,
        branchObserver,
        SpotlightArticlePage(
          articleId: _pathId(state, 'articleId'),
          articleUrl: state.uri.queryParameters['url'],
        ),
      ),
    ),
    GoRoute(
      path: 'profile/:userId/edit',
      pageBuilder: (context, state) => _page(
        context,
        state,
        branchObserver,
        ProfileEditPage(userId: _pathId(state, 'userId')),
      ),
    ),
    GoRoute(
      path: 'novel/:novelId',
      pageBuilder: (context, state) => _page(
        context,
        state,
        branchObserver,
        NovelPage(
          novelId: _pathId(state, 'novelId'),
          atPixivPage: switch (state.extra) {
            NovelRouteExtra(:final atPixivPage) => atPixivPage,
            _ => null,
          },
        ),
      ),
      routes: [
        GoRoute(
          path: 'image/:imageId',
          parentNavigatorKey: rootNavigatorKey,
          pageBuilder: (context, state) => _page(
            context,
            state,
            rootObserver,
            _NovelImageRoute(
              novelId: _pathId(state, 'novelId'),
              imageId: state.pathParameters['imageId']!,
            ),
          ),
        ),
        GoRoute(
          path: 'comments',
          pageBuilder: (context, state) => _page(
            context,
            state,
            branchObserver,
            CommentsPage(
              workId: _pathId(state, 'novelId'),
              kind: CommentWorkKind.novel,
            ),
          ),
        ),
        GoRoute(
          path: 'comments/:rootCommentId',
          pageBuilder: (context, state) => _page(
            context,
            state,
            branchObserver,
            CommentRepliesPage(
              workId: _pathId(state, 'novelId'),
              kind: CommentWorkKind.novel,
              rootCommentId: _pathId(state, 'rootCommentId'),
              rootComment: state.extra is CommentEntity
                  ? state.extra! as CommentEntity
                  : null,
            ),
          ),
        ),
      ],
    ),
    GoRoute(
      path: 'novel-ranking',
      pageBuilder: (context, state) => _page(
        context,
        state,
        branchObserver,
        NovelRankingPage(
          initialMode: novelRankingModeFromQuery(
            state.uri.queryParameters['mode'],
          ),
          date: rankingDateFromState(state),
          onRouteChanged: (mode, date) =>
              replaceNovelRankingMode(context, mode, date),
        ),
      ),
    ),
    GoRoute(
      path: 'new-novels',
      pageBuilder: (context, state) => _page(
        context,
        state,
        branchObserver,
        NewPage(
          type: NewFeedType.novel,
          initialScope: newFeedScopeFromQuery(
            state.uri.queryParameters['scope'],
          ),
          onScopeChanged: (scope) => replaceNewNovelScope(context, scope),
        ),
      ),
    ),
    GoRoute(
      path: 'history',
      pageBuilder: (context, state) =>
          _page(context, state, branchObserver, const HistoryPage()),
    ),
    GoRoute(
      path: 'watchlater',
      pageBuilder: (context, state) =>
          _page(context, state, branchObserver, const WatchLaterPage()),
    ),
    GoRoute(
      path: 'watchlist',
      pageBuilder: (context, state) =>
          _page(context, state, branchObserver, const WatchlistPage()),
    ),
    GoRoute(
      path: 'novel-markers',
      pageBuilder: (context, state) =>
          _page(context, state, branchObserver, const NovelMarkersPage()),
    ),
    GoRoute(
      path: 'local-novels',
      pageBuilder: (context, state) =>
          _page(context, state, branchObserver, const LocalNovelsPage()),
      routes: [
        GoRoute(
          path: ':localId',
          pageBuilder: (context, state) => _page(
            context,
            state,
            branchObserver,
            LocalNovelReaderPage(localId: _pathId(state, 'localId')),
          ),
        ),
      ],
    ),
    GoRoute(
      path: 'bookmarks/tags',
      pageBuilder: (context, state) => _page(
        context,
        state,
        branchObserver,
        BookmarkTagsPage(
          kind: bookmarkKindFromQuery(state.uri.queryParameters['kind']),
          initialRestrict: bookmarkRestrictFromQuery(
            state.uri.queryParameters['restrict'],
          ),
        ),
      ),
    ),
    GoRoute(
      path: 'bookmarks/tag',
      pageBuilder: (context, state) => _page(
        context,
        state,
        branchObserver,
        BookmarkTagFeedPage(
          tag: state.uri.queryParameters['tag'] ?? '',
          kind: bookmarkKindFromQuery(state.uri.queryParameters['kind']),
          restrict: bookmarkRestrictFromQuery(
            state.uri.queryParameters['restrict'],
          ),
        ),
      ),
    ),
    // Tag search opens on top of whatever stack the tag was tapped in (detail
    // page, user page, reverse-image result). Routing it to the search branch
    // would switch tabs and lose the page the user came from.
    GoRoute(
      path: 'tag/:keyword',
      pageBuilder: (context, state) => _page(
        context,
        state,
        branchObserver,
        TagSearchPage(keyword: state.pathParameters['keyword']!),
      ),
    ),
  ];
  if (includeSearch) {
    routes.addAll(_searchRoutes(branchObserver, prefix: 'search/'));
  }
  if (includeAppPages) {
    // The app-level pages, opened inside a branch beside the rail
    // (_appPageLocation).
    routes.addAll([
      GoRoute(
        path: 'me',
        pageBuilder: (context, state) =>
            _page(context, state, branchObserver, _mePage(state)),
      ),
      GoRoute(
        path: 'downloads',
        pageBuilder: (context, state) =>
            _page(context, state, branchObserver, const DownloadTasksPage()),
      ),
    ]);
  }
  return routes;
}

MePage _mePage(GoRouterState state) => MePage(
  initialTab: MeTab.values.asNameMap()[state.uri.queryParameters['tab']],
);

GoRoute _overlayRoute(
  String path, {
  required GlobalKey<NavigatorState> rootNavigatorKey,
  required RouteObserver<ModalRoute<dynamic>> rootObserver,
  required GoRouterPageBuilder pageBuilder,
}) {
  return GoRoute(
    path: path,
    parentNavigatorKey: rootNavigatorKey,
    pageBuilder: pageBuilder,
    routes: _commonBranchRoutes(
      rootObserver,
      rootNavigatorKey: rootNavigatorKey,
      rootObserver: rootObserver,
    ),
  );
}

/// Settings subpages grafted under the `/settings` home branch. They take
/// the branch observer so route-aware widgets behave the same as on any
/// other branch stack.
List<RouteBase> _settingsSubRoutes(
  RouteObserver<ModalRoute<dynamic>> observer,
) {
  return [
    GoRoute(
      path: 'all',
      pageBuilder: (context, state) => _settingsPage(
        context,
        state,
        observer,
        SettingsPage(initialLocation: state.uri.toString()),
      ),
    ),
    GoRoute(
      path: 'account',
      pageBuilder: (context, state) => _adaptiveSettingsPage(
        context,
        state,
        observer,
        const AccountSettingsPage(),
      ),
    ),
    GoRoute(
      path: 'theme',
      pageBuilder: (context, state) => _adaptiveSettingsPage(
        context,
        state,
        observer,
        const ThemeSettingsPage(),
      ),
    ),
    GoRoute(
      path: 'language',
      pageBuilder: (context, state) => _adaptiveSettingsPage(
        context,
        state,
        observer,
        const LanguageSettingsPage(),
      ),
    ),
    GoRoute(
      path: 'translate',
      pageBuilder: (context, state) => _adaptiveSettingsPage(
        context,
        state,
        observer,
        const TranslateSettingsPage(),
      ),
      routes: [
        GoRoute(
          path: 'credentials/:provider',
          pageBuilder: (context, state) => _adaptiveSettingsPage(
            context,
            state,
            observer,
            TranslationCredentialsPage(
              baidu: state.pathParameters['provider'] == 'baidu',
            ),
          ),
        ),
      ],
    ),
    GoRoute(
      path: 'network',
      pageBuilder: (context, state) => _adaptiveSettingsPage(
        context,
        state,
        observer,
        const NetworkSettingsPage(),
      ),
      routes: [
        GoRoute(
          path: 'probe',
          pageBuilder: (context, state) => _adaptiveSettingsPage(
            context,
            state,
            observer,
            const NetworkProbePage(),
          ),
        ),
        GoRoute(
          path: 'advanced',
          pageBuilder: (context, state) => _adaptiveSettingsPage(
            context,
            state,
            observer,
            const NetworkAdvancedSettingsPage(),
          ),
        ),
      ],
    ),
    // The route ships in every build so the release unlock gesture
    // (about page, 7 taps) can reach it — only the entry is hidden.
    GoRoute(
      path: 'frame-probe',
      pageBuilder: (context, state) => _adaptiveSettingsPage(
        context,
        state,
        observer,
        const FrameProbePage(),
      ),
    ),
    GoRoute(
      path: 'browse',
      pageBuilder: (context, state) => _adaptiveSettingsPage(
        context,
        state,
        observer,
        const BrowseSettingsPage(),
      ),
    ),
    GoRoute(
      path: 'motion',
      pageBuilder: (context, state) => _adaptiveSettingsPage(
        context,
        state,
        observer,
        const MotionSettingsPage(),
      ),
    ),
    GoRoute(
      path: 'navigation',
      pageBuilder: (context, state) => _adaptiveSettingsPage(
        context,
        state,
        observer,
        const NavigationSettingsPage(),
      ),
      routes: [
        GoRoute(
          path: 'bottom-bar',
          pageBuilder: (context, state) => _adaptiveSettingsPage(
            context,
            state,
            observer,
            const BottomBarSettingsPage(),
          ),
        ),
      ],
    ),
    GoRoute(
      path: 'download',
      pageBuilder: (context, state) => _adaptiveSettingsPage(
        context,
        state,
        observer,
        const DownloadSettingsPage(),
      ),
      routes: [
        GoRoute(
          path: 'destination',
          pageBuilder: (context, state) => _adaptiveSettingsPage(
            context,
            state,
            observer,
            const DownloadDestinationPage(),
          ),
        ),
      ],
    ),
    GoRoute(
      path: 'muted',
      pageBuilder: (context, state) => _adaptiveSettingsPage(
        context,
        state,
        observer,
        const MutedItemsPage(),
      ),
    ),
    GoRoute(
      path: 'backup',
      pageBuilder: (context, state) => _adaptiveSettingsPage(
        context,
        state,
        observer,
        const BackupSettingsPage(),
      ),
    ),
    GoRoute(
      path: 'tasks',
      pageBuilder: (context, state) => _adaptiveSettingsPage(
        context,
        state,
        observer,
        const DownloadTasksPage(),
      ),
    ),
    GoRoute(
      path: 'about',
      pageBuilder: (context, state) => _adaptiveSettingsPage(
        context,
        state,
        observer,
        const AboutSettingsPage(),
      ),
      routes: [
        GoRoute(
          path: 'licenses',
          pageBuilder: (context, state) => _adaptiveSettingsPage(
            context,
            state,
            observer,
            FutureBuilder<PackageInfo>(
              future: PackageInfo.fromPlatform(),
              builder: (context, snapshot) => LicensesSettingsPage(
                applicationVersion: snapshot.data?.version,
              ),
            ),
          ),
        ),
      ],
    ),
  ];
}

/// Hosts leaf settings routes inside [SettingsAdaptiveHost] so desktop and wide
/// tablets keep the shared master-detail workspace instead of single-column
/// islands.
Page<dynamic> _adaptiveSettingsPage(
  BuildContext context,
  GoRouterState state,
  RouteObserver<ModalRoute<dynamic>> observer,
  Widget page,
) => _settingsPage(
  context,
  state,
  observer,
  SettingsAdaptiveHost(location: state.uri.toString(), narrowPage: page),
);

/// A settings page that reveals the entry its `focus` query names (the
/// settings search links there).
Page<dynamic> _settingsPage(
  BuildContext context,
  GoRouterState state,
  RouteObserver<ModalRoute<dynamic>> observer,
  Widget page,
) => _page(
  context,
  state,
  observer,
  SettingsFocusScope(
    target: state.uri.queryParameters[focusQuery],
    child: page,
  ),
);

StatefulShellBranch _branch({
  required String path,
  required int branchIndex,
  required Widget home,
  Widget Function(BuildContext context, GoRouterState state)? homeBuilder,
  required GlobalKey<NavigatorState> navigatorKey,
  required RouteObserver<ModalRoute<dynamic>> observer,
  NavigatorObserver? forwardObserver,
  required GlobalKey<NavigatorState> rootNavigatorKey,
  required RouteObserver<ModalRoute<dynamic>> rootObserver,
  required String restorationScopeId,
  bool includeSearch = true,
  List<RouteBase> routes = const [],
}) {
  final commonRoutes = _commonBranchRoutes(
    observer,
    rootNavigatorKey: rootNavigatorKey,
    rootObserver: rootObserver,
    includeSearch: includeSearch,
    includeAppPages: true,
  );
  return StatefulShellBranch(
    navigatorKey: navigatorKey,
    observers: [observer, ?forwardObserver],
    restorationScopeId: restorationScopeId,
    // Hands HomeBranchStack every branch's Navigator; it mounts them.
    preload: true,
    routes: [
      GoRoute(
        path: path,
        pageBuilder: (context, state) => _page(
          context,
          state,
          observer,
          // The bottom bar is a shell-level sibling of the branch strip;
          // this scaffold feeds it the root page's scrolling and draws it
          // under the routes that cover the root.
          BranchRootScaffold(
            branchIndex: branchIndex,
            child: homeBuilder?.call(context, state) ?? home,
          ),
        ),
        routes: [...commonRoutes, ...routes],
      ),
    ],
  );
}

class _ImageViewerRoute extends ConsumerWidget {
  const _ImageViewerRoute({
    required this.illustId,
    required this.page,
    required this.quality,
    this.extra,
  });

  final int illustId;
  final int page;
  final ViewQuality quality;
  final ImageViewerRouteExtra? extra;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Prefer the store entity over the tap-time snapshot: when the detail
    // payload lands mid-session it carries original-tier URLs the snapshot
    // lacked, and recomputing urls lets PixivImage's gapless URL swap
    // upgrade to the real tier instead of staying on large forever. The
    // store does not notify: the detail the page below loads does.
    final detail = ref.watch(illustDetailControllerProvider(illustId));
    final entity =
        ref.watch(illustStoreProvider).get(illustId) ?? extra?.entity;
    final urls = entity?.viewerUrls(quality) ?? extra?.urls ?? const <String>[];
    return ImageViewerPage(
      entity: entity,
      urls: urls,
      // A restored viewer has no snapshot and no extra: it waits for the
      // detail's pages.
      loading: detail.isLoading,
      failure: switch (detail) {
        AsyncData(value: IllustDetailError(error: final Object error)) ||
        AsyncError(:final error) => FeedError(
          title: context.l10n.illustDetailLoadFailed,
          error: error,
          retryLabel: context.l10n.retry,
          onRetry: () => ref
              .read(illustDetailControllerProvider(illustId).notifier)
              .reload(),
        ),
        _ => null,
      },
      initialPage: page,
      heroTagForPage: switch (extra) {
        ImageViewerRouteExtra(:final heroScope?, :final entryPage) => (page) {
          if (page != entryPage) return null;
          final base = illustHeroTag(heroScope, illustId);
          return page == 0 ? base : '$base-$page';
        },
        _ => null,
      },
      tierKeyForPage: entity == null
          ? null
          : (page) => entity.imageTierKeyAt(page),
      tier: quality.tier,
      prefetchUrlForPage: entity == null
          ? null
          : (page) => entity.mediumUrlAt(page),
      onPageChanged: (page) => replaceImageViewerPage(
        context,
        illustId: illustId,
        page: page,
        quality: quality,
        extra: extra,
      ),
    );
  }
}

/// An image the author uploaded into a novel, alone in the viewer. Its
/// address comes from the body the reader below loaded.
class _NovelImageRoute extends ConsumerWidget {
  const _NovelImageRoute({required this.novelId, required this.imageId});

  final int novelId;
  final String imageId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final urls = ref
        .watch(novelStoreProvider.select((novels) => novels[novelId]))
        ?.uploadedImage(
          NovelImageLoadRequest(
            source: NovelImageSource.uploaded,
            identifier: imageId,
          ),
        );
    return ImageViewerPage(
      urls: [
        ?switch (ref.watch(viewQualityProvider)) {
          ViewQuality.original => urls?.original,
          ViewQuality.medium || ViewQuality.large => urls?.large,
        },
      ],
    );
  }
}

Widget _scoped(RouteObserver<ModalRoute<dynamic>> observer, Widget child) =>
    RouteObserverScope(observer: observer, child: child);

Page<dynamic> _page(
  BuildContext context,
  GoRouterState state,
  RouteObserver<ModalRoute<dynamic>> observer,
  Widget child, {
  bool sharedElement = false,
  bool sharedElementBackdrop = true,
  bool boundedOverlayOnWide = false,
}) {
  // Reduced-motion collapses the transition without dropping the state it
  // communicates: the route still changes on the same frame. The animation
  // speed scales each transition's own duration.
  final isDesktop = switch (Theme.of(context).platform) {
    TargetPlatform.windows ||
    TargetPlatform.macOS ||
    TargetPlatform.linux => true,
    TargetPlatform.android ||
    TargetPlatform.iOS ||
    TargetPlatform.fuchsia => false,
  };
  final duration = MotionTokens.resolve(
    context,
    sharedElement
        ? MotionTokens.sharedElement
        : isDesktop
        ? MotionTokens.desktopPageTransition
        : MotionTokens.pageTransition,
  );
  final page = FuncPage<dynamic>(
    key: state.pageKey,
    restorationId: RestorationScope.maybeOf(context) == null
        ? null
        : state.pageKey.value,
    // The detail route animates at the same time as the Hero overlay.
    // Keeping its static subtree in one repaint layer prevents the route
    // animation from repainting every image card on each tick; Hero still
    // extracts its own child into the navigator overlay and keeps the
    // custom flight clip.
    child: _scoped(observer, child),
    transitionDuration: duration,
    reverseTransitionDuration: duration,
    sharedElement: sharedElement,
    sharedElementBackdrop: sharedElementBackdrop,
    boundedOverlayOnWide: boundedOverlayOnWide,
  );
  ForwardHistoryStack.attachPage(
    page,
    bucket: _historyBucketForPath(state.uri.path),
    location: state.uri.toString(),
    extra: state.extra,
  );
  return page;
}

String _historyBucketForPath(String path) {
  for (final root in const [
    'recommended',
    'ranking',
    'new',
    'search',
    'settings',
  ]) {
    final prefix = '/$root';
    if (path == prefix || path.startsWith('$prefix/')) return root;
  }
  return 'root';
}

int _pathId(GoRouterState state, String name) =>
    int.parse(state.pathParameters[name]!);

/// Keeps the work the detail pager last settled on in the route's
/// restoration bucket. The pager source travels in `extra`, which a
/// restored route no longer has, so without this a restore after swiping
/// A→B reopened A.
class _RememberedIllust extends StatefulWidget {
  const _RememberedIllust({required this.builder});

  /// `remembered` is null until the pager settles on another work.
  final Widget Function(int? remembered, ValueChanged<int> remember) builder;

  @override
  State<_RememberedIllust> createState() => _RememberedIllustState();
}

class _RememberedIllustState extends State<_RememberedIllust>
    with RestorationMixin {
  final _shown = RestorableIntN(null);

  @override
  String get restorationId => 'illust-shown';

  @override
  void restoreState(RestorationBucket? oldBucket, bool initialRestore) {
    registerForRestoration(_shown, 'id');
  }

  void _remember(int id) {
    _shown.value = id;
    final page = ModalRoute.of(context)?.settings;
    if (page is Page<dynamic>) {
      ForwardHistoryStack.updatePageEntry(page, (current) {
        final nextLocation = current.location.replaceFirst(
          RegExp(r'/illust/\d+'),
          '/illust/$id',
        );
        final nextExtra = switch (current.extra) {
          final IllustRouteExtra e
              when e.pagerSource != null && e.pagerSource!.ids.contains(id) =>
            IllustRouteExtra(
              pagerSource: e.pagerSource,
              heroScope: e.heroScope,
            ),
          _ => null,
        };
        return ForwardHistoryEntry(
          bucket: current.bucket,
          location: nextLocation,
          extra: nextExtra,
        );
      });
    }
  }

  @override
  void dispose() {
    _shown.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(_shown.value, _remember);
}
