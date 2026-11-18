// THEME-16: icons are outlined; the filled twin of an outlined icon marks
// a state or selected destination. THEME-17: every IconButton names its
// action in a tooltip.
//
// Heuristic scans over lib/ with comments stripped, like the motion
// census: a call's arguments are read by matching brackets.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

final _comment = RegExp(r'//[^\n]*|/\*.*?\*/', dotAll: true);
final _icon = RegExp(r'(?<![\w.])Icons\.([a-z0-9_]+)');
final _appIcon = RegExp(r'(?<![\w.])AppIcons\.([a-zA-Z0-9_]+)');
final _iconButton = RegExp(
  r'(?<![\w.])IconButton(?:\.(?:filled|filledTonal|outlined))?\(',
);

/// Material filled icons whose outlined twin the app also uses, per file.
const _filledStates = <String, Set<String>>{};

/// Custom [AppIcons] `*Filled` glyphs whose outlined twin the app also uses,
/// per file: each marks a toggle/task status or an active navigation selection.
const _appFilledStates = <String, Set<String>>{
  // Card/row bookmark state.
  'lib/app/widgets/bookmark_switch_button.dart': {'heartFilled'},
  'lib/app/widgets/novel_entry.dart': {'heartFilled'},
  // Card actions that are on: the work/author is muted or in watch-later.
  'lib/app/widgets/card_actions/illust_card_actions.dart': {
    'eyeOffFilled',
    'userOffFilled',
    'watchLaterFilled',
  },
  // Primary navigation selected destination state.
  'lib/app/widgets/func_bottom_nav.dart': {
    'homeFilled',
    'newWorksFilled',
    'rankingFilled',
    'searchFilled',
    'userFilled',
  },
  // Rail settings active state.
  'lib/app/widgets/shell_rail.dart': {'settingsFilled'},
  // A tag chip's muted mark.
  'lib/app/widgets/tag_chips.dart': {'banFilled'},
  // Viewer info panel open toggle state.
  'lib/features/illust/viewer/image_viewer_page.dart': {'infoFilled'},
  // Me dashboard wide master-detail selection states.
  'lib/features/settings/me_dashboard_page.dart': {
    'heartFilled',
    'userFilled',
    'watchLaterFilled',
  },
  // Settings index wide master-detail About selection state.
  'lib/features/settings/settings_page.dart': {'infoFilled'},
  // Novel bookmark / marker active states.
  'lib/features/novel/novel_markers_page.dart': {'watchLaterFilled'},
  'lib/features/novel/novel_reader_stage_widgets.dart': {'watchLaterFilled'},
  // The profile menu's mute entry while the user is muted.
  'lib/features/profile/profile_header_delegate.dart': {'userOffFilled'},
  // A download task's or group's terminal/cancelled status.
  'lib/features/settings/pages/download_task_presentation.dart': {'banFilled'},
};

/// Icon buttons without a tooltip, per file.
const _untitledButtons = <String, int>{
  // The heart labels itself through Semantics: a tooltip would take the
  // long press that opens the tag picker.
  'lib/app/widgets/bookmark_switch_button.dart': 1,
};

Map<String, String> _sources() => {
  for (final file in Directory('lib').listSync(recursive: true))
    if (file is File &&
        file.path.endsWith('.dart') &&
        file.path != 'lib/app/icons/app_icons.dart')
      file.path: file.readAsStringSync().replaceAll(_comment, ''),
};

/// The argument text of the call opened at [start], without what its
/// nested brackets hold.
String _topLevelArguments(String src, int start) {
  final out = StringBuffer();
  var depth = 0;
  for (var i = start; i < src.length; i++) {
    final char = src[i];
    if (')]}'.contains(char)) {
      if (depth == 0) break;
      depth--;
    } else if ('([{'.contains(char)) {
      depth++;
    } else if (depth == 0) {
      out.write(char);
    }
  }
  return out.toString();
}

void main() {
  test('a filled icon with an outlined twin marks a state', () {
    final sources = _sources();
    final used = {
      for (final src in sources.values)
        for (final match in _icon.allMatches(src)) match[1]!,
    };
    final filled = <String, Set<String>>{};
    sources.forEach((file, src) {
      for (final match in _icon.allMatches(src)) {
        final name = match[1]!;
        if (used.contains('${name}_outlined')) {
          (filled[file] ??= {}).add(name);
        }
      }
    });
    expect(
      filled,
      _filledStates,
      reason:
          'THEME-16 an action uses the outlined icon — the filled one '
          'marks a state; pin a new state here with what it marks',
    );

    final usedApp = {
      for (final src in sources.values)
        for (final match in _appIcon.allMatches(src)) match[1]!,
    };
    final filledApp = <String, Set<String>>{};
    sources.forEach((file, src) {
      for (final match in _appIcon.allMatches(src)) {
        final name = match[1]!;
        if (name.endsWith('Filled') &&
            usedApp.contains(name.substring(0, name.length - 6))) {
          (filledApp[file] ??= {}).add(name);
        }
      }
    });
    expect(
      filledApp,
      _appFilledStates,
      reason:
          'THEME-16 a custom AppIcon uses the outlined twin at rest — '
          'the *Filled twin marks a state or selected destination',
    );
  });

  test('every icon button has a tooltip', () {
    final untitled = <String, int>{};
    _sources().forEach((file, src) {
      for (final match in _iconButton.allMatches(src)) {
        if (!_topLevelArguments(src, match.end).contains('tooltip:')) {
          untitled[file] = (untitled[file] ?? 0) + 1;
        }
      }
    });
    expect(
      untitled,
      _untitledButtons,
      reason:
          'THEME-17 an icon button names its action in a localized '
          'tooltip; pin one that labels itself through Semantics',
    );
  });
}
