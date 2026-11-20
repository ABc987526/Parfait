import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parfait/core/novel/novel_repository.dart';

import 'illust_fixtures.dart';
import 'json_response.dart';

/// The novel ranking endpoint: two novels a page, a second page after the
/// first, and a next_url echoing the request's mode (or
/// [mismatchedNextMode]) and date.
class NovelRankingFixture {
  final requests = <Uri>[];
  NovelRankingMode? mismatchedNextMode;

  http.Client client() => MockClient((request) async {
    requests.add(request.url);
    final mode = request.url.queryParameters['mode']!;
    final isFirst = request.url.queryParameters['offset'] == null;
    final start = isFirst ? 1 : 3;
    final nextMode = mismatchedNextMode?.apiValue ?? mode;
    // Pixiv echoes a past ranking's date into next_url.
    final date = request.url.queryParameters['date'];
    return jsonResponse({
      'novels': [
        for (var id = start; id < start + 2; id++)
          novelJson(id, title: 'novel ranking $id'),
      ],
      'next_url': isFirst
          ? 'https://app-api.pixiv.net/v1/novel/ranking'
                '?filter=for_android&mode=$nextMode'
                '${date == null ? '' : '&date=$date'}&offset=30'
          : null,
    });
  });
}
