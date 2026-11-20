import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Rooted storage paths for the app.
///
/// Production leaves directory overrides `null` so every consumer keeps its
/// exact platform default (`path_provider` / `sqflite` / system secure stores).
/// Dev mode sets every surface inside one isolated root directory so dev runs
/// cannot read or mutate production data.
class AppStoragePaths {
  const AppStoragePaths.production()
    : isDev = false,
      profileName = 'prod',
      rootDir = null,
      supportDir = null,
      tempDir = null,
      databaseDir = null,
      downloadsDir = null,
      webViewUserDataDir = null,
      credentialsDir = null,
      preferencesFile = null;

  const AppStoragePaths._dev({
    required this.profileName,
    required Directory this.rootDir,
    required Directory this.supportDir,
    required Directory this.tempDir,
    required Directory this.databaseDir,
    required Directory this.downloadsDir,
    required Directory this.webViewUserDataDir,
    required Directory this.credentialsDir,
    required File this.preferencesFile,
  }) : isDev = true;

  factory AppStoragePaths.dev(
    Directory rootDir, {
    String profileName = 'default',
  }) {
    final safeProfile = profileName.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    final profileRoot = Directory(p.join(rootDir.path, safeProfile));
    return AppStoragePaths._dev(
      profileName: safeProfile,
      rootDir: profileRoot,
      supportDir: Directory(p.join(profileRoot.path, 'support')),
      tempDir: Directory(p.join(profileRoot.path, 'temp')),
      databaseDir: Directory(p.join(profileRoot.path, 'databases')),
      downloadsDir: Directory(p.join(profileRoot.path, 'downloads')),
      webViewUserDataDir: Directory(p.join(profileRoot.path, 'webview2')),
      credentialsDir: Directory(p.join(profileRoot.path, 'credentials')),
      preferencesFile: File(
        p.join(profileRoot.path, 'shared_preferences.json'),
      ),
    );
  }

  static const _defineDevRoot = String.fromEnvironment('PARFAIT_DEV_ROOT');

  static String? _nonEmpty(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  /// Resolves the desktop isolated dev root purely from [environment] without
  /// calling `path_provider` (which eagerly creates the production support dir).
  @visibleForTesting
  static Directory? resolveDesktopDevRootFromEnv(
    Map<String, String> environment, {
    bool? isWindows,
    bool? isLinux,
    bool? isMacOS,
  }) {
    final envRoot = _nonEmpty(environment['PARFAIT_DEV_ROOT']);
    if (envRoot != null) {
      return Directory(envRoot);
    }
    final defineRoot = _nonEmpty(_defineDevRoot);
    if (defineRoot != null) {
      return Directory(defineRoot);
    }
    final win = isWindows ?? Platform.isWindows;
    if (win) {
      final base =
          _nonEmpty(environment['APPDATA']) ??
          _nonEmpty(environment['LOCALAPPDATA']) ??
          _nonEmpty(environment['USERPROFILE']);
      if (base == null) return null;
      return Directory(
        p.windows.join(base, 'io.github.lopution', 'parfait-dev', 'profiles'),
      );
    }
    final linux = isLinux ?? Platform.isLinux;
    if (linux) {
      final xdgData = _nonEmpty(environment['XDG_DATA_HOME']);
      final home = _nonEmpty(environment['HOME']);
      final base =
          xdgData ??
          (home == null ? null : p.posix.join(home, '.local', 'share'));
      if (base == null) return null;
      return Directory(p.posix.join(base, 'parfait-dev', 'profiles'));
    }
    final mac = isMacOS ?? Platform.isMacOS;
    if (mac) {
      final home = _nonEmpty(environment['HOME']);
      if (home == null) return null;
      return Directory(
        p.posix.join(
          home,
          'Library',
          'Application Support',
          'parfait-dev',
          'profiles',
        ),
      );
    }
    return null;
  }

  /// Resolves a platform-appropriate isolated dev root directory.
  static Future<Directory> resolveDefaultDevRoot([
    Map<String, String>? environment,
  ]) async {
    final env = environment ?? Platform.environment;
    final desktopRoot = resolveDesktopDevRootFromEnv(env);
    if (desktopRoot != null) {
      return desktopRoot;
    }
    final support = await getApplicationSupportDirectory();
    if (Platform.isAndroid || Platform.isIOS) {
      return Directory(p.join(support.path, 'dev_profiles'));
    }
    return Directory(p.join(support.parent.path, 'parfait-dev', 'profiles'));
  }

  static AppStoragePaths _active = const AppStoragePaths.production();

  static AppStoragePaths get active => _active;

  static void setActive(AppStoragePaths paths) {
    _active = paths;
  }

  final bool isDev;
  final String profileName;
  final Directory? rootDir;
  final Directory? supportDir;
  final Directory? tempDir;
  final Directory? databaseDir;
  final Directory? downloadsDir;
  final Directory? webViewUserDataDir;
  final Directory? credentialsDir;
  final File? preferencesFile;

  String? databasePath(String databaseName) {
    final dir = databaseDir;
    return dir == null ? null : p.join(dir.path, databaseName);
  }

  Future<Directory> resolveSupportDir() async =>
      supportDir ?? await getApplicationSupportDirectory();

  Future<Directory> resolveTempDir() async =>
      tempDir ?? await getTemporaryDirectory();

  Future<void> ensureCreated() async {
    if (!isDev) return;
    for (final dir in [
      supportDir,
      tempDir,
      databaseDir,
      downloadsDir,
      webViewUserDataDir,
      credentialsDir,
    ]) {
      if (dir != null && !await dir.exists()) {
        await dir.create(recursive: true);
      }
    }
  }
}

final appStoragePathsProvider = Provider<AppStoragePaths>(
  (ref) => AppStoragePaths.active,
);
