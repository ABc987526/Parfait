import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../network/http_client_providers.dart';
import '../platform/local_network.dart';
import '../translation/translation_credentials.dart';
import '../translation/translation_service.dart';

/// Writes the next part of a work with the same OpenAI-compatible endpoint the
/// translation uses. Kept apart from the translation transports: it asks for
/// prose, not for a translation, so nothing it returns enters the translation
/// cache.
class NovelCompleter {
  NovelCompleter(this._client, this._store, this._localNetwork);

  static const _timeout = Duration(seconds: 180);
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
    final credentials = await _store.readLlm();
    if (credentials == null) {
      throw const TranslationUnavailable(TranslationFailureKind.notConfigured);
    }
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
      ..body = jsonEncode({
        'model': (credentials.model?.isEmpty ?? true)
            ? 'gpt-4o-mini'
            : credentials.model,
        'temperature': 0.8,
        'messages': [
          {'role': 'system', 'content': system},
          {'role': 'user', 'content': user},
        ],
      });
    final http.Response response;
    try {
      response = await http.Response.fromStream(
        await _client.send(request).timeout(_timeout),
      ).timeout(_timeout);
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
    if (response.bodyBytes.length > _maxResponseBytes) {
      throw const TranslationError(
        'novel completion response too large',
        TranslationFailureKind.malformed,
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
    final content = _contentOf(decoded);
    if (content == null) {
      throw const TranslationError(
        'malformed response',
        TranslationFailureKind.malformed,
      );
    }
    return content;
  }

  static String? _contentOf(Object? decoded) {
    if (decoded is! Map<String, dynamic>) return null;
    final choices = decoded['choices'];
    if (choices is! List || choices.isEmpty) return null;
    final first = choices.first;
    if (first is! Map<String, dynamic>) return null;
    final message = first['message'];
    if (message is! Map<String, dynamic>) return null;
    final content = message['content'];
    if (content is! String) return null;
    final text = content.trim();
    return text.isEmpty ? null : text;
  }
}

final novelCompleterProvider = Provider<NovelCompleter>((ref) {
  return NovelCompleter(
    ref.watch(thirdPartyHttpClientProvider),
    ref.watch(translationCredentialStoreProvider),
    ref.watch(localNetworkGateProvider),
  );
});
