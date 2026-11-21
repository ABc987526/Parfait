import 'package:material_ui/material_ui.dart';

import '../../app/motion/app_overlays.dart';
import '../../app/theme/func_semantic_tokens.dart';
import '../../l10n/context.dart';

/// What the reader asks the model for: where the new part starts, whether it
/// replaces the rest or is inserted, what should happen, and how long.
class NovelContinuationRequest {
  const NovelContinuationRequest({
    required this.startIndex,
    required this.rewrite,
    required this.direction,
    required this.words,
  });

  /// The paragraph the new part starts after; null appends at the end.
  final int? startIndex;

  /// Replace everything after [startIndex] instead of inserting into it.
  final bool rewrite;
  final String direction;
  final int words;
}

const int _minWords = 100;
const int _maxWords = 4000;
const int _recentParagraphs = 12;

Future<NovelContinuationRequest?> showNovelContinuationSheet(
  BuildContext context, {
  required List<String> paragraphs,
}) {
  return showAppBottomSheet<NovelContinuationRequest>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _NovelContinuationSheet(paragraphs: paragraphs),
  );
}

class _NovelContinuationSheet extends StatefulWidget {
  const _NovelContinuationSheet({required this.paragraphs});

  final List<String> paragraphs;

  @override
  State<_NovelContinuationSheet> createState() =>
      _NovelContinuationSheetState();
}

class _NovelContinuationSheetState extends State<_NovelContinuationSheet> {
  final _direction = TextEditingController();
  final _words = TextEditingController(text: '500');
  int? _start;
  bool _rewrite = false;

  /// The last few paragraphs are the ones a reader picks from; offering a
  /// thousand radio rows would be worse than a short list.
  List<int> get _pickable {
    final total = widget.paragraphs.length;
    final first = total <= _recentParagraphs ? 0 : total - _recentParagraphs;
    return [for (var index = first; index < total; index++) index];
  }

  @override
  void dispose() {
    _direction.dispose();
    _words.dispose();
    super.dispose();
  }

  String _excerpt(int index) {
    final text = widget.paragraphs[index].trim().replaceAll('\n', ' ');
    return text.length <= 24 ? text : '${text.substring(0, 24)}…';
  }

  int get _wordCount {
    final parsed = int.tryParse(_words.text.trim()) ?? 500;
    return parsed.clamp(_minWords, _maxWords).toInt();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(FuncSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.novelContinue,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: FuncSpacing.md),
            Text(
              l10n.novelContinueStart,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: FuncSpacing.xs),
            Wrap(
              spacing: FuncSpacing.sm,
              runSpacing: FuncSpacing.xs,
              children: [
                ChoiceChip(
                  label: Text(l10n.novelContinueFromEnd),
                  selected: _start == null,
                  onSelected: (_) => setState(() => _start = null),
                ),
                for (final index in _pickable)
                  ChoiceChip(
                    label: Text('${index + 1}'),
                    selected: _start == index,
                    onSelected: (_) => setState(() => _start = index),
                  ),
              ],
            ),
            if (_start case final start?) ...[
              const SizedBox(height: FuncSpacing.xs),
              Text(
                _excerpt(start),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: FuncSpacing.sm),
              Wrap(
                spacing: FuncSpacing.sm,
                children: [
                  ChoiceChip(
                    label: Text(l10n.novelContinueInsert),
                    selected: !_rewrite,
                    onSelected: (_) => setState(() => _rewrite = false),
                  ),
                  ChoiceChip(
                    label: Text(l10n.novelContinueRewrite),
                    selected: _rewrite,
                    onSelected: (_) => setState(() => _rewrite = true),
                  ),
                ],
              ),
            ],
            const SizedBox(height: FuncSpacing.md),
            TextField(
              controller: _direction,
              minLines: 2,
              maxLines: 4,
              decoration: InputDecoration(
                labelText: l10n.novelContinueDirection,
              ),
            ),
            TextField(
              controller: _words,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: l10n.novelContinueWords),
            ),
            const SizedBox(height: FuncSpacing.lg),
            Row(
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(l10n.cancel),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: () => Navigator.pop(
                    context,
                    NovelContinuationRequest(
                      startIndex: _start,
                      rewrite: _rewrite,
                      direction: _direction.text.trim(),
                      words: _wordCount,
                    ),
                  ),
                  child: Text(l10n.novelContinueGenerate),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
