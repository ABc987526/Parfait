import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:parfait/core/history/history_models.dart';

import '../helpers/illust_fixtures.dart';

final bool _demoGalleryEnabled =
    Platform.environment['PARFAIT_DEMO_GALLERY'] == '1';

class _DemoWorkSpec {
  const _DemoWorkSpec({
    required this.width,
    required this.height,
    required this.title,
    required this.author,
    required this.account,
    required this.views,
    required this.bookmarks,
    required this.bookmarked,
    required this.topColor,
    required this.bottomColor,
    required this.glowColor,
    required this.horizonColor,
    required this.glowX,
    required this.glowY,
  });

  final int width;
  final int height;
  final String title;
  final String author;
  final String account;
  final int views;
  final int bookmarks;
  final bool bookmarked;
  final (int, int, int) topColor;
  final (int, int, int) bottomColor;
  final (int, int, int) glowColor;
  final (int, int, int) horizonColor;
  final double glowX;
  final double glowY;
}

const _demoGalleryWorks = <_DemoWorkSpec>[
  _DemoWorkSpec(
    width: 900,
    height: 1240,
    title: '夏影の踏切とラムネ',
    author: '藤原 凛',
    account: 'fujiwara_rin',
    views: 18420,
    bookmarks: 4290,
    bookmarked: false,
    topColor: (48, 72, 138),
    bottomColor: (246, 179, 146),
    glowColor: (255, 224, 178),
    horizonColor: (38, 45, 82),
    glowX: 0.64,
    glowY: 0.42,
  ),
  _DemoWorkSpec(
    width: 1200,
    height: 860,
    title: '星屑のアトリエ・夜想',
    author: '苍井 遥',
    account: 'aoi_haruka',
    views: 31200,
    bookmarks: 8910,
    bookmarked: true,
    topColor: (24, 34, 68),
    bottomColor: (92, 68, 128),
    glowColor: (255, 214, 150),
    horizonColor: (18, 22, 42),
    glowX: 0.34,
    glowY: 0.36,
  ),
  _DemoWorkSpec(
    width: 880,
    height: 1380,
    title: '雨上がりの停留所にて',
    author: 'Mika_04',
    account: 'mika04',
    views: 9640,
    bookmarks: 1850,
    bookmarked: false,
    topColor: (116, 158, 154),
    bottomColor: (242, 232, 212),
    glowColor: (255, 250, 234),
    horizonColor: (66, 94, 96),
    glowX: 0.56,
    glowY: 0.30,
  ),
  _DemoWorkSpec(
    width: 1000,
    height: 1000,
    title: '白昼夢の標本箱',
    author: '白羽 雫',
    account: 'shirahane',
    views: 12300,
    bookmarks: 2740,
    bookmarked: false,
    topColor: (218, 166, 176),
    bottomColor: (102, 106, 130),
    glowColor: (255, 236, 228),
    horizonColor: (58, 56, 74),
    glowX: 0.48,
    glowY: 0.46,
  ),
  _DemoWorkSpec(
    width: 920,
    height: 1460,
    title: '夜行列車、窓辺の灯',
    author: 'Kurose',
    account: 'kurose_art',
    views: 45100,
    bookmarks: 11200,
    bookmarked: true,
    topColor: (20, 42, 74),
    bottomColor: (212, 132, 66),
    glowColor: (255, 218, 132),
    horizonColor: (16, 24, 42),
    glowX: 0.58,
    glowY: 0.54,
  ),
  _DemoWorkSpec(
    width: 1280,
    height: 800,
    title: '潮騒と群青のスケッチ',
    author: '星野 葵',
    account: 'hoshino_aoi',
    views: 7820,
    bookmarks: 1420,
    bookmarked: false,
    topColor: (56, 118, 172),
    bottomColor: (186, 224, 230),
    glowColor: (255, 252, 240),
    horizonColor: (42, 84, 128),
    glowX: 0.72,
    glowY: 0.32,
  ),
  _DemoWorkSpec(
    width: 900,
    height: 1280,
    title: '薄明の図書館と黒猫',
    author: '青木 蓮',
    account: 'aoki_ren',
    views: 19500,
    bookmarks: 5120,
    bookmarked: false,
    topColor: (74, 58, 92),
    bottomColor: (224, 164, 136),
    glowColor: (255, 228, 198),
    horizonColor: (40, 32, 50),
    glowX: 0.38,
    glowY: 0.40,
  ),
  _DemoWorkSpec(
    width: 860,
    height: 1520,
    title: '冬の境界線・序章',
    author: 'Nagi',
    account: 'nagi_works',
    views: 22800,
    bookmarks: 6300,
    bookmarked: false,
    topColor: (146, 174, 198),
    bottomColor: (242, 240, 238),
    glowColor: (255, 248, 240),
    horizonColor: (84, 102, 124),
    glowX: 0.52,
    glowY: 0.28,
  ),
  _DemoWorkSpec(
    width: 1160,
    height: 900,
    title: '路地裏の珈琲店',
    author: '椎名 紬',
    account: 'shiina_t',
    views: 11050,
    bookmarks: 2190,
    bookmarked: false,
    topColor: (86, 56, 48),
    bottomColor: (218, 174, 126),
    glowColor: (255, 232, 184),
    horizonColor: (48, 32, 28),
    glowX: 0.42,
    glowY: 0.44,
  ),
  _DemoWorkSpec(
    width: 900,
    height: 1320,
    title: '琥珀色の放課後',
    author: 'Haru',
    account: 'haru_illust',
    views: 28900,
    bookmarks: 7640,
    bookmarked: true,
    topColor: (196, 94, 92),
    bottomColor: (248, 206, 146),
    glowColor: (255, 244, 210),
    horizonColor: (92, 46, 56),
    glowX: 0.62,
    glowY: 0.48,
  ),
  _DemoWorkSpec(
    width: 960,
    height: 960,
    title: '深海の郵便局',
    author: '水瀬 祈',
    account: 'minase_i',
    views: 15600,
    bookmarks: 3890,
    bookmarked: false,
    topColor: (28, 76, 96),
    bottomColor: (116, 188, 176),
    glowColor: (212, 250, 240),
    horizonColor: (18, 46, 62),
    glowX: 0.50,
    glowY: 0.34,
  ),
  _DemoWorkSpec(
    width: 900,
    height: 1400,
    title: '月光奏鳴曲・習作',
    author: 'Lumina',
    account: 'lumina_jp',
    views: 34700,
    bookmarks: 9450,
    bookmarked: false,
    topColor: (44, 50, 88),
    bottomColor: (162, 152, 204),
    glowColor: (244, 240, 255),
    horizonColor: (28, 30, 54),
    glowX: 0.66,
    glowY: 0.26,
  ),
];

_DemoWorkSpec _demoWorkSpec(int id) =>
    _demoGalleryWorks[(id - 1000).abs() % _demoGalleryWorks.length];

/// Fixture JSON builders for the review world's API dispatch. Real API
/// envelopes so the real repositories parse them; ids are stable so every
/// run produces the same frames.

/// Works with their own shape (width, height); every other work is 800×600.
/// The 1500 row is a feed of every shape a Hero flight treats differently
/// ([reviewShapesFeed]).
const reviewWorkShapes = <int, (int, int)>{
  1501: (800, 1680), // taller than 1:2: the card shows its top
  1502: (800, 4800), // far taller: the card shows the square thumbnail
  1503: (1500, 500), // a panorama on the detail page
  1504: (800, 1520), // whole on the card, past the capsule on the detail
  1505: (800, 1200),
  1506: (800, 800),
  1507: (800, 1680),
};

/// The ids of the shapes feed.
const reviewShapesFeed = [
  1500, 1501, 1502, 1503, 1504, 1505, 1506, 1507, 1508, 1509, 1510, 1511, //
];

Map<String, dynamic> reviewIllustJson(
  int id, {
  bool bookmarked = false,
  int pageCount = 1,
  String caption = '',
}) {
  final fixedShape = reviewWorkShapes[id];
  if (!_demoGalleryEnabled) {
    final (width, height) = fixedShape ?? (800, 600);
    return illustJson(
      id,
      bookmarked: bookmarked,
      pageCount: pageCount,
      withMetaPages: pageCount > 1,
      caption: caption,
      width: width,
      height: height,
    );
  }
  final spec = _demoWorkSpec(id);
  final (width, height) = fixedShape ?? (spec.width, spec.height);
  final json = illustJson(
    id,
    bookmarked: bookmarked || spec.bookmarked,
    pageCount: pageCount,
    withMetaPages: pageCount > 1,
    caption: caption,
    totalView: spec.views,
    totalBookmarks: spec.bookmarks,
    width: width,
    height: height,
  );
  json['title'] = spec.title;
  final slot = (id - 1000).abs() % _demoGalleryWorks.length;
  json['user'] = {
    'id': 99,
    'name': spec.author,
    'account': spec.account,
    'profile_image_urls': {'medium': 'https://i.pximg.net/u${100 + slot}.jpg'},
  };
  json['tags'] = [
    {'name': 'オリジナル', 'translated_name': '原创'},
    {'name': '風景', 'translated_name': '风景'},
    {'name': '光と影', 'translated_name': '光影'},
    {'name': 'イラスト', 'translated_name': '插画'},
  ];
  return json;
}

Map<String, dynamic> reviewNovelJson(int id, {bool bookmarked = false}) => {
  'id': id,
  'title': 'novel $id',
  'caption': 'caption $id',
  'restrict': 0,
  'x_restrict': 0,
  'is_original': false,
  'is_bookmarked': bookmarked,
  'text_length': 4000 + id,
  'total_bookmarks': 30 + id,
  'total_view': 200 + id,
  'total_comments': 3,
  'visible': true,
  'is_muted': false,
  'is_mypixiv_only': false,
  'is_x_restricted': false,
  'novel_ai_type': 0,
  'create_date': '2026-08-01T10:00:00+09:00',
  'user': {
    'id': 99,
    'name': 'author',
    'account': 'author',
    'profile_image_urls': {'medium': 'https://i.pximg.net/u.jpg'},
  },
  'tags': [
    {'name': '原创', 'translated_name': 'original'},
    {'name': 'fantasy'},
  ],
  'image_urls': {
    'square_medium': 'https://i.pximg.net/n$id/square.jpg',
    'medium': 'https://i.pximg.net/n$id/medium.jpg',
    'large': 'https://i.pximg.net/n$id/large.jpg',
  },
  'series': {'id': 77, 'title': 'series 77'},
};

/// The reader's novel: a title long enough to wrap in its title block.
Map<String, dynamic> reviewNovelDetailJson(int id) => {
  'novel': {...reviewNovelJson(id), 'title': '星の降る街で、きみと過ごした最後の夏の話 $id'},
};

const reviewIllustratedNovelId = 2100;
const reviewMarkedNovelId = 2101;

/// The `/webview/v2/novel` bootstrap page, same shape as
/// novel_webview_text_test's fixture: `Object.defineProperty` installs
/// `window.pixiv.novel`.
/// [reviewIllustratedNovelId] has an image after its first paragraph; every
/// novel links to its second page at the end of its first paragraph, turns
/// a page after its second and opens a chapter after its fourth.
/// [reviewMarkedNovelId] carries the account's bookmark on its second page.
String reviewNovelWebviewHtml(int id, {int paragraphs = 6}) {
  final illustrated = id == reviewIllustratedNovelId;
  final text = [
    '[chapter:第一章　はじまり]',
    for (var i = 0; i < paragraphs; i++) ...[
      '第${i + 1}段：novel $id 的正文内容。${i == 0 ? '[jump:2]' : ''}',
      if (illustrated && i == 0) '[uploadedimage:1]',
      if (i == 1) '[newpage]',
      if (i == 3) '[chapter:第二章　まちかど]',
    ],
  ].join('\n\n');
  final novel = jsonEncode({
    'id': '$id',
    'title': 'novel $id',
    'text': text,
    'userId': '99',
    'coverUrl': 'https://i.pximg.net/n$id/medium.jpg',
    'tags': ['原创', 'fantasy'],
    'caption': 'caption $id',
    if (illustrated)
      'images': {
        '1': {
          'urls': {'1200x1200': 'https://i.pximg.net/n$id/image-1.png'},
        },
      },
    if (id == reviewMarkedNovelId) 'marker': {'page': 2},
    'seriesNavigation': {
      'prev': {'id': '70', 'title': 'novel 70'},
      'next': {'id': '80', 'title': 'novel 80'},
    },
  });
  return '''
<!DOCTYPE html><html><head></head><body>
<script>
Object.defineProperty(window, 'pixiv', {value: {
  "context": {"csrfToken": "x"},
  "novel": $novel,
}, configurable: true, writable: true});
</script>
</body></html>
''';
}

Map<String, dynamic> reviewUserJson(int id) => {
  'id': id,
  'name': 'user $id',
  'account': 'user_$id',
  'profile_image_urls': {'medium': 'https://i.pximg.net/u$id.jpg'},
  'comment': 'bio of user $id',
};

Map<String, dynamic> reviewUserPreviewJson(int id) => {
  'user': reviewUserJson(id),
  'illusts': [reviewIllustJson(9000 + id), reviewIllustJson(9010 + id)],
  'novels': <Map<String, dynamic>>[],
  'is_muted': false,
};

/// Users without a cover, whose profile header takes their avatar's
/// ambient light: 701's avatar is colourful, 702's a neutral grey.
const reviewCoverlessUsers = {701, 702};
const _neutralAvatarUsers = {702};

Map<String, dynamic> reviewUserDetailJson(int id) => {
  'user': {
    ...reviewUserJson(id),
    'is_followed': false,
    'is_access_blocking_user': false,
  },
  'profile': {
    'webpage': 'https://example.com/u$id',
    'gender': 'unknown',
    'birth': '2000-01-01',
    'birth_day': '01-01',
    'birth_year': 2000,
    'region': 'Japan',
    'address_id': 42,
    'country_code': 'JP',
    'job': 'creator',
    'job_id': 1,
    'total_follow_users': 50,
    'total_mypixiv_users': 5,
    'total_illusts': 120,
    'total_manga': 10,
    'total_novels': 8,
    'total_illust_bookmarks_public': 200,
    'total_illust_series': 2,
    'total_novel_series': 1,
    'twitter_account': '',
    'twitter_url': '',
    'pawoo_url': '',
    'is_premium': false,
    'is_using_custom_profile_image': true,
    'background_image_url': reviewCoverlessUsers.contains(id)
        ? null
        : 'https://i.pximg.net/u$id/bg.jpg',
  },
  'profile_publicity': {
    'gender': 'public',
    'region': 'public',
    'birth_day': 'public',
    'birth_year': 'public',
    'job': 'public',
    'pawoo': 'public',
  },
  'workspace': {
    'pc': 'pc',
    'monitor': 'monitor',
    'tool': 'tool',
    'scanner': 'scanner',
    'tablet': 'tablet',
    'mouse': 'mouse',
    'printer': 'printer',
    'desktop': 'desktop',
    'music': 'music',
    'desk': 'desk',
    'chair': 'chair',
    'comment': 'workspace comment',
    'workspace_image_url': null,
  },
};

Map<String, dynamic> reviewCommentJson(
  int id,
  int workId, {
  String? stampUrl,
}) => {
  'id': id,
  'comment': 'comment $id on $workId',
  'date': '2026-09-01T10:00:00+09:00',
  // The signed-in reviewer (user 100) wrote comment 2.
  'user': reviewUserJson(id == 2 ? 100 : 7000 + id),
  'has_replies': id == 1,
  if (stampUrl != null) 'stamp': {'stamp_url': stampUrl},
};

Map<String, dynamic> reviewTrendTagJson(int id) => {
  'tag': 'tag$id',
  'translated_name': '翻译$id',
  'illust': reviewIllustJson(9500 + id),
};

Map<String, dynamic> reviewBookmarkTagJson(String tag) => {
  'name': tag,
  'count': 4,
};

Map<String, dynamic> reviewWatchlistJson(int id) => {
  'id': id,
  'title': 'watchlist series $id',
  'user': reviewUserJson(99),
  'latest_content_id': id + 600,
  'last_published_content_datetime':
      '2026-09-${(id % 28 + 1).toString().padLeft(2, '0')}T12:00:00+09:00',
  'published_content_count': id + 3,
  'url': 'https://i.pximg.net/w$id.jpg',
};

/// Five illusts then three novels in the signed-in account's history,
/// newest first.
List<HistoryRecord> reviewHistory() => [
  for (var i = 0; i < 5; i++)
    HistoryRecord(
      accountId: '100',
      contentType: HistoryContentType.illust,
      contentId: 1000 + i,
      lastViewedAt: DateTime(2026, 9, 30).subtract(Duration(hours: i)),
      snapshot: HistorySnapshot(
        title: 'illust ${1000 + i}',
        authorName: 'author',
        // As recorded from a work: its medium image.
        coverUrl: 'https://i.pximg.net/${1000 + i}/medium.jpg',
      ),
    ),
  for (var i = 0; i < 3; i++)
    HistoryRecord(
      accountId: '100',
      contentType: HistoryContentType.novel,
      contentId: 2000 + i,
      lastViewedAt: DateTime(2026, 9, 29).subtract(Duration(hours: i)),
      snapshot: HistorySnapshot(
        title: 'novel ${2000 + i}',
        authorName: 'author',
        coverUrl: 'https://i.pximg.net/n${2000 + i}/square.jpg',
      ),
    ),
];

/// Deterministic art: a gradient per picture, so shots show where each
/// image lands without real assets. Every size of one picture — square,
/// medium, large, original, a page's own URLs — shares its colours, as on
/// pixiv, so a hero flight or a medium-to-large swap does not change the
/// picture. The shape follows the fixtures: works are their 800×600
/// metadata, square crops and avatars square, covers and the rest portrait.
class ReviewImageBytes {
  ReviewImageBytes._();

  static final _cache = <String, Uint8List>{};

  static const _sizeNames = {
    'square', 'medium', 'large', 'original', 's', 'm', 'l', '360', '1200', //
  };

  static Uint8List forUrl(String url) =>
      _cache.putIfAbsent(url, () => _render(url));

  static (String tier, int targetMax) _tierFor(String file) => switch (file) {
    'original' => ('2400P', 2400),
    'large' || 'l' || '1200' => ('1200P', 1200),
    'medium' || 'm' => ('540P', 540),
    _ => ('360P', 360),
  };

  static (int, int) _scaledSize(int baseW, int baseH, int targetMax) {
    final longEdge = math.max(baseW, baseH);
    if (longEdge <= 0) return (targetMax, targetMax);
    final scale = targetMax / longEdge;
    final w = math.max(160, (baseW * scale).round());
    final h = math.max(160, (baseH * scale).round());
    return (w, h);
  }

  static Uint8List _render(String url) {
    final segments = Uri.parse(url).pathSegments;
    final file = segments.last.split('.').first;
    final workId = int.tryParse(segments.first);
    final isWork = workId != null;
    final picture = isWork
        ? '${segments.first}/${segments.length > 2 ? segments[1] : 'p0'}'
        : _sizeNames.contains(file)
        ? segments.take(segments.length - 1).join('/')
        : segments.join('/');
    final isAvatar = segments.length == 1 && file.startsWith('u');
    final isSquare = file == 'square' || file == 's' || isAvatar;
    final (tierLabel, targetMax) = isAvatar ? ('AVT', 300) : _tierFor(file);
    final (int baseW, int baseH) = isWork
        ? (reviewWorkShapes[workId] ??
              (_demoGalleryEnabled
                  ? (_demoWorkSpec(workId).width, _demoWorkSpec(workId).height)
                  : (800, 600)))
        : (300, 420);
    final (w, h) = isSquare
        ? (targetMax, targetMax)
        : isWork
        ? _scaledSize(baseW, baseH, targetMax)
        : _scaledSize(baseW, baseH, math.min(targetMax, 1200));

    final seed = picture.hashCode & 0xFFFFFF;
    final neutral =
        isAvatar &&
        _neutralAvatarUsers.contains(int.tryParse(file.substring(1)));
    if (_demoGalleryEnabled && !neutral) {
      final pageSeg = isWork && segments.length > 2 ? segments[1] : 'p0';
      final pageIndex = int.tryParse(pageSeg.replaceFirst('p', '')) ?? 0;
      final specIndex = isWork
          ? ((workId - 1000).abs() + pageIndex * 3) % _demoGalleryWorks.length
          : (int.tryParse(file.substring(isAvatar ? 1 : 0)) ?? seed) %
                _demoGalleryWorks.length;
      final spec = _demoGalleryWorks[specIndex];
      return _renderDemoArt(w, h, spec, isAvatar: isAvatar);
    }

    final hue = seed % 360;
    final top = neutral
        ? img.ColorRgb8(225, 225, 225)
        : img.ColorRgb8(
            60 + (hue * 2 % 140),
            80 + (hue * 5 % 120),
            120 + (hue * 3 % 120),
          );
    final bottom = neutral
        ? img.ColorRgb8(150, 150, 150)
        : img.ColorRgb8(
            40 + (hue * 7 % 100),
            60 + (hue * 4 % 110),
            90 + (hue * 6 % 130),
          );

    final image = img.Image(width: w, height: h);
    final bandStep = math.max(4, h ~/ 64);
    for (var y = 0; y < h; y += bandStep) {
      final t = y / math.max(1, h - 1);
      final r = (top.r + (bottom.r - top.r) * t).round();
      final g = (top.g + (bottom.g - top.g) * t).round();
      final b = (top.b + (bottom.b - top.b) * t).round();
      img.fillRect(
        image,
        x1: 0,
        y1: y,
        x2: w - 1,
        y2: math.min(h - 1, y + bandStep - 1),
        color: img.ColorRgb8(r, g, b),
      );
    }

    // Crisp geometric diagonal lines & rule-of-thirds alignment grid so
    // progressive resolution jumps (540P -> 1200P -> 2400P) stay legible.
    final gridColor = img.ColorRgba8(255, 255, 255, 110);
    final borderColor = img.ColorRgba8(255, 255, 255, 210);
    final stroke = w >= 1000 ? 2 : 1;
    final gridStep = math.max(48, w ~/ 8);
    for (var x = gridStep; x < w; x += gridStep) {
      img.drawLine(
        image,
        x1: x,
        y1: 0,
        x2: x,
        y2: h - 1,
        color: gridColor,
        thickness: stroke,
      );
    }
    for (var y = gridStep; y < h; y += gridStep) {
      img.drawLine(
        image,
        x1: 0,
        y1: y,
        x2: w - 1,
        y2: y,
        color: gridColor,
        thickness: stroke,
      );
    }
    img.drawLine(
      image,
      x1: 0,
      y1: 0,
      x2: w - 1,
      y2: h - 1,
      color: gridColor,
      thickness: stroke,
    );
    img.drawLine(
      image,
      x1: w - 1,
      y1: 0,
      x2: 0,
      y2: h - 1,
      color: gridColor,
      thickness: stroke,
    );
    final pad = math.max(6, w ~/ 40);
    img.drawRect(
      image,
      x1: pad,
      y1: pad,
      x2: w - 1 - pad,
      y2: h - 1 - pad,
      color: borderColor,
      thickness: stroke,
    );

    if (!isAvatar && w >= 200 && h >= 120) {
      final font = w >= 1000
          ? img.arial48
          : w >= 460
          ? img.arial24
          : img.arial14;
      final label = '$tierLabel ${w}x$h';
      final boxPad = w >= 1000 ? 18 : 10;
      final charW = w >= 1000
          ? 28
          : w >= 460
          ? 15
          : 9;
      final textH = w >= 1000
          ? 48
          : w >= 460
          ? 24
          : 14;
      final boxW = math.min(w - pad * 2, label.length * charW + boxPad * 2);
      final boxH = math.min(h - pad * 2, textH + boxPad * 2);
      final bx = pad + 4;
      final by = pad + 4;
      img.fillRect(
        image,
        x1: bx,
        y1: by,
        x2: bx + boxW,
        y2: by + boxH,
        color: img.ColorRgba8(18, 16, 22, 215),
      );
      img.drawString(
        image,
        label,
        font: font,
        x: bx + boxPad,
        y: by + boxPad,
        color: img.ColorRgb8(255, 255, 255),
      );
    }

    return Uint8List.fromList(img.encodePng(image, level: 1));
  }

  static Uint8List _renderDemoArt(
    int w,
    int h,
    _DemoWorkSpec spec, {
    required bool isAvatar,
  }) {
    final image = img.Image(width: w, height: h);
    final (tr, tg, tb) = spec.topColor;
    final (br, bg, bb) = spec.bottomColor;
    final (gr, gg, gb) = spec.glowColor;
    final (hr, hg, hb) = spec.horizonColor;

    final minDim = math.min(w, h).toDouble();
    final cx = w * spec.glowX;
    final cy = h * spec.glowY;
    final maxR = minDim * (isAvatar ? 0.64 : 0.56);
    final maxR2 = maxR * maxR;
    final coreR = minDim * (isAvatar ? 0.11 : 0.058);
    final coreInner = coreR * 0.72;
    final coreOuter = coreR * 1.32;
    final phase = spec.glowX * math.pi * 2;
    final hDenom = math.max(1, h - 1).toDouble();
    final wDenom = math.max(1, w - 1).toDouble();

    final farR = ((hr * 0.42 + br * 0.58)).roundToDouble();
    final farG = ((hg * 0.42 + bg * 0.58)).roundToDouble();
    final farB = ((hb * 0.42 + bb * 0.58)).roundToDouble();
    final midR = ((hr * 0.72 + br * 0.28)).roundToDouble();
    final midG = ((hg * 0.72 + bg * 0.28)).roundToDouble();
    final midB = ((hb * 0.72 + bb * 0.28)).roundToDouble();

    // Deterministic bokeh flecks for upper sky depth.
    final bokeh = <({double x, double y, double r, double strength})>[];
    if (!isAvatar) {
      var seed = (spec.title.hashCode ^ spec.author.hashCode) & 0x7fffffff;
      int nextInt() {
        seed = (seed * 1103515245 + 12345) & 0x7fffffff;
        return seed;
      }

      for (var i = 0; i < 24; i++) {
        final bx = (0.06 + (nextInt() % 880) / 1000.0) * w;
        final by = (0.06 + (nextInt() % 640) / 1000.0) * h;
        final radius = (minDim * (0.008 + (nextInt() % 18) / 1000.0)).clamp(
          3.0,
          26.0,
        );
        final strength = 0.08 + (nextInt() % 14) / 100.0;
        bokeh.add((x: bx, y: by, r: radius, strength: strength));
      }
    }

    // Continuous 1x1 gradient + radial glow + smooth celestial core.
    for (var y = 0; y < h; y++) {
      final ny = y / hDenom;
      final skyT = math.pow(ny, 1.06).toDouble();
      final mistBand = math.exp(-math.pow((ny - 0.72) / 0.16, 2));
      final baseR = tr + (br - tr) * skyT + (gr - br) * (mistBand * 0.14);
      final baseG = tg + (bg - tg) * skyT + (gg - bg) * (mistBand * 0.14);
      final baseB = tb + (bb - tb) * skyT + (gb - bb) * (mistBand * 0.14);
      final dy = y - cy;
      final dy2 = dy * dy;

      for (var x = 0; x < w; x++) {
        final dx = x - cx;
        final d2 = dx * dx + dy2;

        var pr = baseR;
        var pg = baseG;
        var pb = baseB;

        if (d2 < maxR2) {
          final dist = math.sqrt(d2);
          final u = 1.0 - dist / maxR;
          final halo = u * u * math.sqrt(u) * (isAvatar ? 0.68 : 0.56);
          pr = pr + (gr - pr) * halo;
          pg = pg + (gg - pg) * halo;
          pb = pb + (gb - pb) * halo;

          if (!isAvatar && dist < coreOuter) {
            final coreT =
                ((coreOuter - dist) / math.max(1e-3, coreOuter - coreInner))
                    .clamp(0.0, 1.0);
            final coreSmooth = coreT * coreT * (3.0 - 2.0 * coreT) * 0.78;
            final lumR = math.min(255.0, gr + 42.0);
            final lumG = math.min(255.0, gg + 42.0);
            final lumB = math.min(255.0, gb + 42.0);
            pr = pr + (lumR - pr) * coreSmooth;
            pg = pg + (lumG - pg) * coreSmooth;
            pb = pb + (lumB - pb) * coreSmooth;
          }
        }

        final dither = ((((x * 73) ^ (y * 151)) & 3) - 1.5) * 0.25;
        image.setPixelRgb(
          x,
          y,
          (pr + dither).round().clamp(0, 255),
          (pg + dither).round().clamp(0, 255),
          (pb + dither).round().clamp(0, 255),
        );
      }
    }

    if (!isAvatar) {
      // Soft glowing bokeh flecks in bounding boxes.
      for (final b in bokeh) {
        final minX = math.max(0, (b.x - b.r).floor());
        final maxX = math.min(w - 1, (b.x + b.r).ceil());
        final minY = math.max(0, (b.y - b.r).floor());
        final maxY = math.min(h - 1, (b.y + b.r).ceil());
        final r2 = b.r * b.r;
        final lr = math.min(255.0, gr * 0.45 + 255.0 * 0.55);
        final lg = math.min(255.0, gg * 0.45 + 255.0 * 0.55);
        final lb = math.min(255.0, gb * 0.45 + 255.0 * 0.55);
        for (var y = minY; y <= maxY; y++) {
          final dy = y - b.y;
          for (var x = minX; x <= maxX; x++) {
            final dx = x - b.x;
            final d2 = dx * dx + dy * dy;
            if (d2 >= r2) continue;
            final falloff = 1.0 - math.sqrt(d2) / b.r;
            final alpha = falloff * falloff * b.strength;
            final px = image.getPixel(x, y);
            image.setPixelRgb(
              x,
              y,
              (px.r + (lr - px.r) * alpha).round().clamp(0, 255),
              (px.g + (lg - px.g) * alpha).round().clamp(0, 255),
              (px.b + (lb - px.b) * alpha).round().clamp(0, 255),
            );
          }
        }
      }

      // Three anti-aliased atmospheric horizon ridge silhouettes.
      for (var x = 0; x < w; x++) {
        final nx = x / wDenom;
        final farY =
            h *
            (0.73 +
                0.042 * math.sin(nx * math.pi * 2.1 + phase) +
                0.018 * math.cos(nx * math.pi * 4.8));
        final midY =
            h *
            (0.80 +
                0.036 * math.cos(nx * math.pi * 2.7 + phase * 0.65) +
                0.016 * math.sin(nx * math.pi * 5.6 + 0.9));
        final nearY =
            h *
            (0.87 +
                0.028 * math.sin(nx * math.pi * 3.2 + phase * 1.1) +
                0.012 * math.cos(nx * math.pi * 6.4));

        final startY = math.max(0, farY.floor() - 1);
        for (var y = startY; y < h; y++) {
          final px = image.getPixel(x, y);
          var r = px.r.toDouble();
          var g = px.g.toDouble();
          var b = px.b.toDouble();

          final farCov = (y - farY + 0.5).clamp(0.0, 1.0) * 0.72;
          if (farCov > 0) {
            r = r + (farR - r) * farCov;
            g = g + (farG - g) * farCov;
            b = b + (farB - b) * farCov;
          }

          final midCov = (y - midY + 0.5).clamp(0.0, 1.0) * 0.84;
          if (midCov > 0) {
            r = r + (midR - r) * midCov;
            g = g + (midG - g) * midCov;
            b = b + (midB - b) * midCov;
          }

          final nearCov = (y - nearY + 0.5).clamp(0.0, 1.0) * 0.96;
          if (nearCov > 0) {
            r = r + (hr - r) * nearCov;
            g = g + (hg - g) * nearCov;
            b = b + (hb - b) * nearCov;
          }

          image.setPixelRgb(
            x,
            y,
            r.round().clamp(0, 255),
            g.round().clamp(0, 255),
            b.round().clamp(0, 255),
          );
        }
      }
    }

    return Uint8List.fromList(img.encodePng(image, level: 1));
  }
}
