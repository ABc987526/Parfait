import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../network/http_client_providers.dart';
import '../network/local_network_address.dart';
import '../platform/local_network.dart';
import '../translation/translation_credentials.dart';
import '../translation/translation_service.dart';

/// Writes the next part of a work with the same OpenAI-compatible endpoint the
/// translation uses. Kept apart from the translation transports: it asks for
/// prose, not for a translation, so nothing it returns enters the translation
/// cache.
class NovelCompleter {
  NovelCompleter(this._client, this._store, this._localNetwork);

  /// Waiting for the reply's headers; a cold model still loading shows up
  /// here rather than in the generation budget.
  static const _connectTimeout = Duration(seconds: 30);

  /// No byte for this long fails the request. A continuation is up to a few
  /// thousand characters, so silence is the only real failure.
  static const _stallTimeout = Duration(seconds: 180);

  static const _maxResponseBytes = 512 * 1024;

  final http.Client _client;
  final TranslationCredentialStore _store;
  final LocalNetworkGate _localNetwork;

  /// The next part of the work, given the text up to the start point, the
  /// user's direction and a rough length.
  Future<String> complete({
    required String context,
    required String direction,
    required int words,
    String? workPrompt,
  }) async {
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
    final system = [
      'You continue a novel, keeping its language, voice and point of view.',
      if (workPrompt != null && workPrompt.trim().isNotEmpty) workPrompt.trim(),
      'Return only the new prose: no title, no notes, no explanation, and do '
          'not repeat the text you were given.',
    ].join('\n\n');
    final user = [
      if (direction.trim().isNotEmpty)
        'Direction for the next part:\n${direction.trim()}',
      'Write about $words characters.',
      'The story so far, ending where the new part begins:\n$context',
    ].join('\n\n');
    final request = http.Request('POST', endpoint)
      ..headers['Content-Type'] = 'application/json'
      ..headers['Authorization'] = 'Bearer ${credentials.apiKey}'
      ..headers['User-Agent'] = 'Parfait/1.0'
      ..headers['Accept'] = 'text/event-stream'
      ..body = jsonEncode({
        'model': (credentials.model?.isEmpty ?? true)
            ? 'gpt-4o-mini'
            : credentials.model,
        'temperature': 0.8,
        // A few thousand characters of prose takes a local model minutes.
        // Reading the reply as it streams means only silence ends it.
        'stream': true,
        'messages': [
          {'role': 'system', 'content': system},
          {'role': 'user', 'content': user},
        ],
      });
    final http.StreamedResponse response;
    try {
      response = await _client.send(request).timeout(_connectTimeout);
    } on TimeoutException {
      throw const TranslationError(
        'novel completion timed out',
        TranslationFailureKind.network,
      );
    } on SocketException {
      throw const TranslationError(
        'novel completion network failure',
        TranslationFailureKind.network,
      );
    } on http.ClientException {
      throw const TranslationError(
        'novel completion network failure',
        TranslationFailureKind.network,
      );
    }
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const TranslationError(
        'LLM credentials invalid',
        TranslationFailureKind.invalidCredentials,
      );
    }
    if (response.statusCode == 429) {
      throw const TranslationError(
        'LLM rate limited',
        TranslationFailureKind.rateLimited,
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw const TranslationError(
        'LLM http failure',
        TranslationFailureKind.network,
      );
    }
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
            'novel completion response too large',
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
        final piece = llmStreamedDelta(payload);
        if (piece != null) answer.write(piece);
      }
    } on TimeoutException {
      throw const TranslationError(
        'novel completion stalled',
        TranslationFailureKind.network,
      );
    } on SocketException {
      throw const TranslationError(
        'novel completion network failure',
        TranslationFailureKind.network,
      );
    } on http.ClientException {
      throw const TranslationError(
        'novel completion network failure',
        TranslationFailureKind.network,
      );
    }
    var text = streamed && answer.isNotEmpty ? answer.toString().trim() : '';
    if (text.isEmpty) {
      final Object? decoded;
      try {
        decoded = jsonDecode(raw.toString());
      } on FormatException {
        throw const TranslationError(
          'malformed response',
          TranslationFailureKind.malformed,
        );
      }
      text = llmMessageContent(decoded) ?? '';
    }
    if (text.isEmpty) {
      throw const TranslationError(
        'malformed response',
        TranslationFailureKind.malformed,
      );
    }
    return text;
  }
}

final novelCompleterProvider = Provider<NovelCompleter>((ref) {
  return NovelCompleter(
    ref.watch(thirdPartyHttpClientProvider),
    ref.watch(translationCredentialStoreProvider),
    ref.watch(localNetworkGateProvider),
  );
});
