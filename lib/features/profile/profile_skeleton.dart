import 'package:material_ui/material_ui.dart';

import '../../app/layout/app_breakpoints.dart';
import '../../app/navigation/home_shell_metrics.dart';
import '../../app/theme/func_semantic_tokens.dart';
import '../../app/widgets/app_top_bar.dart';
import '../../app/widgets/skeleton/func_skeleton.dart';
import '../../app/widgets/skeleton/illust_grid_skeleton.dart';
import '../../app/window/desktop_command_bar.dart';
import '../../l10n/context.dart';
import 'profile_header_delegate.dart';
import 'profile_illust_feed.dart';

/// First-load placeholder for the user page: the header's no-cover layout —
/// banner band, avatar straddling the banner's bottom edge, identity bones,
/// the tab slot, then the works grid — instead of a bare spinner.
///
/// On wide viewports (`>= 840×480` content area) it mirrors `_buildWideProfile`
/// with a 332dp left artist card skeleton beside the right tab strip and grid
/// skeleton (omitting duplicate desktop back arrows). On narrower windows it
/// follows `_ProfileExpandedIdentity`'s vertical rhythm, or a one-row identity
/// under a toolbar-high banner on short windows.
///
/// The banner is structure, not a bone: it keeps the real header's
/// `surfaceContainerHigh` and sits beneath [FuncSkeleton] so the shimmer
/// never sweeps it. The [BackButton] is real too — loading must never trap
/// the route — so it lives outside the skeleton's excluded semantics.
class ProfileSkeleton extends StatelessWidget {
  const ProfileSkeleton({super.key});

  static const _wideSidebarWidth = 332.0;

  Widget _statBones(TextTheme textTheme) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final width in const [48.0, 56.0])
          ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: kMinInteractiveDimension,
            ),
            child: Padding(
              padding: const EdgeInsetsDirectional.only(
                top: FuncSpacing.xxs,
                bottom: FuncSpacing.xxs,
                end: FuncSpacing.lg,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SkeletonBone.text(
                    width: width * 0.6,
                    style: textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  SkeletonBone.text(width: width, style: textTheme.labelMedium),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildWideSkeleton(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;
    final tokens = theme.extension<FuncSemanticTokens>();
    final hairline = tokens?.brandHairline ?? colorScheme.outlineVariant;
    final useDesktopChrome = DesktopCommandBarScope.isActiveOf(context);
    final loadingLabel = context.l10n.profileLoading;
    const bannerHeight = 108.0;
    const avatarDiameter = 72.0;

    return KeyedSubtree(
      key: const ValueKey('profile-wide-split'),
      child: Column(
        children: [
          if (!useDesktopChrome) const AppTopBar(),
          Expanded(
            child: FuncSkeleton(
              label: loadingLabel,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: _wideSidebarWidth,
                    child: SingleChildScrollView(
                      physics: const NeverScrollableScrollPhysics(),
                      padding: const EdgeInsets.all(FuncSpacing.lg),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: colorScheme.surface,
                          borderRadius: FuncShape.card,
                          border: Border.all(color: hairline),
                        ),
                        child: ClipRRect(
                          borderRadius: FuncShape.card,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(
                                height: bannerHeight + 28,
                                child: Stack(
                                  clipBehavior: Clip.none,
                                  children: [
                                    Positioned(
                                      top: 0,
                                      left: 0,
                                      right: 0,
                                      height: bannerHeight,
                                      child: ColoredBox(
                                        color: colorScheme.surfaceContainerHigh,
                                      ),
                                    ),
                                    const PositionedDirectional(
                                      start: FuncSpacing.lg,
                                      bottom: 0,
                                      child: SkeletonBone.circle(
                                        key: ValueKey(
                                          'profile-skeleton-avatar',
                                        ),
                                        diameter: avatarDiameter,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  FuncSpacing.lg,
                                  FuncSpacing.md,
                                  FuncSpacing.lg,
                                  FuncSpacing.lg,
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    FractionallySizedBox(
                                      key: const ValueKey(
                                        'profile-skeleton-name',
                                      ),
                                      widthFactor: 0.55,
                                      child: SkeletonBone.text(
                                        style: textTheme.titleLarge?.copyWith(
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: FuncSpacing.xxs),
                                    FractionallySizedBox(
                                      widthFactor: 0.35,
                                      child: SkeletonBone.text(
                                        style: textTheme.bodyMedium,
                                      ),
                                    ),
                                    const SizedBox(height: FuncSpacing.sm),
                                    _statBones(textTheme),
                                    const SizedBox(height: FuncSpacing.md),
                                    FractionallySizedBox(
                                      widthFactor: 0.85,
                                      child: SkeletonBone.text(
                                        style: textTheme.bodyMedium,
                                      ),
                                    ),
                                    const SizedBox(height: FuncSpacing.xs),
                                    FractionallySizedBox(
                                      widthFactor: 0.6,
                                      child: SkeletonBone.text(
                                        style: textTheme.bodyMedium,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  VerticalDivider(width: 1, thickness: 1, color: hairline),
                  Expanded(
                    child: Column(
                      children: [
                        DecoratedBox(
                          decoration: BoxDecoration(
                            color: theme.scaffoldBackgroundColor,
                            border: Border(bottom: BorderSide(color: hairline)),
                          ),
                          child: SizedBox(
                            key: const ValueKey('profile-skeleton-tabs'),
                            width: double.infinity,
                            height: useDesktopChrome
                                ? kDesktopPageHeaderHeight
                                : kToolbarHeight,
                          ),
                        ),
                        Expanded(
                          child: IllustGridSkeleton(
                            label: loadingLabel,
                            padding: gridPadding,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final contentSize = HomeShellChrome.contentSizeOf(context);
    final wideSplit =
        contentSize.width >= AppBreakpoints.expanded &&
        contentSize.height >= AppBreakpoints.compactHeight;
    if (wideSplit) {
      return _buildWideSkeleton(context);
    }

    final topInset = MediaQuery.viewPaddingOf(context).top;
    final window = MediaQuery.sizeOf(context);
    final short = ReplicaProfileHeaderGeometry.isShortWindow(window);
    final statsInRow = short && AppBreakpoints.useSideBySideForm(window);
    final avatarRadius = short
        ? ReplicaProfileHeaderGeometry.shortAvatarRadius
        : ReplicaProfileHeaderGeometry.avatarRadius;
    final avatar = SkeletonBone.circle(
      key: const ValueKey('profile-skeleton-avatar'),
      diameter: avatarRadius * 2,
    );
    final bannerHeight =
        topInset +
        kToolbarHeight +
        (short ? 0 : ReplicaProfileHeaderGeometry.bannerBelowToolbar);
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final canPop = Navigator.maybeOf(context)?.canPop() ?? false;
    final suppressDesktopBack =
        DesktopCommandBarScope.isActiveOf(context) &&
        !EmbeddedHeaderScope.isActiveOf(context);
    final statBones = _statBones(textTheme);

    return Stack(
      children: [
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: bannerHeight,
          child: ColoredBox(color: colorScheme.surfaceContainerHigh),
        ),
        Positioned.fill(
          child: FuncSkeleton(
            label: context.l10n.profileLoading,
            // Clipped, not scrolled: a short landscape viewport cuts the
            // bones off instead of overflowing.
            child: SingleChildScrollView(
              physics: const NeverScrollableScrollPhysics(),
              child: Stack(
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(height: bannerHeight),
                      // The avatar's lower half; on a short window the row
                      // starts under the banner.
                      SizedBox(
                        height: short
                            ? FuncSpacing.sm
                            : ReplicaProfileHeaderGeometry.nameRowBelowBanner,
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: FuncSpacing.lg,
                        ),
                        child: Row(
                          children: [
                            if (short) ...[
                              avatar,
                              const SizedBox(width: FuncSpacing.md),
                            ],
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  FractionallySizedBox(
                                    key: const ValueKey(
                                      'profile-skeleton-name',
                                    ),
                                    widthFactor: 0.45,
                                    child: SkeletonBone.text(
                                      style: textTheme.titleLarge?.copyWith(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                  FractionallySizedBox(
                                    widthFactor: 0.3,
                                    child: SkeletonBone.text(
                                      style: textTheme.bodyMedium,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (statsInRow) statBones,
                            // The share button's slot sets the row's
                            // minimum height, as in the real header.
                            const SizedBox.square(
                              dimension: kMinInteractiveDimension,
                            ),
                          ],
                        ),
                      ),
                      if (!statsInRow)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(
                            FuncSpacing.lg,
                            FuncSpacing.xs,
                            FuncSpacing.lg,
                            0,
                          ),
                          child: statBones,
                        ),
                      const SizedBox(height: FuncSpacing.sm),
                      // The tab strip's slot: the band stays empty — fake tab
                      // captions would read as content, not placeholder.
                      const SizedBox(
                        key: ValueKey('profile-skeleton-tabs'),
                        height: kToolbarHeight,
                      ),
                      // Unbounded here, so the grid paints three cards per
                      // column; the viewport clips whatever does not fit.
                      IllustGridSkeleton(
                        label: context.l10n.profileLoading,
                        padding: gridPadding,
                      ),
                    ],
                  ),
                  // Avatar centred on the banner's bottom edge, as in the
                  // real header.
                  if (!short)
                    Positioned(
                      left: FuncSpacing.lg,
                      top: bannerHeight - avatarRadius,
                      child: avatar,
                    ),
                ],
              ),
            ),
          ),
        ),
        if (canPop && !suppressDesktopBack)
          Positioned(top: topInset, left: 0, child: const BackButton()),
      ],
    );
  }
}
