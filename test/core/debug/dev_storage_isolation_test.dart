import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:parfait/core/actionqueue/action_bootstrap.dart';
import 'package:parfait/core/actionqueue/action_database.dart';
import 'package:parfait/core/auth/account_store.dart';
import 'package:parfait/core/auth/credential.dart';
import 'package:parfait/core/auth/credential_store.dart';
import 'package:parfait/core/debug/dev_isolated_stores.dart';
import 'package:parfait/core/debug/dev_redaction.dart';
import 'package:parfait/core/history/history_database.dart';
import 'package:parfait/core/history/history_repository.dart';
import 'package:parfait/core/localnovel/local_novel_database.dart';
import 'package:parfait/core/localnovel/local_novel_repository.dart';
import 'package:parfait/core/paging/feed_database.dart';
import 'package:parfait/core/paging/feed_snapshot_store.dart';
import 'package:parfait/core/platform/app_storage_paths.dart';
import 'package:parfait/core/platform/desktop_file_sink.dart';
import 'package:parfait/core/platform/dev_webview_environment.dart';
import 'package:parfait/core/translation/legacy_translation_cleanup.dart';
import 'package:parfait/core/translation/translation_credentials.dart';
import 'package:parfait/core/translation/translation_service.dart';
import 'package:parfait/core/watchlater/watch_later_database.dart';
import 'package:parfait/core/watchlater/watch_later_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/test_preferences.dart';

void main() {
  test(
    'dev storage surfaces stay completely isolated from prod sentinels',
    () async {
      final sandbox = await Directory.systemTemp.createTemp('parfait_iso_');
      final prodRoot = Directory(p.join(sandbox.path, 'prod'));
      final devRoot = Directory(p.join(sandbox.path, 'dev'));

      final sentinels = <String, List<int>>{
        p.join(prodRoot.path, 'shared_preferences.json'): utf8.encode(
          '{"prod":true}',
        ),
        p.join(prodRoot.path, 'credentials', '999.json'): utf8.encode(
          '{"accessToken":"prod_secret"}',
        ),
        p.join(prodRoot.path, 'credentials', 'translation.json'): utf8.encode(
          '{"baidu":{"appId":"p"}}',
        ),
        p.join(prodRoot.path, 'databases', 'feeds.db'): utf8.encode(
          'prod-feed-sentinel',
        ),
        p.join(prodRoot.path, 'databases', 'actions.db'): utf8.encode(
          'prod-action-sentinel',
        ),
        p.join(prodRoot.path, 'databases', 'history.db'): utf8.encode(
          'prod-hist-sentinel',
        ),
        p.join(prodRoot.path, 'databases', 'watchlater.db'): utf8.encode(
          'prod-wl-sentinel',
        ),
        p.join(prodRoot.path, 'databases', 'local_novels.db'): utf8.encode(
          'prod-ln-sentinel',
        ),
        p.join(prodRoot.path, 'support', 'app.log'): utf8.encode('prod log'),
        p.join(prodRoot.path, 'temp', 'image_cache.bin'): utf8.encode(
          'prod temp',
        ),
        p.join(prodRoot.path, 'downloads', 'Parfait', 'keep.png'): utf8.encode(
          'prod img',
        ),
      };
      final initialMtimes = <String, DateTime>{};
      for (final entry in sentinels.entries) {
        final f = File(entry.key)..parent.createSync(recursive: true);
        f.writeAsBytesSync(entry.value, flush: true);
        initialMtimes[entry.key] = f.lastModifiedSync();
      }

      final previous = AppStoragePaths.active;
      final paths = AppStoragePaths.dev(devRoot, profileName: 'sentinel');
      await paths.ensureCreated();
      AppStoragePaths.setActive(paths);

      final prefsPlatform = DevFileSharedPreferencesAsyncPlatform(
        paths.preferencesFile!,
      );
      installPreferencesForTest(prefsPlatform);

      final container = ProviderContainer(
        overrides: [
          appStoragePathsProvider.overrideWithValue(paths),
          credentialStoreProvider.overrideWithValue(
            DevFileCredentialStore(paths.credentialsDir!),
          ),
          translationCredentialStoreProvider.overrideWithValue(
            DevFileTranslationCredentialStore(paths.credentialsDir!),
          ),
        ],
      );
      final feedDb = container.read(feedDatabaseProvider);
      final actionDb = container.read(actionDatabaseProvider);
      final historyDb = container.read(historyDatabaseProvider);
      final watchDb = container.read(watchLaterDatabaseProvider);
      final novelDb = container.read(localNovelDatabaseProvider);
      addTearDown(() async {
        await feedDb.close();
        await actionDb.close();
        await historyDb.close();
        await watchDb.close();
        await novelDb.close();
        container.dispose();
        AppStoragePaths.setActive(previous);
        if (await sandbox.exists()) await sandbox.delete(recursive: true);
      });

      // 1. Preferences
      final prefs = SharedPreferencesAsync();
      await prefs.setString('dev_marker', 'isolated_value');
      expect(await prefs.getString('dev_marker'), 'isolated_value');
      expect(paths.preferencesFile!.existsSync(), isTrue);

      // 2. Credentials & legacy translation session cleanup
      final credStore = container.read(credentialStoreProvider);
      await credStore.write(
        '900001',
        const Credential(accessToken: 'dev_tok', refreshToken: 'dev_ref'),
      );
      final loadedCred = await credStore.read('900001');
      expect(loadedCred?.accessToken, 'dev_tok');

      final trStore = container.read(translationCredentialStoreProvider);
      await trStore.writeBaidu(
        const BaiduTranslationCredentials(
          appId: 'dev_app',
          secret: 'dev_secret',
        ),
      );
      await trStore.retireLegacyWebSession();
      expect((await trStore.readBaidu())?.appId, 'dev_app');

      // 3. All 5 SQLite databases + support dir
      final dbPaths = [
        paths.databasePath(FeedDatabase.databaseName)!,
        paths.databasePath(ActionDatabase.databaseName)!,
        paths.databasePath(HistoryDatabase.databaseName)!,
        paths.databasePath(WatchLaterDatabase.databaseName)!,
        paths.databasePath(LocalNovelDatabase.databaseName)!,
      ];
      final historyRepo = container.read(historyRepositoryProvider);
      await feedDb.database;
      await actionDb.database;
      await watchDb.database;
      await novelDb.database;
      expect(await historyRepo.count(accountId: '900001'), 0);
      for (final dbPath in dbPaths) {
        expect(
          File(dbPath).existsSync(),
          isTrue,
          reason: 'missing dev db: $dbPath',
        );
      }

      final supportDir = await paths.resolveSupportDir();
      File(p.join(supportDir.path, 'dev.log')).writeAsStringSync('isolated');
      expect(supportDir.path, paths.supportDir!.path);

      // 4. Temp dir
      final tempDir = await paths.resolveTempDir();
      File(p.join(tempDir.path, 'img.bin')).writeAsStringSync('cache');
      expect(tempDir.path, paths.tempDir!.path);

      // 5. Downloads dir via DesktopFileMediaStoreSession
      final session = DesktopFileMediaStoreSession(
        baseDirectory: () async => paths.downloadsDir!,
      );
      final handle = await session.begin(
        displayName: '900001_p0.png',
        mimeType: 'image/png',
      );
      await handle.write([137, 80, 78, 71]);
      final outUri = await handle.finalize();
      expect(outUri.toFilePath(), contains(paths.downloadsDir!.path));

      // Sentinel verification: prod files are byte-for-byte & timestamp identical.
      for (final entry in sentinels.entries) {
        final f = File(entry.key);
        expect(f.existsSync(), isTrue);
        expect(
          f.readAsBytesSync(),
          entry.value,
          reason: 'mutated sentinel: ${entry.key}',
        );
        expect(
          f.lastModifiedSync(),
          initialMtimes[entry.key],
          reason: 'mtime changed: ${entry.key}',
        );
      }
    },
  );

  test(
    'redactDevText and redactDevMap mask tokens, cookies, headers, params, and envelopes',
    () {
      const envelopeB64 =
          'eyJ2ZXJzaW9uIjoyLCJwYXlsb2FkVHlwZSI6InBpeGl2LWFjY291bnQtdHJhbnNmZXIiLCJwYXlsb2FkIjp7fX0=';
      const raw =
          'GET https://app-api.pixiv.net/cb?code=secret_code&client_secret=cs_123&oauth_token=ot_456&baidu_secret=bs_789&status_code=200 '
          'Authorization: Basic dXNlcjpwYXNz X-Api-Key: sk_secret_key '
          'Cookie: a=1; PHPSESSID=secretcookie_val; theme=dark '
          'env=$envelopeB64';
      final redacted = redactDevText(raw);
      for (final secret in [
        'secret_code',
        'cs_123',
        'ot_456',
        'bs_789',
        'dXNlcjpwYXNz',
        'sk_secret_key',
        'secretcookie_val',
        envelopeB64,
      ]) {
        expect(redacted, isNot(contains(secret)));
      }
      expect(redacted, contains('status_code=200'));
      expect(redacted, contains(kRedactedPlaceholder));

      final setCookieRedacted = redactDevText(
        'Set-Cookie: PHPSESSID=setcookie_val; Path=/; HttpOnly',
      );
      expect(setCookieRedacted, isNot(contains('setcookie_val')));
      expect(setCookieRedacted, contains(kRedactedPlaceholder));

      final map = redactDevMap({
        'accessToken': 'abc',
        'refreshToken': 'def',
        'cookie': 'PHPSESSID=xyz',
        'Set-Cookie': 'a=b',
        'transferEnvelope': {'cipher': 'secret'},
        'nested': [
          {'x-parfait-workbench-token': 'wb123', 'route': '/recommended'},
        ],
      });
      final encoded = jsonEncode(map);
      for (final secret in [
        'abc',
        'def',
        'PHPSESSID',
        'a=b',
        'secret',
        'wb123',
      ]) {
        expect(encoded, isNot(contains(secret)));
      }
      expect(encoded, contains('/recommended'));
    },
  );

  test(
    'resolveDesktopDevRootFromEnv resolves desktop roots without creating prod dirs',
    () async {
      final sandbox = await Directory.systemTemp.createTemp(
        'parfait_env_root_',
      );
      addTearDown(() async {
        if (await sandbox.exists()) await sandbox.delete(recursive: true);
      });

      final winRoot = AppStoragePaths.resolveDesktopDevRootFromEnv(
        {'APPDATA': r'C:\Users\dev\AppData\Roaming'},
        isWindows: true,
        isLinux: false,
        isMacOS: false,
      );
      expect(
        winRoot?.path,
        r'C:\Users\dev\AppData\Roaming\io.github.lopution\parfait-dev\profiles',
      );

      final linuxProdDir = Directory(
        p.join(sandbox.path, 'io.github.lopution.parfait'),
      );
      final linuxRoot = AppStoragePaths.resolveDesktopDevRootFromEnv(
        {'XDG_DATA_HOME': sandbox.path},
        isWindows: false,
        isLinux: true,
        isMacOS: false,
      );
      expect(linuxRoot?.path, p.join(sandbox.path, 'parfait-dev', 'profiles'));
      expect(linuxProdDir.existsSync(), isFalse);

      final macRoot = AppStoragePaths.resolveDesktopDevRootFromEnv(
        {'HOME': '/Users/dev'},
        isWindows: false,
        isLinux: false,
        isMacOS: true,
      );
      expect(
        macRoot?.path,
        '/Users/dev/Library/Application Support/parfait-dev/profiles',
      );
    },
  );

  test(
    'corrupt dev credential files fail without leaking plaintext tokens (ERR-06)',
    () async {
      final sandbox = await Directory.systemTemp.createTemp(
        'parfait_corrupt_cred_',
      );
      addTearDown(() async {
        if (await sandbox.exists()) await sandbox.delete(recursive: true);
      });

      final credDir = Directory(p.join(sandbox.path, 'credentials'));
      final pixivDir = Directory(p.join(credDir.path, 'pixiv'))
        ..createSync(recursive: true);
      final encoded = base64UrlEncode(
        utf8.encode('900001'),
      ).replaceAll('=', '');
      File(
        p.join(pixivDir.path, '$encoded.json'),
      ).writeAsStringSync('{"accessToken":"leaked_secret_token", broken');
      File(
        p.join(credDir.path, 'translation.json'),
      ).writeAsStringSync('{"baiduSecret":"leaked_baidu_secret", broken');

      final credStore = DevFileCredentialStore(credDir);
      await expectLater(
        credStore.read('900001'),
        throwsA(
          isA<CredentialStoreException>().having(
            (e) => e.cause.toString(),
            'cause',
            isNot(contains('leaked_secret_token')),
          ),
        ),
      );

      final trStore = DevFileTranslationCredentialStore(credDir);
      await expectLater(
        trStore.readBaidu(),
        throwsA(
          isA<TranslationCredentialsStoreException>().having(
            (e) => e.cause.toString(),
            'cause',
            isNot(contains('leaked_baidu_secret')),
          ),
        ),
      );
    },
  );

  test(
    'dev Windows WebView2 blocks CookieManager and WebView resolution when uninitialized',
    () async {
      final sandbox = await Directory.systemTemp.createTemp(
        'parfait_wv_block_',
      );
      final previous = AppStoragePaths.active;
      final paths = AppStoragePaths.dev(sandbox, profileName: 'wv');
      AppStoragePaths.setActive(paths);
      DevWebViewEnvironmentHolder.resetForTest();
      addTearDown(() async {
        DevWebViewEnvironmentHolder.resetForTest();
        AppStoragePaths.setActive(previous);
        if (await sandbox.exists()) await sandbox.delete(recursive: true);
      });

      await expectLater(
        DevWebViewEnvironmentHolder.prewarm(
          paths,
          (_) async => throw StateError('WebView2 missing'),
          true,
        ),
        throwsStateError,
      );
      expect(DevWebViewEnvironmentHolder.initError, isA<StateError>());
      expect(
        DevWebViewEnvironmentHolder.isUnavailableInDevWindows(
          isWindowsOverride: true,
        ),
        isTrue,
      );
      expect(
        () => DevWebViewEnvironmentHolder.resolveForWebView(
          isWindowsOverride: true,
        ),
        throwsStateError,
      );

      final trStore = DevFileTranslationCredentialStore(paths.credentialsDir!);
      await expectLater(
        retireLegacyTranslationData(trStore, isWindowsOverride: true),
        throwsStateError,
      );
    },
  );
}
