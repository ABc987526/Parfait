import 'dart:ui';

import 'package:parfait/core/share/share_service.dart';

/// Records what a page hands to the platform share boundary — the system sheet
/// is an external boundary, so a recording stand-in is legitimate here (the
/// page itself always runs).
class RecordingShareService implements ShareService {
  final List<SharePayload> payloads = [];
  ShareOutcome outcome = ShareOutcome.openedSheet;

  SharePayload? get lastPayload => payloads.lastOrNull;

  @override
  Future<ShareOutcome> share(
    SharePayload payload, {
    Rect? sharePositionOrigin,
  }) async {
    payloads.add(payload);
    return outcome;
  }
}
