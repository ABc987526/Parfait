import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../../l10n/context.dart';
import '../theme/func_semantic_tokens.dart';
import '../theme/func_tokens.dart';
import 'desktop_title_bar.dart';

const double kWindowsCaptionButtonWidth = 46;
const Color _closeHoverBackground = Color(0xFFC42B1C);

/// Shared minimize / maximize-restore / close button cluster used by both the
/// integrated overlay and `DesktopCommandBar`.
class DesktopWindowCaptionButtons extends StatelessWidget {
  const DesktopWindowCaptionButtons({
    super.key,
    required this.height,
    required this.isMaximized,
    required this.isActive,
    required this.nativeHoveredButton,
    required this.nativePressedButton,
    required this.maximizeKey,
    required this.actions,
    required this.brightnessListenable,
  });

  final double height;
  final bool isMaximized;
  final bool isActive;
  final String nativeHoveredButton;
  final String nativePressedButton;
  final GlobalKey? maximizeKey;
  final DesktopWindowActions? actions;
  final ValueListenable<Brightness>? brightnessListenable;

  Widget _cluster(BuildContext context, Brightness surfaceBrightness) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final iconBase = surfaceBrightness == Brightness.dark
        ? FuncTokens.white
        : theme.colorScheme.onSurface;
    final foreground = isActive ? iconBase : iconBase.withValues(alpha: 0.6);
    final hoverOverlay = surfaceBrightness == Brightness.dark
        ? FuncTokens.white.withValues(alpha: 0.10)
        : theme.colorScheme.onSurface.withValues(alpha: 0.08);
    final pressedOverlay = surfaceBrightness == Brightness.dark
        ? FuncTokens.white.withValues(alpha: 0.16)
        : theme.colorScheme.onSurface.withValues(alpha: 0.14);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _WindowCaptionButton(
          key: const Key('desktop-window-minimize'),
          tooltip: l10n.windowMinimize,
          height: height,
          kind: _CaptionButtonKind.minimize,
          foreground: foreground,
          hoverColor: hoverOverlay,
          pressedColor: pressedOverlay,
          onPressed: actions?.onMinimize,
        ),
        KeyedSubtree(
          key: maximizeKey,
          child: _WindowCaptionButton(
            key: const Key('desktop-window-maximize'),
            tooltip: isMaximized ? l10n.windowRestore : l10n.windowMaximize,
            height: height,
            kind: isMaximized
                ? _CaptionButtonKind.restore
                : _CaptionButtonKind.maximize,
            foreground: foreground,
            hoverColor: hoverOverlay,
            pressedColor: pressedOverlay,
            forceHovered: nativeHoveredButton == 'maximize',
            forcePressed: nativePressedButton == 'maximize',
            onPressed: actions?.onToggleMaximize,
          ),
        ),
        _WindowCaptionButton(
          key: const Key('desktop-window-close'),
          tooltip: l10n.windowClose,
          height: height,
          kind: _CaptionButtonKind.close,
          foreground: foreground,
          hoverColor: _closeHoverBackground,
          hoverForeground: FuncTokens.white,
          pressedColor: _closeHoverBackground.withValues(alpha: 0.85),
          onPressed: actions?.onClose,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final listenable = brightnessListenable;
    if (listenable == null) {
      return _cluster(context, Theme.of(context).brightness);
    }
    return ValueListenableBuilder<Brightness>(
      valueListenable: listenable,
      builder: (context, brightness, _) => _cluster(context, brightness),
    );
  }
}

enum _CaptionButtonKind { minimize, maximize, restore, close }

class _WindowCaptionButton extends StatefulWidget {
  const _WindowCaptionButton({
    super.key,
    required this.tooltip,
    required this.height,
    required this.kind,
    required this.foreground,
    required this.hoverColor,
    required this.pressedColor,
    this.hoverForeground,
    this.forceHovered = false,
    this.forcePressed = false,
    this.onPressed,
  });

  final String tooltip;
  final double height;
  final _CaptionButtonKind kind;
  final Color foreground;
  final Color hoverColor;
  final Color pressedColor;
  final Color? hoverForeground;
  final bool forceHovered;
  final bool forcePressed;
  final VoidCallback? onPressed;

  @override
  State<_WindowCaptionButton> createState() => _WindowCaptionButtonState();
}

class _WindowCaptionButtonState extends State<_WindowCaptionButton> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final effectivePressed = _pressed || widget.forcePressed;
    final effectiveHovered = _hovered || widget.forceHovered;
    final bg = effectivePressed
        ? widget.pressedColor
        : effectiveHovered
        ? widget.hoverColor
        : FuncTokens.transparent;
    final fg = (effectiveHovered || effectivePressed)
        ? (widget.hoverForeground ?? widget.foreground)
        : widget.foreground;

    Widget button = MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() {
        _hovered = false;
        _pressed = false;
      }),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onPressed,
        child: ColoredBox(
          color: bg,
          child: SizedBox(
            width: kWindowsCaptionButtonWidth,
            height: widget.height,
            child: Center(
              child: CustomPaint(
                size: const Size.square(10),
                painter: _CaptionGlyphPainter(kind: widget.kind, color: fg),
              ),
            ),
          ),
        ),
      ),
    );
    if (Overlay.maybeOf(context) != null) {
      button = Tooltip(message: widget.tooltip, child: button);
    }

    return Semantics(button: true, label: widget.tooltip, child: button);
  }
}

class _CaptionGlyphPainter extends CustomPainter {
  const _CaptionGlyphPainter({required this.kind, required this.color});

  final _CaptionButtonKind kind;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke
      ..isAntiAlias = true;
    final w = size.width;
    final h = size.height;

    switch (kind) {
      case _CaptionButtonKind.minimize:
        final y = (h / 2).floorToDouble() + 0.5;
        canvas.drawLine(Offset(0, y), Offset(w, y), paint);
      case _CaptionButtonKind.maximize:
        canvas.drawRect(Rect.fromLTWH(0.5, 0.5, w - 1, h - 1), paint);
      case _CaptionButtonKind.restore:
        const inset = 2.0;
        canvas.drawRect(
          Rect.fromLTWH(0.5, inset + 0.5, w - inset - 1, h - inset - 1),
          paint,
        );
        final back = Path()
          ..moveTo(inset + 0.5, inset + 0.5)
          ..lineTo(inset + 0.5, 0.5)
          ..lineTo(w - 0.5, 0.5)
          ..lineTo(w - 0.5, h - inset - 0.5)
          ..lineTo(w - inset - 0.5, h - inset - 0.5);
        canvas.drawPath(back, paint);
      case _CaptionButtonKind.close:
        canvas.drawLine(
          const Offset(0.5, 0.5),
          Offset(w - 0.5, h - 0.5),
          paint,
        );
        canvas.drawLine(Offset(w - 0.5, 0.5), Offset(0.5, h - 0.5), paint);
    }
  }

  @override
  bool shouldRepaint(_CaptionGlyphPainter oldDelegate) =>
      kind != oldDelegate.kind || color != oldDelegate.color;
}

/// Simulated macOS window traffic lights used by DevShell and multi-platform
/// visual review runs when emulating macOS on non-Apple hosts.
class SimulatedMacTrafficLights extends StatelessWidget {
  const SimulatedMacTrafficLights({super.key, this.height = FuncSpacing.xxl});

  final double height;

  static const double _dotDiameter = 12;
  static const Color _closeColor = Color(0xFFFF5F57);
  static const Color _minimizeColor = Color(0xFFFEBC2E);
  static const Color _zoomColor = Color(0xFF28C840);
  static const Color _borderColor = Color(0x26000000);

  @override
  Widget build(BuildContext context) {
    Widget dot(Color color) => DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        border: Border.all(color: _borderColor, width: 0.5),
      ),
      child: const SizedBox(width: _dotDiameter, height: _dotDiameter),
    );

    return ExcludeSemantics(
      child: SizedBox(
        height: height,
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: Padding(
            padding: const EdgeInsetsDirectional.only(start: FuncSpacing.md),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                dot(_closeColor),
                const SizedBox(width: FuncSpacing.sm),
                dot(_minimizeColor),
                const SizedBox(width: FuncSpacing.sm),
                dot(_zoomColor),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
