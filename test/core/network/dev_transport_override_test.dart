@Tags(['socket'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:parfait/core/network/compat/network_contracts.dart';
import 'package:parfait/core/network/compat/network_policy.dart';
import 'package:parfait/core/network/compat/network_providers.dart';
import 'package:parfait/core/network/compat/pixiv_network_factory.dart';
import 'package:parfait/core/network/dev_transport_override.dart';

Future<void> _tolerant(Future<void> Function() body) async {
  Object? lastError;
  StackTrace? lastStack;
  for (var attempt = 0; attempt < 3; attempt++) {
    try {
      await body();
      return;
    } on Object catch (error, stack) {
      lastError = error;
      lastStack = stack;
    }
  }
  Error.throwWithStackTrace(lastError!, lastStack!);
}

void main() {
  test(
    'loopbackNetworkClientFactory rewrites URLs to /__pixiv__/<host><path> with headers',
    () => _tolerant(() async {
      final seen =
          <({String host, String purpose, String path, String query})>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final origin = Uri.parse('http://127.0.0.1:${server.port}');
      final factory = loopbackNetworkClientFactory(origin);
      final policy = NetworkAccessPolicy(
        mode: NetworkMode.directOnly,
        clientFactory: factory,
      );
      final client = PixivPolicyHttpClient(
        policy: policy,
        purpose: PixivDestinationPurpose.appApi,
      );

      try {
        server.listen((req) async {
          seen.add((
            host: req.headers.value('x-parfait-target-host') ?? '',
            purpose: req.headers.value('x-parfait-purpose') ?? '',
            path: req.uri.path,
            query: req.uri.query,
          ));
          req.response.statusCode = 200;
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode({'ok': true}));
          await req.response.close();
        });

        final resp = await client.get(
          Uri.parse(
            'https://app-api.pixiv.net/v1/illust/recommended?filter=for_ios',
          ),
        );

        expect(resp.statusCode, 200);
        expect(jsonDecode(resp.body), {'ok': true});
        expect(seen, hasLength(1));
        expect(seen.first.host, 'app-api.pixiv.net');
        expect(seen.first.purpose, 'appApi');
        expect(
          seen.first.path,
          '/__pixiv__/app-api.pixiv.net/v1/illust/recommended',
        );
        expect(seen.first.query, 'filter=for_ios');
      } finally {
        client.close();
        await policy.dispose();
        await server.close(force: true);
      }
    }),
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'devTransportProvider disables route memory stores in loopback mode and toggles cleanly',
    () => _tolerant(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) => req.response.close());

      final origin = Uri.parse('http://127.0.0.1:${server.port}');
      final container = ProviderContainer(
        overrides: [
          devTransportProvider.overrideWith(
            () => DevTransportNotifier(
              DevTransportConfig(
                mode: DevDataSourceMode.loopback,
                loopbackOrigin: origin,
              ),
            ),
          ),
        ],
      );

      try {
        expect(
          container.read(devTransportProvider).mode,
          DevDataSourceMode.loopback,
        );
        final loopbackPolicy = container.read(networkAccessPolicyProvider);
        expect(loopbackPolicy.fastRouteStore, isNull);
        expect(loopbackPolicy.routeKindStore, isNull);
        expect(loopbackPolicy.imageRouteScoreStore, isNull);

        container
            .read(devTransportProvider.notifier)
            .setMode(DevDataSourceMode.live);
        expect(
          container.read(devTransportProvider).mode,
          DevDataSourceMode.live,
        );
        final livePolicy = container.read(networkAccessPolicyProvider);
        expect(livePolicy.fastRouteStore, isNotNull);
        expect(livePolicy.routeKindStore, isNotNull);
        expect(livePolicy.imageRouteScoreStore, isNotNull);

        container
            .read(devTransportProvider.notifier)
            .setMode(DevDataSourceMode.loopback, loopbackOrigin: origin);
        expect(
          container.read(devTransportProvider).mode,
          DevDataSourceMode.loopback,
        );
        expect(container.read(devTransportProvider).loopbackOrigin, origin);
      } finally {
        container.dispose();
        await server.close(force: true);
      }
    }),
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'loopbackNetworkClientFactory forwards streamed request errors without unhandled zone exceptions',
    () => _tolerant(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        await req.drain<void>();
        await req.response.close();
      });

      final origin = Uri.parse('http://127.0.0.1:${server.port}');
      final factory = loopbackNetworkClientFactory(origin);
      final client = factory(
        NetworkRoute.direct(const NetworkRevision(0)),
        'app-api.pixiv.net',
        PixivDestinationPurpose.appApi,
      );
      final streamed = http.StreamedRequest(
        'POST',
        Uri.parse('https://app-api.pixiv.net/v1/upload'),
      );
      streamed.sink.addError(StateError('stream failed'));
      unawaited(streamed.sink.close());

      try {
        await expectLater(client.send(streamed), throwsA(isA<StateError>()));
      } finally {
        client.close();
        await server.close(force: true);
      }
    }),
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
