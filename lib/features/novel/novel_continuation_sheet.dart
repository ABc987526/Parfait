import 'package:material_ui/material_ui.dart';

import '../../app/icons/ui_icons.dart';
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

/// The slider's granularity: one step per 100 characters, so a drag lands on a
/// round number and the field beside it never shows an odd one.
const int _wordStep = 100;
const List<int> _wordPresets = [300, 500, 800, 1500];

/// Tall enough for two rows plus a hint, short enough to leave the controls
/// below visible on a phone.
const double _positionListHeight = 224;

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

  @override
  void initState() {
    super.initState();
    // The slider and the field are one value: dragging rewrites the field,
    // typing moves the slider. The listener rebuilds for both.
    _words.addListener(_onWordsChanged);
  }

  void _onWordsChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _words.removeListener(_onWordsChanged);
    _direction.dispose();
    _words.dispose();
    super.dispose();
  }

  String _excerpt(int index) {
    final text = widget.paragraphs[index].trim().replaceAll(
      RegExp(r'\s+'),
      ' ',
    );
    return text.length <= 42 ? text : '${text.substring(0, 42)}…';
  }

  int get _wordCount {
    final parsed = int.tryParse(_words.text.trim()) ?? 500;
    return parsed.clamp(_minWords, _maxWords).toInt();
  }

  /// One value for both controls; writing the field triggers the listener, so
  /// the caller does not wrap this in its own setState.
  void _selectWords(int value) {
    final next = value.clamp(_minWords, _maxWords).toInt();
    final text = '$next';
    if (_words.text != text) _words.text = text;
  }

  void _submit() {
    Navigator.pop(
      context,
      NovelContinuationRequest(
        startIndex: _start,
        rewrite: _rewrite && _start != null,
        direction: _direction.text.trim(),
        words: _wordCount,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return Padding(
      // The keyboard covers the sheet instead of shrinking it to nothing.
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: media.size.height * 0.88),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(context),
            Flexible(
              child: ListView(
                padding: const EdgeInsetsDirectional.fromSTEB(
                  FuncSpacing.xl,
                  FuncSpacing.lg,
                  FuncSpacing.xl,
                  FuncSpacing.md,
                ),
                children: [
                  _sectionLabel(context, context.l10n.novelContinueStart),
                  const SizedBox(height: FuncSpacing.sm),
                  _positionList(context),
                  if (_start != null) ...[
                    const SizedBox(height: FuncSpacing.lg),
                    _sectionLabel(context, context.l10n.novelContinueMode),
                    const SizedBox(height: FuncSpacing.sm),
                    _ChoiceRow(
                      selected: !_rewrite,
                      title: context.l10n.novelContinueInsert,
                      subtitle: context.l10n.novelContinueInsertHint,
                      onTap: () => setState(() => _rewrite = false),
                    ),
                    _ChoiceRow(
                      selected: _rewrite,
                      title: context.l10n.novelContinueRewrite,
                      subtitle: context.l10n.novelContinueRewriteHint,
                      onTap: () => setState(() => _rewrite = true),
                    ),
                  ],
                  const SizedBox(height: FuncSpacing.lg),
                  _sectionLabel(context, context.l10n.novelContinueWords),
                  const SizedBox(height: FuncSpacing.sm),
                  _wordControls(context),
                  const SizedBox(height: FuncSpacing.lg),
                  _sectionLabel(context, context.l10n.novelContinueDirection),
                  const SizedBox(height: FuncSpacing.sm),
                  TextField(
                    controller: _direction,
                    minLines: 2,
                    maxLines: 4,
                    decoration: InputDecoration(
                      hintText: context.l10n.novelContinueDirectionHint,
                    ),
                  ),
                ],
              ),
            ),
            _footer(context),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(
        FuncSpacing.xl,
        FuncSpacing.lg,
        FuncSpacing.xl,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(context.l10n.novelContinue, style: theme.textTheme.titleLarge),
          const SizedBox(height: FuncSpacing.xs),
          Text(
            context.l10n.novelContinueSheetHint,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  /// Every paragraph is a choice, not only the last dozen: the model can be
  /// asked to write into the middle of a chapter. The end comes first because
  /// that is what most continuations want.
  Widget _positionList(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: _positionListHeight,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(FuncSpacing.md),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: FuncSpacing.xs),
        itemCount: widget.paragraphs.length + 1,
        itemBuilder: (context, position) {
          if (position == 0) {
            return _ChoiceRow(
              selected: _start == null,
              title: context.l10n.novelContinueFromEnd,
              subtitle: context.l10n.novelContinueFromEndHint,
              onTap: () => setState(() => _start = null),
            );
          }
          final index = position - 1;
          return _ChoiceRow(
            selected: _start == index,
            title: context.l10n.novelContinueParagraph(index + 1),
            subtitle: _excerpt(index),
            onTap: () => setState(() => _start = index),
          );
        },
      ),
    );
  }

  Widget _wordControls(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Slider(
                value: _wordCount.toDouble(),
                min: _minWords.toDouble(),
                max: _maxWords.toDouble(),
                divisions: (_maxWords - _minWords) ~/ _wordStep,
                label: '$_wordCount',
                onChanged: (value) => _selectWords(value.round()),
              ),
            ),
            const SizedBox(width: FuncSpacing.sm),
            SizedBox(
              width: 88,
              child: TextField(
                controller: _words,
                keyboardType: TextInputType.number,
                textAlign: TextAlign.center,
                decoration: const InputDecoration(isDense: true),
              ),
            ),
          ],
        ),
        Wrap(
          spacing: FuncSpacing.sm,
          children: [
            for (final preset in _wordPresets)
              ChoiceChip(
                label: Text('$preset'),
                selected: _wordCount == preset,
                onSelected: (_) => _selectWords(preset),
              ),
          ],
        ),
        const SizedBox(height: FuncSpacing.xs),
        Text(
          context.l10n.novelContinueWordsApprox(_wordCount),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _footer(BuildContext context) {
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(
        FuncSpacing.xl,
        FuncSpacing.sm,
        FuncSpacing.xl,
        FuncSpacing.lg,
      ),
      child: Row(
        children: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.cancel),
          ),
          const Spacer(),
          FilledButton(
            onPressed: _submit,
            child: Text(context.l10n.novelContinueGenerate),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(BuildContext context, String text) => Text(
    text,
    style: Theme.of(context).textTheme.labelLarge?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    ),
  );
}

/// One selectable row: a check marker, a title and an optional preview line.
/// Radio widgets are avoided on purpose — a screen of them reads as a form,
/// while these rows are a list of paragraphs to drop the new part into.
class _ChoiceRow extends StatelessWidget {
  const _ChoiceRow({
    required this.selected,
    required this.title,
    required this.onTap,
    this.subtitle,
  });

  final bool selected;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: FuncSpacing.md,
          vertical: FuncSpacing.sm,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(
                selected ? UiIcons.checkCircle : UiIcons.circleUnchecked,
                size: 18,
                color: selected ? scheme.primary : scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: FuncSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: selected ? scheme.primary : null,
                    ),
                  ),
                  if (subtitle case final subtitle?) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
