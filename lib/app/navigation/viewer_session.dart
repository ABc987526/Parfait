import 'package:flutter/widgets.dart';

import '../pixiv_image.dart';
import 'home_shell_metrics.dart';

/// A page first decodes at twice the screen's width, sharp up to a 2x
/// zoom, instead of the whole file: an original is thousands of pixels
/// on a side, tens of megabytes decoded, and slow to decode on a swipe.
const double viewerPreviewScale = 2.0;

/// The decode width of an image viewer page's preview; both `openImageViewer`
/// and `ImageViewerPage` use this so the preloaded cache entry matches.
int viewerPreviewDecodeWidth(BuildContext context) => PixivImage.decodeWidthFor(
  HomeShellChrome.contentSizeOf(context).width * viewerPreviewScale,
  devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
);

/// Whether the viewer chrome (top bar + bottom bar) is visible. This is
/// session-level state: it deliberately survives page turns, keyboard turns,
/// page-sheet jumps and `replaceImageViewerPage` route swaps — the user asked
/// for an immersive view and it stays immersive until they ask otherwise.
bool viewerSessionChromeVisible = true;

/// A fresh viewer session opens with the chrome visible. `openImageViewer` is
/// the session entry — in-session page swaps go through
/// `replaceImageViewerPage` and must not reset this.
void beginImageViewerSession() {
  viewerSessionChromeVisible = true;
}

/// Test hook: resets the session-level viewer state so widget tests are
/// independent of each other's chrome toggles.
@visibleForTesting
void debugResetViewerSession() {
  viewerSessionChromeVisible = true;
}
