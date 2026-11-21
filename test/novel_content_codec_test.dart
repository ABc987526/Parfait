import 'package:flutter_test/flutter_test.dart';

import 'package:parfait/core/novel/novel_content_codec.dart';
import 'package:parfait/core/novel/novel_entity.dart';
import 'package:parfait/core/user/user_entity.dart';

void main() {
  const user = UserEntity(id: 1, name: '作者', account: 'a');

  NovelEntity novelWith(List<NovelBlock> blocks) => NovelEntity(
    id: 7,
    title: '落花',
    caption: '',
    user: user,
    tags: const [],
    textLength: 20,
    contentVersion: 'v1',
    paragraphs: blocks.whereType<NovelParagraph>().toList(),
    markup: NovelMarkupDocument(
      tokens: const [],
      blocks: blocks,
      diagnostics: const [],
      sourceLength: 20,
      budgetExceeded: false,
    ),
  );

  test('a body round-trips with images and page breaks', () {
    final decoded = decodeNovelContent(
      encodeNovelContent(
        novelWith([
          NovelParagraph(id: 'p0', text: '第一段'),
          NovelPageBreakBlock(
            id: 'p1',
            token: NovelNewPageToken(rawText: '[newpage]', sourceOffset: 0),
          ),
          NovelImageBlock(
            id: 'p2',
            image: const NovelImageLoadRequest(
              source: NovelImageSource.pixiv,
              identifier: '42-2',
              illustId: 42,
              page: 2,
            ),
          ),
          NovelParagraph(
            id: 'p3',
            text: '第二章',
            isChapterHeading: true,
            pageBreakBefore: true,
          ),
        ]),
      ),
    );

    expect(decoded, isNotNull);
    expect(
      [for (final block in decoded!.blocks) block.id],
      ['p0', 'p1', 'p2', 'p3'],
    );
    // The page break still starts a Pixiv page where it did.
    expect(decoded.pixivPageStarts, ['p0', 'p2']);
    final image = decoded.blocks.whereType<NovelImageBlock>().single;
    expect(image.image.source, NovelImageSource.pixiv);
    expect(image.image.identifier, '42-2');
    expect(image.image.illustId, 42);
    expect(image.image.page, 2);
    final heading = decoded.blocks.whereType<NovelParagraph>().last;
    expect(heading.text, '第二章');
    expect(heading.isChapterHeading, isTrue);
    expect(heading.pageBreakBefore, isTrue);
  });

  test('a payload that is not a body decodes to null', () {
    expect(decodeNovelContent(null), isNull);
    expect(decodeNovelContent('nope'), isNull);
    expect(decodeNovelContent({'version': 1, 'blocks': []}), isNull);
    expect(decodeNovelContent({'version': 99, 'blocks': []}), isNull);
  });
}
