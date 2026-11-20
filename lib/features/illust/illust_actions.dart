import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/haptics/app_haptics.dart';
import '../../app/navigation/route_facade.dart'
    show showDownloadSubmittedSnackBar;
import '../../app/widgets/app_snack_bar.dart';
import '../../app/widgets/errors/error_details.dart' show showErrorSnackBar;
import '../../core/download/download_task.dart' show DownloadGroupSubmission;
import '../../core/entity/illust_entity.dart';
import '../../core/illust/illust_download_controller.dart';
import '../../core/share/share_service.dart';
import '../../l10n/context.dart';

/// Submits every page of [entity] through [illustDownloadControllerProvider]
/// (dedupe-safe) and surfaces either submission feedback or an error prompt.
Future<void> downloadAllIllustPages(
  BuildContext context,
  WidgetRef ref,
  IllustEntity entity,
) async {
  final l10n = context.l10n;
  final DownloadGroupSubmission submission;
  try {
    submission = await ref
        .read(illustDownloadControllerProvider)
        .downloadAll(entity);
  } catch (error) {
    if (!context.mounted) return;
    AppHaptics.error();
    showErrorSnackBar(
      context,
      action: l10n.downloadSubmissionFailed,
      error: error,
    );
    return;
  }
  if (!context.mounted) return;
  showDownloadSubmittedSnackBar(
    context,
    alreadyQueued: submission.group == null,
  );
}

/// Shares [entity]'s Pixiv URL, anchoring the platform popover to [context],
/// and shows a prompt when sharing falls back to copying the link.
Future<void> shareIllust(
  BuildContext context,
  WidgetRef ref,
  IllustEntity entity,
) async {
  final outcome = await ref
      .read(shareServiceProvider)
      .share(
        SharePayload.illust(
          id: entity.id,
          title: entity.title,
          author: entity.user.name,
        ),
        sharePositionOrigin: shareOriginOf(context),
      );
  if (outcome == ShareOutcome.copiedToClipboard && context.mounted) {
    showAppSnackBar(context, context.l10n.linkCopied);
  }
}
