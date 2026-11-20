import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

import '../auth/credential.dart';
import '../auth/credential_store.dart';
import '../platform/platform_caps.dart';
import '../translation/translation_credentials.dart';

class _SerialQueue {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        completer.complete(await action());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }
}

/// File-backed [SharedPreferencesAsyncPlatform] for isolated dev sessions.
///
/// Installed before `ProviderScope` initialization in `main_dev.dart` so even
/// direct `SharedPreferencesAsync()` callers never touch production OS prefs.
base class DevFileSharedPreferencesAsyncPlatform
    extends SharedPreferencesAsyncPlatform {
  DevFileSharedPreferencesAsyncPlatform(this.file);

  final File file;
  final _SerialQueue _queue = _SerialQueue();
  Map<String, Object>? _cache;

  Future<T> _serialized<T>(Future<T> Function() action) => _queue.run(action);

  Future<Map<String, Object>> _load() async {
    if (_cache != null) return _cache!;
    if (!await file.exists()) {
      return _cache = <String, Object>{};
    }
    final raw = await file.readAsString();
    if (raw.trim().isEmpty) {
      return _cache = <String, Object>{};
    }
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    final map = <String, Object>{};
    for (final entry in decoded.entries) {
      final value = entry.value;
      if (value is List) {
        map[entry.key] = value.cast<String>().toList(growable: false);
      } else if (value is Object) {
        map[entry.key] = value;
      }
    }
    return _cache = map;
  }

  Future<void> _save(Map<String, Object> data) async {
    await _writeJsonAtomic(file, data);
    _cache = data;
  }

  Future<void> _mutate(void Function(Map<String, Object> next) update) async {
    final next = Map<String, Object>.from(await _load());
    update(next);
    await _save(next);
  }

  @override
  Future<void> setString(
    String key,
    String value,
    SharedPreferencesOptions options,
  ) => _serialized(() => _mutate((data) => data[key] = value));

  @override
  Future<void> setBool(
    String key,
    bool value,
    SharedPreferencesOptions options,
  ) => _serialized(() => _mutate((data) => data[key] = value));

  @override
  Future<void> setDouble(
    String key,
    double value,
    SharedPreferencesOptions options,
  ) => _serialized(() => _mutate((data) => data[key] = value));

  @override
  Future<void> setInt(
    String key,
    int value,
    SharedPreferencesOptions options,
  ) => _serialized(() => _mutate((data) => data[key] = value));

  @override
  Future<void> setStringList(
    String key,
    List<String> value,
    SharedPreferencesOptions options,
  ) => _serialized(
    () => _mutate((data) => data[key] = List<String>.unmodifiable(value)),
  );

  @override
  Future<String?> getString(String key, SharedPreferencesOptions options) =>
      _serialized(() async => (await _load())[key] as String?);

  @override
  Future<bool?> getBool(String key, SharedPreferencesOptions options) =>
      _serialized(() async => (await _load())[key] as bool?);

  @override
  Future<double?> getDouble(String key, SharedPreferencesOptions options) =>
      _serialized(() async => ((await _load())[key] as num?)?.toDouble());

  @override
  Future<int?> getInt(String key, SharedPreferencesOptions options) =>
      _serialized(() async => (await _load())[key] as int?);

  @override
  Future<List<String>?> getStringList(
    String key,
    SharedPreferencesOptions options,
  ) => _serialized(() async {
    final value = (await _load())[key] as List<String>?;
    return value == null ? null : List<String>.from(value);
  });

  @override
  Future<void> clear(
    ClearPreferencesParameters parameters,
    SharedPreferencesOptions options,
  ) => _serialized(
    () => _mutate((data) {
      final allowList = parameters.filter.allowList;
      if (allowList == null) {
        data.clear();
      } else {
        data.removeWhere((key, _) => allowList.contains(key));
      }
    }),
  );

  static Object _clonePrefValue(Object value) =>
      value is List<String> ? List<String>.from(value) : value;

  @override
  Future<Map<String, Object>> getPreferences(
    GetPreferencesParameters parameters,
    SharedPreferencesOptions options,
  ) => _serialized(() async {
    final data = await _load();
    final allowList = parameters.filter.allowList;
    if (allowList == null) {
      return {
        for (final entry in data.entries)
          entry.key: _clonePrefValue(entry.value),
      };
    }
    return {
      for (final key in allowList)
        if (data.containsKey(key)) key: _clonePrefValue(data[key]!),
    };
  });

  @override
  Future<Set<String>> getKeys(
    GetPreferencesParameters parameters,
    SharedPreferencesOptions options,
  ) => _serialized(() async {
    final data = await _load();
    final allowList = parameters.filter.allowList;
    if (allowList == null) return data.keys.toSet();
    return data.keys.where(allowList.contains).toSet();
  });
}

/// File-backed [CredentialStore] inside dev's isolated credentials dir.
class DevFileCredentialStore implements CredentialStore {
  DevFileCredentialStore(Directory credentialsDir)
    : _dir = Directory(p.join(credentialsDir.path, 'pixiv'));

  final Directory _dir;
  final _SerialQueue _queue = _SerialQueue();

  File _fileFor(String accountId) {
    final encoded = base64UrlEncode(utf8.encode(accountId)).replaceAll('=', '');
    return File(p.join(_dir.path, '$encoded.json'));
  }

  @override
  Future<Credential?> read(String accountId) => _queue.run(() async {
    try {
      final file = _fileFor(accountId);
      if (!await file.exists()) return null;
      final decoded =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final access = decoded['accessToken'] as String?;
      final refresh = decoded['refreshToken'] as String?;
      if (access == null || refresh == null) return null;
      return Credential(
        accessToken: access,
        refreshToken: refresh,
        cookie: decoded['cookie'] as String?,
      );
    } on FormatException catch (error) {
      // Strip FormatException.source so corrupt JSON cannot quote tokens into CrashLog (ERR-06).
      throw CredentialStoreException(
        'read',
        accountId,
        FormatException(error.message),
      );
    } on Object catch (error) {
      throw CredentialStoreException('read', accountId, error);
    }
  });

  @override
  Future<void> write(String accountId, Credential credential) =>
      _queue.run(() async {
        try {
          await _writeJsonAtomic(_fileFor(accountId), {
            'accessToken': credential.accessToken,
            'refreshToken': credential.refreshToken,
            'cookie': credential.cookie,
          }, restrictPermissions: true);
        } on Object catch (error) {
          throw CredentialStoreException('write', accountId, error);
        }
      });

  @override
  Future<void> delete(String accountId) => _queue.run(() async {
    try {
      final file = _fileFor(accountId);
      if (await file.exists()) await file.delete();
    } on Object catch (error) {
      throw CredentialStoreException('delete', accountId, error);
    }
  });
}

/// File-backed [TranslationCredentialStore] inside dev's isolated dir.
class DevFileTranslationCredentialStore implements TranslationCredentialStore {
  DevFileTranslationCredentialStore(Directory credentialsDir)
    : _file = File(p.join(credentialsDir.path, 'translation.json'));

  final File _file;
  final _SerialQueue _queue = _SerialQueue();

  Future<Map<String, dynamic>> _readAllUnlocked() async {
    try {
      if (!await _file.exists()) return <String, dynamic>{};
      final raw = await _file.readAsString();
      if (raw.trim().isEmpty) return <String, dynamic>{};
      return (jsonDecode(raw) as Map).cast<String, dynamic>();
    } on FormatException catch (error) {
      // Strip FormatException.source so corrupt JSON cannot quote secrets into CrashLog (ERR-06).
      throw TranslationCredentialsStoreException(
        'read',
        FormatException(error.message),
      );
    } on Object catch (error) {
      throw TranslationCredentialsStoreException('read', error);
    }
  }

  Future<void> _writeAllUnlocked(Map<String, dynamic> map) async {
    try {
      await _writeJsonAtomic(_file, map, restrictPermissions: true);
    } on Object catch (error) {
      throw TranslationCredentialsStoreException('write', error);
    }
  }

  @override
  Future<BaiduTranslationCredentials?> readBaidu() => _queue.run(() async {
    final map = await _readAllUnlocked();
    final appId = map['baiduAppId'] as String?;
    final secret = map['baiduSecret'] as String?;
    if (appId == null || secret == null) return null;
    return BaiduTranslationCredentials(appId: appId, secret: secret);
  });

  @override
  Future<void> writeBaidu(BaiduTranslationCredentials credentials) =>
      _queue.run(() async {
        final map = await _readAllUnlocked();
        map['baiduAppId'] = credentials.appId;
        map['baiduSecret'] = credentials.secret;
        await _writeAllUnlocked(map);
      });

  @override
  Future<LlmTranslationCredentials?> readLlm() => _queue.run(() async {
    final map = await _readAllUnlocked();
    final baseUrl = map['llmBaseUrl'] as String?;
    final apiKey = map['llmApiKey'] as String?;
    if (baseUrl == null || apiKey == null) return null;
    return LlmTranslationCredentials(
      baseUrl: baseUrl,
      apiKey: apiKey,
      model: map['llmModel'] as String?,
    );
  });

  @override
  Future<void> writeLlm(LlmTranslationCredentials credentials) =>
      _queue.run(() async {
        final map = await _readAllUnlocked();
        map['llmBaseUrl'] = credentials.baseUrl;
        map['llmApiKey'] = credentials.apiKey;
        final model = credentials.model;
        if (model == null || model.isEmpty) {
          map.remove('llmModel');
        } else {
          map['llmModel'] = model;
        }
        await _writeAllUnlocked(map);
      });

  @override
  Future<bool> hasBaidu() async => (await readBaidu()) != null;

  @override
  Future<bool> hasLlm() async => (await readLlm()) != null;

  @override
  Future<void> deleteBaidu() => _queue.run(() async {
    final map = await _readAllUnlocked();
    map.remove('baiduAppId');
    map.remove('baiduSecret');
    await _writeAllUnlocked(map);
  });

  @override
  Future<void> deleteLlm() => _queue.run(() async {
    final map = await _readAllUnlocked();
    map.remove('llmBaseUrl');
    map.remove('llmApiKey');
    map.remove('llmModel');
    await _writeAllUnlocked(map);
  });

  @override
  Future<void> deleteAll() => _queue.run(() async {
    try {
      if (await _file.exists()) await _file.delete();
    } on Object catch (error) {
      throw TranslationCredentialsStoreException('delete', error);
    }
  });

  @override
  Future<void> retireLegacyWebSession() async {}
}

int _atomicWriteSeq = 0;

Future<void> _writeJsonAtomic(
  File file,
  Object data, {
  bool restrictPermissions = false,
}) async {
  final isWindows = PlatformCaps.system().isWindows;
  if (!await file.parent.exists()) {
    await file.parent.create(recursive: true);
    if (restrictPermissions && !isWindows) {
      try {
        await Process.run('chmod', ['0700', file.parent.path]);
      } on Object {
        // Best effort on non-POSIX or restricted test sandboxes.
      }
    }
  }
  final tmp = File('${file.path}.tmp.$pid.${_atomicWriteSeq++}');
  if (restrictPermissions && !isWindows) {
    await tmp.create();
    try {
      await Process.run('chmod', ['0600', tmp.path]);
    } on Object {
      // Best effort on non-POSIX or restricted test sandboxes.
    }
  }
  await tmp.writeAsString(jsonEncode(data), flush: true);
  // Dart's File.rename uses MoveFileExW(MOVEFILE_REPLACE_EXISTING) on Windows
  // and rename(2) on POSIX, so overwriting directly avoids a crash-loss window.
  await tmp.rename(file.path);
}
