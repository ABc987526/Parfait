import 'dart:async';

import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'app/dev_workbench/dev_workbench_bridge.dart';
import 'core/auth/account_store.dart';
import 'core/debug/dev_isolated_stores.dart';
import 'core/debug/dev_telemetry.dart';
import 'core/log.dart';
import 'core/logging/crash_log.dart';
import 'core/network/dev_transport_override.dart';
import 'core/platform/app_storage_paths.dart';
import 'core/platform/dev_webview_environment.dart';
import 'core/platform/platform_caps.dart';
import 'core/translation/translation_service.dart';
import 'main.dart';

/// Isolated developer entrypoint (`flutter run -t lib/main_dev.dart`).
///
/// Reuses production routing, widgets, storage schemas, and network policy
/// while binding all six storage/process surfaces to a dev profile dir, routing
/// telemetry through redacted buffers, and wiring VM extensions + local Web
/// Workbench bridge.
Future<void> main(List<String> args) async {
  final options = DevClientOptions.fromRuntime(args);
  await bootParfaitApp(
    resolveDevStoragePaths: () async {
      final root = await AppStoragePaths.resolveDefaultDevRoot();
      return AppStoragePaths.dev(root, profileName: options.profileName);
    },
    additionalOverrides: [
      devTransportProvider.overrideWith(
        () => DevTransportNotifier(options.initialTransportConfig),
      ),
      // Dev sessions intentionally store credentials in 0600 JSON files inside
      // the isolated dev profile dir rather than the OS keychain/keystore so
      // local dev/live experiments never touch production credentials. This
      // entrypoint is never packaged into release builds.
      credentialStoreProvider.overrideWith(
        (ref) => DevFileCredentialStore(
          ref.watch(appStoragePathsProvider).credentialsDir!,
        ),
      ),
      translationCredentialStoreProvider.overrideWith(
        (ref) => DevFileTranslationCredentialStore(
          ref.watch(appStoragePathsProvider).credentialsDir!,
        ),
      ),
    ],
    beforeRunApp: (paths) async {
      final prefsFile = paths.preferencesFile;
      if (prefsFile != null) {
        SharedPreferencesAsyncPlatform.instance =
            DevFileSharedPreferencesAsyncPlatform(prefsFile);
      }
      devLogListener = (message) =>
          DevTelemetry.instance.record(message, level: 'info', source: 'log');
      CrashLog.devCrashListener = (action, summary) =>
          DevTelemetry.instance.record(
            action == null ? summary : '[$action] $summary',
            level: 'error',
            source: 'crash',
          );
      if (PlatformCaps.system().isWindows) {
        try {
          await DevWebViewEnvironmentHolder.prewarm(paths);
        } on Object catch (error) {
          log('dev webview2 prewarm failed (WebView blocked): $error');
        }
      }
    },
    devWorkbenchBuilder: (router, child) =>
        DevWorkbenchHost(router: router, options: options, child: child),
  );
}
