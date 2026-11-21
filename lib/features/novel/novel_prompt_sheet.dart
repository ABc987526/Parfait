import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/motion/app_overlays.dart';
import '../../app/theme/func_semantic_tokens.dart';
import '../../core/localnovel/local_novel_repository.dart';
import '../../core/translation/translation_service.dart';
import '../../l10n/context.dart';

/// Edits the work's own prompt as its parts: characters (name and
/// personality), style, world, and anything else in free form. Empty parts
/// are left out, and a form with nothing in it makes the work follow the
/// global prompt again.
Future<void> editNovelPrompt(
  BuildContext context,
  WidgetRef ref,
  int novelId,
) async {
  final repository = ref.read(localNovelRepositoryProvider);
  final spec =
      await repository.readNovelPromptSpec(novelId) ?? const NovelPromptSpec();
  if (!context.mounted) return;
  final saved = await showAppBottomSheet<NovelPromptSpec>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _NovelPromptSheet(initial: spec),
  );
  if (saved == null) return;
  await repository.writeNovelPromptSpec(novelId, saved);
  // The engine signature caches this work's prompt: recompute it before the
  // next restore, or the old key would keep answering from the old rows.
  ref.invalidate(translationEngineSignatureProvider(novelId));
}

class _NovelPromptSheet extends StatefulWidget {
  const _NovelPromptSheet({required this.initial});

  final NovelPromptSpec initial;

  @override
  State<_NovelPromptSheet> createState() => _NovelPromptSheetState();
}

class _NovelPromptSheetState extends State<_NovelPromptSheet> {
  late final _instructions = TextEditingController(
    text: widget.initial.instructions,
  );
  late final _style = TextEditingController(text: widget.initial.style);
  late final _world = TextEditingController(text: widget.initial.world);
  late final List<(TextEditingController, TextEditingController)> _roles = [
    for (final role in widget.initial.roles)
      (
        TextEditingController(text: role.name),
        TextEditingController(text: role.personality),
      ),
  ];

  @override
  void dispose() {
    _instructions.dispose();
    _style.dispose();
    _world.dispose();
    for (final role in _roles) {
      role.$1.dispose();
      role.$2.dispose();
    }
    super.dispose();
  }

  NovelPromptSpec _spec() => NovelPromptSpec(
    roles: [
      for (final role in _roles)
        if (role.$1.text.trim().isNotEmpty)
          NovelPromptRole(
            name: role.$1.text.trim(),
            personality: role.$2.text.trim(),
          ),
    ],
    style: _style.text,
    world: _world.text,
    instructions: _instructions.text,
  );

  void _addRole() {
    setState(
      () => _roles.add((TextEditingController(), TextEditingController())),
    );
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
              l10n.novelPromptTitle,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: FuncSpacing.xs),
            Text(
              l10n.novelPromptHint,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            for (final (index, role) in _roles.indexed) ...[
              const SizedBox(height: FuncSpacing.md),
              TextField(
                controller: role.$1,
                decoration: InputDecoration(
                  labelText: '${index + 1}. ${l10n.novelPromptRoleName}',
                ),
              ),
              TextField(
                controller: role.$2,
                minLines: 1,
                maxLines: 2,
                decoration: InputDecoration(
                  labelText: l10n.novelPromptRolePersonality,
                ),
              ),
            ],
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                onPressed: _addRole,
                child: Text(l10n.novelPromptAddRole),
              ),
            ),
            TextField(
              controller: _style,
              minLines: 1,
              maxLines: 2,
              decoration: InputDecoration(labelText: l10n.novelPromptStyle),
            ),
            TextField(
              controller: _world,
              minLines: 1,
              maxLines: 3,
              decoration: InputDecoration(labelText: l10n.novelPromptWorld),
            ),
            TextField(
              controller: _instructions,
              minLines: 2,
              maxLines: 4,
              decoration: InputDecoration(labelText: l10n.novelPromptExtra),
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
                  onPressed: () => Navigator.pop(context, _spec()),
                  child: Text(l10n.save),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
