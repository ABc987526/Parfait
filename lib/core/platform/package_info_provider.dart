import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Shared application package metadata loaded once per [ProviderContainer].
/// Retries are disabled so missing platform bindings in tests never leave
/// Riverpod backoff timers pending.
final packageInfoProvider = FutureProvider<PackageInfo>(
  (ref) => PackageInfo.fromPlatform(),
  retry: (retryCount, error) => null,
);
