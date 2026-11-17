import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
import '../../core/user/user_repository.dart';
import '../../core/watchlater/watch_later_store.dart';
import '../../l10n/context.dart';
import '../localnovel/local_novels_page.dart';
import '../novel/novel_markers_page.dart';
import '../profile/profile_filter_bar.dart';
import '../profile/profile_illust_feed.dart';
import '../profile/profile_novel_feed.dart';
import '../profile/profile_user_feed.dart';
import '../watchlater/watchlater_page.dart';
import '../watchlist/watchlist_page.dart';
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
          _RecentHistory(key: _historyKey),
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
      detail: HeroControllerScope.none(
        child: Navigator(
          key: _detailNavigatorKey,
          onGenerateInitialRoutes: (_, _) => [
            _buildDetailRoute(effectiveSection, instant: true),
          ],
          onGenerateRoute: (_) => _buildDetailRoute(effectiveSection),
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
/// Nothing while the history is empty.
class _RecentHistory extends ConsumerStatefulWidget {
  const _RecentHistory({super.key});

  static const _count = 8;
  static const _cover = 88.0;
  static const _gap = FuncSpacing.sm;

  /// The row's own Hero scope (TRANS-07): the same work may sit on a feed
  /// still mounted in another branch.
  static const _heroScope = 'me-history';

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
    final route = ModalRoute.of(context);
    final navigator = Navigator.maybeOf(context);
    final shell = navigator == null ? null : ModalRoute.of(navigator.context);
    final covers = [
      ?route?.secondaryAnimation,
      if (!identical(shell, route)) ?shell?.secondaryAnimation,
    ];
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
    if (shown.isEmpty) return const SizedBox.shrink();
    final store = ref.watch(illustStoreProvider);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: FuncSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            // A group heading's inset: the group's and the title's own.
            padding: const EdgeInsets.fromLTRB(
              FuncSpacing.lg + FuncSpacing.lg,
              0,
              FuncSpacing.lg,
              FuncSpacing.xs,
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
            height: _RecentHistory._cover,
            child: IllustPagerScope(
              source: _pager,
              // Eight covers at most: built all at once, keyed by work, so
              // each keeps its state as the order changes.
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: FuncSpacing.lg),
                child: Row(
                  children: [
                    for (final (index, record) in shown.indexed) ...[
                      if (index > 0) const SizedBox(width: _RecentHistory._gap),
                      _RowSlot(
                        key: ValueKey(_keyOf(record)),
                        order: _order,
                        from: _from[_keyOf(record)],
                        entering: _joined.contains(_keyOf(record)),
                        child: _rowCover(store, record),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A cover's place on the row. When the row takes a new order, a cover
/// that moved slides from where it was to its new place; one new to the row
/// slides in from the leading edge and fades in. A new order arriving
/// mid-slide carries on from where the cover is. Reduced motion moves it at
/// once.
class _RowSlot extends StatefulWidget {
  const _RowSlot({
    super.key,
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

  late final _controller = AnimationController(vsync: this, value: 1);

  /// The slide's start, in logical pixels from the cover's place.
  double _start = 0;
  bool _fading = false;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (widget.entering) _slide(from: -1, fade: true);
  }

  @override
  void didUpdateWidget(_RowSlot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.order == oldWidget.order) return;
    final from = widget.from;
    if (from != null && from != 0) _slide(from: from, fade: false);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  double get _offset =>
      _start * (1 - MotionTokens.spatialCurve.transform(_controller.value));

  void _slide({required int from, required bool fade}) {
    final duration = MotionTokens.resolve(context, MotionTokens.spatial);
    if (duration == Duration.zero) return;
    final leading = Directionality.of(context) == TextDirection.ltr ? 1 : -1;
    _start = _offset + from * _stride * leading;
    _fading = fade;
    _controller
      ..duration = duration
      ..forward(from: 0);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
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
    return Semantics(
      container: true,
      button: true,
      label: record.snapshot.title,
      onTap: onTap,
      excludeSemantics: true,
      child: SizedBox.square(
        dimension: _size,
        child: Material(
          color: Theme.of(context).colorScheme.surfaceContainer,
          shape: const RoundedRectangleBorder(borderRadius: FuncShape.card),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Stack(
              fit: StackFit.expand,
              children: [
                image ??
                    Icon(
                      novel ? Icons.menu_book_outlined : Icons.image_outlined,
                    ),
                if (novel)
                  const Positioned(
                    left: 7,
                    top: 7,
                    child: EntityBadge(icon: Icons.menu_book_outlined),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
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
  return '$activeLabel · $totalLabel';
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
        : '${themeModeLabel(context, appSettings.themeCode)} · '
              '${languageDisplayName(appSettings.languageTag)}';

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
              subtitle: Text(
                '${l10n.profileIllust} · ${l10n.profileNovel} · '
                '${l10n.bookmarkTags}',
              ),
              tone: blueTone,
              onTap: () => unawaited(openMe(context, tab: MeTab.bookmarks)),
            ),
            SettingsTile.topLevel(
              icon: Icons.people_outline,
              title: l10n.profileFollowing,
              subtitle: Text(
                '${l10n.restrictPublic} · ${l10n.restrictPrivate}',
              ),
              tone: blueTone,
              onTap: () => unawaited(openMe(context, tab: MeTab.following)),
            ),
            SettingsTile.topLevel(
              icon: Icons.library_books_outlined,
              title: l10n.watchlistTitle,
              subtitle: Text('${l10n.watchlistManga} · ${l10n.watchlistNovel}'),
              tone: blueTone,
              onTap: () => unawaited(openWatchlist(context)),
            ),
            // Pixiv keeps novel markers with the signed-in account.
            if (signedIn)
              SettingsTile.topLevel(
                icon: Icons.bookmarks_outlined,
                title: l10n.novelMarkers,
                subtitle: Text(
                  '${l10n.novelReadingProgress} · ${l10n.novelMarker}',
                ),
                tone: blueTone,
                onTap: () => unawaited(openNovelMarkers(context)),
              ),
            for (final destination in HomeDestination.values)
              if (offBar.contains(destination))
                SettingsTile.topLevel(
                  icon: homeDestinationIcon(destination),
                  title: homeDestinationLabel(context, destination),
                  subtitle: Text(l10n.navigationSettings),
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

/// Default right pane on wide Me workspaces: recent browsing history plus
/// live local library & download overview cards.
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
    final scheme = Theme.of(context).colorScheme;
    final orangeTone = categoryTone(scheme, CategoryHue.orange);
    final greenTone = categoryTone(scheme, CategoryHue.green);
    final account = ref.watch(accountStoreProvider).value?.current;
    final watchLaterCount = ref.watch(watchLaterStoreProvider).value?.length;
    final localNovelsCount = ref.watch(localNovelStoreProvider).value?.length;
    final downloadStats =
        ref.watch(_downloadStatsProvider).value ?? (active: 0, total: 0);

    return Scaffold(
      appBar: AppTopBar(
        contentWidth: 780,
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
            _RecentHistory(key: historyKey),
            SettingsGroup(
              title: Text(l10n.settingsGroupData),
              children: [
                SettingsTile.topLevel(
                  icon: Icons.bookmark_border,
                  title: l10n.watchLaterTitle,
                  subtitle: Text(_watchLaterSummary(context, watchLaterCount)),
                  tone: orangeTone,
                  onTap: () => onSelectSection(_MeSection.watchLater),
                ),
                SettingsTile.topLevel(
                  icon: Icons.auto_stories_outlined,
                  title: l10n.localNovelsTitle,
                  subtitle: Text(
                    _localNovelsSummary(context, localNovelsCount),
                  ),
                  tone: orangeTone,
                  onTap: () => onSelectSection(_MeSection.localNovels),
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
                  onTap: () => onSelectSection(_MeSection.downloads),
                ),
              ],
            ),
          ],
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
          ProfileFilterBar(
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
                  ? ProfileNovelFeed(feedKey: feedKey)
                  : ProfileIllustFeed(feedKey: feedKey),
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
          ProfileFilterBar(
            restrict: _restrict,
            onRestrictChanged: (value) => setState(() => _restrict = value),
          ),
          Expanded(
            child: ProfileUserFeed(
              feedKey: ProfileFeedKey(
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
