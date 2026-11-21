import 'package:material_ui/material_ui.dart';

import '../../app/motion/app_overlays.dart';
import '../../app/theme/func_semantic_tokens.dart';
import '../../app/icons/app_icons.dart';
import '../../l10n/context.dart';

/// Picks the paragraph an inserted illustration goes after. Returns its index,
/// or null when the sheet was dismissed.
Future<int?> showNovelImageInsertSheet(
  BuildContext context, {
  required List<String> paragraphs,
}) {
  return showAppBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _NovelImageInsertSheet(paragraphs: paragraphs),
  );
}

class _NovelImageInsertSheet extends StatelessWidget {
  const _NovelImageInsertSheet({required this.paragraphs});

  final List<String> paragraphs;

  String _excerpt(int index) {
    final text = paragraphs[index].trim().replaceAll('\n', ' ');
    if (text.isEmpty) return '—';
    return text.length <= 32 ? text : '${text.substring(0, 32)}…';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        FuncSpacing.xl,
        FuncSpacing.xl,
        FuncSpacing.xl,
        FuncSpacing.md,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.novelImagePickParagraph, style: theme.textTheme.titleLarge),
          const SizedBox(height: FuncSpacing.sm),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: paragraphs.length,
              itemBuilder: (context, index) => ListTile(
                dense: true,
                title: Text(
                  '${index + 1}. ${_excerpt(index)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Icon(AppIcons.illust),
                onTap: () => Navigator.pop(context, index),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
