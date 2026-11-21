/// Local-novel library index: decoded TXT files copied into the app
/// support directory and indexed in `local_novels.db`.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;

import '../log.dart';
import '../novel/novel_content_codec.dart';
import '../novel/novel_entity.dart';
import '../novel/novel_snapshot_codec.dart';
import '../platform/app_storage_paths.dart';
import '../platform/saf_tree.dart';
import 'local_novel_database.dart';
import 'local_novel_decoder.dart';

/// One indexed local novel.
class LocalNovel {
  const LocalNovel({
    required this.id,
    required this.title,
    required this.path,
    required this.charCount,
    required this.importedAt,
    this.author,
    this.encoding,
    this.readOffset,
    this.sourceNovelId,
    this.sourceContentVersion,
    this.payloadJson,
  });

  final int id;
  final String title;
  final String? author;

  /// Absolute path inside the app's private `local_novels/` directory.
  final String path;
  final int charCount;
  final DateTime importedAt;
  final LocalNovelEncoding? encoding;

  /// Reading cursor written by the local reader (character offset).
  final int? readOffset;

  /// The online novel this copy was saved from, or null for a file import.
  final int? sourceNovelId;

  /// That novel's `contentVersion` when it was saved.
  final String? sourceContentVersion;

  /// Snapshot of the body as saved (paragraphs, markup and image blocks), so
  /// the reader can restore the work as it was. Null for a TXT import.
  final String? payloadJson;

  File get file => File(path);
}

/// CRUD + import boundary for the local TXT library. The file is written
/// before its index row; a row that fails to store takes the file with it,
/// so the library directory holds no file the list cannot show.
class LocalNovelRepository {
  LocalNovelRepository({required LocalNovelDatabase database})
    : _database = database;

  final LocalNovelDatabase _database;

  /// Largest TXT accepted for import. The whole text is decoded and held
  /// in memory, and a very long web novel is a few tens of MiB.
  static const maxImportBytes = 64 * 1024 * 1024;

  /// Directory that owns copied-in TXT files; injectable for tests.
  static Future<Directory> defaultNovelsDirectory() async {
    final support = await AppStoragePaths.active.resolveSupportDir();
    return Directory(path.join(support.path, 'local_novels'));
  }

  Future<List<LocalNovel>> list() async {
    final db = await _database.database;
    final rows = await db.query(
      LocalNovelDatabase.table,
      orderBy: 'imported_at DESC, id DESC',
    );
    return [for (final row in rows) _fromRow(row)];
  }

  Future<LocalNovel?> get(int id) async {
    final db = await _database.database;
    final rows = await db.query(
      LocalNovelDatabase.table,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  /// Decodes [bytes] as a TXT novel, copies it under [targetDir], and
  /// indexes it. Returns the inserted entity.
  Future<LocalNovel> importBytes({
    required String fileName,
    required Uint8List bytes,
    required Directory targetDir,
  }) async {
    if (bytes.length > maxImportBytes) {
      throw const DocumentTooLargeException(maxImportBytes);
    }
    final (text, encoding) = decodeLocalNovelText(bytes);
    await targetDir.create(recursive: true);
    final file = await _createUniqueFile(targetDir, fileName);

    final int id;
    try {
      await file.writeAsString(text, flush: true);
      final db = await _database.database;
      id = await db.insert(LocalNovelDatabase.table, {
        'title': _titleOf(fileName),
        'author': null,
        'path': file.path,
        'char_count': text.length,
        'imported_at': DateTime.now().millisecondsSinceEpoch,
        'read_offset': null,
      });
    } on Object {
      try {
        await file.delete();
      } on FileSystemException catch (error) {
        log('local novel: orphaned file not removed: $error');
      }
      rethrow;
    }
    return LocalNovel(
      id: id,
      title: _titleOf(fileName),
      path: file.path,
      charCount: text.length,
      importedAt: DateTime.now(),
      encoding: encoding,
    );
  }

  /// Removes the index row, the stored file and the work's saved prompt; a
  /// missing file is tolerated so cleanup of a half-deleted entry still
  /// completes. Cached translations stay: they are keyed by source text and
  /// shared with every other work that holds the same sentence.
  Future<void> delete(LocalNovel novel) async {
    final db = await _database.database;
    await db.delete(
      LocalNovelDatabase.promptTable,
      where: 'novel_id = ?',
      whereArgs: [-novel.id],
    );
    await db.delete(
      LocalNovelDatabase.table,
      where: 'id = ?',
      whereArgs: [novel.id],
    );
    final file = novel.file;
    if (await file.exists()) {
      await file.delete();
    }
  }

  /// Saves the reader's copy of an online [novel] as a local one: its
  /// paragraphs become one UTF-8 text file in the library, so the work stays
  /// readable offline and its translations can be cached against the row.
  ///
  /// Markup is flattened: images and Pixiv page breaks do not survive, since
  /// the local reader lays out plain lines.
  Future<LocalNovel> saveFromNovel({
    required NovelEntity novel,
    required Directory targetDir,
  }) async {
    final blocks = novel.markup?.blocks ?? novel.paragraphs;
    final text = [for (final block in blocks) block.plainText].join('\n');
    // Metadata for the list and title, plus the body (blocks, images, page
    // breaks) the feed codec does not carry. The text file stays the fallback.
    final metadata =
        NovelSnapshotCodec().encodeEntity(novel) as Map<String, Object?>;
    final payload = jsonEncode({
      ...metadata,
      'content': encodeNovelContent(novel),
    });
    if (text.length > maxImportBytes) {
      throw const DocumentTooLargeException(maxImportBytes);
    }
    await targetDir.create(recursive: true);
    final file = await _createUniqueFile(targetDir, '${novel.title}.txt');
    final author = novel.user.name.trim().isEmpty ? null : novel.user.name;
    final int id;
    try {
      await file.writeAsString(text, flush: true);
      final db = await _database.database;
      id = await db.insert(LocalNovelDatabase.table, {
        'title': novel.title,
        'author': author,
        'path': file.path,
        'char_count': text.length,
        'imported_at': DateTime.now().millisecondsSinceEpoch,
        'read_offset': null,
        'source_novel_id': novel.id,
        'source_content_version': novel.contentVersion,
        'payload_json': payload,
      });
    } on Object {
      try {
        await file.delete();
      } on FileSystemException catch (error) {
        log('local novel: orphaned file not removed: $error');
      }
      rethrow;
    }
    return LocalNovel(
      id: id,
      title: novel.title,
      author: author,
      path: file.path,
      charCount: text.length,
      importedAt: DateTime.now(),
      sourceNovelId: novel.id,
      sourceContentVersion: novel.contentVersion,
      payloadJson: payload,
    );
  }

  /// Writes a continuation of a work as a new library entry (the original is
  /// untouched), titled after it, so both versions read side by side.
  Future<LocalNovel> saveContinuation({
    required String title,
    required String? author,
    required int? sourceNovelId,
    required List<String> paragraphs,
    required Directory targetDir,
  }) async {
    final text = paragraphs.join('\n');
    if (text.length > maxImportBytes) {
      throw const DocumentTooLargeException(maxImportBytes);
    }
    await targetDir.create(recursive: true);
    final file = await _createUniqueFile(targetDir, '$title.txt');
    final int id;
    try {
      await file.writeAsString(text, flush: true);
      final db = await _database.database;
      id = await db.insert(LocalNovelDatabase.table, {
        'title': title,
        'author': author,
        'path': file.path,
        'char_count': text.length,
        'imported_at': DateTime.now().millisecondsSinceEpoch,
        'read_offset': null,
        'source_novel_id': sourceNovelId,
      });
    } on Object {
      try {
        await file.delete();
      } on FileSystemException catch (error) {
        log('local novel: orphaned continuation not removed: $error');
      }
      rethrow;
    }
    return LocalNovel(
      id: id,
      title: title,
      author: author,
      path: file.path,
      charCount: text.length,
      importedAt: DateTime.now(),
      sourceNovelId: sourceNovelId,
    );
  }

  /// Directory that owns a saved novel's own illustrations.
  static Future<Directory> localImagesDirectory() async {
    final support = await AppStoragePaths.active.resolveSupportDir();
    return Directory(path.join(support.path, 'local_novels', 'images'));
  }

  /// Copies a picked image beside the library and places it after the block at
  /// [afterIndex] of the saved body, bumping the body's version so the reader
  /// lays the page out again on the next open.
  Future<void> insertLocalImage({
    required int localId,
    required int afterIndex,
    required String fileName,
    required Uint8List bytes,
    required Directory imagesDir,
  }) async {
    final row = await get(localId);
    if (row == null) throw StateError('local novel $localId not found');
    final payload = row.payloadJson;
    if (payload == null) {
      throw StateError('local novel $localId has no body to illustrate');
    }
    final decoded = jsonDecode(payload);
    if (decoded is! Map<String, dynamic>) {
      throw StateError('local novel $localId has an unreadable payload');
    }
    final document = decodeNovelContent(decoded['content']);
    if (document == null || document.blocks.isEmpty) {
      throw StateError('local novel $localId has no body to illustrate');
    }
    await imagesDir.create(recursive: true);
    final name = await _uniqueImageName(imagesDir, fileName);
    final file = File(path.join(imagesDir.path, name));
    await file.writeAsBytes(bytes, flush: true);

    final blocks = document.blocks;
    final index = afterIndex.clamp(0, blocks.length - 1);
    final anchor = blocks[index];
    final insertAt = blocks.indexWhere((block) => block.id == anchor.id) + 1;
    final identifier = 'local:$name';
    final nextBlocks = [...blocks]
      ..insert(
        insertAt,
        NovelImageBlock(
          id: '${anchor.id}-img',
          image: NovelImageLoadRequest(
            source: NovelImageSource.uploaded,
            identifier: identifier,
          ),
        ),
      );
    final nextDocument = NovelMarkupDocument(
      tokens: const [],
      blocks: nextBlocks,
      diagnostics: const [],
      sourceLength: document.sourceLength,
      budgetExceeded: false,
    );
    final previousVersion = decoded['content'] is Map<String, dynamic>
        ? (decoded['content'] as Map<String, dynamic>)['content_version']
              as String?
        : null;
    final version = '${previousVersion ?? 'local:$localId'}+img$insertAt';
    final previousImages = decoded['local_images'];
    final next = <String, Object?>{
      ...decoded,
      'content': encodeNovelDocument(
        nextDocument,
        contentVersion: version,
        sourceLength: document.sourceLength,
      ),
      'local_images': {
        if (previousImages is Map)
          for (final entry in previousImages.entries)
            if (entry.key is String && entry.value is String)
              entry.key as String: entry.value as String,
        identifier: file.path,
      },
    };
    final db = await _database.database;
    await db.update(
      LocalNovelDatabase.table,
      {'payload_json': jsonEncode(next)},
      where: 'id = ?',
      whereArgs: [localId],
    );
  }

  /// A file name the images directory does not hold yet.
  static Future<String> _uniqueImageName(Directory dir, String fileName) async {
    final base = path.basename(fileName);
    final dot = base.lastIndexOf('.');
    final rawStem = dot > 0 ? base.substring(0, dot) : base;
    final stem = rawStem.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final extension = dot > 0 ? base.substring(dot) : '.jpg';
    for (var suffix = 0; ; suffix++) {
      final name = suffix == 0 ? '$stem$extension' : '$stem-$suffix$extension';
      if (!await File(path.join(dir.path, name)).exists()) return name;
    }
  }

  /// The saved copy of online novel [novelId], if this library has one.
  Future<LocalNovel?> findBySourceNovel(int novelId) async {
    final db = await _database.database;
    final rows = await db.query(
      LocalNovelDatabase.table,
      where: 'source_novel_id = ?',
      whereArgs: [novelId],
      orderBy: 'imported_at DESC, id DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  /// Cached translations for [sourceHashes] in one language and engine
  /// configuration, by source hash. Absent rows are simply not returned.
  Future<Map<String, String>> readTranslations({
    required Iterable<String> sourceHashes,
    required String language,
    required String engine,
  }) async {
    final hashes = sourceHashes.toSet().toList(growable: false);
    if (hashes.isEmpty) return const {};
    final db = await _database.database;
    final rows = await db.query(
      LocalNovelDatabase.translationTable,
      columns: ['source_hash', 'text'],
      where:
          'language = ? AND engine = ? AND source_hash IN '
          '(${List.filled(hashes.length, '?').join(', ')})',
      whereArgs: [language, engine, ...hashes],
    );
    return {
      for (final row in rows)
        row['source_hash']! as String: row['text']! as String,
    };
  }

  /// Stores [entries] (source hash → translation), replacing rows for the
  /// same hash, language and engine.
  Future<void> writeTranslations({
    required String language,
    required String engine,
    required Map<String, String> entries,
  }) async {
    if (entries.isEmpty) return;
    final db = await _database.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final batch = db.batch();
    for (final entry in entries.entries) {
      batch.rawInsert(
        'INSERT OR REPLACE INTO ${LocalNovelDatabase.translationTable} '
        '(source_hash, language, engine, text, created_at) '
        'VALUES (?, ?, ?, ?, ?)',
        [entry.key, language, engine, entry.value, now],
      );
    }
    await batch.commit(noResult: true);
  }

  /// Drops every cached translation, for every work, language and engine.
  Future<void> clearTranslations() async {
    final db = await _database.database;
    await db.delete(LocalNovelDatabase.translationTable);
  }

  /// Roughly how much the cached translations occupy, for the settings row.
  Future<int> translationCacheBytes() async {
    final db = await _database.database;
    final rows = await db.rawQuery(
      'SELECT COALESCE(SUM(LENGTH(source_hash) + LENGTH(text)), 0) AS bytes '
      'FROM ${LocalNovelDatabase.translationTable}',
    );
    final value = rows.isEmpty ? null : rows.first['bytes'];
    return value is int ? value : 0;
  }

  /// The work's own prompt (its entity id, negative for a local copy), or
  /// null when it follows the global one. Structured parts are composed in.
  Future<String?> readNovelPrompt(int novelId) async {
    final spec = await readNovelPromptSpec(novelId);
    if (spec == null) return null;
    final composed = composeNovelPrompt(spec).trim();
    return composed.isEmpty ? null : composed;
  }

  /// The work's structured prompt, or null when it has none.
  Future<NovelPromptSpec?> readNovelPromptSpec(int novelId) async {
    final db = await _database.database;
    final rows = await db.query(
      LocalNovelDatabase.promptTable,
      where: 'novel_id = ?',
      whereArgs: [novelId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return NovelPromptSpec(
      roles: _decodeRoles(row['roles']),
      style: (row['style'] as String?) ?? '',
      world: (row['world'] as String?) ?? '',
      instructions: (row['prompt'] as String?) ?? '',
    );
  }

  /// Saves the work's structured prompt; an empty spec removes it, so the
  /// work follows the global prompt again.
  Future<void> writeNovelPromptSpec(int novelId, NovelPromptSpec spec) async {
    final db = await _database.database;
    if (composeNovelPrompt(spec).trim().isEmpty) {
      await db.delete(
        LocalNovelDatabase.promptTable,
        where: 'novel_id = ?',
        whereArgs: [novelId],
      );
      return;
    }
    await db.rawInsert(
      'INSERT OR REPLACE INTO ${LocalNovelDatabase.promptTable} '
      '(novel_id, prompt, style, world, roles) VALUES (?, ?, ?, ?, ?)',
      [
        novelId,
        spec.instructions.trim(),
        spec.style.trim(),
        spec.world.trim(),
        jsonEncode([for (final role in spec.roles) role.toJson()]),
      ],
    );
  }

  /// Saves the work's own prompt; an empty [prompt] removes it, so the work
  /// follows the global prompt again.
  Future<void> writeNovelPrompt(int novelId, String? prompt) =>
      writeNovelPromptSpec(
        novelId,
        NovelPromptSpec(instructions: prompt?.trim() ?? ''),
      );

  static List<NovelPromptRole> _decodeRoles(Object? raw) {
    if (raw is! String || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [for (final entry in decoded) ?NovelPromptRole.fromJson(entry)];
    } on FormatException {
      return const [];
    }
  }

  Future<void> updateReadOffset(int id, int offset) async {
    final db = await _database.database;
    await db.update(
      LocalNovelDatabase.table,
      {'read_offset': offset},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Creates a unique, filesystem-safe file inside [dir]: `name.txt`,
  /// `name-1.txt`, … Sanitizes separators so a picked file name can never
  /// escape the library directory. The exclusive create makes the file this
  /// import's alone, so two imports of one name never share it and a failed
  /// import deletes only its own.
  Future<File> _createUniqueFile(Directory dir, String fileName) async {
    var stem = _titleOf(fileName).replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    if (stem.isEmpty) stem = 'novel';
    for (var suffix = 0; ; suffix++) {
      final candidate = File(
        path.join(dir.path, suffix == 0 ? '$stem.txt' : '$stem-$suffix.txt'),
      );
      try {
        return await candidate.create(exclusive: true);
      } on PathExistsException {
        continue;
      }
    }
  }

  static String _titleOf(String fileName) {
    final base = path.basename(fileName);
    final dot = base.lastIndexOf('.');
    return dot > 0 ? base.substring(0, dot) : base;
  }

  LocalNovel _fromRow(Map<String, Object?> row) {
    return LocalNovel(
      id: row['id']! as int,
      title: row['title']! as String,
      author: row['author'] as String?,
      path: row['path']! as String,
      charCount: (row['char_count'] as int?) ?? 0,
      importedAt: DateTime.fromMillisecondsSinceEpoch(
        row['imported_at']! as int,
      ),
      readOffset: row['read_offset'] as int?,
      sourceNovelId: row['source_novel_id'] as int?,
      sourceContentVersion: row['source_content_version'] as String?,
      payloadJson: row['payload_json'] as String?,
    );
  }
}

/// One character the work's prompt describes.
class NovelPromptRole {
  const NovelPromptRole({required this.name, this.personality = ''});

  final String name;
  final String personality;

  Map<String, Object?> toJson() => {'name': name, 'personality': personality};

  static NovelPromptRole? fromJson(Object? json) {
    if (json is! Map) return null;
    final name = json['name'];
    if (name is! String || name.trim().isEmpty) return null;
    final personality = json['personality'];
    return NovelPromptRole(
      name: name.trim(),
      personality: personality is String ? personality.trim() : '',
    );
  }
}

/// The parts a work's own prompt is written in: who is in it, how it reads,
/// where it happens, and anything else in free form.
class NovelPromptSpec {
  const NovelPromptSpec({
    this.roles = const [],
    this.style = '',
    this.world = '',
    this.instructions = '',
  });

  final List<NovelPromptRole> roles;
  final String style;
  final String world;
  final String instructions;

  bool get isEmpty =>
      roles.isEmpty &&
      style.trim().isEmpty &&
      world.trim().isEmpty &&
      instructions.trim().isEmpty;
}

/// The prompt text the model receives: one labelled line per filled part.
String composeNovelPrompt(NovelPromptSpec spec) {
  final roles = [
    for (final role in spec.roles)
      if (role.name.trim().isNotEmpty)
        role.personality.trim().isEmpty
            ? role.name.trim()
            : '${role.name.trim()}（${role.personality.trim()}）',
  ];
  return [
    if (roles.isNotEmpty) '角色设定：${roles.join('；')}',
    if (spec.style.trim().isNotEmpty) '文风：${spec.style.trim()}',
    if (spec.world.trim().isNotEmpty) '世界设定：${spec.world.trim()}',
    if (spec.instructions.trim().isNotEmpty) spec.instructions.trim(),
  ].join('\n');
}

final localNovelDatabaseProvider = Provider<LocalNovelDatabase>((ref) {
  final database = LocalNovelDatabase(
    databasePath: ref
        .watch(appStoragePathsProvider)
        .databasePath(LocalNovelDatabase.databaseName),
  );
  ref.onDispose(database.close);
  return database;
});

final localNovelRepositoryProvider = Provider<LocalNovelRepository>((ref) {
  return LocalNovelRepository(database: ref.watch(localNovelDatabaseProvider));
});
