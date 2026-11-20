import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:parfait/app/widgets/errors/error_details.dart';
import 'package:parfait/app/widgets/settings/persist_settings.dart';
import 'package:parfait/core/download/download_recovery.dart';
import 'package:parfait/core/errors/error_category.dart';
import 'package:parfait/core/logging/crash_log.dart';
import 'package:parfait/core/network/api_error.dart';
import 'package:parfait/core/network/compat/network_contracts.dart';
import 'package:parfait/core/network/next_page_parser.dart';
import 'package:parfait/l10n/context.dart';
import 'helpers/prompt_host.dart';
import 'helpers/localized_app.dart';

Widget _host(Widget child) {
  return localizedApp(
    builder: promptHostBuilder,
    body: Center(child: child),
  );
}

void _mockClipboard(Map<String, String> store) {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') {
      store['text'] = (call.arguments as Map)['text'] as String;
    }
    return null;
  });
  addTearDown(
    () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
  );
}

/// Two failures with the same value: equal, but not the same object.
class _EqualError {
  @override
  bool operator ==(Object other) => other is _EqualError;

  @override
  int get hashCode => 0;
}

void main() {
  group('FailureReport', () {
    late Directory dir;
    late File file;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('failure_report_test');
      file = File('${dir.path}/crash.log');
      CrashLog.useFile(file);
    });

    tearDown(() {
      CrashLog.useFile(null);
      dir.deleteSync(recursive: true);
    });

    testWidgets('records an error once however often it is mounted', (
      tester,
    ) async {
      final first = StateError('boom');
      final second = StateError('again');
      final retried = _EqualError();
      // dart:io continuations parked in the fake-async zone are never
      // resumed, so the CrashLog writes run on the real event loop.
      await tester.runAsync(() async {
        await tester.pumpWidget(
          _host(FailureReport(action: '加载失败', error: first)),
        );
        await tester.pumpWidget(
          _host(FailureReport(action: '加载失败', error: first)),
        );
        await tester.pumpWidget(_host(const SizedBox()));
        await tester.pumpWidget(
          _host(FailureReport(action: '加载失败', error: first)),
        );
        await tester.pumpWidget(
          _host(FailureReport(action: '加载失败', error: second)),
        );
        // A retry's error equal to the last one is still a new failure.
        await tester.pumpWidget(
          _host(FailureReport(action: '加载失败', error: _EqualError())),
        );
        await tester.pumpWidget(
          _host(FailureReport(action: '加载失败', error: retried)),
        );
        await CrashLog.pending;
      });

      final content = file.readAsStringSync();
      expect('reported: 加载失败'.allMatches(content).length, 4);
      expect('Bad state: boom'.allMatches(content).length, 1);
      expect(content, contains('Bad state: again'));
      expect(find.textContaining('Bad state'), findsNothing);
    });
  });

  testWidgets('copy diagnostics puts the raw text on the clipboard only', (
    tester,
  ) async {
    final clipboard = <String, String>{};
    _mockClipboard(clipboard);
    await tester.pumpWidget(
      _host(CopyDiagnosticsButton(error: StateError('boom'))),
    );
    expect(find.textContaining('boom'), findsNothing);

    await tester.tap(find.text('复制诊断信息'));
    await tester.pump();

    expect(clipboard['text'], 'Bad state: boom');
    expect(find.text('已复制诊断信息'), findsOneWidget);
  });

  group('errorCategoryText', () {
    testWidgets('maps every category to a localized sentence', (tester) async {
      final seen = <ErrorCategory, String>{};
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) {
              for (final category in ErrorCategory.values) {
                seen[category] = errorCategoryText(context, category);
              }
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      expect(seen.length, ErrorCategory.values.length);
      expect(seen[ErrorCategory.network], '网络连接失败');
      expect(seen[ErrorCategory.timeout], '连接超时');
      expect(seen[ErrorCategory.unauthorized], '需要重新登录');
      expect(seen[ErrorCategory.unknown], '未知错误');
      expect(seen.values.every((text) => text.isNotEmpty), isTrue);
    });
  });

  group('showErrorSnackBar', () {
    late Directory dir;
    late File file;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('error_snackbar_test');
      file = File('${dir.path}/crash.log');
      CrashLog.useFile(file);
    });

    tearDown(() {
      CrashLog.useFile(null);
      dir.deleteSync(recursive: true);
    });

    testWidgets('shows action + category and records the raw error', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showErrorSnackBar(
                context,
                action: context.l10n.historyLoadFailed,
                error: const SocketException('connection reset'),
              ),
              child: const Text('go'),
            ),
          ),
        ),
      );
      // dart:io continuations parked in the fake-async zone are never
      // resumed, so fire the handler — and with it the CrashLog write chain —
      // on the real event loop.
      final button = tester.widget<TextButton>(
        find.widgetWithText(TextButton, 'go'),
      );
      await tester.runAsync(() async {
        button.onPressed!();
        await CrashLog.pending;
      });
      final content = file.readAsStringSync();
      expect(content, contains('reported: 历史记录加载失败'));
      expect(content, contains('SocketException'));
      expect(content, contains('connection reset'));

      await tester.pump();
      expect(find.text('历史记录加载失败：网络连接失败'), findsOneWidget);
      expect(
        find.textContaining('connection reset'),
        findsNothing,
        reason: 'the snackbar never prints raw exception text',
      );
    });
  });
  testWidgets('a settings write that fails after its page closed is reported', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      localizedApp(
        builder: promptHostBuilder,
        navigatorKey: navigator,
        home: const SizedBox(),
      ),
    );
    late BuildContext page;
    unawaited(
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (context) {
            page = context;
            return const SizedBox();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    final write = Completer<void>();

    final saved = persistSettings(page, () => write.future);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    write.completeError(StateError('disk full'));
    expect(await saved, isFalse);
    await tester.pumpAndSettle();

    expect(find.textContaining('设置保存失败'), findsOneWidget);
  });

  group('ErrorCategory', () {
    test('categorizeError puts each error in its category', () {
      for (final (error, category) in <(Object, ErrorCategory)>[
        (const ApiNetworkError('no route'), ErrorCategory.network),
        (const SocketException('closed'), ErrorCategory.network),
        (const HandshakeException('tls'), ErrorCategory.network),
        for (final kind in NetworkFailureKind.values)
          (
            NetworkFailureException(kind),
            kind == NetworkFailureKind.timeout
                ? ErrorCategory.timeout
                : ErrorCategory.network,
          ),
        (const ApiTimeout(), ErrorCategory.timeout),
        (TimeoutException('slow'), ErrorCategory.timeout),
        (const ApiRateLimited(null), ErrorCategory.rateLimited),
        (const ApiUnauthorized(), ErrorCategory.unauthorized),
        (const ApiHttpError(404), ErrorCategory.notFound),
        for (final status in [500, 502, 503, 599])
          (ApiHttpError(status), ErrorCategory.server),
        for (final status in [400, 403, 418, 499])
          (ApiHttpError(status), ErrorCategory.unknown),
        (const ApiParseError('nope'), ErrorCategory.parse),
        (const FormatException('bad json'), ErrorCategory.parse),
        (const NextPageParseError('missing cursor'), ErrorCategory.parse),
        (const FileSystemException('denied', '/tmp/x'), ErrorCategory.storage),
        (const ApiCancelled(), ErrorCategory.unknown),
        (StateError('x'), ErrorCategory.unknown),
        ('plain string', ErrorCategory.unknown),
      ]) {
        expect(categorizeError(error), category, reason: '$error');
      }
    });

    test(
      'categorizeDownloadFailure maps five kinds; the rest stay unknown',
      () {
        const mapped = {
          DownloadFailureKind.auth: ErrorCategory.unauthorized,
          DownloadFailureKind.rateLimit: ErrorCategory.rateLimited,
          DownloadFailureKind.network: ErrorCategory.network,
          DownloadFailureKind.storage: ErrorCategory.storage,
          DownloadFailureKind.decode: ErrorCategory.parse,
        };
        for (final kind in DownloadFailureKind.values) {
          expect(
            categorizeDownloadFailure(kind),
            mapped[kind] ?? ErrorCategory.unknown,
            reason: '$kind',
          );
        }
      },
    );
  });

  group('CrashLog', () {
    late Directory dir;
    late File file;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('crashlog_test');
      file = File('${dir.path}/crash.log');
      CrashLog.useFile(file);
    });

    tearDown(() {
      CrashLog.useFile(null);
      dir.deleteSync(recursive: true);
    });

    test('record appends timestamped entries with error and stack', () async {
      CrashLog.record(StateError('boom'), StackTrace.current);
      CrashLog.record('plain message');
      await CrashLog.pending;

      final content = file.readAsStringSync();
      expect(content, contains('Bad state'));
      expect(content, contains('boom'));
      expect(content, contains('plain message'));
      expect(content.split('===').length - 1, greaterThanOrEqualTo(2));
    });

    test('a file error is logged without its path', () async {
      CrashLog.report(
        'rename',
        const PathNotFoundException(
          r'C:\Users\someone\a.zip',
          OSError('No such file or directory', 2),
          "Cannot rename file to 'C:\\Users\\O'Connor\\b.zip'",
        ),
      );
      await CrashLog.pending;

      final content = file.readAsStringSync();
      expect(
        content,
        contains('PathNotFoundException: Cannot rename file to …'),
      );
      expect(content, contains('No such file or directory, errno = 2'));
      expect(content, isNot(contains('someone')));
      expect(content, isNot(contains('Connor')));
    });

    test('record without an installed file is a no-op', () {
      CrashLog.useFile(null);
      expect(() => CrashLog.record(Error()), returnsNormally);
    });

    test(
      'oversize file is rotated down to the newest half before append',
      () async {
        file.writeAsBytesSync(List.filled(CrashLog.maxBytes + 100, 0x61));
        CrashLog.record('after-rotation');
        await CrashLog.pending;

        final bytes = file.readAsBytesSync();
        expect(bytes.length, lessThan(CrashLog.maxBytes));
        expect(String.fromCharCodes(bytes), contains('after-rotation'));
      },
    );
  });
}
