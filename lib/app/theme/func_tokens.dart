import 'package:material_ui/material_ui.dart';

abstract final class FuncTokens {
  /// The brand pink, a cherry-blossom pink taken from Misono Mika's hair:
  /// fills (filled buttons, the follow button) under white text in both themes.
  static const Color primary = Color(0xFFE077A6);

  /// Light text accent (#B44673, 358 deg) and dark hair-pink text accent
  /// (#EBA6C6, 350 deg) from task/11-09-accent-mika-pink.
  static const Color lightAccent = Color(0xFFB44673);
  static const Color darkAccent = Color(0xFFEBA6C6);

  /// Deepened Mika cherry-rose surface for compact phone top bars, calibrated
  /// so both pure white titles/selected tabs (6.66:1) and warm sakura
  /// unselected tab labels (5.03:1) clear WCAG AA 4.5:1.
  static const Color lightBrandedHeader = Color(0xFF9E3661);

  /// Selection (`primaryContainer` / `onPrimaryContainer`): Mika's hair
  /// midtone (#F5D6E4) under deep rose (#6D3047) on light; deep rose (#5C3443)
  /// under hair highlight (#FEE8F3) on dark.
  static const Color lightPrimaryContainer = Color(0xFFF5D6E4);
  static const Color lightOnPrimaryContainer = Color(0xFF6D3047);
  static const Color darkPrimaryContainer = Color(0xFF5C3443);
  static const Color darkOnPrimaryContainer = Color(0xFFFEE8F3);

  /// The accent on the inverse surface (a SnackBar's action).
  static const Color lightInversePrimary = darkAccent;
  static const Color darkInversePrimary = lightOnPrimaryContainer;

  static const Color white = Color(0xFFFFFFFF);

  /// Neutrals and surface ladders carrying Mika's hair hue (346 deg light,
  /// 350 deg dark) with subtle chroma so pages read warm-sakura yet restrained.
  static const Color darkBackground = Color(0xFF1C1619);
  static const Color darkText = Color(0xFFD8D4D4);
  static const Color darkSubdued = Color(0xFF655F60);
  static const Color darkTextSecondary = Color(0xFFADA7A8);

  static const Color lightBackground = Color(0xFFFFF9FE);
  static const Color lightText = Color(0xFF3B3737);
  static const Color lightSubdued = Color(0x403B3737);
  static const Color lightTextSecondary = Color(0xFF696364);

  static const Color transparent = Color(0x00000000);
  static const Color imageOverlay = Color(0x3DFFFFFF);

  /// Faint 1dp inner frame for light-theme artwork thumbnails so white-ground
  /// illustrations hold their edge on [#FFF9FE].
  static const Color cocoaHairline = Color(0x143A2A2E);

  /// Original Mika container ladders above [lightBackground]/[darkBackground].
  static const Color lightContainerLow = Color(0xFFFFF6FB);
  static const Color lightContainer = Color(0xFFFCEFF6);
  static const Color lightContainerHigh = Color(0xFFF7E9F0);
  static const Color lightContainerHighest = Color(0xFFF2E2EA);
  static const Color darkContainerLow = Color(0xFF261E21);
  static const Color darkContainer = Color(0xFF2C2327);
  static const Color darkContainerHigh = Color(0xFF392E33);
  static const Color darkContainerHighest = Color(0xFF44373C);

  /// Inverted surface for transient chrome (SnackBar).
  static const Color lightInverseSurface = Color(0xFF342F30);
  static const Color darkInverseSurface = Color(0xFFE8E3E4);

  static const Color lightOnInverseSurface = Color(0xFFF7F2F2);
  static const Color darkOnInverseSurface = lightInverseSurface;

  /// Soft warm hairline dividers.
  static const Color darkDivider = Color(0x1FD8D4D4);
  static const Color lightDivider = Color(0x1F3B3737);

  /// Soft bar and layer shadows (warm cocoa #3A2A2E on light).
  static const List<BoxShadow> lightBarShadow = [
    BoxShadow(color: Color(0x1F000000), offset: Offset(0, -1), blurRadius: 2),
    BoxShadow(color: Color(0x0D000000), offset: Offset(0, -1), blurRadius: 5),
  ];
  static const List<BoxShadow> darkBarShadow = [
    BoxShadow(color: Color(0x47000000), offset: Offset(0, -1), blurRadius: 2),
    BoxShadow(color: Color(0x29000000), offset: Offset(0, -1), blurRadius: 5),
  ];

  static const List<BoxShadow> lightLayerLift = [
    BoxShadow(color: Color(0x1A3A2A2E), offset: Offset(0, 1), blurRadius: 3),
    BoxShadow(color: Color(0x2E3A2A2E), offset: Offset(0, 6), blurRadius: 20),
  ];
  static const List<BoxShadow> darkLayerLift = [
    BoxShadow(color: Color(0x66000000), offset: Offset(0, 1), blurRadius: 3),
    BoxShadow(color: Color(0x8C000000), offset: Offset(0, 8), blurRadius: 24),
  ];

  static const List<BoxShadow> lightCardLift = [
    BoxShadow(color: Color(0x143A2A2E), offset: Offset(0, 1), blurRadius: 2),
    BoxShadow(color: Color(0x123A2A2E), offset: Offset(0, 3), blurRadius: 10),
  ];
  static const List<BoxShadow> darkCardLift = [
    BoxShadow(color: Color(0x4D000000), offset: Offset(0, 1), blurRadius: 3),
  ];

  /// `colorScheme.shadow`.
  static const Color lightShadow = Color(0xFF3A2A2E);
  static const Color darkShadow = Color(0xFF000000);

  /// Scrim/overlay tone for dimming content under floating surfaces.
  static const Color surfaceOverlay = Color(0x52000000);

  /// Pills floating over artwork (page counters, load progress):
  /// dark enough that white glyphs keep 4.5:1 even over a pure white image.
  static const Color imageControl = Color(0x8C000000);
  static const Color onImageControl = white;

  /// A bookmarked heart and its burst: a state color, not the accent, so it
  /// stays under system colors and in both themes.
  static const Color bookmarked = Color(0xFFFF4060);

  /// Status tones: M3 tone 40 on the light theme, tone 80 on the dark.
  static const Color lightError = Color(0xFFBB1614);
  static const Color darkError = Color(0xFFFFB4A9);
  static const Color lightWarning = Color(0xFF964900);
  static const Color darkWarning = Color(0xFFFFB786);
  static const Color lightSuccess = Color(0xFF106D20);
  static const Color darkSuccess = Color(0xFF82DB7E);

  /// Text on the dark error fill: tone 20 of the same palette. White on
  /// tone 80 read at 1.7:1.
  static const Color darkOnError = Color(0xFF690003);

  static const Color networkProbeDnsWarning = Color(0xFFEF6C00);
  static const Color networkProbeSuccess = Color(0xFF388E3C);
  static const Color networkProbeWarning = Color(0xFFF57C00);
  static const Color networkProbeError = Color(0xFFD32F2F);
  static const Color networkProbeEch = Color(0xFF00796B);
  static const Color networkProbeNoSni = Color(0xFF303F9F);
  static const Color networkProbeNeutral = Color(0xFF616161);
}
