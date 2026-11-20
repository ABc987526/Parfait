import 'package:flutter/foundation.dart';

/// Optional listener installed only by the dev client (`main_dev.dart`) to
/// mirror redacted console logs into telemetry. Always `null` in production.
void Function(String message)? devLogListener;

/// Single owner of debug console logging (C5d).
///
/// Release builds compile this out entirely: diagnostic prints never leak
/// into release consoles.
void log(String message) {
  if (kReleaseMode) return;
  devLogListener?.call(message);
  debugPrint(message);
}
