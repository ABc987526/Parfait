import 'dart:async' show unawaited;

import 'package:material_ui/material_ui.dart';

import '../../../../app/clipboard.dart';
import '../../../../app/format/app_format.dart';
import '../../../../app/format/content_locale.dart';
import '../../../../app/navigation/routes.dart';
import '../../../../app/pixiv_image.dart';
import '../../../../app/theme/func_semantic_tokens.dart';
import '../../../../app/widgets/bookmark_switch_button.dart';
import '../../../../app/widgets/caption_rich_text.dart';
import '../../../../app/widgets/tag_chips.dart';
import '../../../../core/entity/illust_entity.dart';
import '../../../../l10n/context.dart';
import 'info_block.dart';

/// Non-modal right inspector panel (**Desktop Detail Option A**): keeps the live
/// masonry gallery scrollable on the left while framing the selected artwork,
/// creator card, actions, stats, tags, and caption beside it.
class DesktopGalleryInspector extends StatelessWidget {
  const DesktopGalleryInspector({
    super.key,
    required this.entity,
    required this.onClose,
    required this.onOpenStage,
    this.panelWidth = width,
  });

  static const double width = 540;

  final IllustEntity entity;
  final VoidCallback onClose;
  final VoidCallback onOpenStage;
  final double panelWidth;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final tokens = FuncSemanticTokens.of(context);
    final aspect = (entity.width > 0 && entity.height > 0)
        ? (entity.width / entity.height).clamp(0.70, 1.75)
        : 1.0;

    return DecoratedBox(
      key: const Key('desktop-gallery-inspector'),
      decoration: BoxDecoration(
        color: tokens.surface,
        border: BorderDirectional(
          start: BorderSide(color: tokens.brandHairline),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 48,
            child: Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(
                FuncSpacing.lg,
                0,
                FuncSpacing.xs,
                0,
              ),
              child: Row(
                children: [
                  InkWell(
                    borderRadius: FuncShape.pill,
                    onTap: () => unawaited(
                      copyToClipboard(
                        context,
                        '${entity.id}',
                        message: l10n.artworkIdCopied,
                      ),
                    ),
                    child: DecoratedBox(
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
                        child: Text(
                          '#${entity.id}',
                          style: tokens.numeric.copyWith(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: colors.primary,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: FuncSpacing.sm),
                  Expanded(
                    child: Text(
                      '${entity.width}×${entity.height}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: tokens.numeric.copyWith(
                        fontSize: 12,
                        color: tokens.contentSecondary,
                      ),
                    ),
                  ),
                  IconButton(
                    key: const Key('desktop-inspector-open-stage'),
                    tooltip: l10n.viewerOpenDetail,
                    icon: const Icon(Icons.open_in_full, size: 18),
                    onPressed: onOpenStage,
                  ),
                  IconButton(
                    key: const Key('desktop-inspector-close'),
                    tooltip: l10n.profileShareClose,
                    icon: const Icon(Icons.close, size: 19),
                    onPressed: onClose,
                  ),
                ],
              ),
            ),
          ),
          Divider(height: 1, color: tokens.brandHairline),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(FuncSpacing.lg),
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: colors.surfaceContainerLow,
                    borderRadius: FuncShape.card,
                    border: Border.all(color: tokens.brandHairline),
                  ),
                  child: ClipRRect(
                    borderRadius: FuncShape.card,
                    child: InkWell(
                      onTap: onOpenStage,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxHeight: 500),
                              child: AspectRatio(
                                aspectRatio: aspect,
                                child: PixivImage.feed(
                                  entity.imageUrls.large,
                                  layoutWidth: panelWidth - FuncSpacing.lg * 2,
                                  fit: BoxFit.contain,
                                ),
                              ),
                            ),
                          ),
                          if (entity.pageCount > 1)
                            Positioned(
                              top: 8,
                              right: 8,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: const Color(0x9E141216),
                                  borderRadius: FuncShape.pill,
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: FuncSpacing.sm,
                                    vertical: FuncSpacing.xxs,
                                  ),
                                  child: Text(
                                    '1 / ${entity.pageCount}',
                                    style: tokens.numeric.copyWith(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: FuncSpacing.md),
                Row(
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
                            BookmarkSwitchButton(
                              illustId: entity.id,
                              title: entity.title,
                            ),
                            Text(
                              AppFormat.count(context, entity.totalBookmarks),
                              style: tokens.numeric.copyWith(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                                color: colors.primary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const Spacer(),
                    InkWell(
                      borderRadius: FuncShape.pill,
                      onTap: onOpenStage,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: tokens.brandTintWeak,
                          borderRadius: FuncShape.pill,
                          border: Border.all(color: tokens.brandHairline),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: FuncSpacing.md,
                            vertical: FuncSpacing.sm,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.open_in_full,
                                size: 15,
                                color: colors.primary,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                l10n.viewerOpenDetail,
                                style: theme.textTheme.labelMedium?.copyWith(
                                  color: colors.primary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: FuncSpacing.md),
                Text(
                  entity.title,
                  locale: contentLocale(context, entity.title),
                  style: tokens.workTitle,
                ),
                const SizedBox(height: FuncSpacing.sm),
                DetailAuthorCard(entity: entity),
                const SizedBox(height: FuncSpacing.md),
                DetailMarksAndStats(entity: entity),
                if (entity.tags.isNotEmpty) ...[
                  const SizedBox(height: FuncSpacing.lg),
                  Text(
                    l10n.detailSectionTags,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: FuncSpacing.sm),
                  TagChips(
                    children: [
                      for (final tag in entity.tags)
                        TagChip(
                          label: tag.name,
                          translated: tag.translatedName,
                          onTap: () =>
                              unawaited(openTagSearch(context, tag.name)),
                        ),
                    ],
                  ),
                ],
                if (entity.caption.isNotEmpty) ...[
                  const SizedBox(height: FuncSpacing.lg),
                  Text(
                    l10n.detailSectionCaption,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: FuncSpacing.sm),
                  CaptionRichText(caption: entity.caption, maxLines: 6),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
