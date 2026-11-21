/// Body serialization for a saved novel.
///
/// The feed-snapshot codec keeps a work's metadata only, so a copy saved from
/// the reader needs its own body payload: the block list (paragraphs, chapter
/// headings, Pixiv page breaks and illustrations) with enough of each image's
/// request to resolve it again. Layout, page starts and image blocks then
/// restore exactly as they were read.
library;

import 'novel_entity.dart';

const int _version = 1;

/// The entity's body as JSON.
Map<String, Object?> encodeNovelContent(NovelEntity novel) {
  final document = novel.markup;
  if (document != null) {
    return encodeNovelDocument(
      document,
      contentVersion: novel.contentVersion,
      sourceLength: document.sourceLength,
    );
  }
  return encodeNovelDocument(
    NovelMarkupDocument.fromParagraphs(novel.paragraphs),
    contentVersion: novel.contentVersion,
    sourceLength: novel.textLength,
  );
}

/// A block list as JSON, for a copy that was edited on the device (an
/// illustration inserted) and must be stored again.
Map<String, Object?> encodeNovelDocument(
  NovelMarkupDocument document, {
  required String contentVersion,
  required int sourceLength,
}) => {
  'version': _version,
  'content_version': contentVersion,
  'source_length': sourceLength,
  'blocks': [for (final block in document.blocks) _encodeBlock(block)],
};

/// The body a payload from [encodeNovelContent] holds, or null when the JSON
/// is not one of ours (or holds no block).
NovelMarkupDocument? decodeNovelContent(Object? json) {
  if (json is! Map<String, dynamic>) return null;
  if (json['version'] != _version) return null;
  final rawBlocks = json['blocks'];
  if (rawBlocks is! List) return null;
  final blocks = <NovelBlock>[];
  for (final raw in rawBlocks) {
    final block = _decodeBlock(raw);
    if (block != null) blocks.add(block);
  }
  if (blocks.isEmpty) return null;
  final length = json['source_length'];
  return NovelMarkupDocument(
    // Tokens carry parser bookkeeping; the block list is what the reader
    // lays out and what page starts derive from.
    tokens: const [],
    blocks: blocks,
    diagnostics: const [],
    sourceLength: length is int ? length : 0,
    budgetExceeded: false,
  );
}

Map<String, Object?> _encodeBlock(NovelBlock block) => switch (block) {
  NovelImageBlock() => {
    'kind': 'image',
    'id': block.id,
    'image': _encodeImage(block.image),
  },
  NovelChapterBlock() => {
    'kind': 'chapter',
    'id': block.id,
    'title': block.title,
  },
  NovelPageBreakBlock() => {'kind': 'page_break', 'id': block.id},
  NovelParagraph() => {
    'kind': 'paragraph',
    'id': block.id,
    'text': block.text,
    'page_break_before': block.pageBreakBefore,
    'chapter_heading': block.isChapterHeading,
    if (block.image case final image?) 'image': _encodeImage(image),
  },
  _ => {'kind': 'paragraph', 'id': block.id, 'text': block.plainText},
};

Map<String, Object?> _encodeImage(NovelImageLoadRequest request) => {
  'source': request.source.name,
  'identifier': request.identifier,
  'illust_id': request.illustId,
  'page': request.page,
};

NovelBlock? _decodeBlock(Object? json) {
  if (json is! Map<String, dynamic>) return null;
  final id = json['id'];
  if (id is! String || id.isEmpty) return null;
  final kind = json['kind'];
  return switch (kind) {
    'image' => switch (_decodeImage(json['image'])) {
      final image? => NovelImageBlock(id: id, image: image),
      null => null,
    },
    'chapter' => NovelChapterBlock(
      id: id,
      token: NovelChapterToken(
        title: json['title'] as String? ?? '',
        rawText: '[chapter]',
        sourceOffset: 0,
      ),
    ),
    'page_break' => NovelPageBreakBlock(
      id: id,
      token: NovelNewPageToken(rawText: '[newpage]', sourceOffset: 0),
    ),
    'paragraph' => NovelParagraph(
      id: id,
      text: json['text'] as String? ?? '',
      pageBreakBefore: json['page_break_before'] == true,
      isChapterHeading: json['chapter_heading'] == true,
      image: _decodeImage(json['image']),
    ),
    _ => null,
  };
}

NovelImageLoadRequest? _decodeImage(Object? json) {
  if (json is! Map<String, dynamic>) return null;
  final identifier = json['identifier'];
  if (identifier is! String || identifier.isEmpty) return null;
  NovelImageSource? source;
  for (final value in NovelImageSource.values) {
    if (value.name == json['source']) {
      source = value;
      break;
    }
  }
  if (source == null) return null;
  return NovelImageLoadRequest(
    source: source,
    identifier: identifier,
    illustId: json['illust_id'] as int?,
    page: json['page'] as int?,
  );
}
