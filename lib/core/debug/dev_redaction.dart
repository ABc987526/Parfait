const String kRedactedPlaceholder = '[REDACTED]';

final _bearerPattern = RegExp(
  r'\bBearer\s+[A-Za-z0-9._~+/=-]+',
  caseSensitive: false,
);
final _cookieHeaderPattern = RegExp(
  r'(?:^|(?<=[\s]))(set-cookie|cookie)\s*:\s*[^\r\n]+',
  caseSensitive: false,
);
final _authHeaderPattern = RegExp(
  r'''(?:^|(?<=[\s]))((?:proxy-)?authorization)\s*:\s*(?:(?:Bearer|Basic|Token|Digest)\s+)?[^\s\r\n"']+''',
  caseSensitive: false,
);
final _apiKeyHeaderPattern = RegExp(
  r'''(?:^|(?<=[\s]))(x-parfait-workbench-token|x-api-key)\s*:\s*[^\s\r\n"']+''',
  caseSensitive: false,
);
final _querySecretPattern = RegExp(
  r'''([A-Za-z0-9_.-]*(?:access_?token|refresh_?token|id_?token|code_?verifier|phpsessid|api_?key|apikey|secret|password|token)|(?<![A-Za-z0-9_])(?:code|cookie))\s*=\s*([^\s&"';]+)''',
  caseSensitive: false,
);
final _jsonSecretPattern = RegExp(
  r'("[A-Za-z0-9_.-]*(?:access_?token|refresh_?token|id_?token|cookie|set-cookie|authorization|x-parfait-workbench-token|api_?key|secret|password|code_?verifier|transfer_?envelope)"\s*:\s*)"([^"\\]*(?:\\.[^"\\]*)*)"',
  caseSensitive: false,
);
final _transferEnvelopeB64Pattern = RegExp(
  r'eyJ2ZXJzaW9uIjoyLCJwYXlsb2FkVHlwZSI6InBpeGl2LWFjY291bnQtdHJhbnNmZXIi[A-Za-z0-9+/=_-]+',
);

bool _isSensitiveKey(String key) {
  final compact = key.trim().toLowerCase().replaceAll(RegExp(r'[-_]'), '');
  return compact.contains('token') ||
      compact.contains('secret') ||
      compact.contains('cookie') ||
      compact.contains('password') ||
      compact.contains('authorization') ||
      compact.contains('apikey') ||
      compact.contains('credential') ||
      compact.contains('transferenvelope');
}

/// Scrubs bearer tokens, auth/cookie headers, JSON secrets, encoded transfer
/// envelopes, and credential query values so debug telemetry and HTTP logs
/// never expose real secrets.
String redactDevText(String input) {
  var result = input.replaceAll(
    _transferEnvelopeB64Pattern,
    kRedactedPlaceholder,
  );
  result = result.replaceAll(_bearerPattern, 'Bearer $kRedactedPlaceholder');
  result = result.replaceAllMapped(
    _cookieHeaderPattern,
    (m) => '${m.group(1)}: $kRedactedPlaceholder',
  );
  result = result.replaceAllMapped(
    _authHeaderPattern,
    (m) => '${m.group(1)}: $kRedactedPlaceholder',
  );
  result = result.replaceAllMapped(
    _apiKeyHeaderPattern,
    (m) => '${m.group(1)}: $kRedactedPlaceholder',
  );
  result = result.replaceAllMapped(
    _querySecretPattern,
    (m) => '${m.group(1)}=$kRedactedPlaceholder',
  );
  result = result.replaceAllMapped(
    _jsonSecretPattern,
    (m) => '${m.group(1)}"$kRedactedPlaceholder"',
  );
  return result;
}

Object? redactDevValue(Object? value) {
  if (value == null || value is num || value is bool) return value;
  if (value is String) return redactDevText(value);
  if (value is Map) return redactDevMap(value);
  if (value is Iterable) {
    return value.map(redactDevValue).toList(growable: false);
  }
  return redactDevText(value.toString());
}

Map<String, Object?> redactDevMap(Map<Object?, Object?> input) {
  final out = <String, Object?>{};
  for (final entry in input.entries) {
    final key = entry.key?.toString() ?? 'null';
    out[key] = _isSensitiveKey(key)
        ? kRedactedPlaceholder
        : redactDevValue(entry.value);
  }
  return out;
}
