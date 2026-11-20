@Tags(['socket'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:parfait/core/debug/dev_redaction.dart';
import 'package:parfait/core/debug/dev_telemetry.dart';
import 'package:parfait/core/debug/dev_workbench_agent.dart';

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
  tearDown(DevTelemetry.instance.clear);

  test(
    'DevWorkbenchAgent exchanges redacted heartbeats and command results over loopback HTTP',
    () => _tolerant(() async {
      DevTelemetry.instance.clear();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final results = <Map<String, dynamic>>[];
      final heartbeats = <Map<String, dynamic>>[];
      final done = Completer<void>();

      server.listen((req) async {
        final body = await utf8.decodeStream(req);
        final json = jsonDecode(body) as Map<String, dynamic>;
        var completeAfterClose = false;
        if (req.uri.path == '/api/client/heartbeat') {
          expect(
            req.headers.value('x-parfait-workbench-token'),
            'tok_secret_wb',
          );
          heartbeats.add(json);
          req.response
            ..statusCode = 200
            ..headers.contentType = ContentType.json
            ..write(
              jsonEncode({
                'ok': true,
                'ackSeq': 1,
                'commands': heartbeats.length == 1
                    ? [
                        {
                          'id': 'c1',
                          'type': 'navigate',
                          'args': {'path': '/ranking'},
                        },
                      ]
                    : const <Object?>[],
              }),
            );
        } else if (req.uri.path == '/api/client/command-result') {
          results.add(json);
          req.response
            ..statusCode = 200
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({'ok': true}));
          completeAfterClose = true;
        }
        await req.response.close();
        if (completeAfterClose && !done.isCompleted) {
          done.complete();
        }
      });

      DevTelemetry.instance.record(
        'GET /oauth?code=secret_abc Authorization: Bearer tok_999',
      );
      final agent = DevWorkbenchAgent(
        workbenchOrigin: Uri.parse('http://127.0.0.1:${server.port}'),
        clientId: 'linux-test',
        platformLabel: 'linux',
        token: 'tok_secret_wb',
        buildSnapshot: () async => {
          'route': '/recommended',
          'accessToken': 'should_be_scrubbed',
        },
        dispatchCommand: (type, args) async => {
          'ok': true,
          'type': type,
          'args': args,
        },
      );

      try {
        await agent.tick();
        await done.future.timeout(const Duration(seconds: 5));

        expect(heartbeats, isNotEmpty);
        final encodedHb = jsonEncode(heartbeats.first);
        expect(encodedHb, isNot(contains('should_be_scrubbed')));
        expect(encodedHb, isNot(contains('secret_abc')));
        expect(encodedHb, isNot(contains('tok_999')));
        expect(encodedHb, contains(kRedactedPlaceholder));
        expect(results.single['id'], 'c1');
        expect(results.single['ok'], isTrue);
      } finally {
        agent.dispose();
        await server.close(force: true);
      }
    }),
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
