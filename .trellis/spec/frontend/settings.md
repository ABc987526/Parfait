---
prefix: SET
applies_to:
  - lib/app/widgets/settings/**
  - lib/features/settings/**
reviewed: 2026-11-18
---

# Settings pages and the Me tab

## Contents

- [Rows and groups](#rows-and-groups)
- [Search and ownership](#search-and-ownership)
- [Me tab](#me-tab)

## Rows and groups

### SET-01 Rows sit in SettingsGroup cards, never Divider
- **Rule:** Settings rows go inside `SettingsGroup`, which draws each child
  as its own `surfaceContainer` card 8dp apart, the gap being the only
  separator; never a `Divider`, never a hand-built group container.
  A note on one row is that row's subtitle; a note on the whole group, or
  on content without a subtitle (a slider, a form), is the group
  `footer`. So is an empty group's line saying it is empty: never a card
  of its own. Notes on how to use a setting are not written (PAGE-20).
  On one page either every group has a title or none does. A leaving
  `Removable` row stops counting from the exit's first frame.
- **Why:** User decision: separate cards on settings and the Me dashboard
  replaced segmented lists and dividers. Notes set apart from their row and a
  page with one titled group read as unrelated. An empty group's note on
  a card read as a row to press.
- **Check:** `test/architecture/settings_rows_test.dart` "SettingsSection is gone from lib/"; `test/muted_items_page_test.dart` "an empty group says it is empty, off the cards"
- **Code:** `lib/app/widgets/settings/settings_group.dart`

### SET-02 Choose the row by the number of values
- **Rule:** A setting with two to four values is a `SettingsMenuTile`
  (current value at the row's end, menu anchored below it on the end
  edge, never over the title). A longer list is a `SettingsGroup` of
  `SettingsChoiceTile`s, which mark the chosen row with a check and
  `ListTile.selected`, not a radio. A two-way property is a
  `SettingsControl` switch; on `BottomBarSettingsPage`, locked-on
  destinations (`shown && onChanged == null`) override local `SwitchTheme`
  with a muted `0.40` primary-blended track, `onPrimary` thumb, and
  `lock_outline`/`check` `thumbIcon` while keeping `onChanged: null`
  (THEME-07), and omit `bottomBarMeLocked` under `DesktopCommandBarScope`.
- **Why:** `RadioListTile` is deprecated in the pinned Flutter, and
  `selected` is what screen readers announce; segmented buttons were
  removed (NAV-17), while locked-on bar destinations needed clear active
  visual state without looking toggleable.
- **Check:** `test/selection_controls_haptics_test.dart`
- **Code:** `lib/app/widgets/settings/settings_menu_tile.dart`, `lib/app/widgets/settings/settings_choice_tile.dart`, `lib/features/settings/pages/bottom_bar_settings_page.dart`

### SET-08 Page entries carry a circle in their group's color
- **Rule:** A row that opens a settings page from the index (`SettingsTile.topLevel`)
  or a section from the Me dashboard carries its icon on a 40dp circle in its
  group's category tone (`CategoryColors`, THEME-07): appearance purple, browse
  blue, network and download green, data orange; account, about and developer
  neutral (`neutralCategoryTone`). Rows inside a settings sub-page show the bare
  icon. Selected `SettingsTile`s step their overlay alpha across default/focused
  (0.12), hovered (0.16) and pressed (0.20), and `AccountSettingsPage` keeps the
  selected account's ID subtitle on `onSurfaceVariant`.
- **Why:** User decision: the circle marks top-level navigation across both Me
  and Settings and tells groups apart before their titles are read; on sub-pages
  the circle outweighed the setting rows around it.
- **Check:** manual
- **Code:** `lib/app/widgets/settings/settings_tile.dart`, `lib/features/settings/settings_page.dart`, `lib/features/settings/me_dashboard_page.dart`, `lib/features/settings/pages/account_settings_page.dart`

### SET-09 A form is one card with its save at the end
- **Rule:** A form's fields and its `FilledButton` save sit in one
  `SettingsGroupContent` card, the save at the card's bottom end. Reset
  and clear actions are `SettingsActionTile` rows in a group under it.
  "Optional" is a field's helper text, never part of its label.
- **Why:** User decision: loose fields and buttons on the page surface
  did not read as one form. A long label was cut at narrow widths.
- **Check:** `test/translation_credentials_page_test.dart`
- **Code:** `lib/features/settings/pages/translation_credentials_page.dart`, `lib/features/settings/network_settings_page.dart`

### SET-10 A row's end says what a tap does
- **Rule:** A row that opens a page of the app is a `SettingsTile` and
  ends in a chevron. A row that leaves the app (a browser) ends its link
  text in an `open_in_new` glyph in the text's size and colour. A row
  that acts in place names the action and shows no glyph; a value row
  shows its value at its end. Facts about the app (its icon, name and
  attribution) head the About page on the page surface, not in a card.
  The version stays a plain value row, though seven taps on it unlock
  the developer options.
- **Why:** User report (10-25): on the About page the license, the
  source link and the facts were alike cards; what opened a page, what
  left the app and what did nothing could not be told apart. The
  attribution left the settings search: it is not a setting.
- **Check:** manual
- **Code:** `lib/features/settings/pages/about_settings_page.dart`, `lib/app/widgets/settings/settings_tile.dart`

### SET-03 Hand-written ListTiles only for content rows
- **Rule:** A hand-written `ListTile` is allowed only for data entries
  (muted items, accounts, diagnostic results). Adding one extends the
  architecture test's per-file whitelist with a reason.
- **Why:** Hand-built settings rows drifted from the shared look and
  haptics.
- **Check:** `test/architecture/settings_rows_test.dart` "hand-written ListTile rows match the design whitelist"
- **Code:** `lib/app/widgets/settings`

### SET-04 A setting needs a real consumer
- **Rule:** Every setting names the product behaviour it changes, and that
  consumer is code outside the settings pages (a feed filter, a request
  header, a download path). A setting without one is removed. A persisted
  field whose UI waits for a concrete future data source may stay as a
  field but is not shown.
- **Why:** Settings shipped that changed nothing (a content filter and a
  file-naming option).
- **Check:** manual
- **Code:** `lib/core/settings`

## Search and ownership

### SET-05 settings_catalog.dart is the whole search index
- **Rule:** A new setting is added to `Setting` in `settings_catalog.dart`
  and nowhere else; its row passes `setting:` so it takes its title from
  the catalog and is anchored. Conditional rows' titles go in
  `extraKeys`.
- **Why:** Rows missing from the index were unreachable from search.
- **Check:** `test/settings_search_test.dart` "title hits come before option hits, case and spaces ignored" "a result opens its page with the setting revealed and marked"
- **Code:** `lib/features/settings/settings_catalog.dart`, `lib/app/widgets/settings/settings_anchor.dart`

### SET-06 Each setting has one home page and master-detail layout on wide workspaces
- **Rule:** `/settings/motion` holds animation speed, reduced motion, press
  feedback and haptic strength (shown on Android and on iOS devices where
  `hapticsCapabilityProvider` reports `tier != HapticsTier.none`). Credential
  export is in account management. History switches and delete-all are in the
  history page's overflow menu; there is no history settings page. The interface
  form (NAV-20) heads `/settings/navigation` and, like haptic strength, exists
  only where `Setting.available` says so: the row and its search entry alike.
  When `MasterDetailWorkspace.canDisplay` holds (`HomeShellChrome.contentSizeOf`
  `>= 840x480` and `viewport.width >= viewport.height * 0.75`), `/settings/all`
  and leaf settings routes wrapped in `SettingsAdaptiveHost` stay inside
  `MasterDetailWorkspace`: a 280dp `surfaceContainerLow` index pane (`52dp` top
  header with `1dp` `brandHairline`, `showChevron: false` rows, and vertical
  `ScrollEdgeFade(axis: Axis.vertical, fadeExtent: FuncSpacing.lg)` over
  `masterBody`) and a `1dp`
  `brandHairline`-separated nested detail `Navigator` (`SettingsDetailScope`,
  `EmbeddedHeaderScope` flat aligned `52dp` headers,
  `MotionTokens.stateFadeCurve` with leaving `IgnorePointer`, and
  `settingsNarrowBody` left-aligned up to 780dp); secondary leaf paths
  (`/settings/about/licenses`, `/settings/network/advanced`,
  `/settings/navigation/bottom-bar`, `/settings/translate/credentials`) map to
  their parent category and scroll the active rail entry into view.
- **Why:** The same setting on two pages drifted apart; hardwareless iPads omit
  dead haptic sliders while Taptic iPhones expose them; and unified `280dp`
  master-detail hosting keeps deep-linked settings pages coherent beside the
  collapsed shell rail without double headers or orphaned single-column sheets.
- **Check:** `test/settings_search_test.dart` "every catalog entry is on its page"; `test/settings_master_detail_test.dart` "wide desktop uses master-detail with nested navigation; below 840dp stays single column"; `test/shared_widgets_test.dart` "MasterDetailWorkspace wraps scrollable masterBody in vertical ScrollEdgeFade"
- **Code:** `lib/app/widgets/master_detail_workspace.dart`, `lib/app/navigation/route_branches.dart`, `lib/features/settings/settings_catalog.dart`, `lib/features/settings/settings_page.dart`, `lib/features/settings/settings_helpers.dart`, `lib/features/settings/pages/motion_settings_page.dart`

## Me tab

### SET-07 The Me tab puts content before settings on unified workspaces and cards
- **Rule:** On narrow layouts (`!MasterDetailWorkspace.canDisplay`), the Me root
  shows an `Icons.settings_outlined` shortcut (`settingsTitle` tooltip) in
  `AppTopBar.actions` (omitted when `DesktopCommandBarScope` owns chrome)
  while keeping the bottom `设置` row (`SET-08`). First comes the account header
  (`_AccountHeader`: 52dp avatar, name with neutral "Premium" pill, user ID,
  opening the profile; trailing manage icon button; or one sign-in button when
  signed out). Next comes the last eight history records as a row of square
  covers (or an empty-history `暂无浏览历史` entry card without a `"see all"`
  button when empty), followed by four grouped
  `SettingsGroup` / `SettingsTile.topLevel` sections (`showChevron: true`,
  `40dp` `CategoryColors` icon discs, `SET-08`, and live double-line count
  subtitles for downloads, watch later and local novels) ordering library,
  collections, recent tools and settings/about. An illustration cover opens the
  detail pager over the row's illustrations; covers in `IllustStore` fly via
  Hero (`'me-history'`, TRANS-07) while unseen ones do not. The row uses
  `HistoryVisibility` settled-route gating plus root-to-leaf `Navigator`
  secondary-animation checks so, while covered, it holds its order and slides
  on `MotionTokens.spatial` once uncovered (painting hovered covers in the top
  layer with unclipped `FuncSpacing.xs` lift headroom and asymmetric enter/exit
  curves). When
  `MasterDetailWorkspace.canDisplay` holds (`>= 840x480` content), the Me tab
  mounts `MasterDetailWorkspace` (`masterBody` scrolled with vertical
  `ScrollEdgeFade`) wrapping its nested detail `Navigator` in
  `SettingsDetailScope` (`780dp` left-aligned `settingsNarrowBody` and aligned
  `AppTopBar`): a `280dp` left rail (`40dp` `_CompactAccountHeader` card,
  grouped `showChevron: false` index items, plus settings/about on touch tablets
  without `DesktopCommandBarScope`) and a default `_MeOverviewPane` showing a
  profile summary card, `_RecentHistory` (`86dp` covers or an empty-history
  card), and a 2-column collection grid (`收藏`, `关注`, `追更`, `稍后再看`)
  jumping directly to sub-sections instead of duplicating vertical data rows.
- **Why:** User decision: settings filled two thirds of the page in a
  style of their own, and nothing showed what the user saw last; then
  narrow Me grouped rows clarify visual hierarchy while wide tablets/desktops
  share the same 280dp `MasterDetailWorkspace` pattern and `SettingsDetailScope`
  alignment as Settings without duplicating data lists or desktop footers. The
  history row holds its order while covered so Hero landing flights target the
  right cover before sliding to match recent history.
- **Check:** `test/settings_test.dart` "the Me header, manage button and end rows open their pages" "signed out, the Me header is one button to the login" "the dashboard badge counts downloads as they start and end" "the recent row follows the history and pages in its own order" "a recent cover flies to its work and back, an unseen one not" "a page over the row holds its order until it has left"; `test/settings_master_detail_test.dart` "wide Me dashboard wraps SettingsDetailScope and shows overview grid"
- **Code:** `lib/app/widgets/master_detail_workspace.dart`, `lib/app/widgets/scroll_edge_fade.dart`, `lib/app/widgets/settings/settings_group.dart`, `lib/app/widgets/settings/settings_tile.dart`, `lib/core/history/history_visibility.dart`, `lib/features/settings/me_dashboard_page.dart`
