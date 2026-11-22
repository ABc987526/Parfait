import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../localnovel/local_novel_repository.dart';
import '../network/http_client_providers.dart';
import '../network/local_network_address.dart';
import '../platform/local_network.dart';
import '../settings/app_settings.dart';
import '../settings/settings_controller.dart';
import 'index_translate_translation.dart';
import 'translation_credentials.dart';
import 'translation_transport.dart';

export 'translation_transport.dart';

/// Google gtx compatibility path. Retained for users who explicitly saved
/// Google before (D2); there is no automatic provider fallback.
class GoogleTranslationTransport
    with SequentialBatchTranslation
    implements TranslationTransport {
  GoogleTranslationTransport(this._client);

  static const _host = 'translate.googleapis.com';
  static const _timeout = Duration(seconds: 15);

  final http.Client _client;

  @override
  Future<String> translate(
    String text, {
    required String targetLanguage,
  }) async {
    final source = text.trim();
    if (source.isEmpty) {
      throw const TranslationError('empty source text');
    }
    final target = targetLanguage.trim().toLowerCase();
    if (!RegExp(r'^[a-z]{2,3}(?:-[a-z]{2,4})?$').hasMatch(target)) {
      throw const TranslationError(
        'invalid target language',
        TranslationFailureKind.unsupportedLanguage,
      );
    }
    final http.Response response;
    try {
      response = await _client
          .get(
            Uri.https(_host, '/translate_a/single', {
              'client': 'gtx',
              'dt': 't',
              'sl': 'auto',
              'tl': target,
              'q': source,
            }),
          )
          .timeout(_timeout);
    } on TimeoutException {
      throw const TranslationError(
        'translation timed out',
        TranslationFailureKind.network,
      );
    } on SocketException {
      throw const TranslationError(
        'translation network failure',
        TranslationFailureKind.network,
      );
    } on http.ClientException {
      throw const TranslationError(
        'translation network failure',
        TranslationFailureKind.network,
      );
    }
    if (response.statusCode == 429) {
      throw const TranslationError(
        'translation rate limited',
        TranslationFailureKind.rateLimited,
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw const TranslationError(
        'translation http failure',
        TranslationFailureKind.network,
      );
    }
    final dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw const TranslationError(
        'malformed response',
        TranslationFailureKind.malformed,
      );
    }
    if (decoded is! List || decoded.isEmpty || decoded.first is! List) {
      throw const TranslationError(
        'malformed response',
        TranslationFailureKind.malformed,
      );
    }
    final translations = decoded.first as List;
    final parts = <String>[];
    for (final item in translations) {
      if (item is List && item.isNotEmpty && item.first is String) {
        parts.add(item.first as String);
      }
    }
    final result = parts.join();
    if (result.trim().isEmpty) {
      throw const TranslationError(
        'empty translation',
        TranslationFailureKind.malformed,
      );
    }
    return result;
  }
}

/// Baidu general translation (D2): AppID + secret from the isolated secure
/// store, standard MD5 signature, HTTPS form post. AppID/secret only exist
/// inside this request scope.
class BaiduTranslationTransport
    with SequentialBatchTranslation
    implements TranslationTransport {
  BaiduTranslationTransport(this._client, this._now, this._store);

  static const _host = 'https://fanyi-api.baidu.com/api/trans/vip/translate';
  static const _timeout = Duration(seconds: 15);

  /// Quotas (re-verified 2026-09-07, see the task research file): the
  /// standard tier gives 50k characters/month at QPS 1 without real-name
  /// verification; the premium tier gives 1M characters/month at QPS 10 and
  /// requires personal real-name verification. Nothing here displays these
  /// numbers; the settings hint carries its own copy.
  static const int _maxBodyBytes = 512 * 1024;

  final http.Client _client;
  final DateTime Function() _now;
  final TranslationCredentialStore _store;

  @override
  Future<String> translate(
    String text, {
    required String targetLanguage,
  }) async {
    final source = text.trim();
    if (source.isEmpty) {
      throw const TranslationError('empty source text');
    }
    if (utf8.encode(source).length > _maxBodyBytes) {
      throw const TranslationError('source text is too long');
    }
    final target = _targetCode(targetLanguage);
    final credentials = await _store.readBaidu();
    if (credentials == null) {
      throw const TranslationUnavailable(TranslationFailureKind.notConfigured);
    }
    final salt = _now().millisecondsSinceEpoch.toString();
    final sign = md5
        .convert(
          utf8.encode('${credentials.appId}$source$salt${credentials.secret}'),
        )
        .toString();

    final http.Response response;
    try {
      response = await _client
          .post(
            Uri.parse(_host),
            headers: const {
              'Content-Type': 'application/x-www-form-urlencoded',
              'User-Agent': 'Parfait/1.0',
            },
            body: {
              'q': source,
              'from': 'auto',
              'to': target,
              'appid': credentials.appId,
              'salt': salt,
              'sign': sign,
            },
          )
          .timeout(_timeout);
    } on TimeoutException {
      throw const TranslationError(
        'translation timed out',
        TranslationFailureKind.network,
      );
    } on SocketException {
      throw const TranslationError(
        'translation network failure',
        TranslationFailureKind.network,
      );
    } on http.ClientException {
      throw const TranslationError(
        'translation network failure',
        TranslationFailureKind.network,
      );
    }
    if (response.statusCode == 429) {
      throw const TranslationError(
        'baidu rate limited',
        TranslationFailureKind.rateLimited,
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw const TranslationError(
        'baidu http failure',
        TranslationFailureKind.network,
      );
    }
    final dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw const TranslationError(
        'malformed response',
        TranslationFailureKind.malformed,
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw const TranslationError(
        'malformed response',
        TranslationFailureKind.malformed,
      );
    }
    final Object? errorCode = decoded['error_code'];
    if (errorCode != null) {
      throw _mapBaiduError(errorCode);
    }
    final results = decoded['trans_result'];
    if (results is! List || results.isEmpty) {
      throw const TranslationError(
        'empty translation',
        TranslationFailureKind.malformed,
      );
    }
    final parts = <String>[];
    for (final entry in results) {
      if (entry is! Map<String, dynamic>) continue;
      final dst = entry['dst'];
      if (dst is String && dst.trim().isNotEmpty) parts.add(dst);
    }
    final result = parts.join('\n').trim();
    if (result.isEmpty) {
      throw const TranslationError(
        'empty translation',
        TranslationFailureKind.malformed,
      );
    }
    return result;
  }

  TranslationError _mapBaiduError(Object errorCode) {
    switch (errorCode.toString()) {
      case '52003':
      case '54001':
      case '54002':
      case '90107':
        return const TranslationError(
          'baidu credentials invalid',
          TranslationFailureKind.invalidCredentials,
        );
      case '54003':
      case '54005':
        return const TranslationError(
          'baidu rate limited',
          TranslationFailureKind.rateLimited,
        );
      case '54000':
      case '54004':
        return const TranslationError(
          'baidu quota exhausted',
          TranslationFailureKind.rateLimited,
        );
      case '58002':
        return const TranslationError(
          'baidu service closed',
          TranslationFailureKind.other,
        );
      default:
        return TranslationError(
          'baidu error $errorCode',
          TranslationFailureKind.other,
        );
    }
  }

  static String _targetCode(String targetLanguage) {
    // The map is closed: unsupported targets are visible, not silently
    // translated into a wrong language.
    switch (targetLanguage.trim().toLowerCase()) {
      case 'zh':
      case 'zh-cn':
      case 'zh-tw':
        return 'zh';
      case 'en':
        return 'en';
      case 'ja':
      case 'ja-jp':
        return 'jp';
      case 'ko':
        return 'kor';
      case 'fr':
        return 'fra';
      case 'es':
        return 'spa';
      case 'it':
        return 'it';
      case 'de':
        return 'de';
      case 'pt':
        return 'pt';
      case 'ru':
        return 'ru';
      case 'nl':
        return 'nl';
      case 'pl':
        return 'pl';
      case 'tr':
        return 'tr';
      case 'ar':
        return 'ara';
      case 'vi':
        return 'vie';
      case 'th':
        return 'th';
      case 'id':
        return 'id';
      default:
        throw const TranslationError(
          'unsupported target language',
          TranslationFailureKind.unsupportedLanguage,
        );
    }
  }
}

/// OpenAI-compatible chat completions transport (D2): HTTP(S), fixed system
/// prompt, zero configurable prompt/model advanced parameters.
///
/// Plain HTTP is accepted because a model server on the user's own network
/// usually offers no certificate the app can verify; the key then travels in
/// clear text to that host only.
class LlmTranslationTransport
    with SequentialBatchTranslation
    implements TranslationTransport {
  LlmTranslationTransport(this._client, this._store, this._localNetwork);

  /// Waiting for the reply's headers. A local model that is still loading
  /// shows up here, not in the generation budget.
  static const _connectTimeout = Duration(seconds: 30);

  /// No byte for this long fails the request: a model that is still
  /// generating keeps the connection busy, a dead one goes quiet.
  static const _stallTimeout = Duration(seconds: 120);

  static const _maxResponseBytes = 256 * 1024;

  /// Source characters per batch request. A page's answer from a local model
  /// takes minutes; keeping each request this small keeps one slow chunk from
  /// costing the whole page.
  static const _batchMaxChars = 1500;
  static const _basePrompt =
      'You are a translation engine for Pixiv text. Translate the user '
      'text into the requested language. Return only the translation with no '
      'quotes, no notes, no explanation. Preserve emoticons, line breaks, '
      'emoji and punctuation.';

  final http.Client _client;
  final TranslationCredentialStore _store;

  /// The endpoint can be a model server on the user's own network.
  final LocalNetworkGate _localNetwork;

  /// Extra instructions the user typed come with the stored credentials, so
  /// an edit applies to the next request without restarting anything. They
  /// follow the fixed contract instead of replacing it, so the answer stays
  /// a bare translation.
  static String _systemPrompt(String? extra) {
    if (extra == null || extra.isEmpty) return _basePrompt;
    return '$_basePrompt\n\nAdditional requirements from the user. Keep the '
        'output format described above (the translation only):\n$extra';
  }

  @override
  Future<String> translate(
    String text, {
    required String targetLanguage,
  }) async {
    final source = text.trim();
    if (source.isEmpty) {
      throw const TranslationError('empty source text');
    }
    final target = targetLanguage.trim().toLowerCase();
    if (!RegExp(r'^[a-z]{2,3}(?:-[a-z]{2,4})?$').hasMatch(target)) {
      throw const TranslationError(
        'invalid target language',
        TranslationFailureKind.unsupportedLanguage,
      );
    }
    // A saved server wins; otherwise the bundled endpoint answers, so
    // translation works before the user configures anything.
    final credentials = await resolveLlmCredentials(_store);
    final endpoint = llmChatCompletionsEndpoint(credentials.baseUrl);
    if (endpoint == null) {
      throw const TranslationError(
        'LLM endpoint is not an HTTP(S) URL',
        TranslationFailureKind.invalidCredentials,
      );
    }
    try {
      await _localNetwork.ensure(endpoint.host);
    } on LocalNetworkBlocked {
      throw const TranslationError(
        'LLM endpoint on the local network is not allowed',
        TranslationFailureKind.localNetwork,
      );
    }
    return _chat(
      endpoint: endpoint,
      credentials: credentials,
      temperature: 0.2,
      messages: [
        {'role': 'system', 'content': _systemPrompt(credentials.prompt)},
        {
          'role': 'user',
          'content': _userPrompt(
            target: target,
            source: source,
            extra: credentials.prompt,
          ),
        },
      ],
    );
  }

  /// The user turn repeats the requirements because not every server keeps
  /// the system message: Gemma's chat template has no system role, so a local
  /// runtime may merge or drop it, and the prompt would read as unused.
  static String _userPrompt({
    required String target,
    required String source,
    required String? extra,
  }) {
    final requirement = extra?.trim() ?? '';
    final style = requirement.isEmpty
        ? ''
        : '\nRequirements for this translation: $requirement';
    return 'Translate into ${_languageName(target)}. Return only the '
        'translation, never the source unchanged.$style\n\n'
        '$source';
  }

  /// The language a target code names, in words a model understands: a local
  /// Gemma does not reliably know that `zh` means Chinese, and answers with
  /// the source unchanged when it is asked to translate "into zh".
  static String _languageName(String code) => switch (code) {
    'zh' || 'zh-cn' || 'zh-hans' => 'Chinese (简体中文)',
    'zh-tw' || 'zh-hant' => 'Traditional Chinese (繁體中文)',
    'en' => 'English',
    'ja' => 'Japanese (日本語)',
    'ru' => 'Russian (русский)',
    'ko' => 'Korean (한국어)',
    'fr' => 'French (français)',
    'de' => 'German (Deutsch)',
    'es' => 'Spanish (español)',
    'pt' => 'Portuguese (português)',
    'it' => 'Italian (italiano)',
    'ar' => 'Arabic (العربية)',
    'th' => 'Thai (ไทย)',
    'vi' => 'Vietnamese (Tiếng Việt)',
    'id' => 'Indonesian (Bahasa Indonesia)',
    _ => code,
  };

  /// A page's paragraphs in a few round trips: the model answers with the same
  /// `[[n]]` markers, and a batch that comes back incomplete falls back to the
  /// per-item path rather than showing a half-translated page.
  ///
  /// The page is split by source length: a local model on a 16 GB card spends
  /// minutes generating one big answer, and one stalled chunk should not take
  /// the whole page with it.
  ///
  /// Only the LLM transport batches: Google's and Baidu's endpoints take one
  /// text per call, and Index Translate's public contract does too.
  @override
  Future<List<String>> translateAll(
    List<String> texts, {
    required String targetLanguage,
  }) async {
    final sources = [for (final text in texts) text.trim()];
    final filled = [
      for (final text in sources)
        if (text.isNotEmpty) text,
    ];
    if (filled.length < 2) {
      return super.translateAll(texts, targetLanguage: targetLanguage);
    }
    var translated = const <String>[];
    try {
      final target = _languageName(_targetOf(targetLanguage));
      translated = [
        for (final chunk in _chunks(filled))
          ...await _translateChunk(chunk, target, targetLanguage),
      ];
    } on TranslationError catch (error) {
      // A wrong key, a rate limit or a network failure fails the same way one
      // request per paragraph, so it is not worth another round trip.
      if (error.kind == TranslationFailureKind.invalidCredentials ||
          error.kind == TranslationFailureKind.rateLimited ||
          error.kind == TranslationFailureKind.network) {
        rethrow;
      }
      return super.translateAll(texts, targetLanguage: targetLanguage);
    } on Object {
      return super.translateAll(texts, targetLanguage: targetLanguage);
    }
    final out = <String>[];
    var next = 0;
    for (final source in sources) {
      out.add(source.isEmpty ? '' : translated[next++]);
    }
    return out;
  }

  /// One chunk, in one request when it holds more than one segment. A
  /// one-segment chunk is just [translate]: a batch marker would cost more
  /// prompt than it saves.
  Future<List<String>> _translateChunk(
    List<String> chunk,
    String target,
    String targetLanguage,
  ) async {
    if (chunk.length == 1) {
      return [await translate(chunk.single, targetLanguage: targetLanguage)];
    }
    final numbered = [
      for (final (index, text) in chunk.indexed) '[[${index + 1}]]\n$text',
    ].join('\n\n');
    final answer = await _batchRequest(
      'Translate every segment below into $target. Keep each [[n]] marker '
      'at the start of its translated segment, in order, and return no '
      'commentary:\n\n$numbered',
    );
    final segments = _splitNumbered(answer);
    if (segments.length != chunk.length) {
      return [
        for (final text in chunk)
          await translate(text, targetLanguage: targetLanguage),
      ];
    }
    return segments;
  }

  /// Splits [texts] into groups whose sources stay under [_batchMaxChars].
  static List<List<String>> _chunks(List<String> texts) {
    final chunks = <List<String>>[];
    var current = <String>[];
    var chars = 0;
    for (final text in texts) {
      if (current.isNotEmpty && chars + text.length > _batchMaxChars) {
        chunks.add(current);
        current = [];
        chars = 0;
      }
      current.add(text);
      chars += text.length;
    }
    if (current.isNotEmpty) chunks.add(current);
    return chunks;
  }

  static String _targetOf(String targetLanguage) {
    final target = targetLanguage.trim().toLowerCase();
    if (!RegExp(r'^[a-z]{2,3}(?:-[a-z]{2,4})?$').hasMatch(target)) {
      throw const TranslationError(
        'invalid target language',
        TranslationFailureKind.unsupportedLanguage,
      );
    }
    return target;
  }

  /// Splits an answer written with `[[n]]` markers into its segments. The
  /// markers must run 1..n in order: a model that renumbers or reorders them
  /// gets no answer, and the caller falls back to one request per paragraph
  /// rather than pairing the wrong translation with a paragraph.
  static List<String> _splitNumbered(String text) {
    final matches = RegExp(r'\[\[(\d+)\]\]').allMatches(text).toList();
    if (matches.isEmpty) return const [];
    final out = <String>[];
    for (var i = 0; i < matches.length; i++) {
      if (int.tryParse(matches[i].group(1) ?? '') != i + 1) return const [];
      out.add(
        text
            .substring(
              matches[i].end,
              i + 1 < matches.length ? matches[i + 1].start : text.length,
            )
            .trim(),
      );
    }
    return out;
  }

  /// One batch round trip. Same setup as [translate] plus the batching rule;
  /// kept apart so a batch failure can fall back without touching the
  /// single-text path.
  Future<String> _batchRequest(String userText) async {
    // A saved server wins; otherwise the bundled endpoint answers, so
    // translation works before the user configures anything.
    final credentials = await resolveLlmCredentials(_store);
    final endpoint = llmChatCompletionsEndpoint(credentials.baseUrl);
    if (endpoint == null) {
      throw const TranslationError(
        'LLM endpoint is not an HTTP(S) URL',
        TranslationFailureKind.invalidCredentials,
      );
    }
    try {
      await _localNetwork.ensure(endpoint.host);
    } on LocalNetworkBlocked {
      throw const TranslationError(
        'LLM endpoint on the local network is not allowed',
        TranslationFailureKind.localNetwork,
      );
    }
    final system =
        '${_systemPrompt(credentials.prompt)}\n\nA user message with '
        '[[n]]-marked segments must be answered with the same markers, one '
        'translated segment each.';
    final requirement = credentials.prompt?.trim() ?? '';
    final user = requirement.isEmpty
        ? userText
        : 'Requirements for the translation: $requirement\n\n$userText';
    return _chat(
      endpoint: endpoint,
      credentials: credentials,
      temperature: 0.2,
      messages: [
        {'role': 'system', 'content': system},
        {'role': 'user', 'content': user},
      ],
    );
  }

  /// One chat completion, read as it arrives.
  ///
  /// The reply is streamed instead of awaited whole: a 26B model on a 16 GB
  /// card needs minutes for a page, and a total timeout killed exactly the
  /// requests that were still producing tokens — which also left the server
  /// generating for a client that had already given up. [_stallTimeout] only
  /// fires when the connection goes silent, so a slow answer survives and a
  /// dead one still ends.
  Future<String> _chat({
    required Uri endpoint,
    required LlmTranslationCredentials credentials,
    required double temperature,
    required List<Map<String, String>> messages,
  }) async {
    final request = http.Request('POST', endpoint)
      ..headers['Content-Type'] = 'application/json'
      ..headers['Authorization'] = 'Bearer ${credentials.apiKey}'
      ..headers['User-Agent'] = 'Parfait/1.0'
      ..headers['Accept'] = 'text/event-stream'
      ..body = jsonEncode({
        'model': (credentials.model?.isEmpty ?? true)
            ? 'gpt-4o-mini'
            : credentials.model,
        'temperature': temperature,
        'stream': true,
        'messages': messages,
      });
    final http.StreamedResponse response;
    try {
      response = await _client.send(request).timeout(_connectTimeout);
    } on TimeoutException {
      throw const TranslationError(
        'translation timed out',
        TranslationFailureKind.network,
      );
    } on SocketException {
      throw const TranslationError(
        'translation network failure',
        TranslationFailureKind.network,
      );
    } on http.ClientException {
      throw const TranslationError(
        'translation network failure',
        TranslationFailureKind.network,
      );
    }
    _checkStatus(response.statusCode);
    final answer = StringBuffer();
    final raw = StringBuffer();
    var streamed = false;
    var seen = 0;
    try {
      await for (final line
          in response.stream
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .timeout(_stallTimeout)) {
        seen += line.length;
        if (seen > _maxResponseBytes) {
          throw const TranslationError(
            'LLM response too large',
            TranslationFailureKind.malformed,
          );
        }
        final trimmed = line.trim();
        if (!trimmed.startsWith('data:')) {
          raw.writeln(line);
          continue;
        }
        streamed = true;
        final payload = trimmed.substring(5).trim();
        if (payload.isEmpty) continue;
        if (payload == '[DONE]') break;
        final piece = _deltaContent(payload);
        if (piece != null) answer.write(piece);
      }
    } on TimeoutException {
      throw const TranslationError(
        'LLM reply stalled',
        TranslationFailureKind.network,
      );
    } on SocketException {
      throw const TranslationError(
        'translation network failure',
        TranslationFailureKind.network,
      );
    } on http.ClientException {
      throw const TranslationError(
        'translation network failure',
        TranslationFailureKind.network,
      );
    }
    // A server that ignored `stream` answers with one JSON body: read that
    // instead of failing an otherwise good reply.
    final text = streamed && answer.isNotEmpty
        ? answer.toString().trim()
        : (_nonStreamed(raw.toString()) ?? '').trim();
    if (text.isEmpty) {
      throw const TranslationError(
        'malformed response',
        TranslationFailureKind.malformed,
      );
    }
    return text;
  }

  static void _checkStatus(int statusCode) {
    if (statusCode == 401 || statusCode == 403) {
      throw const TranslationError(
        'LLM credentials invalid',
        TranslationFailureKind.invalidCredentials,
      );
    }
    if (statusCode == 429) {
      throw const TranslationError(
        'LLM rate limited',
        TranslationFailureKind.rateLimited,
      );
    }
    if (statusCode < 200 || statusCode >= 300) {
      throw const TranslationError(
        'LLM http failure',
        TranslationFailureKind.network,
      );
    }
  }

  /// The text one streamed chunk carries: OpenAI sends it under `delta`, a
  /// server that ignored streaming sends the whole `message` once.
  static String? _deltaContent(String payload) => llmStreamedDelta(payload);

  static String? _nonStreamed(String body) {
    if (body.trim().isEmpty) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      return null;
    }
    return _extractContent(decoded);
  }

  static String? _extractContent(Object? decoded) => llmMessageContent(decoded);
}

/// The text a streamed chat chunk carries, or null when the chunk holds no
/// text (a role-only opener, a keep-alive, a malformed line). Both `delta` and
/// `message` are read: a server that ignored `stream` answers once with the
/// whole message.
String? llmStreamedDelta(String payload) {
  final Object? decoded;
  try {
    decoded = jsonDecode(payload);
  } on FormatException {
    return null;
  }
  if (decoded is! Map<String, dynamic>) return null;
  final choices = decoded['choices'];
  if (choices is! List || choices.isEmpty) return null;
  final first = choices.first;
  if (first is! Map<String, dynamic>) return null;
  for (final key in const ['delta', 'message']) {
    final part = first[key];
    if (part is! Map<String, dynamic>) continue;
    final content = part['content'];
    if (content is String && content.isNotEmpty) return content;
  }
  return null;
}

/// The text of a whole chat completion body, or null when it holds none.
String? llmMessageContent(Object? decoded) {
  if (decoded is! Map<String, dynamic>) return null;
  final choices = decoded['choices'];
  if (choices is! List || choices.isEmpty) return null;
  final first = choices.first;
  if (first is! Map<String, dynamic>) return null;
  final message = first['message'];
  if (message is! Map<String, dynamic>) return null;
  final content = message['content'];
  if (content is! String) return null;
  final trimmed = content.trim();
  return trimmed.isEmpty ? null : trimmed;
}

final translationServiceProvider = Provider<TranslationTransport>((ref) {
  final client = ref.watch(thirdPartyHttpClientProvider);
  final store = ref.watch(translationCredentialStoreProvider);
  return ConfiguredTranslationService(
    resolveProvider: () => ref.read(_translationSelectionProvider),
    google: GoogleTranslationTransport(client),
    baidu: BaiduTranslationTransport(client, DateTime.now, store),
    llm: LlmTranslationTransport(
      client,
      store,
      ref.watch(localNetworkGateProvider),
    ),
    indexTranslate: IndexTranslateTranslationTransport(
      client,
      model: ref.watch(indexTranslateModelProvider),
      enableThinking: ref.watch(indexTranslateThinkingProvider),
    ),
  );
});

/// Isolated secure storage for translation credentials (D2). A single
/// instance shared by the settings UI and the transports.
final translationCredentialStoreProvider = Provider<TranslationCredentialStore>(
  (ref) => SecureTranslationCredentialStore(),
);

/// Fingerprint of the translation configuration, so a cached translation is
/// reused only under the engine and tuning that produced it: another model,
/// another prompt or another provider starts a fresh cache.
/// Fingerprint of the translation configuration for one work, so a cached
/// translation is reused only under the engine and tuning that produced it:
/// another model, another global prompt, another provider, or this work's own
/// prompt starting or changing all start a fresh cache.
final translationEngineSignatureProvider = FutureProvider.family<String, int>((
  ref,
  novelId,
) async {
  final settings = ref.watch(settingsProvider).value;
  final provider =
      settings?.translationProvider ?? TranslationProvider.translationLlm;
  switch (provider) {
    case TranslationProvider.translationLlm:
      final credentials = await resolveLlmCredentials(
        ref.watch(translationCredentialStoreProvider),
      );
      final own = await ref
          .watch(localNovelRepositoryProvider)
          .readNovelPrompt(novelId);
      final model = credentials.model ?? '';
      final tuning =
          '${credentials.baseUrl}\u0000${credentials.prompt ?? ''}\u0000'
          '${own ?? ''}';
      return 'llm:$model:${_shortDigest(tuning)}';
    case TranslationProvider.indexTranslate:
      final model = settings?.indexTranslateModel.name ?? '';
      final thinking = settings?.indexTranslateThinking ?? false;
      return 'index:$model:$thinking';
    case TranslationProvider.baidu:
      return 'baidu';
    case TranslationProvider.google:
      return 'google';
    case TranslationProvider.disabled:
      return 'disabled';
  }
});

String _shortDigest(String value) {
  if (value.isEmpty) return 'none';
  return sha1.convert(utf8.encode(value)).toString().substring(0, 8);
}

/// Live translation provider selection (non-secret). A cleared credential is
/// observed on the next tap because selection and credentials are read per
/// request.
final _translationSelectionProvider = Provider<TranslationProvider>((ref) {
  return ref.watch(settingsProvider).value?.translationProvider ??
      TranslationProvider.translationLlm;
});

class ConfiguredTranslationService implements TranslationTransport {
  ConfiguredTranslationService({
    required this.resolveProvider,
    required this.google,
    required this.baidu,
    required this.llm,
    required this.indexTranslate,
  });

  final TranslationProvider Function() resolveProvider;
  final TranslationTransport google;
  final TranslationTransport baidu;
  final TranslationTransport llm;
  final TranslationTransport indexTranslate;

  @override
  Future<String> translate(
    String text, {
    required String targetLanguage,
  }) async => _selected().translate(text, targetLanguage: targetLanguage);

  @override
  Future<List<String>> translateAll(
    List<String> texts, {
    required String targetLanguage,
  }) async => _selected().translateAll(texts, targetLanguage: targetLanguage);

  /// Throws [TranslationUnavailable] when translation is switched off.
  TranslationTransport _selected() => switch (resolveProvider()) {
    TranslationProvider.disabled => throw const TranslationUnavailable(
      TranslationFailureKind.disabled,
    ),
    TranslationProvider.google => google,
    TranslationProvider.baidu => baidu,
    TranslationProvider.translationLlm => llm,
    TranslationProvider.indexTranslate => indexTranslate,
  };
}
