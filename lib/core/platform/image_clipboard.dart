import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Whether the current platform supports writing encoded image bytes to the OS
/// clipboard through [ImageClipboard].
bool get isDesktopImageClipboardSupported {
  if (kIsWeb) return false;
  return switch (defaultTargetPlatform) {
    TargetPlatform.windows ||
    TargetPlatform.macOS ||
    TargetPlatform.linux => true,
    TargetPlatform.android ||
    TargetPlatform.iOS ||
    TargetPlatform.fuchsia => false,
  };
}

/// Cross-platform desktop original-image clipboard bridge.
class ImageClipboard {
  const ImageClipboard._();

  static const MethodChannel _channel = MethodChannel(
    'parfait/image_clipboard',
  );

  /// Writes encoded image [bytes] (PNG/JPEG/WebP/GIF) as an image entry on the
  /// OS clipboard. Returns `false` if the platform rejected or lacks support.
  static Future<bool> copyImageBytes(Uint8List bytes) async {
    if (!isDesktopImageClipboardSupported || bytes.isEmpty) {
      return false;
    }
    try {
      final copied = await _channel.invokeMethod<bool>(
        'copyImage',
        <String, Object>{'bytes': bytes},
      );
      return copied ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}
