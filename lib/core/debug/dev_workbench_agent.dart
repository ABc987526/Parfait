import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../log.dart';
import 'dev_redaction.dart';
import 'dev_telemetry.dart';

typedef DevCommandDispatcher =
    Future<Map<String, Object?>> Function(
      String type,
      Map<String, Object?> args,
    );

typedef DevSnapshotBuilder = Future<Map<String, Object?>> Function();

bool isAllowedLoopbackUri(Uri uri) {
  if (uri.scheme != 'http') return false;
  final host = uri.host.toLowerCase();
  return host == '127.0.0.1' ||
      host == 'localhost' ||
      host == '::1' ||
      host == '10.0.2.2';
}

/// Polls a local Web Workbench over loopback HTTP with redacted snapshots and
/// executes validated remote commands from the workbench queue.
class DevWorkbenchAgent {
  DevWorkbenchAgent({
    required this.workbenchOrigin,
    required this.clientId,
    required this.platformLabel,
    required DevSnapshotBuilder buildSnapshot,
    required DevCommandDispatcher dispatchCommand,
    this.token,
  }) : _buildSnapshot = buildSnapshot,
       _dispatchCommand = dispatchCommand {
    if (!isAllowedLoopbackUri(workbenchOrigin)) {
      throw ArgumentError.value(
        workbenchOrigin,
        'workbenchOrigin',
        'only loopback HTTP origins are allowed',
      );
    }
  }

  final Uri workbenchOrigin;
  final String clientId;
  final String platformLabel;
  final String? token;
  final DevSnapshotBuilder _buildSnapshot;
  final DevCommandDispatcher _dispatchCommand;

  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 2)
    ..idleTimeout = const Duration(seconds: 5);

  Timer? _timer;
  bool _inFlight = false;
  bool _disposed = false;
  bool _loggedTickFailure = false;
  int _lastAckSeq = 0;

  void start() {
    if (_disposed || _timer != null) return;
    log('dev workbench agent starting: $workbenchOrigin (client=$clientId)');
    _timer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(tick()),
    );
    unawaited(tick());
  }

  Future<void> tick() async {
    if (_disposed || _inFlight) return;
    _inFlight = true;
    try {
      final snapshot = redactDevMap(await _buildSnapshot());
      final pendingLogs = DevTelemetry.instance.since(_lastAckSeq, limit: 80);
      final response = await _postJson('/api/client/heartbeat', {
        'clientId': clientId,
        'platform': platformLabel,
        'snapshot': snapshot,
        'logs': [for (final entry in pendingLogs) entry.toJson()],
      });
      if (response == null || _disposed) return;
      _loggedTickFailure = false;
      final ack = response['ackSeq'];
      final latestSeq = DevTelemetry.instance.latestSeq;
      if (ack is int && ack > _lastAckSeq && ack <= latestSeq) {
        _lastAckSeq = ack;
      } else if (pendingLogs.isNotEmpty) {
        _lastAckSeq = pendingLogs.last.seq;
      }
      final rawCommands = response['commands'];
      if (rawCommands is! List) return;
      for (final raw in rawCommands) {
        if (raw is! Map) continue;
        final id = raw['id']?.toString();
        final type = raw['type']?.toString();
        if (id == null || type == null) continue;
        final rawArgs = raw['args'];
        final args = rawArgs is Map
            ? rawArgs.map((k, v) => MapEntry(k.toString(), v as Object?))
            : const <String, Object?>{};
        await _runCommand(id, type, args);
      }
    } on Object catch (error, stackTrace) {
      if (!_loggedTickFailure) {
        _loggedTickFailure = true;
        log('dev workbench heartbeat failed: $error\n$stackTrace');
      }
    } finally {
      _inFlight = false;
    }
  }

  Future<void> _runCommand(
    String id,
    String type,
    Map<String, Object?> args,
  ) async {
    Map<String, Object?> report;
    try {
      final result = await _dispatchCommand(type, args);
      report = {
        'clientId': clientId,
        'id': id,
        'ok': true,
        'result': redactDevMap(result),
      };
    } on Object catch (error) {
      report = {
        'clientId': clientId,
        'id': id,
        'ok': false,
        'error': redactDevText(error.toString()),
      };
    }
    await _postJson('/api/client/command-result', report);
  }

  Future<Map<String, dynamic>?> _postJson(
    String path,
    Map<String, Object?> body,
  ) async {
    final uri = workbenchOrigin.resolve(path);
    final req = await _http.postUrl(uri).timeout(const Duration(seconds: 2));
    final bytes = utf8.encode(jsonEncode(body));
    req.headers.contentType = ContentType.json;
    req.contentLength = bytes.length;
    final authToken = token;
    if (authToken != null && authToken.isNotEmpty) {
      req.headers.set('x-parfait-workbench-token', authToken);
    }
    req.add(bytes);
    final res = await req.close().timeout(const Duration(seconds: 3));
    final text = await utf8
        .decodeStream(res)
        .timeout(const Duration(seconds: 3));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      if (!_loggedTickFailure) {
        _loggedTickFailure = true;
        log('dev workbench POST $path HTTP ${res.statusCode}: $text');
      }
      return null;
    }
    if (text.isEmpty) return null;
    final decoded = jsonDecode(text);
    return decoded is Map<String, dynamic> ? decoded : null;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _http.close(force: true);
  }
}
