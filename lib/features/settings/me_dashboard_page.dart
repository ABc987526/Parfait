import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable, listEquals;
import 'package:flutter/rendering.dart'
    show
        BoxHitTestResult,
        ContainerBoxParentData,
        ContainerRenderObjectMixin,
        RenderBoxContainerDefaultsMixin;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../app/format/app_format.dart';
import '../../app/icons/app_icons.dart';
import '../../app/layout/content_widths.dart';
import '../../app/motion/hero_transition.dart';
import '../../app/motion/motion_tokens.dart';
import '../../app/navigation/routes.dart';
import '../../app/person_avatar.dart';
import '../../app/pixiv_image.dart';
import '../../app/pull_to_refresh.dart';
import '../../app/theme/func_semantic_tokens.dart';
import '../../app/theme/func_tokens.dart';
import '../../app/widgets/ambient_wash.dart';
import '../../app/widgets/app_top_bar.dart';
import '../../app/widgets/edge_icon_buttons.dart';
import '../../app/widgets/entity_row.dart' show EntityBadge;
import '../../app/widgets/feed/feed_grid.dart'
    show IllustPagerAnchor, IllustPagerScope, IllustPagerSource;
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/func_bottom_nav.dart';
import '../../app/widgets/master_detail_workspace.dart';
import '../../app/widgets/person_card.dart';
import '../../app/widgets/scroll_edge_fade.dart';
import '../../app/widgets/settings/settings_group.dart';
import '../../app/widgets/settings/settings_tile.dart';
import '../../app/widgets/settings_load_error.dart';
import '../../app/window/desktop_command_bar.dart' show DesktopCommandBarScope;
import '../../core/auth/account.dart';
import '../../core/auth/account_store.dart';
import '../../core/bookmark/bookmark_models.dart';
import '../../core/download/download_providers.dart';
import '../../core/download/download_task.dart' show isTerminal;
import '../../core/entity/illust_entity.dart';
import '../../core/entity/illust_store.dart';
import '../../core/history/history_models.dart';
import '../../core/history/history_repository.dart';
import '../../core/localnovel/local_novel_store.dart';
import '../../core/navigation/home_destination.dart';
import '../../core/profile/profile_feed_controller.dart';
import '../../core/profile/profile_models.dart';
import '../../core/settings/settings_controller.dart';
import '../../core/user/user_detail_controller.dart';
import '../../core/user/user_entity.dart';
import '../../core/user/user_repository.dart';
import '../../core/user/user_store.dart';
import '../../core/watchlater/watch_later_store.dart';
import '../../core/watchlist/watchlist_store.dart';
import '../../l10n/context.dart';
import 'pages/download_tasks_page.dart';
import 'settings_catalog.dart';
import 'settings_helpers.dart';
import 'settings_page.dart' show settingsPageIcons;

enum _MeSection {
  bookmarks,
  following,
  watchlist,
  novelMarkers,
  history,
  watchLater,
  localNovels,
  downloads,
}

/// The "me" destination, YouTube's way: who is signed in, what they saw
/// last, the places of their own content as a list, then settings and
/// about. Content comes first — it is what the page is opened for.
class MeDashboardPage extends ConsumerStatefulWidget {
  const MeDashboardPage({super.key});

  @override
  ConsumerState<MeDashboardPage> createState() => _MeDashboardPageState();
}

class _MeNetworkScope extends InheritedWidget {
  const _MeNetworkScope({required this.activated, required super.child});

  final bool activated;

  static bool of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_MeNetworkScope>()
          ?.activated ??
      true;

  @override
  bool updateShouldNotify(_MeNetworkScope oldWidget) =>
      activated != oldWidget.activated;
}

class _MeDashboardPageState extends ConsumerState<MeDashboardPage> {
  /// Preserves `_RecentHistoryState` (keep-alive covers & reorder animations)
  /// across narrow dashboard rebuilds.
  final _historyKey = GlobalKey();
  final _detailNavigatorKey = GlobalKey<NavigatorState>(
    debugLabel: 'me-detail',
  );
  _MeSection _selectedSection = _MeSection.bookmarks;
  bool _hasBeenVisible = false;

  void _selectSection(_MeSection section) {
    if (section == _selectedSection) return;
    setState(() => _selectedSection = section);
    final navigator = _detailNavigatorKey.currentState;
    if (navigator == null) return;
    unawaited(
      navigator.pushAndRemoveUntil<void>(
        _buildDetailRoute(section),
        (_) => false,
      ),
    );
  }

  Route<dynamic> _buildDetailRoute(_MeSection section, {bool instant = false}) {
    return PageRouteBuilder<void>(
      settings: RouteSettings(name: 'me/${section.name}'),
      transitionDuration: instant
          ? Duration.zero
          : MotionTokens.resolve(context, MotionTokens.desktopPageTransition),
      reverseTransitionDuration: instant
          ? Duration.zero
          : MotionTokens.resolve(context, MotionTokens.desktopPageTransition),
      pageBuilder: (_, _, _) => _buildWideDetail(section),
      transitionsBuilder: (_, animation, _, child) {
        final isReversing = animation.status == AnimationStatus.reverse;
        final curved = animation.drive(
          CurveTween(
            curve: isReversing
                ? MotionTokens.stateFadeCurve.flipped
                : MotionTokens.stateFadeCurve,
          ),
        );
        return IgnorePointer(
          ignoring: isReversing,
          child: FadeTransition(opacity: curved, child: child),
        );
      },
    );
  }

  Widget _buildWideDetail(_MeSection section) {
    return switch (section) {
      _MeSection.bookmarks => const _MeBookmarksPane(),
      _MeSection.following => const _MeFollowingPane(),
      _MeSection.watchlist => const WatchlistPage(),
      _MeSection.novelMarkers => const NovelMarkersPage(),
      _MeSection.history => const HistoryPage(),
      _MeSection.watchLater => const WatchLaterPage(),
      _MeSection.localNovels => const LocalNovelsPage(),
      _MeSection.downloads => const DownloadTasksPage(),
    };
  }

  @override
  Widget build(BuildContext context) {
    final route = ModalRoute.of(context);
    if (TickerMode.valuesOf(context).enabled && (route?.isCurrent ?? true)) {
      _hasBeenVisible = true;
    }
    final accounts = ref.watch(accountStoreProvider);
    final usable = accounts.value?.usableCurrent;
    if (usable != null && _hasBeenVisible) {
      ref.watch(userDetailControllerProvider(usable.userId));
    }
    final userDetail = usable == null
        ? null
        : ref.watch(userStoreProvider.select((users) => users[usable.userId]));
    final detail = userDetail != null && userDetail.hasDetail
        ? userDetail
        : null;
    final desktopOwned = DesktopCommandBarScope.isActiveOf(context);
    final wide = MasterDetailWorkspace.canDisplay(context);
    return _MeNetworkScope(
      activated: _hasBeenVisible,
      child: RefreshActionAnchor(
        onRefresh: () {
          ref.invalidate(_recentHistoryProvider);
          ref.invalidate(_downloadStatsProvider);
          ref.invalidate(watchLaterStoreProvider);
          ref.invalidate(localNovelStoreProvider);
          if (usable != null && _hasBeenVisible) {
            ref.invalidate(userDetailControllerProvider(usable.userId));
            ref.invalidate(
              profileIllustFeedProvider(
                ProfileFeedKey(
                  userId: usable.userId,
                  kind: ProfileFeedKind.bookmarks,
                  workType: UserWorkType.illust,
                  restrict: UserRestrict.public,
                ),
              ),
            );
          }
          unawaited(ref.read(accountStoreProvider.notifier).reload());
        },
        child: wide
            ? _wideBody(
                context,
                accounts,
                detail: detail,
                desktopOwned: desktopOwned,
              )
            : Scaffold(
                // Root pages own no inline composer: leaving the default `true`
                // would subscribe this whole subtree to per-frame viewInsets
                // churn every time the IME animates — a relayout storm across
                // all five live branches.
                resizeToAvoidBottomInset: false,
                appBar: desktopOwned
                    ? null
                    : AppTopBar(
                        contentWidth: ContentWidths.settings,
                        title: Text(context.l10n.homeMe),
                        actions: [
                          IconButton(
                            tooltip: context.l10n.settingsTitle,
                            icon: const Icon(AppIcons.settings),
                            onPressed: () =>
                                openSettingsPage(context, settingsIndexPath),
                          ),
                        ],
                      ),
                body: _narrowBody(context, accounts, detail: detail),
              ),
      ),
    );
  }

  Widget _narrowBody(
    BuildContext context,
    AsyncValue<AccountState> accounts, {
    required UserEntity? detail,
  }) {
    void reload() => ref.read(accountStoreProvider.notifier).reload();
    if (accounts.hasError) {
      return SettingsLoadError(
        error: accounts.error!,
        onRetry: reload,
        messageKey: 'accountReadFailed',
      );
    }
    if (accounts.isLoading && !accounts.hasValue) return const FeedLoading();
    final state = accounts.value;
    if (state?.status == AccountStatus.failure) {
      return SettingsLoadError(
        error: state?.error ?? StateError('account state unavailable'),
        onRetry: reload,
        messageKey: 'accountReadFailed',
      );
    }
    return settingsNarrowBody(
      ListView(
        padding: const EdgeInsets.only(
          top: FuncSpacing.sm,
          bottom: FuncSpacing.xl,
        ),
        children: [
          _AccountHeader(account: state?.current, detail: detail),
          _RecentHistory(key: _historyKey, showEmptyCard: true),
          _MeNarrowGroups(detail: detail),
          const FuncNavBarSpacer(),
        ],
      ),
    );
  }

  Widget _wideBody(
    BuildContext context,
    AsyncValue<AccountState> accounts, {
    required UserEntity? detail,
    required bool desktopOwned,
  }) {
    void reload() => ref.read(accountStoreProvider.notifier).reload();
    if (accounts.hasError) {
      return Scaffold(
        appBar: desktopOwned
            ? null
            : AppTopBar(
                contentWidth: ContentWidths.settings,
                title: Text(context.l10n.homeMe),
              ),
        body: SettingsLoadError(
          error: accounts.error!,
          onRetry: reload,
          messageKey: 'accountReadFailed',
        ),
      );
    }
    if (accounts.isLoading && !accounts.hasValue) {
      return Scaffold(
        appBar: desktopOwned
            ? null
            : AppTopBar(
                contentWidth: ContentWidths.settings,
                title: Text(context.l10n.homeMe),
              ),
        body: const FeedLoading(),
      );
    }
    final state = accounts.value;
    if (state?.status == AccountStatus.failure) {
      return Scaffold(
        appBar: desktopOwned
            ? null
            : AppTopBar(
                contentWidth: ContentWidths.settings,
                title: Text(context.l10n.homeMe),
              ),
        body: SettingsLoadError(
          error: state?.error ?? StateError('account state unavailable'),
          onRetry: reload,
          messageKey: 'accountReadFailed',
        ),
      );
    }
    final signedIn = state?.usableCurrent != null;
    final effectiveSection =
        !signedIn && _selectedSection == _MeSection.novelMarkers
        ? _MeSection.bookmarks
        : _selectedSection;
    if (effectiveSection != _selectedSection) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _selectSection(effectiveSection);
      });
    }
    return MasterDetailWorkspace(
      key: const ValueKey('me-wide-dashboard'),
      title: Text(context.l10n.homeMe),
      masterTop: _CompactAccountHeader(account: state?.current, detail: detail),
      masterBody: _MeWideRailGroups(
        signedIn: signedIn,
        detail: detail,
        selected: effectiveSection,
        includeSettingsEntries: !desktopOwned,
        onSelectSection: _selectSection,
      ),
      detail: SettingsDetailScope(
        onPush: (location) =>
            GoRouter.maybeOf(context)?.push<void>(location) ??
            Future<void>.value(),
        child: HeroControllerScope.none(
          child: Navigator(
            key: _detailNavigatorKey,
            onGenerateInitialRoutes: (_, _) => [
              _buildDetailRoute(effectiveSection, instant: true),
            ],
            onGenerateRoute: (_) => _buildDetailRoute(effectiveSection),
          ),
        ),
      ),
    );
  }
}

String? _resolvedAvatarUrl(Account? account, UserEntity? detail) {
  final primary = account?.profileImageUrl;
  if (primary != null && primary.isNotEmpty) return primary;
  final fallback = detail?.profileImageUrl;
  if (fallback != null && fallback.isNotEmpty) return fallback;
  return null;
}

String? _resolvedWashUrl(Account? account, UserEntity? detail) {
  final cover = detail?.backgroundImageUrl;
  if (cover != null && cover.isNotEmpty) return cover;
  return _resolvedAvatarUrl(account, detail);
}

/// Atmospheric personal header for mobile Me dashboard: subtle [AmbientWash]
/// backdrop when cover/avatar artwork is available, `PersonCard` identity
/// (preserving its single button semantic label), and a crisp live 3-column
/// stats footer once `userDetail` is loaded.
class _AccountHeader extends StatelessWidget {
  const _AccountHeader({required this.account, this.detail});

  final Account? account;
  final UserEntity? detail;

  static const _avatarDiameter = 54.0;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final tokens = FuncSemanticTokens.of(context);
    final value = account;
    final detail = value == null ? null : this.detail;
    final url = _resolvedAvatarUrl(value, detail);
    final washUrl = _resolvedWashUrl(value, detail);
    final card = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        PersonCard(
          color: FuncTokens.transparent,
          onTap: value == null
              ? () => openLogin(context)
              : () => openMe(context),
          tapHint: value == null ? null : l10n.meOpenProfile,
          endPadding: PersonCard.padding - EdgeIconButtons.glyphInset,
          trailing: value == null
              ? null
              : IconButton(
                  tooltip: l10n.accountManagement,
                  icon: const Icon(AppIcons.accountManage),
                  onPressed: () =>
                      openSettingsPage(context, SettingsPageRef.account.path),
                ),
          child: Row(
            children: [
              SizedBox.square(
                dimension: _avatarDiameter,
                child: PersonAvatar(
                  imageUrl: url,
                  radius: _avatarDiameter / 2,
                  ring: value != null,
                ),
              ),
              const SizedBox(width: FuncSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            value?.name ?? l10n.signedOut,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: tokens.display,
                          ),
                        ),
                        if (value?.isPremium ?? false) ...[
                          const SizedBox(width: FuncSpacing.sm),
                          const _PremiumBadge(),
                        ],
                      ],
                    ),
                    const SizedBox(height: FuncSpacing.xxs),
                    Text(
                      value == null
                          ? l10n.login
                          : l10n.labelValue(l10n.profileId, '${value.userId}'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (value != null && detail != null)
          DecoratedBox(
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: tokens.brandHairline)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: _HeaderStatCell(
                    label: l10n.profileBookmarked,
                    value: AppFormat.count(
                      context,
                      detail.totalIllustBookmarksPublic,
                    ),
                    onTap: () =>
                        unawaited(openMe(context, tab: MeTab.bookmarks)),
                  ),
                ),
                Expanded(
                  child: _HeaderStatCell(
                    label: l10n.profileFollowing,
                    value: AppFormat.count(context, detail.totalFollowUsers),
                    onTap: () =>
                        unawaited(openMe(context, tab: MeTab.following)),
                  ),
                ),
                Expanded(
                  child: _HeaderStatCell(
                    label: l10n.profileMyPixiv,
                    value: AppFormat.count(context, detail.totalMyPixivUsers),
                    onTap: () => unawaited(openMe(context)),
                  ),
                ),
              ],
            ),
          ),
      ],
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        FuncSpacing.lg,
        FuncSpacing.sm,
        FuncSpacing.lg,
        FuncSpacing.lg,
      ),
      child: Material(
        color: colors.surfaceContainer,
        shape: const RoundedRectangleBorder(borderRadius: FuncShape.panel),
        clipBehavior: Clip.antiAlias,
        child: washUrl == null
            ? card
            : Stack(
                children: [
                  Positioned.fill(
                    child: _CardWashBackdrop(
                      imageUrl: washUrl,
                      surfaceColor: colors.surfaceContainer,
                    ),
                  ),
                  card,
                ],
              ),
      ),
    );
  }
}

class _CardWashBackdrop extends StatelessWidget {
  const _CardWashBackdrop({required this.imageUrl, required this.surfaceColor});

  final String imageUrl;
  final Color surfaceColor;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ExcludeSemantics(
        child: Stack(
          fit: StackFit.expand,
          children: [
            AmbientWash(
              image: PixivImage.providerFor(context, imageUrl, decodeWidth: 96),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    surfaceColor.withValues(alpha: 0.42),
                    surfaceColor.withValues(alpha: 0.90),
                    surfaceColor,
                  ],
                  stops: const [0, 0.72, 1],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HeaderStatCell extends StatelessWidget {
  const _HeaderStatCell({
    required this.label,
    required this.value,
    required this.onTap,
  });

  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Semantics(
      container: true,
      button: true,
      label: '$label, $value',
      onTap: onTap,
      child: ExcludeSemantics(
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: FuncSpacing.sm,
              vertical: FuncSpacing.sm + FuncSpacing.xxs,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700)
                      .tabular,
                ),
                const SizedBox(height: FuncSpacing.xxs),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Compact `40dp` identity card pinned below the `52dp` master header in the
/// wide [MasterDetailWorkspace] Me rail.
class _CompactAccountHeader extends StatelessWidget {
  const _CompactAccountHeader({required this.account, this.detail});

  final Account? account;
  final UserEntity? detail;

  static const _avatarDiameter = 40.0;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final value = account;
    final url = _resolvedAvatarUrl(value, value == null ? null : detail);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        FuncSpacing.md,
        FuncSpacing.sm,
        FuncSpacing.md,
        FuncSpacing.xs,
      ),
      child: Material(
        color: colors.surfaceContainer,
        shape: const RoundedRectangleBorder(borderRadius: FuncShape.card),
        clipBehavior: Clip.antiAlias,
        child: Semantics(
          onTapHint: value == null ? null : l10n.meOpenProfile,
          child: InkWell(
            onTap: value == null
                ? () => openLogin(context)
                : () => openMe(context),
            child: Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(
                FuncSpacing.md,
                FuncSpacing.sm,
                FuncSpacing.xs,
                FuncSpacing.sm,
              ),
              child: Row(
                children: [
                  SizedBox.square(
                    dimension: _avatarDiameter,
                    child: PersonAvatar(
                      imageUrl: url,
                      radius: _avatarDiameter / 2,
                      ring: value != null,
                    ),
                  ),
                  const SizedBox(width: FuncSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          value?.name ?? l10n.signedOut,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          value == null
                              ? l10n.login
                              : l10n.labelValue(
                                  l10n.profileId,
                                  '${value.userId}',
                                ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (value != null)
                    IconButton(
                      tooltip: l10n.accountManagement,
                      icon: const Icon(AppIcons.accountManage),
                      onPressed: () => openSettingsPage(
                        context,
                        SettingsPageRef.account.path,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// pixiv Premium beside the name: a neutral pill, a fact about the
/// account rather than an accent (THEME-07).
class _PremiumBadge extends StatelessWidget {
  const _PremiumBadge();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: FuncShape.pill,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: FuncSpacing.sm,
          vertical: FuncSpacing.xxs,
        ),
        child: Text(
          context.l10n.premiumBadge,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

typedef _DownloadStats = ({int active, int total});

/// Live active and total download counts; emits only when either count changes
/// so progress ticks never rebuild the dashboard rows.
final _downloadStatsProvider = StreamProvider.autoDispose<_DownloadStats>((
  ref,
) async* {
  final manager = ref.watch(downloadManagerProvider);
  _DownloadStats snapshot() {
    final tasks = manager.tasks;
    var active = 0;
    for (final task in tasks) {
      if (!isTerminal(task.status)) active++;
    }
    return (active: active, total: tasks.length);
  }

  var last = snapshot();
  yield last;
  await for (final _ in manager.changes) {
    final next = snapshot();
    if (next == last) continue;
    yield last = next;
  }
});

/// The latest history records, newest first. Read again after every
/// history write, so a work seen elsewhere is on the row by the time the
/// page shows again.
final _recentHistoryProvider = FutureProvider.autoDispose<List<HistoryRecord>>((
  ref,
) async {
  final accountId = ref.watch(historyAccountIdProvider);
  if (accountId == null) return const [];
  final repository = ref.watch(historyRepositoryProvider);
  final changes = repository.changes.listen((_) => ref.invalidateSelf());
  ref.onDispose(changes.cancel);
  final result = await repository.page(
    accountId: accountId,
    limit: _RecentHistory._count,
  );
  return result.records;
});

/// The works seen last, as a row of covers; "view all" opens the history.
/// Renders a restrained empty-history entry card when empty and [showEmptyCard]
/// is true so users can still reach [HistoryPage].
class _RecentHistory extends ConsumerStatefulWidget {
  const _RecentHistory({super.key, this.showEmptyCard = false});

  static const _count = 8;
  static const _cover = 86.0;
  static const _gap = FuncSpacing.sm;

  /// The row's own Hero scope (TRANS-07): the same work may sit on a feed
  /// still mounted in another branch.
  static const _heroScope = 'me-history';

  final bool showEmptyCard;

  @override
  ConsumerState<_RecentHistory> createState() => _RecentHistoryState();
}

class _RecentHistoryState extends ConsumerState<_RecentHistory>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  /// The row's illustrations for the detail pager. Never disposed here: a
  /// pushed detail route still holds it — its lifetime is the route's.
  final _pager = IllustPagerSource();

  /// The covers as shown. Each work viewed moves to the front of the
  /// history, but the row keeps its order while any page is over it (one
  /// opened from it, or from anywhere else), so the image flying back lands
  /// where its cover was when the pager aimed it. Once that page has left,
  /// the row takes the new order, each cover sliding to its place.
  List<HistoryRecord> _shown = const [];

  /// Bumped each time the row takes a new order; [_from] holds where each
  /// cover was then, in places relative to its new one, and [_joined] the
  /// covers that order brought onto the row. A first fill (an empty row
  /// before) slides nothing.
  int _order = 0;
  Map<(HistoryContentType, int), int> _from = const {};
  Set<(HistoryContentType, int)> _joined = const {};

  /// The transitions of the pages over the row: over its own route in the
  /// branch, and over the home shell on the root navigator (the profile,
  /// downloads). The row is covered while either is not dismissed.
  ///
  /// Not TickerMode: the Overlay turns tickers off under any opaque page,
  /// so it cannot tell a page over the row from another tab.
  List<Animation<double>> _covers = const [];
  bool _covered = false;

  /// Whether the open work flew in. One opened without a flight (its work
  /// not in the store yet, no ratio to fly by) takes none back either.
  bool _flies = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final covers = <Animation<double>>[];
    final seenRoutes = <ModalRoute<dynamic>>{};
    void collect(ModalRoute<dynamic>? candidate) {
      if (candidate == null || !seenRoutes.add(candidate)) return;
      final secondary = candidate.secondaryAnimation;
      if (secondary != null && !covers.contains(secondary)) {
        covers.add(secondary);
      }
    }

    collect(ModalRoute.of(context));
    final seenNavigators = <NavigatorState>{};
    var navigator = Navigator.maybeOf(context);
    while (navigator != null && seenNavigators.add(navigator)) {
      final navContext = navigator.context;
      collect(ModalRoute.of(navContext));
      // Navigator.maybeOf(navContext) returns `navigator` itself because
      // `navContext` is its own StatefulElement; use findAncestorStateOfType
      // to step strictly above it toward the root Navigator.
      navigator = navContext.findAncestorStateOfType<NavigatorState>();
    }
    if (listEquals(covers, _covers)) return;
    for (final cover in _covers) {
      cover.removeStatusListener(_onCover);
    }
    _covers = covers;
    for (final cover in covers) {
      cover.addStatusListener(_onCover);
    }
    _covered = _isCovered;
  }

  @override
  void dispose() {
    for (final cover in _covers) {
      cover.removeStatusListener(_onCover);
    }
    super.dispose();
  }

  bool get _isCovered => _covers.any((cover) => !cover.isDismissed);

  /// A page starts covering the row, or the last one over it has left
  /// and its image has landed.
  void _onCover(AnimationStatus status) {
    final covered = _isCovered;
    if (covered == _covered) return;
    setState(() {
      _covered = covered;
      if (!covered) _flies = true;
    });
  }

  static (HistoryContentType, int) _keyOf(HistoryRecord record) =>
      (record.contentType, record.contentId);

  void _adopt(List<HistoryRecord> records) {
    final before = {for (final (i, r) in _shown.indexed) _keyOf(r): i};
    final moved =
        before.length != records.length ||
        records.indexed.any((e) => before[_keyOf(e.$2)] != e.$1);
    if (before.isEmpty) {
      _from = const {};
      _joined = const {};
    } else if (moved) {
      _order++;
      _from = {
        for (final (i, r) in records.indexed)
          if (before[_keyOf(r)] case final was?) _keyOf(r): was - i,
      };
      _joined = {
        for (final r in records)
          if (!before.containsKey(_keyOf(r))) _keyOf(r),
      };
    }
    _shown = records;
  }

  void _open(HistoryRecord record) {
    final id = record.contentId;
    switch (record.contentType) {
      case HistoryContentType.novel:
        unawaited(openNovel(context, id));
      case HistoryContentType.illust:
        _pager.update([
          for (final record in _shown)
            if (record.contentType == HistoryContentType.illust)
              record.contentId,
        ]);
        final entity = ref.read(illustStoreProvider).get(id);
        final url = record.snapshot.coverUrl;
        final flies = entity != null && url != null;
        setState(() => _flies = flies);
        unawaited(
          openIllust(
            context,
            id,
            initialEntity: entity,
            heroScope: _RecentHistory._heroScope,
            heroImageUrl: flies ? url : null,
            heroImageDecodeWidth: flies
                ? PixivImage.decodeWidthOf(
                    context,
                    _RecentCover.layoutWidth(entity),
                    listen: false,
                  )
                : null,
            pagerSource: _pager,
          ),
        );
    }
  }

  Widget _rowCover(IllustStore store, HistoryRecord record) {
    final illust = record.contentType == HistoryContentType.illust;
    final cover = _RecentCover(
      record: record,
      entity: illust ? store.get(record.contentId) : null,
      flies: _flies,
      onTap: () => _open(record),
    );
    return illust
        ? IllustPagerAnchor(illustId: record.contentId, child: cover)
        : cover;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    // Under another tab the row is left; it catches up once it shows
    // again. Under a page it holds until that page has left.
    final showing = TickerMode.valuesOf(context).enabled;
    // After a switch the provider keeps the previous account's records
    // while the next ones load, or for good if that read fails: covers of
    // another account leave at once, slide-free, whatever is over the row.
    final account = ref.watch(historyAccountIdProvider);
    if (_shown.isNotEmpty && _shown.first.accountId != account) {
      _shown = const [];
      _from = const {};
      _joined = const {};
    }
    final records = ref
        .watch(_recentHistoryProvider)
        .value
        ?.where((record) => record.accountId == account)
        .toList();
    if (records != null && showing && !_covered) _adopt(records);
    final shown = _shown;
    final theme = Theme.of(context);
    if (shown.isEmpty) {
      if (!widget.showEmptyCard) return const SizedBox.shrink();
      return SettingsGroup(
        title: Text(context.l10n.historySettings),
        children: [
          InkWell(
            onTap: () => unawaited(openHistory(context)),
            child: Padding(
              padding: const EdgeInsets.all(FuncSpacing.lg),
              child: Row(
                children: [
                  Icon(
                    AppIcons.history,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: FuncSpacing.md),
                  Expanded(
                    child: Text(
                      context.l10n.historyEmpty,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Icon(
                    Icons.chevron_right,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }
    final store = ref.watch(illustStoreProvider);
    return Padding(
      padding: const EdgeInsets.only(bottom: FuncSpacing.xl - FuncSpacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            // A group heading's inset: the group's and the title's own.
            // Bottom is 0 to offset the cover row's FuncSpacing.xs lift headroom.
            padding: const EdgeInsets.fromLTRB(
              FuncSpacing.lg + FuncSpacing.lg,
              0,
              FuncSpacing.lg,
              0,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(
                      context.l10n.historySettings,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                TextButton(
                  style: TextButton.styleFrom(
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () => unawaited(openHistory(context)),
                  child: Text(context.l10n.detailViewAll),
                ),
              ],
            ),
          ),
          SizedBox(
            height: _RecentHistory._cover + 2 * FuncSpacing.xs,
            child: IllustPagerScope(
              source: _pager,
              // Eight covers at most: built all at once, keyed by work, so
              // each keeps its state as the order changes.
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final rowWidth =
                      shown.length * _RecentHistory._cover +
                      math.max(0, shown.length - 1) * _RecentHistory._gap +
                      2 * FuncSpacing.lg;
                  return ScrollEdgeFade(
                    axis: Axis.horizontal,
                    fadeExtent: FuncSpacing.lg,
                    initialAfter: rowWidth > constraints.maxWidth + 0.5,
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(
                        horizontal: FuncSpacing.lg,
                        vertical: FuncSpacing.xs,
                      ),
                      child: _HistoryCoverRow(
                        coverSize: _RecentHistory._cover,
                        gap: _RecentHistory._gap,
                        textDirection: Directionality.of(context),
                        children: [
                          for (final (index, record) in shown.indexed)
                            _HistoryCoverSlot(
                              key: ValueKey(_keyOf(record)),
                              paintPriority: _paintPriority(
                                index: index,
                                total: shown.length,
                                from: _from[_keyOf(record)],
                                entering: _joined.contains(_keyOf(record)),
                              ),
                              child: _RowSlot(
                                order: _order,
                                from: _from[_keyOf(record)],
                                entering: _joined.contains(_keyOf(record)),
                                child: _rowCover(store, record),
                              ),
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  static int _paintPriority({
    required int index,
    required int total,
    required int? from,
    required bool entering,
  }) {
    if ((from != null && from > 0) || (index == 0 && entering)) {
      return 2 + (total - index);
    }
    if (from != null && from < 0) return 0;
    return 1;
  }
}

class _HistoryCoverSlotData extends ContainerBoxParentData<RenderBox> {
  int paintPriority = 1;
}

class _HistoryCoverSlot extends ParentDataWidget<_HistoryCoverSlotData> {
  const _HistoryCoverSlot({
    super.key,
    required this.paintPriority,
    required super.child,
  });

  final int paintPriority;

  @override
  void applyParentData(RenderObject renderObject) {
    final data = renderObject.parentData! as _HistoryCoverSlotData;
    if (data.paintPriority != paintPriority) {
      data.paintPriority = paintPriority;
      renderObject.parent?.markNeedsPaint();
    }
  }

  @override
  Type get debugTypicalAncestorWidgetClass => _HistoryCoverRow;
}

/// Lays out recent history covers left-to-right (or RTL) in widget/semantics
/// order while painting promoted forward-moving covers above displaced ones so
/// crossing cards never clip the leading cover in half.
class _HistoryCoverRow extends MultiChildRenderObjectWidget {
  const _HistoryCoverRow({
    required this.coverSize,
    required this.gap,
    required this.textDirection,
    required super.children,
  });

  final double coverSize;
  final double gap;
  final TextDirection textDirection;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderHistoryCoverRow(
        coverSize: coverSize,
        gap: gap,
        textDirection: textDirection,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderHistoryCoverRow renderObject,
  ) {
    renderObject
      ..coverSize = coverSize
      ..gap = gap
      ..textDirection = textDirection;
  }
}

class _RenderHistoryCoverRow extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _HistoryCoverSlotData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _HistoryCoverSlotData> {
  _RenderHistoryCoverRow({
    required double coverSize,
    required double gap,
    required TextDirection textDirection,
  }) : _coverSize = coverSize,
       _gap = gap,
       _textDirection = textDirection;

  double _coverSize;
  set coverSize(double value) {
    if (_coverSize == value) return;
    _coverSize = value;
    markNeedsLayout();
  }

  double _gap;
  set gap(double value) {
    if (_gap == value) return;
    _gap = value;
    markNeedsLayout();
  }

  TextDirection _textDirection;
  set textDirection(TextDirection value) {
    if (_textDirection == value) return;
    _textDirection = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _HistoryCoverSlotData) {
      child.parentData = _HistoryCoverSlotData();
    }
  }

  Size _rowSize(int count) {
    if (count == 0) return Size(0, _coverSize);
    return Size(count * _coverSize + (count - 1) * _gap, _coverSize);
  }

  @override
  double computeMinIntrinsicWidth(double height) => _rowSize(childCount).width;

  @override
  double computeMaxIntrinsicWidth(double height) => _rowSize(childCount).width;

  @override
  double computeMinIntrinsicHeight(double width) => _coverSize;

  @override
  double computeMaxIntrinsicHeight(double width) => _coverSize;

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      constraints.constrain(_rowSize(childCount));

  @override
  void performLayout() {
    final count = childCount;
    size = constraints.constrain(_rowSize(count));
    final childConstraints = BoxConstraints.tightFor(
      width: _coverSize,
      height: _coverSize,
    );
    final stride = _coverSize + _gap;
    final ltr = _textDirection == TextDirection.ltr;
    var index = 0;
    var child = firstChild;
    while (child != null) {
      child.layout(childConstraints, parentUsesSize: false);
      final data = child.parentData! as _HistoryCoverSlotData;
      final slot = ltr ? index : count - 1 - index;
      data.offset = Offset(slot * stride, 0);
      child = data.nextSibling;
      index++;
    }
  }

  List<RenderBox> _paintOrderedChildren() {
    final ordered = <RenderBox>[];
    var child = firstChild;
    while (child != null) {
      ordered.add(child);
      child = (child.parentData! as _HistoryCoverSlotData).nextSibling;
    }
    final indexed = ordered.indexed.toList()
      ..sort((a, b) {
        final pa = (a.$2.parentData! as _HistoryCoverSlotData).paintPriority;
        final pb = (b.$2.parentData! as _HistoryCoverSlotData).paintPriority;
        final byPriority = pa.compareTo(pb);
        return byPriority != 0 ? byPriority : a.$1.compareTo(b.$1);
      });
    return [for (final (_, box) in indexed) box];
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    for (final child in _paintOrderedChildren()) {
      final data = child.parentData! as _HistoryCoverSlotData;
      context.paintChild(child, data.offset + offset);
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    for (final child in _paintOrderedChildren().reversed) {
      final data = child.parentData! as _HistoryCoverSlotData;
      final hit = result.addWithPaintOffset(
        offset: data.offset,
        position: position,
        hitTest: (result, transformed) =>
            child.hitTest(result, position: transformed),
      );
      if (hit) return true;
    }
    return false;
  }
}

class _SlotLift extends InheritedWidget {
  const _SlotLift({required this.scale, required super.child});

  final ValueListenable<double> scale;

  static ValueListenable<double>? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_SlotLift>()?.scale;

  @override
  bool updateShouldNotify(_SlotLift oldWidget) =>
      !identical(scale, oldWidget.scale);
}

/// A cover's place on the row. When the row takes a new order, a cover
/// that moved slides from where it was to its new place; one new to the row
/// slides in from the leading edge and fades in. A new order arriving
/// mid-slide carries on from where the cover is. Reduced motion moves it at
/// once.
class _RowSlot extends StatefulWidget {
  const _RowSlot({
    required this.order,
    required this.from,
    required this.entering,
    required this.child,
  });

  /// The row's order generation; a new one starts a slide.
  final int order;

  /// Where the cover was when the row took [order], in places relative to
  /// its new one; null when it is new to the row.
  final int? from;

  /// Whether the cover joined the row with [order].
  final bool entering;
  final Widget child;

  @override
  State<_RowSlot> createState() => _RowSlotState();
}

class _RowSlotState extends State<_RowSlot>
    with SingleTickerProviderStateMixin {
  static const _stride = _RecentHistory._cover + _RecentHistory._gap;

  /// The fade of a cover joining the row: an effect, shorter than the move.
  static const _fadeIn = Interval(0, 0.5);

  late final _controller = AnimationController(vsync: this, value: 1)
    ..addListener(_syncLift);
  late final ValueNotifier<double> _liftScale = ValueNotifier(1.0);

  /// The slide's start, in logical pixels from the cover's place.
  double _start = 0;
  bool _fading = false;
  bool _lifting = false;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (widget.entering) {
      _slide(from: -1, fade: true, lift: false);
    }
  }

  @override
  void didUpdateWidget(_RowSlot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.order == oldWidget.order) return;
    final from = widget.from;
    if (from != null && from != 0) {
      _slide(from: from, fade: false, lift: from > 0);
    }
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_syncLift)
      ..dispose();
    _liftScale.dispose();
    super.dispose();
  }

  void _syncLift() {
    final next = !_lifting || _controller.isCompleted
        ? 1.0
        : 1.0 + 0.04 * math.sin(_controller.value * math.pi);
    if (_liftScale.value != next) _liftScale.value = next;
  }

  // Symmetric ease preserves combined center-of-mass (x_promoted + x_displaced
  // == 1.0 across every frame) so adjacent slots never open an empty gap, while
  // [_HistoryCoverRow] paints the lifted promoted cover cleanly on top.
  static const _slideCurve = Curves.easeInOutCubic;

  double get _offset => _start * (1 - _slideCurve.transform(_controller.value));

  void _slide({required int from, required bool fade, required bool lift}) {
    final duration = MotionTokens.resolve(context, MotionTokens.spatial);
    if (duration == Duration.zero) return;
    final leading = Directionality.of(context) == TextDirection.ltr ? 1 : -1;
    _start = _offset + from * _stride * leading;
    _fading = fade;
    _lifting = lift;
    _controller
      ..duration = duration
      ..forward(from: 0);
    _syncLift();
  }

  @override
  Widget build(BuildContext context) => _SlotLift(
    scale: _liftScale,
    child: AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (context, child) {
        final moved = Transform.translate(
          offset: Offset(_offset, 0),
          child: child,
        );
        return _fading
            ? Opacity(
                opacity: _fadeIn.transform(_controller.value),
                // Still one object to a screen reader while it fades in.
                alwaysIncludeSemantics: true,
                child: moved,
              )
            : moved;
      },
    ),
  );
}

/// A work of the row: its cover, the top of a tall one and the middle of
/// a wide one, a novel marked as one. An illustration whose work is in the
/// store carries the Hero to its detail page. One object to a screen
/// reader, read by its title.
class _RecentCover extends StatelessWidget {
  const _RecentCover({
    required this.record,
    required this.entity,
    required this.flies,
    required this.onTap,
  });

  final HistoryRecord record;

  /// The illustration's work from the store, for its ratio.
  final IllustEntity? entity;
  final bool flies;
  final VoidCallback onTap;

  static const _size = _RecentHistory._cover;

  /// The cover's decode width: a wide image covers the square by its
  /// height, so it is decoded wider.
  static double layoutWidth(IllustEntity? entity) =>
      _size * math.max(1, entity?.pageAspectRatioAt(0) ?? 1);

  @override
  Widget build(BuildContext context) {
    final url = record.snapshot.coverUrl;
    final novel = record.contentType == HistoryContentType.novel;
    final entity = this.entity;
    Widget? image;
    if (url != null) {
      final tag = illustHeroTag(_RecentHistory._heroScope, record.contentId);
      image = PixivImage.feed(
        url,
        layoutWidth: layoutWidth(entity),
        alignment: Alignment.topCenter,
        transitionKey: entity == null ? null : tag,
      );
      if (entity != null) {
        image = HeroMode(
          enabled: flies,
          child: Hero(
            tag: tag,
            curve: MotionTokens.spatialCurve,
            createRectTween: illustHeroRectTween,
            flightShuttleBuilder: illustHeroFlightShuttleBuilder,
            child: IllustHeroCardFrame(
              cropAspect: entity.pageAspectRatioAt(0),
              child: image,
            ),
          ),
        );
      }
    }
    final content = InkWell(
      onTap: onTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          image ?? Icon(novel ? AppIcons.novel : AppIcons.illust),
          if (novel)
            const Positioned(
              left: 7,
              top: 7,
              child: EntityBadge(icon: AppIcons.novel),
            ),
        ],
      ),
    );
    final scheme = Theme.of(context).colorScheme;
    Widget buildCard(double elevation) => Material(
      color: scheme.surfaceContainer,
      elevation: elevation,
      shadowColor: scheme.shadow,
      shape: const RoundedRectangleBorder(borderRadius: FuncShape.card),
      clipBehavior: Clip.antiAlias,
      child: content,
    );
    final lift = _SlotLift.of(context);
    return Semantics(
      container: true,
      button: true,
      label: record.snapshot.title,
      onTap: onTap,
      excludeSemantics: true,
      child: SizedBox.square(
        dimension: _size,
        child: lift == null
            ? buildCard(0)
            : ValueListenableBuilder<double>(
                valueListenable: lift,
                child: content,
                builder: (_, scale, child) {
                  final elevation = ((scale - 1.0) / 0.04).clamp(0.0, 1.0) * 4;
                  return Transform.scale(
                    scale: scale,
                    child: Material(
                      color: scheme.surfaceContainer,
                      elevation: elevation,
                      shadowColor: scheme.shadow,
                      shape: const RoundedRectangleBorder(
                        borderRadius: FuncShape.card,
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: child,
                    ),
                  );
                },
              ),
      ),
    );
  }
}

String? _joinSubtitleParts(Iterable<String?> parts) {
  final clean = [
    for (final part in parts)
      if (part != null && part.trim().isNotEmpty) part.trim(),
  ];
  if (clean.isEmpty) return null;
  return clean.join(' ·\u00A0');
}

/// Narrow/single-column Me dashboard groups (`SET-01`, `SET-08`): monochrome
/// leading icons, crisp single-line collection rows with live trailing counts,
/// and summary lines reserved for Settings and About.
class _MeNarrowGroups extends ConsumerWidget {
  const _MeNarrowGroups({this.detail});

  final UserEntity? detail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final downloadStats =
        ref.watch(_downloadStatsProvider).value ?? (active: 0, total: 0);
    final watchLaterCount = ref.watch(watchLaterStoreProvider).value?.length;
    final localNovelsCount = ref.watch(localNovelStoreProvider).value?.length;
    final watchlistEntries = ref.watch(watchlistStoreProvider);
    final activeWatchlist = watchlistEntries.values
        .where((e) => e.shown)
        .length;
    final appSettings = ref.watch(settingsProvider).value;
    final offBar = ref.watch(homeArrangementProvider).hidden;
    final signedIn = ref.watch(
      accountStoreProvider.select(
        (async) => async.value?.usableCurrent != null,
      ),
    );
    final detail = signedIn ? this.detail : null;
    final settingsSubtitle = appSettings == null
        ? l10n.settingsBrowseHint
        : _joinSubtitleParts([
                themeModeLabel(context, appSettings.themeCode),
                languageDisplayName(appSettings.languageTag),
              ]) ??
              l10n.settingsBrowseHint;

    String? countText(int? count) =>
        count != null && count > 0 ? AppFormat.count(context, count) : null;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsGroup(
          title: Text(l10n.settingsGroupLibrary),
          children: [
            SettingsTile.topLevel(
              icon: AppIcons.heart,
              title: l10n.profileBookmarked,
              trailingText: countText(detail?.totalIllustBookmarksPublic),
              onTap: () => unawaited(openMe(context, tab: MeTab.bookmarks)),
            ),
            SettingsTile.topLevel(
              icon: AppIcons.users,
              title: l10n.profileFollowing,
              trailingText: countText(detail?.totalFollowUsers),
              onTap: () => unawaited(openMe(context, tab: MeTab.following)),
            ),
            SettingsTile.topLevel(
              icon: AppIcons.watchlist,
              title: l10n.watchlistTitle,
              trailingText: countText(activeWatchlist),
              onTap: () => unawaited(openWatchlist(context)),
            ),
            // Pixiv keeps novel markers with the signed-in account.
            if (signedIn)
              SettingsTile.topLevel(
                icon: AppIcons.novelMarkers,
                title: l10n.novelMarkers,
                onTap: () => unawaited(openNovelMarkers(context)),
              ),
            for (final destination in HomeDestination.values)
              if (offBar.contains(destination))
                SettingsTile.topLevel(
                  icon: homeDestinationIcon(destination),
                  title: homeDestinationLabel(context, destination),
                  onTap: () => openHomeDestination(context, destination),
                ),
          ],
        ),
        SettingsGroup(
          title: Text(l10n.settingsGroupData),
          children: [
            SettingsTile.topLevel(
              icon: AppIcons.watchLater,
              title: l10n.watchLaterTitle,
              trailingText: countText(watchLaterCount),
              onTap: () => unawaited(openWatchLater(context)),
            ),
            SettingsTile.topLevel(
              icon: AppIcons.localNovel,
              title: l10n.localNovelsTitle,
              trailingText: countText(localNovelsCount),
              onTap: () => unawaited(openLocalNovels(context)),
            ),
            SettingsTile.topLevel(
              icon: AppIcons.downloading,
              title: l10n.downloaderSettings,
              trailingText: downloadStats.active == 0
                  ? countText(downloadStats.total)
                  : null,
              trailingBadge: Badge(
                isLabelVisible: downloadStats.active > 0,
                label: Text(AppFormat.count(context, downloadStats.active)),
              ),
              onTap: () => unawaited(openDownloadTasks(context)),
            ),
          ],
        ),
        SettingsGroup(
          title: const Text('Parfait'),
          children: [
            SettingsTile.topLevel(
              icon: AppIcons.settings,
              title: l10n.settingsTitle,
              subtitle: Text(settingsSubtitle),
              onTap: () => openSettingsPage(context, settingsIndexPath),
            ),
            SettingsTile.topLevel(
              icon: settingsPageIcons[SettingsPageRef.about]!,
              title: l10n.aboutSettings,
              subtitle: const _MeVersionSummary(),
              onTap: () =>
                  openSettingsPage(context, SettingsPageRef.about.path),
            ),
          ],
        ),
      ],
    );
  }
}

/// Wide [MasterDetailWorkspace] left-rail navigation groups for Me (`280dp`,
/// `showChevron: false`). Every section appears once here with live trailing
/// counts and opens directly in the right pane; touch tablets keep
/// Settings/About here because their outer `ShellRail` does not render desktop
/// bottom Settings controls.
class _MeWideRailGroups extends ConsumerWidget {
  const _MeWideRailGroups({
    required this.signedIn,
    required this.detail,
    required this.selected,
    required this.includeSettingsEntries,
    required this.onSelectSection,
  });

  final bool signedIn;
  final UserEntity? detail;
  final _MeSection selected;
  final bool includeSettingsEntries;
  final ValueChanged<_MeSection> onSelectSection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final downloadStats =
        ref.watch(_downloadStatsProvider).value ?? (active: 0, total: 0);
    final watchLaterCount = ref.watch(watchLaterStoreProvider).value?.length;
    final localNovelsCount = ref.watch(localNovelStoreProvider).value?.length;
    final watchlistEntries = ref.watch(watchlistStoreProvider);
    final activeWatchlist = watchlistEntries.values
        .where((e) => e.shown)
        .length;
    final offBar = ref.watch(homeArrangementProvider).hidden;
    final resolvedDetail = signedIn ? detail : null;

    String? countText(int? count) =>
        count != null && count > 0 ? AppFormat.count(context, count) : null;

    return ListView(
      padding: const EdgeInsets.only(
        top: FuncSpacing.xs,
        bottom: FuncSpacing.xl,
      ),
      children: [
        SettingsGroup(
          title: Text(l10n.settingsGroupLibrary),
          children: [
            SettingsTile.topLevel(
              icon: AppIcons.heart,
              selectedIcon: AppIcons.heartFilled,
              title: l10n.profileBookmarked,
              trailingText: countText(
                resolvedDetail?.totalIllustBookmarksPublic,
              ),
              selected: selected == _MeSection.bookmarks,
              showChevron: false,
              onTap: () => onSelectSection(_MeSection.bookmarks),
            ),
            SettingsTile.topLevel(
              icon: AppIcons.users,
              title: l10n.profileFollowing,
              trailingText: countText(resolvedDetail?.totalFollowUsers),
              selected: selected == _MeSection.following,
              showChevron: false,
              onTap: () => onSelectSection(_MeSection.following),
            ),
            SettingsTile.topLevel(
              icon: AppIcons.watchlist,
              title: l10n.watchlistTitle,
              trailingText: countText(activeWatchlist),
              selected: selected == _MeSection.watchlist,
              showChevron: false,
              onTap: () => onSelectSection(_MeSection.watchlist),
            ),
            if (signedIn)
              SettingsTile.topLevel(
                icon: AppIcons.novelMarkers,
                title: l10n.novelMarkers,
                selected: selected == _MeSection.novelMarkers,
                showChevron: false,
                onTap: () => onSelectSection(_MeSection.novelMarkers),
              ),
            for (final destination in HomeDestination.values)
              if (offBar.contains(destination))
                SettingsTile.topLevel(
                  icon: homeDestinationIcon(destination),
                  title: homeDestinationLabel(context, destination),
                  showChevron: false,
                  onTap: () => openHomeDestination(context, destination),
                ),
          ],
        ),
        SettingsGroup(
          title: Text(l10n.settingsGroupData),
          children: [
            SettingsTile.topLevel(
              icon: AppIcons.history,
              title: l10n.historySettings,
              selected: selected == _MeSection.history,
              showChevron: false,
              onTap: () => onSelectSection(_MeSection.history),
            ),
            SettingsTile.topLevel(
              icon: AppIcons.watchLater,
              selectedIcon: AppIcons.watchLaterFilled,
              title: l10n.watchLaterTitle,
              trailingText: countText(watchLaterCount),
              selected: selected == _MeSection.watchLater,
              showChevron: false,
              onTap: () => onSelectSection(_MeSection.watchLater),
            ),
            SettingsTile.topLevel(
              icon: AppIcons.localNovel,
              title: l10n.localNovelsTitle,
              trailingText: countText(localNovelsCount),
              selected: selected == _MeSection.localNovels,
              showChevron: false,
              onTap: () => onSelectSection(_MeSection.localNovels),
            ),
            SettingsTile.topLevel(
              icon: AppIcons.downloading,
              title: l10n.downloaderSettings,
              trailingText: downloadStats.active == 0
                  ? countText(downloadStats.total)
                  : null,
              selected: selected == _MeSection.downloads,
              showChevron: false,
              trailingBadge: Badge(
                isLabelVisible: downloadStats.active > 0,
                label: Text(AppFormat.count(context, downloadStats.active)),
              ),
              onTap: () => onSelectSection(_MeSection.downloads),
            ),
          ],
        ),
        if (includeSettingsEntries)
          SettingsGroup(
            title: const Text('Parfait'),
            children: [
              SettingsTile.topLevel(
                icon: AppIcons.settings,
                title: l10n.settingsTitle,
                showChevron: false,
                onTap: () => openSettingsPage(context, settingsIndexPath),
              ),
              SettingsTile.topLevel(
                icon: settingsPageIcons[SettingsPageRef.about]!,
                title: l10n.aboutSettings,
                showChevron: false,
                onTap: () =>
                    openSettingsPage(context, SettingsPageRef.about.path),
              ),
            ],
          ),
      ],
    );
  }
}

/// Dedicated inline bookmarks feed for the wide Me workspace, avoiding nested
/// `UserPage` profile sidebars inside the detail pane.
class _MeBookmarksPane extends ConsumerStatefulWidget {
  const _MeBookmarksPane();

  @override
  ConsumerState<_MeBookmarksPane> createState() => _MeBookmarksPaneState();
}

class _MeBookmarksPaneState extends ConsumerState<_MeBookmarksPane> {
  BookmarkEntityType _kind = BookmarkEntityType.illust;
  UserRestrict _restrict = UserRestrict.public;
  String? _tag;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final userId = ref.watch(
      accountStoreProvider.select(
        (async) => async.value?.usableCurrent?.userId,
      ),
    );
    if (userId == null) {
      return Scaffold(
        appBar: AppTopBar(title: Text(l10n.profileBookmarked)),
        body: FeedEmpty(
          icon: AppIcons.heart,
          title: l10n.signedOut,
          actionLabel: l10n.login,
          onAction: () => openLogin(context),
        ),
      );
    }
    if (!_MeNetworkScope.of(context)) {
      return Scaffold(
        appBar: AppTopBar(title: Text(l10n.profileBookmarked)),
        body: const SizedBox.shrink(),
      );
    }
    final feedKey = ProfileFeedKey(
      userId: userId,
      kind: ProfileFeedKind.bookmarks,
      workType: _kind == BookmarkEntityType.novel
          ? UserWorkType.novel
          : UserWorkType.illust,
      restrict: _restrict,
      bookmarkTag: _tag,
    );
    return Scaffold(
      appBar: AppTopBar(
        title: Text(l10n.profileBookmarked),
        actions: [
          TextButton(
            onPressed: () => unawaited(
              openBookmarkTags(context, kind: _kind, restrict: _restrict),
            ),
            child: Text(l10n.bookmarkTags),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          profileFilterBar(
            kind: _kind,
            onKindChanged: (value) => setState(() {
              _kind = value;
              _tag = null;
            }),
            restrict: _restrict,
            onRestrictChanged: (value) => setState(() {
              _restrict = value;
              _tag = null;
            }),
            tag: _tag,
            onTagChanged: (value) => setState(() => _tag = value),
          ),
          Expanded(
            child: DesktopInspectableGallery(
              active: _kind == BookmarkEntityType.illust,
              child: _kind == BookmarkEntityType.novel
                  ? profileNovelFeed(feedKey)
                  : profileIllustFeed(feedKey),
            ),
          ),
        ],
      ),
    );
  }
}

/// Dedicated inline following-creators list for the wide Me workspace.
class _MeFollowingPane extends ConsumerStatefulWidget {
  const _MeFollowingPane();

  @override
  ConsumerState<_MeFollowingPane> createState() => _MeFollowingPaneState();
}

class _MeFollowingPaneState extends ConsumerState<_MeFollowingPane> {
  UserRestrict _restrict = UserRestrict.public;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final userId = ref.watch(
      accountStoreProvider.select(
        (async) => async.value?.usableCurrent?.userId,
      ),
    );
    if (userId == null) {
      return Scaffold(
        appBar: AppTopBar(title: Text(l10n.profileFollowing)),
        body: FeedEmpty(
          icon: AppIcons.users,
          title: l10n.signedOut,
          actionLabel: l10n.login,
          onAction: () => openLogin(context),
        ),
      );
    }
    if (!_MeNetworkScope.of(context)) {
      return Scaffold(
        appBar: AppTopBar(title: Text(l10n.profileFollowing)),
        body: const SizedBox.shrink(),
      );
    }
    return Scaffold(
      appBar: AppTopBar(title: Text(l10n.profileFollowing)),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          profileFilterBar(
            restrict: _restrict,
            onRestrictChanged: (value) => setState(() => _restrict = value),
          ),
          Expanded(
            child: profileUserFeed(
              ProfileFeedKey(
                userId: userId,
                kind: ProfileFeedKind.following,
                restrict: _restrict,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MeVersionSummary extends StatelessWidget {
  const _MeVersionSummary();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PackageInfo>(
      future: PackageInfo.fromPlatform(),
      builder: (context, snapshot) {
        final info = snapshot.data;
        return Text(info?.version ?? '—');
      },
    );
  }
}
