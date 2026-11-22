import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/widgets/app_snack_bar.dart';
import '../../app/widgets/inline_translation.dart';
import '../../core/logging/crash_log.dart';
import '../../core/localnovel/local_novel_repository.dart';
import '../../core/novel/novel_entity.dart';
import '../../core/translation/translation_service.dart';
import '../../l10n/context.dart';
import 'novel_layout.dart';
import 'novel_reader.dart';

/// Bilingual reading for the reader stage, page by page with the in-app
/// engine: the paragraphs of the current page are translated in one batch
/// and each translation shows under its paragraph; the reader translates
/// on as it turns — the current page first, then the page ahead. One batch
/// runs at a time. Translations stay for the stage's life, also while
/// bilingual reading is off, so turning it back on costs nothing.
mixin BilingualReading<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  /// The document being read.
  NovelEntity get bilingualNovel;

  /// The reader whose pages are translated.
  NovelReaderHandle get bilingualReader;

  bool bilingual = false;

  /// Reads the page in the target language only: a translated paragraph takes
  /// its source's place instead of gaining a line under it.
  bool translationOnly = false;

  /// A batch is being translated.
  bool translatingPage = false;

  /// Why the last batch produced nothing, kept for the reading options to
  /// state: a snackbar is gone before anyone reads it, and "nothing happened"
  /// is the hardest thing to report.
  TranslationFailureKind? lastFailure;

  /// How many paragraphs of the last batch the engine handed back unchanged.
  int lastEchoed = 0;

  /// Paragraphs of the page on screen that still have no translation.
  int get pendingTranslations {
    final layout = bilingualReader.layout?.call();
    final page = bilingualReader.currentPage?.call();
    if (layout == null || page == null) return 0;
    return _untranslated(layout, page).length;
  }

  /// Whether the page holds translations to take back or redo.
  bool get hasTranslations => _translations.isNotEmpty;

  Map<String, String> _translations = const {};
  Map<String, String> _sources = const {};
  String? _sourcesVersion;

  /// Paragraphs the engine handed back unchanged. They are not translations,
  /// so nothing shows for them, but asking again on every settle would spend
  /// a request per page for a paragraph that is already in the target
  /// language. Kept apart from [_translations] so a retry, a re-translate or
  /// a new prompt can try again, and so an echoed answer never enters the
  /// cache as if it were a translation.
  final Set<String> _echoed = {};

  /// What the last cache read covered (`localId|language|engine`), so a page
  /// turn does not read the same rows again.
  String? _cacheKey;
  String? _engine;

  /// Set by [retranslate]: the next restore must not read the cache it is
  /// about to overwrite.
  bool _skipCacheOnce = false;

  /// What the reader shows: under its paragraphs in bilingual mode, in their
  /// place when reading translations only.
  Map<String, String> get pageTranslations =>
      bilingual || translationOnly ? _translations : const {};

  void toggleBilingual() {
    setState(() => bilingual = !bilingual);
    bilingualPageSettled();
  }

  /// Switches between the source and a translation-only page.
  void toggleTranslationOnly() {
    setState(() => translationOnly = !translationOnly);
    bilingualPageSettled();
  }

  /// Throws the page's translations away and translates it again, overwriting
  /// their cached rows. The reader's re-translate action calls this.
  Future<void> retranslate() async {
    if (translatingPage) return;
    setState(() {
      _translations = const {};
      // A re-translate is the reader saying the old answer was not good
      // enough: give the echoed paragraphs another chance too.
      _echoed.clear();
      lastFailure = null;
      lastEchoed = 0;
    });
    _skipCacheOnce = true;
    await _translateAhead();
  }

  /// Drops what is shown and the cache mark, e.g. after this work's prompt
  /// changed: the next settle reads under the new signature.
  void invalidateTranslations() {
    setState(() {
      _translations = const {};
      _echoed.clear();
      _cacheKey = null;
    });
  }

  /// The reader settled on a page — a turn or a relayout: translate what
  /// it shows, then the page after it.
  void bilingualPageSettled() {
    if ((bilingual || translationOnly) && !translatingPage) {
      unawaited(_translateAhead());
    }
  }

  /// The way out of a failure the translation settings can fix.
  void showTranslationSettings() => openTranslationSettings(context);

  Future<void> _translateAhead() async {
    final layout = bilingualReader.layout?.call();
    final page = bilingualReader.currentPage?.call();
    if (layout == null || page == null) return;
    _syncSources();
    try {
      await _restoreTranslations();
    } on Object catch (error, stack) {
      // The engine signature or the cache read failed. Left unhandled this
      // becomes a silent no-op: the page keeps its source and nothing says
      // why, which reads as "translation is broken".
      CrashLog.record(error, stack);
      if (!mounted) return;
      setState(() {
        translatingPage = false;
        lastFailure = TranslationFailureKind.other;
      });
      _showFailure(TranslationFailureKind.other);
      return;
    }
    var ids = _untranslated(layout, page);
    if (ids.isEmpty) ids = _untranslated(layout, page + 1);
    if (ids.isEmpty) return;
    final version = _sourcesVersion;
    final sources = [for (final id in ids) _sources[id]!];
    final target = Localizations.localeOf(context).languageCode;
    setState(() => translatingPage = true);
    List<String> results = const [];
    TranslationFailureKind? failure;
    try {
      results = await ref
          .read(translationServiceProvider)
          .translateAll(sources, targetLanguage: target);
      if (results.length != sources.length) {
        failure = TranslationFailureKind.malformed;
      }
    } on TranslationUnavailable catch (error) {
      failure = error.kind;
    } on TranslationError catch (error) {
      failure = error.kind;
    } on Object catch (error, stack) {
      CrashLog.record(error, stack);
      failure = TranslationFailureKind.other;
    }
    if (!mounted) return;
    if (failure != null) {
      setState(() {
        translatingPage = false;
        lastFailure = failure;
        bilingual = false;
        // Translations-only with no translation is source text wearing the
        // mode's name: switch it off so the page stops pretending, and say
        // why whether it was turned on as bilingual reading or as
        // translations only.
        translationOnly = false;
      });
      _showFailure(failure);
      return;
    }
    if (version != bilingualNovel.contentVersion) {
      // The body was replaced while the batch ran; none of it applies.
      setState(() => translatingPage = false);
      bilingualPageSettled();
      return;
    }
    // The reader relayouts with the new map and reports its page again,
    // which translates the next batch.
    var unchanged = 0;
    final next = {..._translations};
    final echoed = {..._echoed};
    for (final (index, id) in ids.indexed) {
      final value = _shown(sources[index], results[index]);
      if (value.isEmpty) {
        // The engine returned the source: remember it so this page is not
        // re-asked, but show and cache nothing for it.
        unchanged++;
        echoed.add(id);
        next.remove(id);
      } else {
        next[id] = value;
        echoed.remove(id);
      }
    }
    setState(() {
      translatingPage = false;
      lastFailure = null;
      lastEchoed = unchanged;
      _translations = Map.unmodifiable(next);
      _echoed
        ..clear()
        ..addAll(echoed);
    });
    if (translationOnly && unchanged == results.length) {
      // Every paragraph came back as its own source: reading translations
      // only would show the original and look like nothing happened.
      showAppSnackBar(context, context.l10n.translationEchoed);
    }
    unawaited(_persistTranslations(ids, sources, results, target));
  }

  /// Fills [_translations] from the cache — keyed by the source text, so it is
  /// shared by comments, online novels and saved copies — before the network
  /// is asked for anything.
  Future<void> _restoreTranslations() async {
    final novelId = bilingualNovel.id;
    final language = Localizations.localeOf(context).languageCode;
    final engine = await ref.read(
      translationEngineSignatureProvider(novelId).future,
    );
    if (!mounted) return;
    _engine = engine;
    final key = '$novelId|$language|$engine';
    if (_cacheKey == key) return;
    _cacheKey = key;
    if (_skipCacheOnce) {
      // A re-translate: read nothing, let the batch overwrite the rows.
      _skipCacheOnce = false;
      return;
    }
    final idsByHash = <String, List<String>>{};
    for (final entry in _sources.entries) {
      if (entry.value.trim().isEmpty) continue;
      idsByHash.putIfAbsent(_sourceHash(entry.value), () => []).add(entry.key);
    }
    if (idsByHash.isEmpty) return;
    try {
      final stored = await ref
          .read(localNovelRepositoryProvider)
          .readTranslations(
            sourceHashes: idsByHash.keys,
            language: language,
            engine: engine,
          );
      if (!mounted || _cacheKey != key || stored.isEmpty) return;
      setState(() {
        _translations = Map.unmodifiable({
          // An empty row is not a translation: rows written by an engine that
          // echoed its input used to be stored as blanks and would otherwise
          // shadow a real answer forever.
          for (final entry in stored.entries)
            if (entry.value.trim().isNotEmpty)
              for (final id in idsByHash[entry.key] ?? const <String>[])
                id: entry.value,
          ..._translations,
        });
      });
    } on Object catch (error, stack) {
      CrashLog.record(error, stack);
    }
  }

  /// Writes a finished batch by source text, so any work holding the same
  /// sentence reads it from the cache.
  Future<void> _persistTranslations(
    List<String> ids,
    List<String> sources,
    List<String> results,
    String language,
  ) async {
    final engine = _engine;
    if (engine == null) return;
    final entries = <String, String>{};
    for (var index = 0; index < ids.length; index++) {
      final source = sources[index];
      if (source.trim().isEmpty) continue;
      final value = _shown(source, results[index]);
      // Blanks are not translations; caching one would make every later open
      // read it back as "already translated" and show nothing.
      if (value.isEmpty) continue;
      entries[_sourceHash(source)] = value;
    }
    if (entries.isEmpty) return;
    try {
      await ref
          .read(localNovelRepositoryProvider)
          .writeTranslations(
            language: language,
            engine: engine,
            entries: entries,
          );
    } on Object catch (error, stack) {
      CrashLog.record(error, stack);
    }
  }

  /// Paragraph texts by id, rebuilt when the body changes; translations
  /// of the old body go with them.
  void _syncSources() {
    final novel = bilingualNovel;
    if (_sourcesVersion == novel.contentVersion) return;
    _sourcesVersion = novel.contentVersion;
    final blocks = novel.markup?.blocks ?? novel.paragraphs;
    _sources = {for (final block in blocks) block.id: block.plainText};
    _translations = const {};
    _echoed.clear();
    _cacheKey = null;
  }

  /// Paragraphs on [page] with text and no translation yet, in order.
  List<String> _untranslated(NovelLayout layout, int page) {
    if (page < 0 || page >= layout.pages.length) return const [];
    final ids = <String>{};
    for (final line in layout.pages[page].lines) {
      final id = line.paragraphId;
      if (line.isTranslation || line.isTitleBlock) continue;
      if ((_translations[id] ?? '').isNotEmpty) continue;
      // Asked before and answered with the source: another request would get
      // the same answer, so this page is done with it.
      if (_echoed.contains(id)) continue;
      if ((_sources[id] ?? '').trim().isEmpty) continue;
      ids.add(id);
    }
    return ids.toList();
  }

  void _showFailure(TranslationFailureKind kind) {
    showAppSnackBar(
      context,
      translationFailureText(context, kind),
      action: translationNeedsSettings(kind)
          ? PromptAction(
              label: context.l10n.translationOpenSettings,
              onPressed: showTranslationSettings,
            )
          : null,
    );
  }
}

final _lineBreaks = RegExp(r'\s*\n\s*');

/// Cache key of a source paragraph: the text itself, so the same sentence in
/// a comment, an online novel or a saved copy is one row.
String _sourceHash(String text) => sha1.convert(utf8.encode(text)).toString();

/// What shows under [source]: nothing when the engine handed it back
/// unchanged (it is already in the target language), otherwise the
/// translation as one run of text.
String _shown(String source, String translation) {
  final text = translation.trim().replaceAll(_lineBreaks, ' ');
  return text == source.trim() ? '' : text;
}
