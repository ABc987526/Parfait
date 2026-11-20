import '../../core/entity/illust_entity.dart';
import '../../core/search/search_models.dart';
import '../widgets/feed/illust_pager_source.dart';

/// In-memory route extra for pushing an artwork detail route.
class IllustRouteExtra {
  const IllustRouteExtra({
    this.entity,
    this.heroScope = 'feed',
    this.heroImageUrl,
    this.heroImageDecodeWidth,
    this.pagerSource,
  });

  final IllustEntity? entity;
  final String heroScope;
  final String? heroImageUrl;

  /// Decode width of the feed card that produced [heroImageUrl]. The detail
  /// page decodes its hero-phase image at this width so the first frame is
  /// the same cache entry the feed already painted.
  final int? heroImageDecodeWidth;

  /// The feed's ordered work list. Present ⇒ the route mounts the
  /// work-to-work pager instead of a single detail
  /// page. The object is in-memory only — never serialized into the URL.
  final IllustPagerSource? pagerSource;
}

/// How a novel opens. In-memory only: a restored reader opens at the
/// account's own place.
class NovelRouteExtra {
  const NovelRouteExtra({required this.atPixivPage});

  /// The Pixiv page (1-based) to open at, before any saved place: the
  /// account's bookmark, from the bookmark list.
  final int atPixivPage;
}

/// In-memory route extra for opening the fullscreen image viewer.
class ImageViewerRouteExtra {
  const ImageViewerRouteExtra({
    required this.urls,
    this.entity,
    this.heroScope,
    this.entryPage = 0,
  });

  final List<String> urls;
  final IllustEntity? entity;
  final String? heroScope;

  /// The page the viewer opened on. Only that page carries the Hero back:
  /// any other page's image is not where the detail page shows it, so the
  /// viewer slides away instead of shrinking to the wrong place.
  final int entryPage;
}

/// The docked panel's handed-over session (R10 narrow): the text exactly as
/// typed, the kind and the filter drafts cross the location as its extra.
class SearchInputDraft {
  const SearchInputDraft({
    required this.keyword,
    required this.type,
    this.illustFilters,
    this.novelFilters,
  });

  final String keyword;
  final SearchResultType type;
  final IllustSearchFilters? illustFilters;
  final NovelSearchFilters? novelFilters;
}
