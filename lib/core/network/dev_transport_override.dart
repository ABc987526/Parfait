import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:rhttp/rhttp.dart' as rhttp;

import 'compat/network_contracts.dart';
import 'compat/network_policy.dart';
import 'compat/rhttp_client_factory.dart';
import 'rhttp_gate.dart';

/// Active data source for the dev client (`Live` real Pixiv vs `Loopback`
/// local gateway). Production always keeps [DevDataSourceMode.live] with no
/// loopback origin.
enum DevDataSourceMode { live, loopback }

@immutable
class DevTransportConfig {
  const DevTransportConfig({
    this.mode = DevDataSourceMode.live,
    this.loopbackOrigin,
  });

  static const production = DevTransportConfig();

  final DevDataSourceMode mode;
  final Uri? loopbackOrigin;

  String? get activeLoopbackOriginString =>
      mode == DevDataSourceMode.loopback ? loopbackOrigin?.toString() : null;

  Uri? get activeLoopbackOrigin =>
      mode == DevDataSourceMode.loopback ? loopbackOrigin : null;

  @override
  bool operator ==(Object other) =>
      other is DevTransportConfig &&
      other.mode == mode &&
      other.loopbackOrigin == loopbackOrigin;

  @override
  int get hashCode => Object.hash(mode, loopbackOrigin);
}

class DevTransportNotifier extends Notifier<DevTransportConfig> {
  DevTransportNotifier([this._initial = DevTransportConfig.production]);

  final DevTransportConfig _initial;

  @override
  DevTransportConfig build() => _initial;

  void setConfig(DevTransportConfig next) {
    if (state == next) return;
    state = next;
  }

  void setMode(DevDataSourceMode mode, {Uri? loopbackOrigin}) {
    setConfig(
      DevTransportConfig(
        mode: mode,
        loopbackOrigin: loopbackOrigin ?? state.loopbackOrigin,
      ),
    );
  }
}

final devTransportProvider =
    NotifierProvider<DevTransportNotifier, DevTransportConfig>(
      DevTransportNotifier.new,
    );

typedef LoopbackInnerClientFactory =
    http.Client Function(
      NetworkRoute route,
      String canonicalHost,
      PixivDestinationPurpose purpose,
    );

/// Builds a [NetworkClientFactory] that forwards canonical Pixiv HTTPS requests
/// over plain HTTP to the local dev loopback gateway [origin], while preserving
/// canonical URLs and cache keys above [NetworkAccessPolicy].
NetworkClientFactory loopbackNetworkClientFactory(
  Uri origin, {
  @visibleForTesting LoopbackInnerClientFactory? innerClientFactory,
}) {
  return (
    NetworkRoute route,
    String canonicalHost,
    PixivDestinationPurpose purpose,
  ) => _LoopbackPixivClient(
    origin: origin,
    route: route,
    purpose: purpose,
    canonicalHost: canonicalHost,
    innerClientFactory: innerClientFactory,
  );
}

class _LoopbackPixivClient extends http.BaseClient {
  _LoopbackPixivClient({
    required this.origin,
    required this.route,
    required this.purpose,
    required this.canonicalHost,
    LoopbackInnerClientFactory? innerClientFactory,
  }) : _inner = _createInnerClient(
         route: route,
         canonicalHost: canonicalHost,
         purpose: purpose,
         innerClientFactory: innerClientFactory,
       );

  static http.Client _createInnerClient({
    required NetworkRoute route,
    required String canonicalHost,
    required PixivDestinationPurpose purpose,
    LoopbackInnerClientFactory? innerClientFactory,
  }) {
    if (innerClientFactory != null) {
      return innerClientFactory(route, canonicalHost, purpose);
    }
    if (RhttpGate.ready != null) {
      return rhttp.RhttpCompatibleClient.createSync(
        settings: rhttp.ClientSettings(
          httpVersionPref: RhttpClientFactory.httpVersionFor(purpose),
          redirectSettings: const rhttp.RedirectSettings.none(),
          timeoutSettings: RhttpClientFactory.timeoutsFor(
            route,
            destinationHost: canonicalHost,
            purpose: purpose,
          ),
        ),
      );
    }
    return IOClient(HttpClient()..idleTimeout = const Duration(seconds: 15));
  }

  final Uri origin;
  final NetworkRoute route;
  final PixivDestinationPurpose purpose;
  final String canonicalHost;
  final http.Client _inner;

  Uri _rewriteUri(Uri raw) {
    final normalizedRaw = raw.path.startsWith('/') ? raw.path : '/${raw.path}';
    return Uri(
      scheme: origin.scheme,
      userInfo: origin.userInfo,
      host: origin.host,
      port: origin.hasPort ? origin.port : null,
      path: _joinBasePath(
        origin.path,
        '/__pixiv__/$canonicalHost$normalizedRaw',
      ),
      query: raw.hasQuery ? raw.query : null,
    );
  }

  static String _joinBasePath(String basePath, String rawPath) {
    final trimmedBase = basePath.endsWith('/')
        ? basePath.substring(0, basePath.length - 1)
        : basePath;
    final normalizedRaw = rawPath.startsWith('/') ? rawPath : '/$rawPath';
    return '$trimmedBase$normalizedRaw';
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final rewrittenUrl = _rewriteUri(request.url);
    final outbound = _cloneRequest(request, rewrittenUrl);
    outbound.headers['x-parfait-target-host'] = canonicalHost;
    outbound.headers['x-parfait-purpose'] = purpose.name;
    outbound.followRedirects = false;
    outbound.maxRedirects = request.maxRedirects;
    outbound.persistentConnection = request.persistentConnection;
    return _inner.send(outbound);
  }

  static http.BaseRequest _cloneRequest(http.BaseRequest request, Uri target) {
    final abortTrigger = switch (request) {
      http.Abortable(:final abortTrigger) => abortTrigger,
      _ => null,
    };
    if (request is http.Request) {
      final cloned =
          http.AbortableRequest(
              request.method,
              target,
              abortTrigger: abortTrigger,
            )
            ..headers.addAll(request.headers)
            ..bodyBytes = request.bodyBytes;
      return cloned;
    }
    if (request is http.MultipartRequest) {
      final cloned = http.MultipartRequest(request.method, target)
        ..headers.addAll(request.headers)
        ..fields.addAll(request.fields)
        ..files.addAll(request.files);
      return cloned;
    }
    final cloned = http.AbortableStreamedRequest(
      request.method,
      target,
      abortTrigger: abortTrigger,
    )..headers.addAll(request.headers);
    if (request.contentLength != null) {
      cloned.contentLength = request.contentLength;
    }
    unawaited(() async {
      try {
        await for (final chunk in request.finalize()) {
          cloned.sink.add(chunk);
        }
      } on Object catch (error, stackTrace) {
        cloned.sink.addError(error, stackTrace);
      } finally {
        try {
          await cloned.sink.close();
        } on Object {
          // Sink may already be closed when the request was aborted.
        }
      }
    }());
    return cloned;
  }

  @override
  void close() {
    _inner.close();
  }
}
