/// Local-novel library index: decoded TXT files copied into the app
/// support directory and indexed in `local_novels.db`.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;

import '../log.dart';
import '../novel/novel_entity.dart';
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

  /// Removes the index row, the stored file and every translation of it; a
  /// missing file is tolerated so cleanup of a half-deleted entry still
  /// completes.
  Future<void> delete(LocalNovel novel) async {
    final db = await _database.database;
    await db.delete(
      LocalNovelDatabase.translationTable,
      where: 'local_id = ?',
      whereArgs: [novel.id],
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
    );
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

  /// Cached translations of [localId] for one language and engine
  /// configuration, by paragraph id.
  Future<Map<String, String>> readTranslations({
    required int localId,
    required String language,
    required String engine,
  }) async {
    final db = await _database.database;
    final rows = await db.query(
      LocalNovelDatabase.translationTable,
      columns: ['paragraph_id', 'text'],
      where: 'local_id = ? AND language = ? AND engine = ?',
      whereArgs: [localId, language, engine],
    );
    return {
      for (final row in rows)
        row['paragraph_id']! as String: row['text']! as String,
    };
  }

  /// Stores [entries] (paragraph id → translation), replacing rows for the
  /// same paragraph, language and engine.
  Future<void> writeTranslations({
    required int localId,
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
        '(local_id, paragraph_id, language, engine, text, created_at) '
        'VALUES (?, ?, ?, ?, ?, ?)',
        [localId, entry.key, language, engine, entry.value, now],
      );
    }
    await batch.commit(noResult: true);
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
    );
  }
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
