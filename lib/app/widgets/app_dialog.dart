import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';

import '../theme/forui_theme_bridge.dart';
import '../theme/func_semantic_tokens.dart';

/// Shared alert/confirmation dialog backed by Forui's [FDialog].
///
/// Renders [title], [content], and [actions] inside an inner transparent
/// [Material] so inputs and Material buttons keep ink, text styles, and focus
/// semantics while inheriting Parfait's `FDialogStyle`.
class AppAlertDialog extends StatelessWidget {
  const AppAlertDialog({
    super.key,
    this.title,
    this.content,
    this.actions,
    this.scrollable = false,
  });

  final Widget? title;
  final Widget? content;
  final List<Widget>? actions;
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    final baseTextStyle = Theme.of(context).textTheme.bodyMedium;
    final hasActions = actions != null && actions!.isNotEmpty;
    return ForuiThemeHost.ensure(
      context,
      FDialog(
        clipBehavior: Clip.antiAlias,
        constraints: const BoxConstraints(minWidth: 280, maxWidth: 480),
        builder: (context, style) {
          final styledTitle = title == null
              ? null
              : DefaultTextStyle.merge(
                  style: style.titleTextStyle,
                  child: title!,
                );
          final styledContent = content == null
              ? null
              : DefaultTextStyle.merge(
                  style: style.bodyTextStyle,
                  child: content!,
                );
          final bodyColumn = Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (scrollable)
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        ?styledTitle,
                        if (styledTitle != null && styledContent != null)
                          const SizedBox(height: FuncSpacing.sm),
                        ?styledContent,
                      ],
                    ),
                  ),
                )
              else ...[
                ?styledTitle,
                if (styledTitle != null && styledContent != null)
                  const SizedBox(height: FuncSpacing.sm),
                if (styledContent != null)
                  Flexible(child: SingleChildScrollView(child: styledContent)),
              ],
              if (hasActions) ...[
                const SizedBox(height: FuncSpacing.lg),
                OverflowBar(
                  alignment: MainAxisAlignment.end,
                  spacing: FuncSpacing.sm,
                  overflowSpacing: FuncSpacing.sm,
                  children: actions!,
                ),
              ],
            ],
          );
          return Material(
            type: MaterialType.transparency,
            textStyle: baseTextStyle,
            child: Padding(
              padding: const EdgeInsets.all(FuncSpacing.xl),
              child: bodyColumn,
            ),
          );
        },
      ),
    );
  }
}
