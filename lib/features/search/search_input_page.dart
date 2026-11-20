import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../app/layout/content_widths.dart';
import '../../app/navigation/route_search_facade.dart';
import '../../app/theme/func_semantic_tokens.dart';
import '../../app/widgets/app_top_bar.dart';
import '../../app/window/desktop_command_bar_scope.dart';
import '../../core/search/search_models.dart';
import '../../l10n/context.dart';
import 'search_filter_labels.dart';
import 'search_input_engine.dart';
import '../../app/icons/ui_icons.dart';

/// The full-page search input: the engine in a page's own chrome.
class SearchInputPage extends StatelessWidget {
  const SearchInputPage({
    super.key,
    this.initialKeyword = '',
    this.initialType = SearchResultType.illust,
    this.initialIllustFilters,
    this.initialNovelFilters,
    this.onTypeChanged,
  });

  final String initialKeyword;
  final SearchResultType initialType;
  final IllustSearchFilters? initialIllustFilters;
  final NovelSearchFilters? initialNovelFilters;
  final void Function(String keyword, SearchResultType type)? onTypeChanged;

  @override
  Widget build(BuildContext context) {
    final route = ModalRoute.of(context);
    final isModal =
        route is PopupRoute || (route is PageRoute && route.fullscreenDialog);
    final hasCommandBar = DesktopCommandBarScope.isActiveOf(context);
    final workspaceMode = hasCommandBar && !isModal;
    return SearchInputEngine(
      initialKeyword: initialKeyword,
      initialType: initialType,
      initialIllustFilters: initialIllustFilters,
      initialNovelFilters: initialNovelFilters,
      onTypeChanged: onTypeChanged,
      workspaceField: workspaceMode,
      // Submitting replaces the input with the results (NAV-06).
      onSubmit: (query) =>
          unawaited(openSearchResults(context, query, replaceCurrent: true)),
      builder: (context, parts) {
        final showFilters = switch (parts.filterButton) {
          SearchFilterButton(muted: true) => false,
          _ => true,
        };
        final Widget? leading = isModal
            ? IconButton(
                tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(UiIcons.close),
              )
            : workspaceMode
            ? null
            : IconButton(
                tooltip: context.l10n.searchCancel,
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const BackButtonIcon(),
              );
        return Scaffold(
          // The keyboard overlays the page instead of squeezing the body into
          // the strip above it; the suggestion list below gets a viewInsets
          // bottom pad so its tail can still scroll clear of the IME.
          resizeToAvoidBottomInset: false,
          appBar: workspaceMode
              ? AppTopBar(
                  automaticallyImplyLeading: false,
                  contentWidth: ContentWidths.management,
                  titleSpacing: 0,
                  title: parts.tabs,
                  actions: [if (showFilters) parts.filterButton],
                )
              : AppTopBar(
                  automaticallyImplyLeading: false,
                  contentWidth: ContentWidths.management,
                  leading: leading,
                  titleSpacing: 0,
                  title: parts.field,
                  // Reserve the trailing 48dp slot when user search hides its
                  // filter button, so the field keeps its place across tabs
                  // and across the push to results.
                  actions: [
                    showFilters
                        ? parts.filterButton
                        : const SizedBox(width: kMinInteractiveDimension),
                  ],
                  bottom: PreferredSize(
                    preferredSize: parts.tabs.preferredSize,
                    child: ContentWidthCap(
                      maxWidth: ContentWidths.management,
                      child: parts.tabs,
                    ),
                  ),
                ),
          body: ContentWidthCap(
            maxWidth: ContentWidths.management,
            child: workspaceMode
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          FuncSpacing.lg,
                          FuncSpacing.md,
                          FuncSpacing.lg,
                          FuncSpacing.xs,
                        ),
                        child: parts.field,
                      ),
                      Expanded(child: parts.body),
                    ],
                  )
                : parts.body,
          ),
        );
      },
    );
  }
}
