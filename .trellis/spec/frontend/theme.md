---
prefix: THEME
applies_to:
  - lib/app/theme/**
  - lib/app/widgets/**
  - lib/app/app.dart
reviewed: 2026-11-18
---

# Theme, color and type

## Contents

- [Sources](#sources)
- [Color](#color)
- [Type and spacing](#type-and-spacing)
- [Chrome over artwork](#chrome-over-artwork)
- [Expression](#expression)

## Sources

### THEME-01 One theme, read from context
- **Rule:** `replicaTheme` builds the only light and dark `ThemeData` (with
  `NoSplash.splashFactory` and visible `onSurface` `highlightColor`,
  `hoverColor` and `focusColor` state layers so `InkWell`, `ListTile` and
  buttons keep crisp press/hover/focus feedback; tinted pills put their fill on
  the outer `Material` rather than inside `InkWell.child`). Feature code reads
  colors, text styles and component defaults from `Theme.of(context)`; it never
  builds a second palette or copies a component theme locally.
  `MaterialUiCompatibilityBridge` and `ForuiThemeHost` (`foruiThemeFrom` + `_ForuiDelegate` for the four shipped locales, defaulting to `FHapticFeedback.none()`) are installed inside the app builder so Forui widgets read the resolved `ColorScheme`, `FuncSemanticTokens`, `MotionScope`, and platform typography one-way without bundled fonts.
- **Why:** Local palettes drifted from the theme and broke dark mode and
  system colors; a transparent `highlightColor` under `NoSplash` left rows and
  buttons with zero press feedback, and opaque child boxes hid `InkWell` state
  layers.
- **Check:** `test/replica_theme_test.dart` "replicaTheme provides visible pressed state feedback for InkWell, ListTile, and buttons" "foruiThemeFrom bridges colors, hairlines, haptics, and keeps platform font" "ForuiThemeHost forwards MotionScope reduce to FAccessibilityMotion.disabled"
- **Code:** `lib/app/theme/replica_theme.dart`, `lib/app/theme/forui_theme_bridge.dart`, `lib/l10n/app_localizations_delegates.dart`, `lib/app/app.dart`

### THEME-02 No bundled font
- **Rule:** Text renders in the platform font with the engine's fallback
  chain. `fontFamilyFallback` exists only for the layout test harness.
- **Why:** The user's ROM font is part of the system look; a bundled family
  overrides it.
- **Check:** `test/architecture/l10n_and_errors_test.dart` "no bundled Montserrat: text uses the platform font"
- **Code:** `lib/app/theme/replica_theme.dart`

### THEME-03 Component text styles derive from the resolved text theme
- **Rule:** AppBar, SnackBar, chip, dialog and rail text styles are set in
  the trailing `copyWith` of `replicaTheme` from the resolved
  `theme.textTheme`, never as a raw `TextStyle` inside `ThemeData(...)`.
- **Why:** Those components install the style wholesale; a raw style drops
  the text theme's letter spacing, line height and fallback chain.
- **Check:** manual
- **Code:** `lib/app/theme/replica_theme.dart`

## Color

### THEME-04 The accent comes from the color scheme
- **Rule:** Everything that paints the accent reads
  `colorScheme.primary` (text, icons, indicators) or
  `FuncSemanticTokens.brand` (fills, THEME-18). The accent tokens
  (`FuncTokens.primary`, `lightAccent`, `darkAccent`, the primary
  container and inverse primary ones) appear only in `func_tokens.dart`
  and `replica_theme.dart`.
- **Why:** With "follow system colors" on, the accent is the system palette;
  the constant would keep painting the brand pink.
- **Check:** `test/architecture/l10n_and_errors_test.dart` "the accent comes from the theme, not the brand constant"
- **Code:** `lib/app/theme/func_tokens.dart`

### THEME-05 System colors drive accents and the full surface ladder
- **Rule:** When a system palette (`systemColors`) is supplied, it drives both
  accent roles (`primary`, `onPrimary`, `primaryContainer`, `onPrimaryContainer`,
  `inversePrimary`, `surfaceTint`, `brand`, `onBrand`) and the full M3 surface,
  container, and neutral ladder (`surface`, `surfaceContainerLowest..Highest`,
  `secondary`, `secondaryContainer`, `onSurface`, `onSurfaceVariant`,
  `outline`, `outlineVariant`, `inverseSurface`, `onInverseSurface`, plus
  `FuncSemanticTokens.canvas`, `surface`, `surfaceRaised`, `contentPrimary`,
  `contentSecondary`, `divider`). Without a system palette, neutrals and the
  page/container ladder stay on Mika's `FuncTokens` warm-sakura ramp; status
  colors and the bookmarked heart always stay fixed.
- **Why:** User decision (11-19): after moving top bars to the clean canvas
  surface, limiting system colors to accent slots left ~90% of the viewport on
  hardcoded pink-tinted neutrals so wallpaper color appeared inactive. Driving
  the full M3 tonal surface ladder makes wallpaper tinting coherent across
  canvases, bars, cards, and Forui controls while keeping the default Mika
  palette untouched when system colors are off.
- **Check:** `test/replica_theme_test.dart` "a system palette drives accent, surface ladder, and semantic tokens"
- **Code:** `lib/app/theme/system_colors.dart`, `lib/app/theme/replica_theme.dart`, `lib/app/theme/func_semantic_tokens.dart`

### THEME-21 No system palette is a fallback, not an error
- **Rule:** `systemColorSchemesProvider` reads `MissingPluginException`
  from the palette and accent channels as "the platform has no system
  palette" and returns null. Startup and the fixed theme keep working.
  A platform without a `dynamic_color` implementation keeps this fallback.
- **Why:** `dynamic_color` has no iOS implementation; an uncaught platform
  exception on startup would leave the app unthemed.
- **Check:** `test/replica_theme_test.dart` "a platform without a dynamic colour plugin has no system colours"
- **Code:** `lib/app/theme/system_colors.dart`

### THEME-06 Text keeps 4.5:1 on every surface tier
- **Rule:** The six container tiers stay monotonic and distinguishable, and
  `onSurface` / `onSurfaceVariant` keep at least 4.5:1 on each tier in both
  themes. Meta text on a selected row uses `onPrimaryContainer` at alpha
  0.8, not the caption gray. The light theme's text accent (`primary`,
  THEME-18) keeps 4.5:1 on the page and up to `surfaceContainer` (sheets);
  on `surfaceContainerHigh` (dialogs) it measures about 4.4:1 and on the
  highest tier about 4.1:1. The dark theme's keeps 4.5:1 on every tier.
  Selection text (`onPrimaryContainer` on `primaryContainer`), the
  SnackBar's action and text keep 4.5:1 in both themes.
- **Why:** The caption gray measured about 3.9:1 on a selected dark row.
  User decision: a deeper accent that clears every tier read darker than
  the rose chosen, so dialogs and the highest tier are a known shortfall.
- **Check:** `test/replica_theme_test.dart` "text stays >= 4.5:1 on every surface tier in both themes", "the accent reads at 4.5:1 up to the sheet tier, on dark on all", "selection and the snackbar action read at 4.5:1 in both themes"
- **Code:** `lib/app/theme/func_tokens.dart`, `lib/app/widgets/entity_row.dart`

### THEME-07 Pink is for actions, selection and indicators
- **Rule:** `primary` marks primary actions, selected states and
  indicators only. `secondary` and `secondaryContainer` are neutrals:
  tonal buttons and progress tracks take the ladder's highest tier
  (faintly pink with it, THEME-05), never the accent. Group titles use
  `onSurfaceVariant`, never `primary`. Selected controls use
  `primaryContainer` / `onPrimaryContainer`. Top-level Settings and Me
  entries use monochrome `AppIcons` on neutral surfaces (no multi-hue
  category color discs; SET-08). Tag
  chips are neutral pills; only keyboard focus rings them in the accent.
  A disabled control takes M3's disabled colors (`onSurface` at 0.38 for
  content, 0.12 for containers), never the accent, even when it is on.
  A bookmarked heart and its burst are `FuncTokens.bookmarked` (#FF4060)
  in both themes and under system colors: a state, not the accent.
  A count badge (`badgeTheme`) is the brand fill (THEME-18), never M3's
  error red. A selected choice row (`SettingsChoiceTile`) tints its title
  and check; its description stays `onSurfaceVariant`. The confirm of an
  irreversible action (removing an account, deleting a comment or a local
  novel, clearing credentials, cancelling downloads) is a
  `DangerFilledButton` in `error` / `onError`; a reversible confirm keeps
  the brand fill.
- **Why:** User decision: the accent loses its meaning when it decorates.
  Removing multi-hue category discs prevents system colors and bookmarks
  from competing with rainbow chrome, while a locked switch drawn in the
  accent read as tappable, a red filter count read as an error, and removing
  an account in the same pink as saving a setting gave no pause.
- **Check:** `test/replica_theme_test.dart` "a disabled switch that is on takes no accent", "text on the error fill reads at 4.5:1 in both themes"
- **Code:** `lib/app/theme/replica_theme.dart`, `lib/app/widgets/settings/settings_tile.dart`, `lib/app/widgets/tag_chips.dart`, `lib/app/widgets/danger_filled_button.dart`, `lib/app/widgets/settings/settings_choice_tile.dart`

### THEME-18 The accent is two colors: text and fill, plus canvas top bars
- **Rule:** With the default palette, `colorScheme.primary` paints text,
  small icons, indicators and outlines: #B44673 on the light theme,
  #EBA6C6 on the dark. `FuncSemanticTokens.brand` (#E077A6 in both) under
  `onBrand` (white) paints fills: `FilledButton` through
  `filledButtonTheme`, the follow button, the solid `ReplicaButton`.
  Selection is a pale container under dark text on the light theme
  (#F5D6E4 / #6D3047) and a deep one under light text on the dark
  (#5C3443 / #FEE8F3); it is never the fill. Top bars (`AppTopBar`) use the
  unified clean page canvas (`FuncSemanticTokens.canvas`) across all five
  platforms (`brandedHeaderSurface == canvas`, `brandedHeaderForeground == text`,
  `brandedHeaderTabUnselected == textSecondary`), revealing `topBarShadow` and
  a `1dp` `brandHairline` edge in `ScrollEdgeShadow` when content scrolls under
  the bar (while `FuncBottomNav` draws a continuous `1dp` top `brandHairline`).
  `replicaTheme` keeps `TextButtonThemeData` disabled alpha at `0.48` and sets
  `ProgressIndicatorThemeData` (`primary` / `brandHairline` track /
  `StrokeCap.round`); `AppTopBar` wraps `leading` and `actions` in
  `IconButtonTheme` with `0.48` disabled alpha so disabled controls stay
  `>= 0.45` without breaking `IconTheme.merge` elsewhere. A system palette
  drives both accent roles and the M3 surface/neutral ladder (THEME-05).
- **Why:** The brand pink measured about 2.9:1 as text on the light page.
  User decision: fills keep the brand pink with white text (2.85:1, accepted),
  cherry-blossom text/selection tokens avoid M3's purple drift, and unifying
  compact phone top bars onto the clean canvas eliminates harsh light-mode
  blocks and brings cross-platform visual parity with a whisper-thin hairline on
  scroll.
- **Check:** `test/replica_theme_test.dart` "fills are the brand pink under white; selection stays tonal" "header tokens use clean canvas and keep >= 4.5:1 contrast"; `test/shared_widgets_test.dart` "AppTopBar keeps disabled IconButton and TextButton foreground alpha >= 0.45"
- **Code:** `lib/app/theme/replica_theme.dart`, `lib/app/theme/func_tokens.dart`, `lib/app/theme/func_semantic_tokens.dart`, `lib/app/widgets/app_top_bar.dart`, `lib/app/widgets/func_bottom_nav.dart`

### THEME-08 Status color goes on the icon, not the text
- **Rule:** In status rows the icon carries the semantic color (success,
  warning, danger); the status text stays `onSurfaceVariant`. The status
  tones are M3's tone 40 on the light theme and tone 80 on the dark; the
  network probe keeps its own fixed literals.
- **Why:** Tinted status text measured below 4.5:1 on `surface`.
- **Check:** manual
- **Code:** `lib/features/settings/pages/download_task_presentation.dart`

### THEME-09 A chip on a same-tier surface needs a hairline
- **Rule:** A chip or action pill whose fill equals the surface it sits on
  draws a hairline border (`divider` token or a tinted outline).
- **Why:** Same-value fills disappear in both themes.
- **Check:** manual
- **Code:** `lib/app/widgets/tag_chips.dart`

### THEME-10 Prompts follow inverted light / elevated dark chrome
- **Rule:** On light themes, prompts (`PromptHost`) use `inverseSurface` /
  `onInverseSurface` with `inversePrimary` actions; on dark themes, prompts use
  `surfaceContainerHigh` with `onSurface` text, `primary` actions, and a
  `outlineVariant` border (`FuncShape.card`), floating at the layer elevation
  (THEME-20).
- **Why:** Light themes need high-contrast dark banners, whereas dark themes
  avoid harsh white slabs by elevating onto `surfaceContainerHigh` with a crisp
  hairline border so toasts stay legible above sheets and cards.
- **Check:** manual
- **Code:** `lib/app/widgets/prompt_host.dart`

## Type and spacing

### THEME-11 One type scale
- **Rule:** Text sizes and weights come from the `textTheme` roles set in
  `replicaTheme`, or from a `FuncSemanticTokens` style derived from them.
  A `fontSize:` literal is allowed only for a deliberately fixed size
  (the bottom bar's 12sp label base).
- **Why:** Local sizes formed a second ramp that did not follow the theme.
- **Check:** manual
- **Code:** `lib/app/theme/replica_theme.dart`, `lib/app/theme/func_semantic_tokens.dart`

### THEME-12 Spacing and radii use tokens
- **Rule:** In `lib/app/**` and `lib/features/**` (outside
  `lib/app/theme/**`), numeric `EdgeInsets` and `Radius.circular` values,
  and `SizedBox` gaps between children, use `FuncSpacing` and `FuncShape`
  (`badge` 6, `control` 10, `card` 12, `panel` 16, `dialog` 18, `sheet` top-22,
  `pill` 999). Pick the nearest spacing token (6 → `sm`, 10 → `md` for card text
  indent else `sm`, 20 → `xl` for page margins else `lg`, 28 → `xxl`).
  Exceptions are allow-listed per file with a reason and a count.
- **Why:** Hand-picked values drifted page by page.
- **Check:** `test/architecture/ui_conventions_test.dart`
- **Code:** `lib/app/theme/func_semantic_tokens.dart`, `lib/app/theme/func_tokens.dart`

### THEME-13 Text fields share one look
- **Rule:** Text fields use the theme's outlined decoration with a
  floating label; call sites do not set `border`. A filter over loaded
  content is a `SearchBar`; the theme's `SearchBarThemeData` makes it flat
  on `surfaceContainerHigh`, and call sites set only its size. A form's
  save is a `FilledButton` at the end of its card (SET-09).
- **Why:** Pages each styled their fields, search bars and save buttons
  differently.
- **Check:** manual
- **Code:** `lib/app/theme/replica_theme.dart`

## Chrome over artwork

### THEME-14 Controls over artwork use ArtworkControls
- **Rule:** Icon controls over artwork (detail top bar, profile banner,
  viewer) use `ArtworkControls`: neutral `onSurface` glyphs (white on the
  viewer) with a surface-colored dual-ring outline (1.0dp inner ring at
  0.6dp blur plus 1.8dp outer ring at 1.0dp blur) over dual ambient blurs
  (radius 4.0 and 8.0). No disc under a control and no gradient scrim over
  the artwork. `AppTopBar` sets `actionsIconTheme` alongside `iconTheme`
  when `overArtwork` is true so trailing overflow glyphs match leading
  controls. Pills and counters keep the `FuncTokens.imageControl` /
  `onImageControl` pair. An accent on the always-black viewer stage is
  `brand`, not the light theme's deeper text accent.
- **Why:** A plain glyph washes out on a white artwork; discs and scrims
  were rejected as covering the work. A single 1dp ring and faint blur still
  left trailing top-bar icons low-contrast over busy saturated illustrations on
  portrait tablets, so both icon themes receive the strengthened dual-ring
  halo. An accent glyph on every work made the accent decoration (THEME-07).
- **Check:** manual
- **Code:** `lib/app/widgets/artwork_controls.dart`, `lib/app/widgets/app_top_bar.dart`

### THEME-15 Badges over artwork are EntityBadge
- **Rule:** Every marker painted over artwork is an `EntityBadge` on the
  `imageControl` scrim. No badge picks its own color: R-18 and AI differ
  by text, not fill. A ranking position is not a badge but an
  `EntityRankLabel`: on a work card a column before the title and author
  lines, on a novel row before the title. Ranks 1–3 take
  `rankPodium` (heavier, larger, `onSurface`), the rest `rank`
  (`onSurfaceVariant`), both tabular.
- **Why:** Colored badges were illegible on some artworks and read as
  warnings.
- **Check:** `test/illust_card_badges_test.dart`
- **Code:** `lib/app/widgets/entity_row.dart`

### THEME-16 Icons are unified outlined vector glyphs; filled marks selection or state
- **Rule:** App UI icons come from two unified fine-stroke vector families:
  custom `24×24` MingCute / Pixiv glyphs compiled deterministically into
  `assets/icon.ttf` (`AppIcons` in `lib/app/icons/app_icons.dart`, built via
  `tool/build_icons.py`), and `forui`'s bundled Lucide icons bridged through
  `UiIcons` (`lib/app/icons/ui_icons.dart` -> `FLucideIcons`, including
  automatic `matchTextDirection` mirroring on directional arrows/chevrons,
  horizontal `UiIcons.more` ellipsis for overflow menus, and `UiIcons.dropdown`
  `chevronsUpDown` for menu triggers). No raw Material `Icons.*` or unbridged
  `FLucideIcons.*` appears in `lib/` outside `lib/app/icons/` (platform-native
  `BackButtonIcon` remains system-supplied). An action, an unselected
  destination or a placeholder uses the outlined glyph. The `*Filled` twin marks
  a state: a selected primary navigation or workspace rail destination
  (`FuncBottomNav`, `ShellRail`, `SettingsPage`, `MeDashboardPage`), a toggle
  that is on (a muted work `AppIcons.eyeOffFilled`, muted user
  `AppIcons.userOffFilled`, bookmarked heart `AppIcons.heartFilled`,
  watch-later `AppIcons.watchLaterFilled`), or a download task status.
  One glyph, one meaning: `AppIcons.watchLater` is watch-later,
  `AppIcons.heart` is a pixiv bookmark, `AppIcons.series` is a series,
  `AppIcons.watchlistAdd` / `AppIcons.watchlistAdded` toggles following
  series, `AppIcons.motion` badges Ugoira works while `AppIcons.playCircle`
  overlays the playable preview, and `AppIcons.accountManage` opens
  account management. Unmuting is a text button: no icon says it.
- **Why:** Mixing stock Material outlines and uneven icon sets broke
  stroke weight consistency and muddled meanings across pages; unifying
  every glyph under `AppIcons` and `UiIcons` keeps optical geometry and stroke
  weight consistent while preserving distinct outlined vs `*Filled` state
  contrast across light, dark, mobile, and desktop shells.
- **Check:** `test/architecture/ui_conventions_test.dart` "a filled icon with an outlined twin marks a state", `test/icon_font_test.dart` "pubspec registers the iconFont family pointing at assets/icon.ttf"
- **Code:** `lib/app/icons/app_icons.dart`, `lib/app/icons/ui_icons.dart`, `tool/build_icons.py`, `lib/app/widgets/card_actions/illust_card_actions.dart`, `lib/app/widgets/watchlist_toggle.dart`

### THEME-17 Every icon button names its action
- **Rule:** Every `IconButton` has a localized tooltip saying what it
  does, which is also its screen-reader label. A button that labels
  itself through `Semantics` (the bookmark heart, whose long press opens
  the tag picker) is pinned in the check.
- **Why:** An icon alone is a guess, and a screen reader read "button".
- **Check:** `test/architecture/ui_conventions_test.dart` "every icon button has a tooltip"
- **Code:** `lib/app/widgets/bookmark_switch_button.dart`

## Expression

### THEME-19 Ambient light is the subject's tone, around it
- **Rule:** Where the frame answers its subject, it is an `AmbientWash` of
  a small decode of an image the page already holds, blurred and
  tone-locked by `AmbientTone`: the wash takes the page's lightness and a
  share of the image's colour, so neutral images give plain page. It sits
  beside or behind the subject and fades into the page, never over it.
  The places:
  - the detail band above a short first image, and the wide detail stage
    (page selection keeps the plain stage); the band stays the page
    colour while the image flies in and rises from the image's edge once
    it has landed (`MotionTokens.ambientRise`);
  - a profile header without a cover, from the avatar (with neither, a
    plain container);
  - the first-run pages (welcome, login), from the app icon, behind the
    header (`ScrollableFormShell.brandGlow`). No pixiv artwork decorates
    them.

  A wash draws in the page's own pass: `AmbientWash` takes an image
  provider, blurs it once at decode (`BlurredImage`), and puts the tone and
  its fade-in on the image's paint. Its fades are page-colour gradients
  over it, not masks. No filter or mask widget wraps a wash that scrolls
  or swipes; the still welcome glow is the one widget-blurred wash.
- **Why:** User decision: the frame answers the work, warm and quiet. A
  desaturated mirror at partial alpha turned dark or saturated works into
  a grey haze on the light page and a muddy band on the dark one. A
  cover-less profile was a grey band; the welcome page was mostly blank.
  Impeller keeps no raster cache: the band's mask, blur and tone filter
  were drawn offscreen every frame, eight layers a frame in a side swipe
  over two pages, and the swipe dropped frames (trace, 11-01). The band
  tinted ahead of its image, or flown with it, read apart (user, 11-05).
- **Check:** `test/ambient_wash_test.dart` "ambient light keeps the page lightness and a share of the colour" "a wash draws its image toned, in the page pass", `test/illust_detail_page_test.dart` "a short first image sits a band low; Hero and badge keep to it" "the band lights up from the image once it has landed", `test/user_profile_test.dart` "a profile without a cover lights its header from the avatar"; placement manual (review shots, light and dark)
- **Code:** `lib/app/widgets/ambient_wash.dart`, `lib/features/illust/detail/widgets/page_image.dart`, `lib/features/illust/detail/illust_detail_page.dart`, `lib/features/profile/profile_header_delegate.dart`, `lib/app/widgets/scrollable_form_shell.dart`

### THEME-20 A shadow marks a layer, or content under a bar
- **Rule:** Shadows come from `FuncSemanticTokens` or the theme's one
  layer elevation. Lifts and `colorScheme.shadow` are the cocoa ink on the
  light theme, not black; the bar shadow stays neutral. A translucent
  layer frosts what passes under it and draws its lift outside its own
  shape. Work cards and feed artwork thumbnails take no shadow or inner
  border (pure `ClipRRect` at `FuncShape.card` in both light and dark themes;
  desktop hover and keyboard focus rings remain in `IllustCard`). The shadows:
  - `barShadow` and `topBarShadow` where content scrolls under a bar;
  - `layerLift` under a layer resting above the page (the detail capsule);
  - `cardLift` under a card that is an object of its own (the detail
    author card);
  - elevation 6 in `colorScheme.shadow` and a `1dp` `brandHairline` border
    for menus, dialogs (`AppAlertDialog` backed by `FDialog` with an inner
    transparent `Material`), linear bars (`AppProgressBar` backed by
    `FDeterminateProgress` / `FProgress`), modal sheets, adaptive
    popovers/side-sheets, and prompts in both light and dark themes.
- **Why:** User decision: depth may grow richer, but a shadow says above
  or under and never decorates. Through the unfrosted 85% capsule, passing
  captions and badges smeared; a whole-shape shadow under a translucent
  surface darkened the surface itself. Flat menus, dialogs and prompts
  read as part of the page, while a 1dp `brandHairline` keeps light and dark
  overlays separated on every backdrop.
- **Check:** `test/replica_theme_test.dart` "overlays and progress indicators share brandHairline across themes"
- **Code:** `lib/app/theme/func_tokens.dart`, `lib/app/theme/func_semantic_tokens.dart`, `lib/app/theme/replica_theme.dart`, `lib/app/theme/forui_theme_bridge.dart`, `lib/app/widgets/app_dialog.dart`, `lib/app/widgets/app_progress_bar.dart`, `lib/app/motion/app_overlays.dart`, `lib/app/widgets/app_spinner.dart`, `lib/features/illust/detail/widgets/detail_action_bar.dart`
