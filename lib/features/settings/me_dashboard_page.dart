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
import '../../app/layout/content_widths.dart';
import '../../app/motion/hero_transition.dart';
import '../../app/motion/motion_tokens.dart';
import '../../app/navigation/routes.dart';
import '../../app/person_avatar.dart';
import '../../app/pixiv_image.dart';
import '../../app/pull_to_refresh.dart';
import '../../app/theme/category_colors.dart';
import '../../app/theme/func_semantic_tokens.dart';
import '../../app/widgets/app_top_bar.dart';
import '../../app/widgets/edge_icon_buttons.dart';
import '../../app/widgets/entity_row.dart' show EntityBadge;
import '../../app/widgets/feed/feed_grid.dart'
    show IllustPagerAnchor, IllustPagerScope, IllustPagerSource;
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/func_bottom_nav.dart';
import '../../app/widgets/master_detail_workspace.dart';
import '../../app/widgets/person_card.dart';
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
import '../../core/profile/profile_models.dart';
import '../../core/settings/settings_controller.dart';
import '../../core/user/user_entity.dart';
import '../../core/user/user_repository.dart';
import '../../core/user/user_store.dart';
import '../../core/watchlater/watch_later_store.dart';
import '../../core/watchlist/watchlist_models.dart';
import '../../core/watchlist/watchlist_store.dart';
import '../../l10n/context.dart';
import 'pages/download_tasks_page.dart';
import 'settings_catalog.dart';
import 'settings_helpers.dart';
import 'settings_page.dart' show settingsPageIcons;

enum _MeSection {
  overview,
  bookmarks,
  following,
  watchlist,
  novelMarkers,
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

class _MeDashboardPageState extends ConsumerState<MeDashboardPage> {
  /// Preserves `_RecentHistoryState` (keep-alive covers & reorder animations)
  /// when crossing the narrow/wide breakpoint (`SET-07`).
  final _historyKey = GlobalKey();
  final _detailNavigatorKey = GlobalKey<NavigatorState>(
    debugLabel: 'me-detail',
  );
  _MeSection _selectedSection = _MeSection.overview;

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
      _MeSection.overview => _MeOverviewPane(
        historyKey: _historyKey,
        onSelectSection: _selectSection,
      ),
      _MeSection.bookmarks => const _MeBookmarksPane(),
      _MeSection.following => const _MeFollowingPane(),
      _MeSection.watchlist => const WatchlistPage(),
      _MeSection.novelMarkers => const NovelMarkersPage(),
      _MeSection.watchLater => const WatchLaterPage(),
      _MeSection.localNovels => const LocalNovelsPage(),
      _MeSection.downloads => const DownloadTasksPage(),
    };
  }

  @override
  Widget build(BuildContext context) {
    final accounts = ref.watch(accountStoreProvider);
    final desktopOwned = DesktopCommandBarScope.isActiveOf(context);
    final wide = MasterDetailWorkspace.canDisplay(context);
    return RefreshActionAnchor(
      onRefresh: () {
        ref.invalidate(_recentHistoryProvider);
        ref.invalidate(_downloadStatsProvider);
        ref.invalidate(watchLaterStoreProvider);
        ref.invalidate(localNovelStoreProvider);
        unawaited(ref.read(accountStoreProvider.notifier).reload());
      },
      child: wide
          ? _wideBody(context, accounts, desktopOwned: desktopOwned)
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
                          icon: const Icon(Icons.settings_outlined),
                          onPressed: () =>
                              openSettingsPage(context, settingsIndexPath),
                        ),
                      ],
                    ),
              body: _narrowBody(context, accounts),
            ),
    );
  }

  Widget _narrowBody(BuildContext context, AsyncValue<AccountState> accounts) {
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
          _AccountHeader(account: state?.current),
          _RecentHistory(key: _historyKey, showEmptyCard: true),
          const _MeNarrowGroups(),
          const FuncNavBarSpacer(),
        ],
      ),
    );
  }

  Widget _wideBody(
    BuildContext context,
    AsyncValue<AccountState> accounts, {
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
        ? _MeSection.overview
        : _selectedSection;
    if (effectiveSection != _selectedSection) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _selectSection(effectiveSection);
      });
    }
    return MasterDetailWorkspace(
      key: const ValueKey('me-wide-dashboard'),
      title: Text(context.l10n.homeMe),
      masterTop: _CompactAccountHeader(account: state?.current),
      masterBody: _MeWideRailGroups(
        signedIn: signedIn,
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

/// The signed-in account on a [PersonCard]: avatar, name, user ID and the
/// premium badge are the card, one button that opens the profile;
/// managing and switching accounts is a button of its own inside it.
/// Signed out, the card is one button to the login, with no manage button.
class _AccountHeader extends StatelessWidget {
  const _AccountHeader({required this.account});

  final Account? account;

  static const _avatarDiameter = 52.0;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final tokens = FuncSemanticTokens.of(context);
    final value = account;
    final url = value?.profileImageUrl;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        FuncSpacing.lg,
        FuncSpacing.sm,
        FuncSpacing.lg,
        FuncSpacing.lg,
      ),
      child: PersonCard(
        onTap: value == null ? () => openLogin(context) : () => openMe(context),
        tapHint: value == null ? null : l10n.meOpenProfile,
        endPadding: PersonCard.padding - EdgeIconButtons.glyphInset,
        trailing: value == null
            ? null
            : IconButton(
                tooltip: l10n.accountManagement,
                icon: const Icon(Icons.manage_accounts_outlined),
                onPressed: () =>
                    openSettingsPage(context, SettingsPageRef.account.path),
              ),
        child: Row(
          children: [
            SizedBox.square(
              dimension: _avatarDiameter,
              child: PersonAvatar(
                imageUrl: url == null || url.isEmpty ? null : url,
                radius: _avatarDiameter / 2,
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
    );
  }
}

/// Compact `40dp` identity card pinned below the `52dp` master header in the
/// wide [MasterDetailWorkspace] Me rail.
class _CompactAccountHeader extends StatelessWidget {
  const _CompactAccountHeader({required this.account});

  final Account? account;

  static const _avatarDiameter = 40.0;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final value = account;
    final url = value?.profileImageUrl;
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
                    imageUrl: url == null || url.isEmpty ? null : url,
                    radius: _avatarDiameter / 2,
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
                    icon: const Icon(Icons.manage_accounts_outlined),
                    onPressed: () =>
                        openSettingsPage(context, SettingsPageRef.account.path),
                  ),
              ],
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
                    Icons.history,
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
  bool _movingForward = true;
  bool _lifting = false;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (widget.entering) {
      _slide(from: -1, fade: true, forward: true, lift: false);
    }
  }

  @override
  void didUpdateWidget(_RowSlot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.order == oldWidget.order) return;
    final from = widget.from;
    if (from != null && from != 0) {
      _slide(from: from, fade: false, forward: from > 0, lift: from > 0);
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

  // Promoted cards glide forward swiftly while displaced cards yield gently,
  // avoiding a symmetric dead-center eclipse between adjacent covers.
  static const _forwardCurve = Cubic(0.2, 0, 0, 1);
  static const _backwardCurve = Cubic(0.7, 0, 0.3, 1);

  Curve get _slideCurve => _movingForward ? _forwardCurve : _backwardCurve;

  double get _offset => _start * (1 - _slideCurve.transform(_controller.value));

  void _slide({
    required int from,
    required bool fade,
    required bool forward,
    required bool lift,
  }) {
    final duration = MotionTokens.resolve(context, MotionTokens.spatial);
    if (duration == Duration.zero) return;
    final leading = Directionality.of(context) == TextDirection.ltr ? 1 : -1;
    _start = _offset + from * _stride * leading;
    _fading = fade;
    _movingForward = forward;
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
          image ??
              Icon(novel ? Icons.menu_book_outlined : Icons.image_outlined),
          if (novel)
            const Positioned(
              left: 7,
              top: 7,
              child: EntityBadge(icon: Icons.menu_book_outlined),
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

String _downloadSummary(BuildContext context, _DownloadStats stats) {
  final l10n = context.l10n;
  if (stats.total == 0) return l10n.downloadTasksEmpty;
  final totalLabel = l10n.labelValue(
    l10n.downloadGroupTasks,
    AppFormat.count(context, stats.total),
  );
  if (stats.active == 0) return totalLabel;
  final activeLabel = l10n.labelValue(
    l10n.downloadRunning,
    AppFormat.count(context, stats.active),
  );
  return _joinSubtitleParts([activeLabel, totalLabel]) ?? totalLabel;
}

String _watchLaterSummary(BuildContext context, int? count) {
  final l10n = context.l10n;
  if (count == null || count == 0) return l10n.watchLaterEmpty;
  return l10n.seriesWorksCount(count);
}

String _localNovelsSummary(BuildContext context, int? count) {
  final l10n = context.l10n;
  if (count == null || count == 0) return l10n.localNovelsEmpty;
  return l10n.seriesWorksCount(count);
}

/// Narrow/single-column Me dashboard groups (`SET-01`, `SET-08`): every group is
/// titled and every row carries a real double-line summary using `SettingsGroup`
/// and [SettingsTile.topLevel].
class _MeNarrowGroups extends ConsumerWidget {
  const _MeNarrowGroups();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final blueTone = categoryTone(scheme, CategoryHue.blue);
    final orangeTone = categoryTone(scheme, CategoryHue.orange);
    final greenTone = categoryTone(scheme, CategoryHue.green);
    final neutralTone = neutralCategoryTone(scheme);
    final downloadStats =
        ref.watch(_downloadStatsProvider).value ?? (active: 0, total: 0);
    final watchLaterCount = ref.watch(watchLaterStoreProvider).value?.length;
    final localNovelsCount = ref.watch(localNovelStoreProvider).value?.length;
    final appSettings = ref.watch(settingsProvider).value;
    final offBar = ref.watch(homeArrangementProvider).hidden;
    final signedIn = ref.watch(
      accountStoreProvider.select(
        (async) => async.value?.usableCurrent != null,
      ),
    );
    final settingsSubtitle = appSettings == null
        ? l10n.settingsBrowseHint
        : _joinSubtitleParts([
                themeModeLabel(context, appSettings.themeCode),
                languageDisplayName(appSettings.languageTag),
              ]) ??
              l10n.settingsBrowseHint;
    final bookmarksSubtitle = _joinSubtitleParts([
      l10n.profileIllust,
      l10n.profileNovel,
    ]);
    final followingSubtitle = _joinSubtitleParts([
      l10n.restrictPublic,
      l10n.restrictPrivate,
    ]);
    final watchlistSubtitle = _joinSubtitleParts([
      l10n.watchlistManga,
      l10n.watchlistNovel,
    ]);
    final novelMarkersSubtitle = _joinSubtitleParts([
      l10n.novelReadingProgress,
      l10n.novelMarker,
    ]);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsGroup(
          title: Text(l10n.settingsGroupLibrary),
          children: [
            SettingsTile.topLevel(
              icon: Icons.favorite_border,
              title: l10n.profileBookmarked,
              subtitle: bookmarksSubtitle == null
                  ? null
                  : Text(bookmarksSubtitle),
              tone: blueTone,
              onTap: () => unawaited(openMe(context, tab: MeTab.bookmarks)),
            ),
            SettingsTile.topLevel(
              icon: Icons.people_outline,
              title: l10n.profileFollowing,
              subtitle: followingSubtitle == null
                  ? null
                  : Text(followingSubtitle),
              tone: blueTone,
              onTap: () => unawaited(openMe(context, tab: MeTab.following)),
            ),
            SettingsTile.topLevel(
              icon: Icons.library_books_outlined,
              title: l10n.watchlistTitle,
              subtitle: watchlistSubtitle == null
                  ? null
                  : Text(watchlistSubtitle),
              tone: blueTone,
              onTap: () => unawaited(openWatchlist(context)),
            ),
            // Pixiv keeps novel markers with the signed-in account.
            if (signedIn)
              SettingsTile.topLevel(
                icon: Icons.bookmarks_outlined,
                title: l10n.novelMarkers,
                subtitle: novelMarkersSubtitle == null
                    ? null
                    : Text(novelMarkersSubtitle),
                tone: blueTone,
                onTap: () => unawaited(openNovelMarkers(context)),
              ),
            for (final destination in HomeDestination.values)
              if (offBar.contains(destination))
                SettingsTile.topLevel(
                  icon: homeDestinationIcon(destination),
                  title: homeDestinationLabel(context, destination),
                  tone: blueTone,
                  onTap: () => openHomeDestination(context, destination),
                ),
          ],
        ),
        SettingsGroup(
          title: Text(l10n.settingsGroupData),
          children: [
            SettingsTile.topLevel(
              icon: Icons.bookmark_border,
              title: l10n.watchLaterTitle,
              subtitle: Text(_watchLaterSummary(context, watchLaterCount)),
              tone: orangeTone,
              onTap: () => unawaited(openWatchLater(context)),
            ),
            SettingsTile.topLevel(
              icon: Icons.auto_stories_outlined,
              title: l10n.localNovelsTitle,
              subtitle: Text(_localNovelsSummary(context, localNovelsCount)),
              tone: orangeTone,
              onTap: () => unawaited(openLocalNovels(context)),
            ),
            SettingsTile.topLevel(
              icon: Icons.downloading_outlined,
              title: l10n.downloaderSettings,
              subtitle: Text(_downloadSummary(context, downloadStats)),
              tone: greenTone,
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
              icon: Icons.settings_outlined,
              title: l10n.settingsTitle,
              subtitle: Text(settingsSubtitle),
              tone: neutralTone,
              onTap: () => openSettingsPage(context, settingsIndexPath),
            ),
            SettingsTile.topLevel(
              icon: settingsPageIcons[SettingsPageRef.about]!,
              title: l10n.aboutSettings,
              subtitle: const _MeVersionSummary(),
              tone: neutralTone,
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
/// `showChevron: false`). Touch tablets keep Settings/About here because their
/// outer `ShellRail` does not render desktop bottom Settings controls.
class _MeWideRailGroups extends ConsumerWidget {
  const _MeWideRailGroups({
    required this.signedIn,
    required this.selected,
    required this.includeSettingsEntries,
    required this.onSelectSection,
  });

  final bool signedIn;
  final _MeSection selected;
  final bool includeSettingsEntries;
  final ValueChanged<_MeSection> onSelectSection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final blueTone = categoryTone(scheme, CategoryHue.blue);
    final orangeTone = categoryTone(scheme, CategoryHue.orange);
    final greenTone = categoryTone(scheme, CategoryHue.green);
    final neutralTone = neutralCategoryTone(scheme);
    final downloadStats =
        ref.watch(_downloadStatsProvider).value ?? (active: 0, total: 0);
    final offBar = ref.watch(homeArrangementProvider).hidden;

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
              icon: Icons.person_outline,
              title: l10n.accountProfile,
              tone: blueTone,
              selected: selected == _MeSection.overview,
              showChevron: false,
              onTap: () => onSelectSection(_MeSection.overview),
            ),
            SettingsTile.topLevel(
              icon: Icons.favorite_border,
              title: l10n.profileBookmarked,
              tone: blueTone,
              selected: selected == _MeSection.bookmarks,
              showChevron: false,
              onTap: () => onSelectSection(_MeSection.bookmarks),
            ),
            SettingsTile.topLevel(
              icon: Icons.people_outline,
              title: l10n.profileFollowing,
              tone: blueTone,
              selected: selected == _MeSection.following,
              showChevron: false,
              onTap: () => onSelectSection(_MeSection.following),
            ),
            SettingsTile.topLevel(
              icon: Icons.library_books_outlined,
              title: l10n.watchlistTitle,
              tone: blueTone,
              selected: selected == _MeSection.watchlist,
              showChevron: false,
              onTap: () => onSelectSection(_MeSection.watchlist),
            ),
            if (signedIn)
              SettingsTile.topLevel(
                icon: Icons.bookmarks_outlined,
                title: l10n.novelMarkers,
                tone: blueTone,
                selected: selected == _MeSection.novelMarkers,
                showChevron: false,
                onTap: () => onSelectSection(_MeSection.novelMarkers),
              ),
            for (final destination in HomeDestination.values)
              if (offBar.contains(destination))
                SettingsTile.topLevel(
                  icon: homeDestinationIcon(destination),
                  title: homeDestinationLabel(context, destination),
                  tone: blueTone,
                  showChevron: false,
                  onTap: () => openHomeDestination(context, destination),
                ),
          ],
        ),
        SettingsGroup(
          title: Text(l10n.settingsGroupData),
          children: [
            SettingsTile.topLevel(
              icon: Icons.bookmark_border,
              title: l10n.watchLaterTitle,
              tone: orangeTone,
              selected: selected == _MeSection.watchLater,
              showChevron: false,
              onTap: () => onSelectSection(_MeSection.watchLater),
            ),
            SettingsTile.topLevel(
              icon: Icons.auto_stories_outlined,
              title: l10n.localNovelsTitle,
              tone: orangeTone,
              selected: selected == _MeSection.localNovels,
              showChevron: false,
              onTap: () => onSelectSection(_MeSection.localNovels),
            ),
            SettingsTile.topLevel(
              icon: Icons.downloading_outlined,
              title: l10n.downloaderSettings,
              tone: greenTone,
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
                icon: Icons.settings_outlined,
                title: l10n.settingsTitle,
                tone: neutralTone,
                showChevron: false,
                onTap: () => openSettingsPage(context, settingsIndexPath),
              ),
              SettingsTile.topLevel(
                icon: settingsPageIcons[SettingsPageRef.about]!,
                title: l10n.aboutSettings,
                tone: neutralTone,
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

/// Default right pane on wide Me workspaces: profile overview header, recent
/// browsing history, and a 2-column collection summary grid.
class _MeOverviewPane extends ConsumerWidget {
  const _MeOverviewPane({
    required this.historyKey,
    required this.onSelectSection,
  });

  final GlobalKey historyKey;
  final ValueChanged<_MeSection> onSelectSection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final account = ref.watch(accountStoreProvider).value?.current;
    final userDetail = account == null
        ? null
        : ref.watch(userStoreProvider.select((users) => users[account.userId]));
    final watchlistEntries = ref.watch(watchlistStoreProvider);
    final watchLaterCount = ref.watch(watchLaterStoreProvider).value?.length;

    return Scaffold(
      appBar: AppTopBar(
        contentWidth: SettingsDetailScope.maybeOf(context) != null
            ? 780
            : ContentWidths.settings,
        title: Text(l10n.accountProfile),
        actions: [
          TextButton.icon(
            onPressed: account == null
                ? () => openLogin(context)
                : () => openMe(context),
            icon: const Icon(Icons.open_in_new, size: 18),
            label: Text(account == null ? l10n.login : l10n.meOpenProfile),
          ),
        ],
      ),
      body: settingsNarrowBody(
        ListView(
          padding: const EdgeInsets.only(
            top: FuncSpacing.md,
            bottom: FuncSpacing.xl,
          ),
          children: [
            _MeProfileOverview(account: account),
            _RecentHistory(key: historyKey, showEmptyCard: true),
            _MeCollectionGrid(
              account: account,
              userDetail: userDetail,
              watchlistEntries: watchlistEntries,
              watchLaterCount: watchLaterCount,
              onSelectSection: onSelectSection,
            ),
          ],
        ),
      ),
    );
  }
}

class _MeProfileOverview extends StatelessWidget {
  const _MeProfileOverview({required this.account});

  final Account? account;

  static const _avatarDiameter = 56.0;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final tokens = FuncSemanticTokens.of(context);
    final value = account;
    final url = value?.profileImageUrl;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        FuncSpacing.lg,
        0,
        FuncSpacing.lg,
        FuncSpacing.xl,
      ),
      child: SettingsCard(
        child: Semantics(
          onTapHint: value == null ? null : l10n.meOpenProfile,
          child: InkWell(
            onTap: value == null
                ? () => openLogin(context)
                : () => openMe(context),
            child: Padding(
              padding: const EdgeInsets.all(FuncSpacing.lg),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final compact =
                      constraints.maxWidth < 520 ||
                      MediaQuery.textScalerOf(context).scale(1) > 1.15;
                  final identity = Row(
                    children: [
                      SizedBox.square(
                        dimension: _avatarDiameter,
                        child: PersonAvatar(
                          imageUrl: url == null || url.isEmpty ? null : url,
                          radius: _avatarDiameter / 2,
                        ),
                      ),
                      const SizedBox(width: FuncSpacing.lg),
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
                                  ? l10n.loginTitle
                                  : l10n.labelValue(
                                      l10n.profileId,
                                      '${value.userId}',
                                    ),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                            if (value?.authState ==
                                AccountAuthState.reauthRequired) ...[
                              const SizedBox(height: FuncSpacing.xxs),
                              Text(
                                l10n.reauthRequired,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: colors.error,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  );
                  final action = value == null
                      ? FilledButton.icon(
                          onPressed: () => openLogin(context),
                          icon: const Icon(Icons.login_outlined, size: 18),
                          label: Text(l10n.login),
                        )
                      : OutlinedButton.icon(
                          onPressed: () => openSettingsPage(
                            context,
                            SettingsPageRef.account.path,
                          ),
                          icon: const Icon(
                            Icons.manage_accounts_outlined,
                            size: 18,
                          ),
                          label: Text(l10n.accountManagement),
                        );
                  if (compact) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        identity,
                        const SizedBox(height: FuncSpacing.md),
                        Align(
                          alignment: AlignmentDirectional.centerEnd,
                          child: action,
                        ),
                      ],
                    );
                  }
                  return Row(
                    children: [
                      Expanded(child: identity),
                      const SizedBox(width: FuncSpacing.md),
                      action,
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MeCollectionGrid extends StatelessWidget {
  const _MeCollectionGrid({
    required this.account,
    required this.userDetail,
    required this.watchlistEntries,
    required this.watchLaterCount,
    required this.onSelectSection,
  });

  final Account? account;
  final UserEntity? userDetail;
  final Map<WatchlistKey, WatchlistEntry> watchlistEntries;
  final int? watchLaterCount;
  final ValueChanged<_MeSection> onSelectSection;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final blueTone = categoryTone(scheme, CategoryHue.blue);
    final orangeTone = categoryTone(scheme, CategoryHue.orange);
    final detail = userDetail != null && userDetail!.hasDetail
        ? userDetail
        : null;
    final bookmarksValue = account != null && detail != null
        ? AppFormat.count(context, detail.totalIllustBookmarksPublic)
        : '—';
    final followingValue = account != null && detail != null
        ? AppFormat.count(context, detail.totalFollowUsers)
        : '—';
    final watchlistValue = watchlistEntries.isNotEmpty
        ? AppFormat.count(
            context,
            watchlistEntries.values.where((e) => e.shown).length,
          )
        : '—';
    final watchLaterValue = watchLaterCount == null
        ? '—'
        : AppFormat.count(context, watchLaterCount!);

    final items = [
      (
        icon: Icons.favorite_border,
        tone: blueTone,
        title: l10n.profileBookmarked,
        count: bookmarksValue,
        subtitle:
            _joinSubtitleParts([l10n.profileIllust, l10n.profileNovel]) ??
            l10n.profileBookmarked,
        section: _MeSection.bookmarks,
      ),
      (
        icon: Icons.people_outline,
        tone: blueTone,
        title: l10n.profileFollowing,
        count: followingValue,
        subtitle:
            _joinSubtitleParts([l10n.restrictPublic, l10n.restrictPrivate]) ??
            l10n.profileFollowing,
        section: _MeSection.following,
      ),
      (
        icon: Icons.library_books_outlined,
        tone: blueTone,
        title: l10n.watchlistTitle,
        count: watchlistValue,
        subtitle:
            _joinSubtitleParts([l10n.watchlistManga, l10n.watchlistNovel]) ??
            l10n.watchlistTitle,
        section: _MeSection.watchlist,
      ),
      (
        icon: Icons.bookmark_border,
        tone: orangeTone,
        title: l10n.watchLaterTitle,
        count: watchLaterValue,
        subtitle: _watchLaterSummary(context, watchLaterCount),
        section: _MeSection.watchLater,
      ),
    ];

    Widget buildTile(int index) {
      final item = items[index];
      return _MeCollectionTile(
        icon: item.icon,
        tone: item.tone,
        title: item.title,
        count: item.count,
        subtitle: item.subtitle,
        onTap: () => onSelectSection(item.section),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        FuncSpacing.lg,
        0,
        FuncSpacing.lg,
        FuncSpacing.xl,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              FuncSpacing.lg,
              0,
              FuncSpacing.lg,
              FuncSpacing.sm,
            ),
            child: DefaultTextStyle.merge(
              style: theme.textTheme.titleSmall?.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
              child: Semantics(
                header: true,
                child: Text(l10n.settingsGroupLibrary),
              ),
            ),
          ),
          LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth < 420) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < items.length; i++) ...[
                      if (i > 0) const SizedBox(height: FuncSpacing.sm),
                      buildTile(i),
                    ],
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(child: buildTile(0)),
                        const SizedBox(width: FuncSpacing.sm),
                        Expanded(child: buildTile(1)),
                      ],
                    ),
                  ),
                  const SizedBox(height: FuncSpacing.sm),
                  IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(child: buildTile(2)),
                        const SizedBox(width: FuncSpacing.sm),
                        Expanded(child: buildTile(3)),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _MeCollectionTile extends StatelessWidget {
  const _MeCollectionTile({
    required this.icon,
    required this.tone,
    required this.title,
    required this.count,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final CategoryTone tone;
  final String title;
  final String count;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tokens = FuncSemanticTokens.of(context);
    return SettingsCard(
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(FuncSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  SizedBox.square(
                    dimension: SettingsTile.iconDiameter,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: tone.fill,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(icon, color: tone.ink),
                    ),
                  ),
                  const Spacer(),
                  Text(
                    count,
                    style: tokens.display
                        .copyWith(fontWeight: FontWeight.w700)
                        .tabular,
                  ),
                  const SizedBox(width: FuncSpacing.xs),
                  Icon(
                    Icons.chevron_right,
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  ),
                ],
              ),
              const SizedBox(height: FuncSpacing.md),
              Text(
                title,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: FuncSpacing.xxs),
              Text(
                subtitle,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
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
          icon: Icons.favorite_border,
          title: l10n.signedOut,
          actionLabel: l10n.login,
          onAction: () => openLogin(context),
        ),
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
          icon: Icons.people_outline,
          title: l10n.signedOut,
          actionLabel: l10n.login,
          onAction: () => openLogin(context),
        ),
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
