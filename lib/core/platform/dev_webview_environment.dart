import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../log.dart';
import 'app_storage_paths.dart';

/// Holds one lazily initialized [WebViewEnvironment] bound to the isolated
/// dev `userDataFolder` on Windows so dev WebView2 never shares `EBWebView`
/// state with production installs.
class DevWebViewEnvironmentHolder {
  DevWebViewEnvironmentHolder._();

  static WebViewEnvironment? _current;
  static Future<WebViewEnvironment?>? _pending;
  static Object? _initError;

  /// Synchronously returns the prewarmed dev WebView2 environment, or `null`
  /// in production / non-Windows builds.
  static WebViewEnvironment? get current => _current;

  /// The last initialization failure recorded on Windows dev mode, if any.
  static Object? get initError => _initError;

  /// Whether isolated dev WebView2 is required on this platform and missing.
  static bool isUnavailableInDevWindows({bool? isWindowsOverride}) =>
      AppStoragePaths.active.isDev &&
      !kIsWeb &&
      (isWindowsOverride ?? Platform.isWindows) &&
      _current == null;

  /// Returns [current] when isolated WebView2 is ready or unneeded, and throws
  /// [StateError] if Windows dev mode failed to initialize an isolated
  /// environment so callers never silently fall back to production `EBWebView`.
  static WebViewEnvironment? resolveForWebView({bool? isWindowsOverride}) {
    if (isUnavailableInDevWindows(isWindowsOverride: isWindowsOverride)) {
      throw StateError(
        'Isolated dev WebView2 environment is unavailable'
        '${_initError == null ? '' : ': $_initError'}',
      );
    }
    return _current;
  }

  static Future<WebViewEnvironment?> prewarm([
    AppStoragePaths? paths,
    @visibleForTesting
    Future<WebViewEnvironment> Function(WebViewEnvironmentSettings settings)?
    createEnvironment,
    @visibleForTesting bool? isWindowsOverride,
  ]) {
    final resolved = paths ?? AppStoragePaths.active;
    final dir = resolved.webViewUserDataDir;
    final isWindows = isWindowsOverride ?? Platform.isWindows;
    if (!resolved.isDev || dir == null || kIsWeb || !isWindows) {
      return Future<WebViewEnvironment?>.value(null);
    }
    return _pending ??= _create(dir, createEnvironment);
  }

  static Future<WebViewEnvironment?> _create(
    Directory dir, [
    Future<WebViewEnvironment> Function(WebViewEnvironmentSettings settings)?
    createEnvironment,
  ]) async {
    try {
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final settings = WebViewEnvironmentSettings(userDataFolder: dir.path);
      final env =
          await (createEnvironment?.call(settings) ??
              WebViewEnvironment.create(settings: settings));
      _current = env;
      _initError = null;
      return env;
    } on Object catch (error) {
      _current = null;
      _initError = error;
      _pending = null;
      log('dev webview2 environment init failed: $error');
      rethrow;
    }
  }

  @visibleForTesting
  static void resetForTest() {
    _current = null;
    _pending = null;
    _initError = null;
  }
}
