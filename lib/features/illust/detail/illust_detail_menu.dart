import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/format/app_format.dart';
import '../../../app/icons/app_icons.dart';
import '../../../app/icons/ui_icons.dart';
import '../../../app/layout/content_widths.dart';
import '../../../app/layout/sliver_width_builder.dart';
import '../../../app/motion/swipe_paging.dart';
import '../../../app/navigation/route_facade.dart';
import '../../../app/theme/func_semantic_tokens.dart';
import '../../../app/widgets/app_menu_button.dart';
import '../../../app/widgets/author_summary.dart';
import '../../../app/widgets/bookmark_switch_button.dart'
    show BookmarkSwitchButton, showBookmarkEditSheet;
import '../../../app/widgets/card_actions/card_action.dart';
import '../../../app/widgets/card_actions/illust_card_actions.dart';
import '../../../app/widgets/follow_switch_button.dart';
import '../../../core/auth/account_store.dart';
import '../../../core/bookmark/bookmark_models.dart';
import '../../../core/bookmark/bookmark_store.dart';
import '../../../core/entity/illust_entity.dart';
import '../../../core/platform/image_clipboard.dart';
import '../../../l10n/context.dart';
import '../illust_actions.dart';
import 'widgets/detail_action_bar.dart';
import 'widgets/info_block.dart';

/// The detail page's own ⋮ actions: share, the bookmark sheet (the heart's
/// long-press), the page-selection entry (multi-page works only), and the
/// artwork-info jump.
enum DetailMenuAction { share, editBookmark, selectPages, info }

/// Typed union of entries shown in [DetailMoreMenu], replacing an untyped
/// `List<Object>` with exhaustively checked pattern matching.
sealed class DetailMenuItem {
  const DetailMenuItem();
}

final class DetailOwnMenuItem extends DetailMenuItem {
  const DetailOwnMenuItem(this.action);

  final DetailMenuAction action;
}

final class DetailCardMenuItem extends DetailMenuItem {
  const DetailCardMenuItem(this.action);

  final CardAction action;
}

/// The ⋮ menu holding the less-frequent detail actions. Every entry carries
/// an icon plus its localized text label — nothing here depends on a
/// long-press to be discoverable (R3).
class DetailMoreMenu extends ConsumerWidget {
  const DetailMoreMenu({
    super.key,
    required this.entity,
    required this.items,
    required this.onSelected,
  });

  final IllustEntity entity;
  final List<DetailMenuItem> items;
  final void Function(BuildContext buttonContext, DetailMenuAction action)
  onSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final container = ProviderScope.containerOf(context);
    final cardState = CardActionState.ofRef(ref);
    final (bookmarked: bookmarked, unsettled: bookmarkUnsettled) = ref.watch(
      bookmarkStoreProvider.select((store) {
        final entry = store[BookmarkKey(BookmarkEntityType.illust, entity.id)];
        return (
          bookmarked: entry?.shown ?? false,
          unsettled: entry?.isUnsettled ?? false,
        );
      }),
    );
    AppMenuEntry<DetailMenuItem> entryOf(DetailMenuItem item) => switch (item) {
      DetailOwnMenuItem(action: DetailMenuAction.share) => AppMenuEntry(
        value: item,
        icon: AppIcons.share,
        label: l10n.cardActionShare,
      ),
      DetailOwnMenuItem(action: DetailMenuAction.editBookmark) => AppMenuEntry(
        value: item,
        icon: AppIcons.heart,
        label: bookmarked ? l10n.bookmarkEditTitle : l10n.bookmarkIllust,
        enabled: !bookmarkUnsettled,
      ),
      DetailOwnMenuItem(action: DetailMenuAction.selectPages) => AppMenuEntry(
        value: item,
        icon: UiIcons.checklist,
        label: l10n.downloadSelectPages,
      ),
      DetailOwnMenuItem(action: DetailMenuAction.info) => AppMenuEntry(
        value: item,
        icon: AppIcons.info,
        label: l10n.illustInfoJump,
      ),
      DetailCardMenuItem(:final action) => AppMenuEntry(
        value: item,
        icon: action.iconFor(cardState, entity),
        label: action.labelFor(cardState, entity, l10n),
      ),
    };
    return AppMenuButton<DetailMenuItem>(
      onSelected: (buttonContext, item) => switch (item) {
        DetailOwnMenuItem(:final action) => onSelected(buttonContext, action),
        DetailCardMenuItem(:final action) => unawaited(
          action.run(context, container, entity),
        ),
      },
      entries: [for (final item in items) entryOf(item)],
    );
  }
}

/// Centres a section's sliver at the article text width when the scroll is
/// wider than it.
class DetailArticleTextWidth extends StatelessWidget {
  const DetailArticleTextWidth({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => SliverWidthBuilder(
    builder: (context, width) {
      final inset = (width - ContentWidths.article) / 2;
      return SliverPadding(
        padding: EdgeInsets.symmetric(horizontal: inset > 0 ? inset : 0),
        sliver: child,
      );
    },
  );
}

/// Under the first image of a collapsed illustration set: shows the rest.
/// Once expanded it follows the last page and folds the set back.
class DetailPagesToggleButton extends StatelessWidget {
  const DetailPagesToggleButton({
    super.key,
    required this.count,
    required this.expanded,
    required this.onPressed,
  });

  final int count;
  final bool expanded;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return MergeSemantics(
      child: Semantics(
        expanded: expanded,
        child: TextButton.icon(
          key: Key(expanded ? 'illust-collapse-pages' : 'illust-expand-pages'),
          style: TextButton.styleFrom(
            minimumSize: const Size.fromHeight(kMinInteractiveDimension),
          ),
          onPressed: onPressed,
          icon: Icon(expanded ? UiIcons.expandLess : UiIcons.expandMore),
          iconAlignment: IconAlignment.end,
          label: Text(
            expanded
                ? context.l10n.detailCollapsePages
                : context.l10n.detailExpandPages(count),
          ),
        ),
      ),
    );
  }
}

/// Hosts a local [SelectionArea] when `IllustDetailPage` is opened outside
/// `IllustDetailPagerPage`; when paged, the pager owns the single outer
/// [SelectionArea] outside its horizontal `PageView` so horizontal swipes beat
/// selection drags in the gesture arena.
class DetailSelectionScope extends StatelessWidget {
  const DetailSelectionScope({
    super.key,
    required this.child,
    this.forceSelectionArea = false,
  });

  final Widget child;
  final bool forceSelectionArea;

  @override
  Widget build(BuildContext context) =>
      !forceSelectionArea && SwipePagerScope.maybeOf(context) != null
      ? child
      : SelectionArea(child: child);
}

/// Two-pane secondary inspector header: author card + compact action row.
class DetailInspectorHeader extends StatelessWidget {
  const DetailInspectorHeader({
    super.key,
    required this.entity,
    required this.moreMenu,
  });

  final IllustEntity entity;
  final Widget moreMenu;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        FuncSpacing.lg,
        FuncSpacing.md,
        FuncSpacing.lg,
        FuncSpacing.sm,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DetailAuthorCard(entity: entity),
          const SizedBox(height: FuncSpacing.sm),
          DetailInspectorActionRow(
            key: const ValueKey('detail-inspector-action-bar'),
            entity: entity,
            moreMenu: moreMenu,
          ),
        ],
      ),
    );
  }
}

/// Embedded desktop side-inspector header: author row, follow, expand, close,
/// and compact action row.
class DetailEmbeddedInspectorHeader extends ConsumerWidget {
  const DetailEmbeddedInspectorHeader({
    super.key,
    required this.entity,
    required this.moreMenu,
    this.onOpenFullStage,
    this.onCloseInspector,
  });

  final IllustEntity entity;
  final Widget moreMenu;
  final ValueChanged<IllustEntity>? onOpenFullStage;
  final VoidCallback? onCloseInspector;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final colors = Theme.of(context).colorScheme;
    final ownUserId = ref.watch(
      accountStoreProvider.select(
        (async) => async.value?.usableCurrent?.userId,
      ),
    );
    final author = entity.user;
    final handle = author.account.trim();
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        FuncSpacing.lg,
        FuncSpacing.sm,
        FuncSpacing.sm,
        FuncSpacing.sm,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Semantics(
                  hint: l10n.openAuthorProfile,
                  child: AuthorSummary(
                    key: const Key('illust-author-row'),
                    name: author.name,
                    account: handle.isEmpty ? null : '@$handle',
                    imageUrl: author.profileImageUrl,
                    avatarRadius: 18,
                    avatarRingColor: colors.primary.withValues(alpha: 0.45),
                    padding: const EdgeInsets.symmetric(
                      horizontal: FuncSpacing.xs,
                      vertical: FuncSpacing.xxs,
                    ),
                    onTap: () => openUser(context, author.id),
                  ),
                ),
              ),
              if (author.id != ownUserId) ...[
                const SizedBox(width: FuncSpacing.xs),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 112),
                  child: FollowSwitchButton(
                    userId: author.id,
                    userName: author.name,
                    userAccount: author.account,
                    compact: true,
                  ),
                ),
              ],
              if (onOpenFullStage != null)
                IconButton(
                  key: const ValueKey('desktop-inspector-expand'),
                  tooltip: l10n.viewerOpenDetail,
                  icon: const Icon(AppIcons.expand, size: 18),
                  onPressed: () => onOpenFullStage!(entity),
                ),
              if (onCloseInspector != null)
                IconButton(
                  key: const ValueKey('desktop-inspector-close'),
                  tooltip: l10n.profileShareClose,
                  icon: const Icon(UiIcons.close, size: 19),
                  onPressed: onCloseInspector,
                ),
            ],
          ),
          const SizedBox(height: FuncSpacing.xs),
          Padding(
            padding: const EdgeInsets.only(right: FuncSpacing.sm),
            child: DetailInspectorActionRow(
              key: const ValueKey('desktop-inspector-action-bar'),
              entity: entity,
              moreMenu: moreMenu,
            ),
          ),
        ],
      ),
    );
  }
}

class DetailInspectorActionRow extends ConsumerWidget {
  const DetailInspectorActionRow({
    super.key,
    required this.entity,
    required this.moreMenu,
  });

  final IllustEntity entity;
  final Widget moreMenu;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).colorScheme;
    final tokens = FuncSemanticTokens.of(context);
    return Row(
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            color: tokens.brandTint,
            borderRadius: FuncShape.pill,
            border: Border.all(color: tokens.brandTintStroke),
          ),
          child: Padding(
            padding: const EdgeInsets.only(
              left: FuncSpacing.xs,
              right: FuncSpacing.md,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                BookmarkSwitchButton(illustId: entity.id, title: entity.title),
                Text(
                  AppFormat.count(context, entity.totalBookmarks),
                  style: tokens.numeric.copyWith(
                    fontWeight: FontWeight.w600,
                    color: colors.primary,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: FuncSpacing.sm),
        DecoratedBox(
          decoration: BoxDecoration(
            color: colors.surfaceContainerLow,
            borderRadius: FuncShape.pill,
            border: Border.all(color: tokens.brandHairline),
          ),
          child: DetailDownloadButton(
            entity: entity,
            onPressed: () =>
                unawaited(downloadAllIllustPages(context, ref, entity)),
          ),
        ),
        const Spacer(),
        Builder(
          builder: (buttonContext) => IconButton(
            tooltip: context.l10n.cardActionShare,
            icon: const Icon(AppIcons.share),
            onPressed: () => unawaited(shareIllust(buttonContext, ref, entity)),
          ),
        ),
        moreMenu,
      ],
    );
  }
}

/// Builds the detail ⋮ menu with typed [DetailMenuItem] entries and standard
/// handlers for share, bookmark editing, page selection, and artwork-info jump.
Widget buildIllustDetailMoreMenu({
  required BuildContext context,
  required WidgetRef ref,
  required IllustEntity entity,
  required bool rendersContent,
  required bool includeShare,
  required bool includeInfoJump,
  required VoidCallback onSelectPages,
  required VoidCallback onInfoJump,
}) {
  return DetailMoreMenu(
    entity: entity,
    items: [
      if (includeShare) const DetailOwnMenuItem(DetailMenuAction.share),
      if (rendersContent) ...[
        const DetailOwnMenuItem(DetailMenuAction.editBookmark),
        if (isDesktopImageClipboardSupported)
          DetailCardMenuItem(copyImageCardAction),
        DetailCardMenuItem(watchLaterCardAction),
      ],
      if (entity.pageCount > 1 && !entity.isUgoira)
        const DetailOwnMenuItem(DetailMenuAction.selectPages),
      if (rendersContent) ...[
        if (includeInfoJump) const DetailOwnMenuItem(DetailMenuAction.info),
        for (final cardAction in muteCardActions)
          DetailCardMenuItem(cardAction),
      ],
    ],
    onSelected: (buttonContext, action) => switch (action) {
      DetailMenuAction.share => unawaited(
        shareIllust(buttonContext, ref, entity),
      ),
      DetailMenuAction.editBookmark => unawaited(
        showBookmarkEditSheet(
          context,
          BookmarkKey(BookmarkEntityType.illust, entity.id),
          title: entity.title,
        ),
      ),
      DetailMenuAction.selectPages => onSelectPages(),
      DetailMenuAction.info => onInfoJump(),
    },
  );
}
