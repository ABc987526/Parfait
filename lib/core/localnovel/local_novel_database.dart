/// SQLite connection and schema owner for the local `local_novels.db`
/// database. [LocalNovelDatabase] owns the schema; connection lifecycle and
/// factory choice live in [SqliteDatabase], and CRUD belongs to
/// [LocalNovelRepository]. See `backend/sqlite.md`.
library;

import 'package:sqflite/sqflite.dart';

import '../sqlite/sqlite_database.dart';

/// Owns the one SQLite connection used by the local-novel library index.
class LocalNovelDatabase {
  LocalNovelDatabase({DatabaseFactory? factory, String? databasePath})
    : _sqlite = SqliteDatabase(
        databaseName: databaseName,
        schemaVersion: schemaVersion,
        closedMessage: 'local novel database is closed',
        factory: factory,
        databasePath: databasePath,
        onCreate: (db, _) => _createSchema(db),
        onUpgrade: _upgrade,
        onDowngrade: SqliteDatabase.refuseDowngrade(databaseName),
      );

  static const databaseName = 'local_novels.db';
  static const table = 'local_novels';

  /// Translations keyed by the *source text*, not by a paragraph id: the same
  /// sentence in a comment, an online novel or its saved copy is one row, and
  /// a body update does not invalidate it.
  static const translationTable = 'translation_cache';

  /// One saved prompt per work (its entity id: negative for a local copy),
  /// added to the engine signature so changing it never reads stale rows.
  static const promptTable = 'novel_prompt';

  static const schemaVersion = 4;

  final SqliteDatabase _sqlite;

  Future<Database> get database => _sqlite.database;

  Future<void> close() => _sqlite.close();

  static Future<void> _createSchema(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE $table (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        author TEXT,
        path TEXT NOT NULL UNIQUE,
        char_count INTEGER NOT NULL DEFAULT 0,
        imported_at INTEGER NOT NULL,
        read_offset INTEGER,
        source_novel_id INTEGER,
        source_content_version TEXT,
        payload_json TEXT
      )
    ''');
    await _createTranslationTable(db);
  }

  static Future<void> _createTranslationTable(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE $translationTable (
        source_hash TEXT NOT NULL,
        language TEXT NOT NULL,
        engine TEXT NOT NULL,
        text TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        PRIMARY KEY (source_hash, language, engine)
      )
    ''');
    await db.execute('''
      CREATE TABLE $promptTable (
        novel_id INTEGER NOT NULL PRIMARY KEY,
        prompt TEXT NOT NULL
      )
    ''');
  }

  static Future<void> _upgrade(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 1) {
      await _createSchema(db);
      return;
    }
    if (oldVersion < 2) {
      // A v1 library: the import source is unknown for its rows.
      await db.execute('ALTER TABLE $table ADD COLUMN source_novel_id INTEGER');
      await db.execute(
        'ALTER TABLE $table ADD COLUMN source_content_version TEXT',
      );
    }
    if (oldVersion < 3) {
      // Rows saved before the snapshot existed keep their TXT rendering.
      await db.execute('ALTER TABLE $table ADD COLUMN payload_json TEXT');
    }
    if (oldVersion < 4) {
      // The per-paragraph cache keyed by local row went away: a row is worth
      // little and cannot be re-keyed without the source text, so the old
      // table is dropped and the first read misses.
      await db.execute('DROP TABLE IF EXISTS local_novel_translations');
      await _createTranslationTable(db);
    }
  }
}
