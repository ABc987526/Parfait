import 'package:flutter/rendering.dart'
    show
        BoxHitTestResult,
        ContainerBoxParentData,
        ContainerRenderObjectMixin,
        RenderBoxContainerDefaultsMixin;
import 'package:material_ui/material_ui.dart';

class MeHistoryCoverSlotData extends ContainerBoxParentData<RenderBox> {
  int paintPriority = 1;
}

class MeHistoryCoverSlot extends ParentDataWidget<MeHistoryCoverSlotData> {
  const MeHistoryCoverSlot({
    super.key,
    required this.paintPriority,
    required super.child,
  });

  final int paintPriority;

  @override
  void applyParentData(RenderObject renderObject) {
    final data = renderObject.parentData! as MeHistoryCoverSlotData;
    if (data.paintPriority != paintPriority) {
      data.paintPriority = paintPriority;
      renderObject.parent?.markNeedsPaint();
    }
  }

  @override
  Type get debugTypicalAncestorWidgetClass => MeHistoryCoverRow;
}

/// Lays out recent history covers left-to-right (or RTL) in widget/semantics
/// order while painting promoted forward-moving covers above displaced ones so
/// crossing cards never clip the leading cover in half.
class MeHistoryCoverRow extends MultiChildRenderObjectWidget {
  const MeHistoryCoverRow({
    super.key,
    required this.coverSize,
    required this.gap,
    required this.textDirection,
    required super.children,
  });

  final double coverSize;
  final double gap;
  final TextDirection textDirection;

  @override
  RenderMeHistoryCoverRow createRenderObject(BuildContext context) =>
      RenderMeHistoryCoverRow(
        coverSize: coverSize,
        gap: gap,
        textDirection: textDirection,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    RenderMeHistoryCoverRow renderObject,
  ) {
    renderObject
      ..coverSize = coverSize
      ..gap = gap
      ..textDirection = textDirection;
  }
}

class RenderMeHistoryCoverRow extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, MeHistoryCoverSlotData>,
        RenderBoxContainerDefaultsMixin<RenderBox, MeHistoryCoverSlotData> {
  RenderMeHistoryCoverRow({
    required double coverSize,
    required double gap,
    required TextDirection textDirection,
  }) : _coverSize = coverSize,
       _gap = gap,
       _textDirection = textDirection;

  double _coverSize;
  set coverSize(double value) {
    if (_coverSize == value) return;
    _coverSize = value;
    markNeedsLayout();
  }

  double _gap;
  set gap(double value) {
    if (_gap == value) return;
    _gap = value;
    markNeedsLayout();
  }

  TextDirection _textDirection;
  set textDirection(TextDirection value) {
    if (_textDirection == value) return;
    _textDirection = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! MeHistoryCoverSlotData) {
      child.parentData = MeHistoryCoverSlotData();
    }
  }

  Size _rowSize(int count) {
    if (count == 0) return Size(0, _coverSize);
    return Size(count * _coverSize + (count - 1) * _gap, _coverSize);
  }

  @override
  double computeMinIntrinsicWidth(double height) => _rowSize(childCount).width;

  @override
  double computeMaxIntrinsicWidth(double height) => _rowSize(childCount).width;

  @override
  double computeMinIntrinsicHeight(double width) => _coverSize;

  @override
  double computeMaxIntrinsicHeight(double width) => _coverSize;

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      constraints.constrain(_rowSize(childCount));

  @override
  void performLayout() {
    final count = childCount;
    size = constraints.constrain(_rowSize(count));
    final childConstraints = BoxConstraints.tightFor(
      width: _coverSize,
      height: _coverSize,
    );
    final stride = _coverSize + _gap;
    final ltr = _textDirection == TextDirection.ltr;
    var index = 0;
    var child = firstChild;
    while (child != null) {
      child.layout(childConstraints, parentUsesSize: false);
      final data = child.parentData! as MeHistoryCoverSlotData;
      final slot = ltr ? index : count - 1 - index;
      data.offset = Offset(slot * stride, 0);
      child = data.nextSibling;
      index++;
    }
  }

  List<RenderBox> _paintOrderedChildren() {
    final ordered = <RenderBox>[];
    var child = firstChild;
    while (child != null) {
      ordered.add(child);
      child = (child.parentData! as MeHistoryCoverSlotData).nextSibling;
    }
    final indexed = ordered.indexed.toList()
      ..sort((a, b) {
        final pa = (a.$2.parentData! as MeHistoryCoverSlotData).paintPriority;
        final pb = (b.$2.parentData! as MeHistoryCoverSlotData).paintPriority;
        final byPriority = pa.compareTo(pb);
        return byPriority != 0 ? byPriority : a.$1.compareTo(b.$1);
      });
    return [for (final (_, box) in indexed) box];
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    for (final child in _paintOrderedChildren()) {
      final data = child.parentData! as MeHistoryCoverSlotData;
      context.paintChild(child, data.offset + offset);
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    for (final child in _paintOrderedChildren().reversed) {
      final data = child.parentData! as MeHistoryCoverSlotData;
      final hit = result.addWithPaintOffset(
        offset: data.offset,
        position: position,
        hitTest: (result, transformed) =>
            child.hitTest(result, position: transformed),
      );
      if (hit) return true;
    }
    return false;
  }
}
