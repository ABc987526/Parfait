import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:charset/charset.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:parfait/core/localnovel/local_novel_database.dart';
import 'package:parfait/core/localnovel/local_novel_decoder.dart';
import 'package:parfait/core/localnovel/local_novel_repository.dart';
import 'package:parfait/core/localnovel/local_novel_store.dart';
import 'package:parfait/core/localnovel/read_offset_anchor.dart';
import 'package:parfait/core/novel/novel_entity.dart';
import 'package:parfait/core/novel/novel_snapshot_codec.dart';
import 'package:parfait/core/platform/saf_tree.dart';
import 'package:parfait/core/user/user_entity.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  group('decoder', () {
    test('plain UTF-8 decodes as utf8', () {
      final (text, encoding) = decodeLocalNovelText(
        Uint8List.fromList(utf8.encode('第一章 开始\n正文内容。')),
      );
      expect(encoding, LocalNovelEncoding.utf8);
      expect(text, '第一章 开始\n正文内容。');
    });

    test('UTF-8 BOM is honoured', () {
      final bytes = Uint8List.fromList([
        0xEF,
        0xBB,
        0xBF,
        ...utf8.encode('bom text'),
      ]);
      final (text, encoding) = decodeLocalNovelText(bytes);
      expect(encoding, LocalNovelEncoding.utf8);
      expect(text, 'bom text');
    });

    test('UTF-16 LE BOM decodes through the utf16 path', () {
      final source = '你好，世界';
      final bytes = utf16.encode(source);
      final (text, encoding) = decodeLocalNovelText(Uint8List.fromList(bytes));
      expect(encoding, LocalNovelEncoding.utf16);
      expect(text, source);
    });

    test('GBK bytes decode Chinese without mojibake', () {
      final source = '修真小说 第一卷\n仙路漫漫';
      final bytes = Uint8List.fromList(gbk.encode(source));
      // GBK bytes are not valid UTF-8, so the fallback chain must engage.
      final (text, encoding) = decodeLocalNovelText(bytes);
      expect(encoding, LocalNovelEncoding.gbk);
      expect(text, source);
    });

    test('undecodable bytes fall back to tagged lossy UTF-8', () {
      // 0xFF alone is invalid UTF-8 and unmapped in GBK.
      final (text, encoding) = decodeLocalNovelText(
        Uint8List.fromList([0x61, 0xFF, 0x62]),
      );
      expect(encoding, LocalNovelEncoding.utf8Lossy);
      expect(text, contains('a'));
      expect(text, contains('b'));
    });
  });

  group('repository', () {
    late Directory dir;
    late LocalNovelRepository repository;
    late LocalNovelDatabase database;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('local-novels-test');
      database = LocalNovelDatabase(
        factory: databaseFactoryFfi,
        databasePath: '${dir.path}/local_novels.db',
      );
      repository = LocalNovelRepository(database: database);
    });

    tearDown(() async {
      await database.close();
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test(
      'import decodes, copies under the directory and indexes a row',
      () async {
        final novel = await repository.importBytes(
          fileName: '我的小说.txt',
          bytes: Uint8List.fromList(utf8.encode('正文一二三')),
          targetDir: dir,
        );

        expect(novel.title, '我的小说');
        expect(novel.charCount, 5);
        expect(novel.encoding, LocalNovelEncoding.utf8);
        expect(await File(novel.path).readAsString(), '正文一二三');
        expect(novel.path, startsWith(dir.path));

        final listed = await repository.list();
        expect(listed, hasLength(1));
        expect(listed.single.id, novel.id);
      },
    );

    test(
      'a file over the limit is refused before anything is stored',
      () async {
        final target = Directory('${dir.path}/novels');
        await expectLater(
          repository.importBytes(
            fileName: 'huge.txt',
            bytes: Uint8List(LocalNovelRepository.maxImportBytes + 1),
            targetDir: target,
          ),
          throwsA(isA<DocumentTooLargeException>()),
        );
        expect(await repository.list(), isEmpty);
        expect(target.existsSync(), isFalse);
      },
    );

    test('an import whose row fails to store leaves no file', () async {
      final target = Directory('${dir.path}/novels');
      final db = await database.database;
      await db.execute('DROP TABLE ${LocalNovelDatabase.table}');
      await expectLater(
        repository.importBytes(
          fileName: 'lost.txt',
          bytes: Uint8List.fromList(utf8.encode('正文')),
          targetDir: target,
        ),
        throwsA(isA<DatabaseException>()),
      );
      expect(target.listSync(), isEmpty);
    });

    test('GBK import stores decoded UTF-8 text on disk', () async {
      final novel = await repository.importBytes(
        fileName: 'legacy.txt',
        bytes: Uint8List.fromList(gbk.encode('古早文本')),
        targetDir: dir,
      );
      expect(novel.encoding, LocalNovelEncoding.gbk);
      expect(await File(novel.path).readAsString(), '古早文本');
    });

    test('same file name imports get unique paths, even at once', () async {
      Future<LocalNovel> import(String text) => repository.importBytes(
        fileName: 'dup.txt',
        bytes: Uint8List.fromList(utf8.encode(text)),
        targetDir: dir,
      );
      final [first, second] = await Future.wait([import('一'), import('二')]);
      expect(first.path, isNot(second.path));
      expect(await File(first.path).readAsString(), '一');
      expect(await File(second.path).readAsString(), '二');
    });

    test('delete removes the row and the file together', () async {
      final novel = await repository.importBytes(
        fileName: 'gone.txt',
        bytes: Uint8List.fromList(utf8.encode('删除我')),
        targetDir: dir,
      );
      final path = novel.path;
      await repository.delete(novel);
      expect(await repository.list(), isEmpty);
      expect(await File(path).exists(), isFalse);
    });

    test('read offset persists through updateReadOffset', () async {
      final novel = await repository.importBytes(
        fileName: 'progress.txt',
        bytes: Uint8List.fromList(utf8.encode('进度')),
        targetDir: dir,
      );
      await repository.updateReadOffset(novel.id, 1234);
      final reloaded = await repository.get(novel.id);
      expect(reloaded!.readOffset, 1234);
    });

    test('saveFromNovel writes the text and indexes its source', () async {
      final novel = NovelEntity(
        id: 4242,
        title: '落花',
        caption: '',
        user: const UserEntity(id: 7, name: '作者', account: 'a'),
        tags: const [],
        textLength: 7,
        contentVersion: 'v1',
        paragraphs: [
          NovelParagraph(id: 'p0', text: '春眠'),
          NovelParagraph(id: 'p1', text: '不觉晓'),
        ],
      );

      final saved = await repository.saveFromNovel(
        novel: novel,
        targetDir: Directory('${dir.path}/saved'),
      );

      expect(saved.title, '落花');
      expect(saved.author, '作者');
      expect(saved.sourceNovelId, 4242);
      expect(saved.sourceContentVersion, 'v1');
      expect(await File(saved.path).readAsString(), '春眠\n不觉晓');
      expect((await repository.findBySourceNovel(4242))?.id, saved.id);
      expect(await repository.findBySourceNovel(1), isNull);
      // The snapshot keeps the body for the reader, images included.
      expect(saved.payloadJson, isNotNull);
      final decoded = NovelSnapshotCodec().decodeEntity(
        jsonDecode(saved.payloadJson!),
      );
      expect(decoded?.title, '落花');
      expect(decoded?.paragraphs.length, 2);
    });

    test('translations are shared by source text, not by work', () async {
      await repository.writeTranslations(
        language: 'zh',
        engine: 'llm:m:abc',
        entries: {'h1': '甲', 'h2': '乙'},
      );

      expect(
        await repository.readTranslations(
          sourceHashes: ['h1', 'h2', 'h3'],
          language: 'zh',
          engine: 'llm:m:abc',
        ),
        {'h1': '甲', 'h2': '乙'},
      );
      // Another engine is another cache: the old rows must not answer it.
      expect(
        await repository.readTranslations(
          sourceHashes: ['h1'],
          language: 'zh',
          engine: 'llm:other:abc',
        ),
        isEmpty,
      );

      // The cache outlives the work that filled it.
      final novel = await repository.importBytes(
        fileName: 'translated.txt',
        bytes: Uint8List.fromList(utf8.encode('a\nb')),
        targetDir: dir,
      );
      await repository.delete(novel);
      expect(
        (await repository.readTranslations(
          sourceHashes: ['h1'],
          language: 'zh',
          engine: 'llm:m:abc',
        ))['h1'],
        '甲',
      );
    });

    test('a work keeps its own prompt until it is cleared', () async {
      expect(await repository.readNovelPrompt(-7), isNull);
      await repository.writeNovelPrompt(-7, '  古风  ');
      expect(await repository.readNovelPrompt(-7), '古风');
      await repository.writeNovelPrompt(-7, '   ');
      expect(await repository.readNovelPrompt(-7), isNull);
    });
  });

  group('store', () {
    late Directory dir;
    late ProviderContainer container;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('local-novels-store');
      final database = LocalNovelDatabase(
        factory: databaseFactoryFfi,
        databasePath: '${dir.path}/local_novels.db',
      );
      addTearDown(database.close);
      container = ProviderContainer.test(
        overrides: [
          localNovelDatabaseProvider.overrideWithValue(database),
          localNovelDirectoryProvider.overrideWithValue(() async => dir),
          localNovelFilePickerProvider.overrideWithValue(
            () async => ('picked.txt', Uint8List.fromList(utf8.encode('选中内容'))),
          ),
        ],
      );
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test(
      'importPicked imports through the picker and updates the list',
      () async {
        await container.read(localNovelStoreProvider.future);
        final novel = await container
            .read(localNovelStoreProvider.notifier)
            .importPicked();
        expect(novel!.title, 'picked');
        expect(await File(novel.path).readAsString(), '选中内容');
        expect(container.read(localNovelStoreProvider).value, hasLength(1));
      },
    );

    test('delete removes the entry from state', () async {
      await container.read(localNovelStoreProvider.future);
      final novel = (await container
          .read(localNovelStoreProvider.notifier)
          .importPicked())!;
      await container.read(localNovelStoreProvider.notifier).delete(novel);
      expect(container.read(localNovelStoreProvider).value, isEmpty);
      expect(await File(novel.path).exists(), isFalse);
    });
  });

  group('read offset anchor', () {
    int forwardOffset(String text, String paragraphId, int offset) {
      final lines = text.split('\n');
      var base = 0;
      for (var i = 0; i < lines.length; i++) {
        if ('p$i' == paragraphId) return base + offset;
        base += lines[i].length + 1;
      }
      throw ArgumentError('unknown paragraph $paragraphId');
    }

    test('empty or absent cursors restore nothing', () {
      expect(novelAnchorForReadOffset(null, 'a\nb'), isNull);
      expect(novelAnchorForReadOffset(0, 'a\nb'), isNull);
      expect(novelAnchorForReadOffset(-3, 'a\nb'), isNull);
      expect(novelAnchorForReadOffset(4, ''), isNull);
    });

    test('offsets inside a paragraph map to that paragraph', () {
      const text = 'hello\nworld';
      expect(novelAnchorForReadOffset(1, text), (paragraphId: 'p0', offset: 1));
      expect(novelAnchorForReadOffset(8, text), (paragraphId: 'p1', offset: 2));
    });

    test('a newline position belongs to the paragraph before it', () {
      const text = 'hello\nworld';
      expect(novelAnchorForReadOffset(5, text), (paragraphId: 'p0', offset: 5));
      expect(novelAnchorForReadOffset(6, text), (paragraphId: 'p1', offset: 0));
    });

    test('round-trips every anchor the persist side can produce', () {
      const text = 'ab\n\ncd\nef';
      for (var i = 0; i < text.split('\n').length; i++) {
        final length = text.split('\n')[i].length;
        for (var offset = 0; offset <= length; offset++) {
          final stored = forwardOffset(text, 'p$i', offset);
          expect(
            novelAnchorForReadOffset(stored, text),
            stored == 0 ? null : (paragraphId: 'p$i', offset: offset),
            reason: 'p$i:$offset -> $stored',
          );
        }
      }
    });

    test('an offset past the end clamps to the last paragraph', () {
      const text = 'a\nb';
      expect(novelAnchorForReadOffset(3, text), (paragraphId: 'p1', offset: 1));
      expect(novelAnchorForReadOffset(999, text), (
        paragraphId: 'p1',
        offset: 1,
      ));
    });

    test('a trailing newline keeps the final empty paragraph reachable', () {
      const text = 'a\n';
      expect(novelAnchorForReadOffset(1, text), (paragraphId: 'p0', offset: 1));
      expect(novelAnchorForReadOffset(2, text), (paragraphId: 'p1', offset: 0));
    });
  });
}
