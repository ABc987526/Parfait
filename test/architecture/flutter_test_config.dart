import 'dart:async';

/// Architecture scans are pure filesystem static checks: bypass the root
/// `test/flutter_test_config.dart` so they never initialize sqflite,
/// temp DB directories, leak_tracker, or shared_preferences.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  await testMain();
}
