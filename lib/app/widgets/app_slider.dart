import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';

import '../haptics/app_haptics.dart';
import '../theme/forui_theme_bridge.dart';

/// The app's only slider: [FSlider] by default, or [AppSlider.scrubber] for
/// the viewer dark-scrim page scrubber backed by Material [Slider].
///
/// With [divisions] every step change plays one tick haptic (AppHaptics
/// throttles a fast fling). Continuous sliders stay silent.
///
/// Defaults [canRequestFocus] to `false` so pointer drags never steal focus
/// away from keyboard shortcuts (`ArrowLeft` / `ArrowRight`).
class AppSlider extends StatefulWidget {
  const AppSlider({
    super.key,
    required this.value,
    required this.onChanged,
    this.min = 0,
    this.max = 1,
    this.divisions,
    this.label,
    this.onChangeEnd,
    this.focusNode,
    this.autofocus = false,
    this.canRequestFocus = false,
  }) : _scrubber = false;

  /// Dark-scrim viewer scrubber preserving [SliderTheme] alignment for the
  /// page-preview bubble above the track.
  const AppSlider.scrubber({
    super.key,
    required this.value,
    required this.onChanged,
    this.min = 0,
    this.max = 1,
    this.divisions,
    this.label,
    this.onChangeEnd,
    this.focusNode,
    this.autofocus = false,
    this.canRequestFocus = false,
  }) : _scrubber = true;

  final double value;
  final ValueChanged<double>? onChanged;
  final double min;
  final double max;
  final int? divisions;
  final String? label;
  final ValueChanged<double>? onChangeEnd;
  final FocusNode? focusNode;
  final bool autofocus;
  final bool canRequestFocus;
  final bool _scrubber;

  @override
  State<AppSlider> createState() => _AppSliderState();
}

class _AppSliderState extends State<AppSlider> {
  FocusNode? _ownFocusNode;

  bool get _allowFocus => widget.canRequestFocus || widget.autofocus;

  FocusNode get _effectiveFocusNode {
    if (widget.focusNode != null) return widget.focusNode!;
    return _ownFocusNode ??= FocusNode(
      debugLabel: 'AppSlider',
      canRequestFocus: _allowFocus,
      skipTraversal: !_allowFocus,
    );
  }

  @override
  void didUpdateWidget(AppSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.focusNode != null && _ownFocusNode != null) {
      _ownFocusNode!.dispose();
      _ownFocusNode = null;
    } else if (widget.focusNode == null && _ownFocusNode != null) {
      _ownFocusNode!
        ..canRequestFocus = _allowFocus
        ..skipTraversal = !_allowFocus;
    }
  }

  @override
  void dispose() {
    _ownFocusNode?.dispose();
    super.dispose();
  }

  double get _span => widget.max - widget.min;

  double _normalize(double raw) {
    final span = _span;
    if (span <= 0) return 0;
    return ((raw - widget.min) / span).clamp(0.0, 1.0);
  }

  double _denormalize(double normalized) {
    final span = _span;
    if (span <= 0) return widget.min;
    final divisions = widget.divisions;
    if (divisions != null && divisions > 0) {
      final stepIndex = (normalized.clamp(0.0, 1.0) * divisions).round();
      return (widget.min + stepIndex * (span / divisions)).clamp(
        widget.min,
        widget.max,
      );
    }
    return (widget.min + normalized.clamp(0.0, 1.0) * span).clamp(
      widget.min,
      widget.max,
    );
  }

  @override
  Widget build(BuildContext context) {
    final onChanged = widget.onChanged;
    if (widget._scrubber) {
      return Slider(
        value: widget.value,
        min: widget.min,
        max: widget.max,
        divisions: widget.divisions,
        label: widget.label,
        onChangeEnd: widget.onChangeEnd,
        focusNode: _effectiveFocusNode,
        autofocus: widget.autofocus,
        onChanged: onChanged == null
            ? null
            : (next) {
                if (widget.divisions != null && next != widget.value) {
                  AppHaptics.tick();
                }
                onChanged(next);
              },
      );
    }

    final normalized = _normalize(widget.value);
    final divisions = widget.divisions;
    final discrete = divisions != null && divisions > 0;
    final marks = discrete
        ? [
            for (var i = 0; i <= divisions; i++)
              FSliderMark(value: i / divisions, tick: false),
          ]
        : const <FSliderMark>[];

    void handleChange(FSliderValue next) {
      if (onChanged == null) return;
      final resolved = _denormalize(next.max);
      if (discrete && resolved != widget.value) {
        AppHaptics.tick();
      }
      onChanged(resolved);
    }

    final control = discrete
        ? FSliderControl.liftedDiscrete(
            value: FSliderValue(max: normalized),
            interaction: FSliderInteraction.tapAndSlideThumb,
            onChange: handleChange,
          )
        : FSliderControl.liftedContinuous(
            value: FSliderValue(max: normalized),
            interaction: FSliderInteraction.slide,
            onChange: handleChange,
          );

    return ForuiThemeHost.ensure(
      context,
      Focus(
        focusNode: _effectiveFocusNode,
        autofocus: widget.autofocus,
        canRequestFocus: _allowFocus,
        skipTraversal: !_allowFocus,
        child: ExcludeFocus(
          excluding: !_allowFocus,
          child: FSlider(
            control: control,
            marks: marks,
            enabled: onChanged != null,
            tooltipControls: widget.label == null
                ? const FSliderTooltipControls.disabled()
                : const FSliderTooltipControls(),
            tooltipBuilder: (_, _) => Text(widget.label ?? ''),
            semanticValueFormatterCallback: (n) =>
                widget.label ??
                _denormalize(n).toStringAsFixed(discrete ? 0 : 1),
            onEnd: widget.onChangeEnd == null
                ? null
                : (v) => widget.onChangeEnd!(_denormalize(v.max)),
          ),
        ),
      ),
    );
  }
}
