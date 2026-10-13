import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:super_editor/src/infrastructure/_logging.dart';
import 'package:super_editor/src/infrastructure/content_layers.dart';

/// A [ContentLayers] widget that's implemented to work with Slivers.
class SliverContentLayers extends ContentLayers {
  const SliverContentLayers({
    super.key,
    super.underlays = const [],
    required super.content,
    super.overlays = const [],
  });

  @override
  RenderSliverContentLayers createRenderObject(BuildContext context) {
    return RenderSliverContentLayers(context as ContentLayersElement);
  }
}

/// `RenderObject` for a [SliverContentLayers] widget.
///
/// Must be given an `Element` of type [ContentLayersElement].
class RenderSliverContentLayers extends RenderSliver with RenderSliverHelpers implements RenderContentLayers {
  RenderSliverContentLayers(this._element);

  @override
  void dispose() {
    _element = null;
    super.dispose();
  }

  ContentLayersElement? _element;

  final _underlays = <RenderBox>[];
  RenderSliver? _content;
  final _overlays = <RenderBox>[];

  @override
  bool get contentNeedsLayout => _contentNeedsLayout;
  bool _contentNeedsLayout = true;

  /// Whether we are at the middle of a [performLayout] call.
  bool _runningLayout = false;

  /// The size that the layers were last built for and laid out at, or `null`
  /// if the layers haven't been built yet.
  ///
  /// The layers are rebuilt when this size changes, e.g., when the cross-axis
  /// extent changes, or when the content's scroll extent changes.
  Size? _layerSize;

  @override
  void attach(PipelineOwner owner) {
    contentLayersLog.info("Attaching RenderSliverContentLayers to owner: $owner");
    super.attach(owner);

    visitChildren((child) {
      child.attach(owner);
    });
  }

  @override
  void detach() {
    contentLayersLog.info("detach()'ing RenderSliverContentLayers from pipeline");
    // IMPORTANT: we must detach ourselves before detaching our children.
    // This is a Flutter framework requirement.
    super.detach();

    // Detach our children.
    visitChildren((child) {
      child.detach();
    });
  }

  /// Marks this render object as needing layout, and, when called from
  /// outside of this render object's own layout, requests that the underlays
  /// and overlays are rebuilt during that next layout.
  ///
  /// The layers are rebuilt, during layout, only when one of these holds:
  ///
  ///  * [markNeedsLayout] was called since the last layout, either because the
  ///    content changed its layout, or because someone outside called it;
  ///  * the cross-axis extent changed;
  ///  * the content's scroll extent changed;
  ///  * this is the first layout.
  ///
  /// A layout that only scrolls, which changes the scroll offset or the
  /// remaining paint extent, doesn't rebuild the layers.
  ///
  /// A layer that depends on something other than the content's layout, such
  /// as a document change that doesn't change the content's layout, can call
  /// [markNeedsLayout] on its ancestor [RenderSliverContentLayers] instead of
  /// `setState()`. All layers are then rebuilt exactly once, during the next
  /// layout, after the content is laid out, so they can query a fresh content
  /// layout. [requestLayerRebuild] does the same, under a clearer name.
  @override
  void markNeedsLayout() {
    super.markNeedsLayout();

    if (_runningLayout) {
      // We are already in a layout phase.
      //
      // When we call ContentLayerElement.buildLayers, markNeedsLayout is called again.
      // We don't to mark the content as dirty, because otherwise the layers will
      // never build.
      return;
    }
    _contentNeedsLayout = true;
  }

  /// Rebuilds every underlay and overlay during the next layout, after the
  /// content is laid out.
  ///
  /// This is the same as calling [markNeedsLayout] from outside of layout.
  void requestLayerRebuild() => markNeedsLayout();

  @override
  List<DiagnosticsNode> debugDescribeChildren() {
    final childDiagnostics = <DiagnosticsNode>[];

    if (_content != null) {
      childDiagnostics.add(_content!.toDiagnosticsNode(name: "content"));
    }

    for (int i = 0; i < _underlays.length; i += 1) {
      childDiagnostics.add(_underlays[i].toDiagnosticsNode(name: "underlay-$i"));
    }
    for (int i = 0; i < _overlays.length; i += 1) {
      childDiagnostics.add(_overlays[i].toDiagnosticsNode(name: "overlay-#$i"));
    }

    return childDiagnostics;
  }

  @override
  void insertChild(RenderObject child, Object slot) {
    assert(isContentLayersSlot(slot));

    if (slot == contentSlot) {
      _content = child as RenderSliver;
    } else if (slot is UnderlaySlot) {
      _underlays.insert(slot.index, child as RenderBox);
    } else if (slot is OverlaySlot) {
      _overlays.insert(slot.index, child as RenderBox);
    }

    adoptChild(child);
  }

  @override
  void moveChildLayer(RenderBox child, Object oldSlot, Object newSlot) {
    assert(oldSlot is UnderlaySlot || oldSlot is OverlaySlot);
    assert(newSlot is UnderlaySlot || newSlot is OverlaySlot);

    if (oldSlot is UnderlaySlot) {
      assert(_underlays.contains(child));
      _underlays.remove(child);
    } else if (oldSlot is OverlaySlot) {
      assert(_overlays.contains(child));
      _overlays.remove(child);
    }

    if (newSlot is UnderlaySlot) {
      _underlays.insert(newSlot.index, child);
    } else if (newSlot is OverlaySlot) {
      _overlays.insert(newSlot.index, child);
    }
  }

  @override
  void removeChild(RenderObject child, Object slot) {
    assert(isContentLayersSlot(slot));

    if (slot == contentSlot) {
      _content = null;
    } else if (slot is UnderlaySlot) {
      _underlays.remove(child);
    } else if (slot is OverlaySlot) {
      _overlays.remove(child);
    }

    dropChild(child);
  }

  @override
  void visitChildren(RenderObjectVisitor visitor) {
    if (_content != null) {
      visitor(_content!);
    }

    for (final RenderBox child in _underlays) {
      visitor(child);
    }

    for (final RenderBox child in _overlays) {
      visitor(child);
    }
  }

  @override
  void performLayout() {
    contentLayersLog.info("Laying out SliverContentLayers");
    if (_content == null) {
      geometry = SliverGeometry.zero;
      _contentNeedsLayout = false;
      return;
    }

    // Whether someone asked for the layers to rebuild, e.g., the content, whose
    // layout changed, or an external call to markNeedsLayout().
    final isLayerRebuildRequested = _contentNeedsLayout;

    _runningLayout = true;
    try {
      _layoutContentAndLayers(isLayerRebuildRequested: isLayerRebuildRequested);
    } finally {
      _runningLayout = false;
    }
  }

  void _layoutContentAndLayers({required bool isLayerRebuildRequested}) {
    // Always layout the content first, so that layers can inspect the content layout.
    contentLayersLog.fine("Laying out content - $_content");
    (_content!.parentData! as SliverLogicalParentData).layoutOffset = 0.0;
    _content!.layout(constraints, parentUsesSize: true);
    contentLayersLog.fine("Content after layout: $_content");

    // The size of the layers, and the our size, is exactly the same as the content.
    final SliverGeometry sliverLayoutGeometry = _content!.geometry!;
    if (sliverLayoutGeometry.scrollOffsetCorrection != null) {
      // The viewport will lay us out again with a corrected scroll offset. Leave
      // _contentNeedsLayout as it is, so that a requested layer rebuild still
      // happens in that next layout.
      geometry = SliverGeometry(
        scrollOffsetCorrection: sliverLayoutGeometry.scrollOffsetCorrection,
      );
      return;
    }
    geometry = SliverGeometry(
      scrollExtent: sliverLayoutGeometry.scrollExtent,
      paintExtent: sliverLayoutGeometry.paintExtent,
      maxPaintExtent: sliverLayoutGeometry.maxPaintExtent,
      maxScrollObstructionExtent: sliverLayoutGeometry.maxScrollObstructionExtent,
      cacheExtent: sliverLayoutGeometry.cacheExtent,
      hasVisualOverflow: sliverLayoutGeometry.hasVisualOverflow,
    );

    _contentNeedsLayout = false;

    // The layers cover the content's whole scroll extent, at the full cross-axis
    // extent. Neither changes when the user scrolls.
    final layerSize = Size(constraints.crossAxisExtent, sliverLayoutGeometry.scrollExtent);

    // Build the underlay and overlays during the layout phase so that they can inspect an
    // up-to-date content layout.
    //
    // This behavior is what allows us to avoid layers that are always one frame behind the
    // content changes.
    //
    // Only rebuild the layers when the content layout might have changed, or someone asked
    // for it. Scrolling changes our constraints on every frame, but it doesn't change the
    // content layout, so a layout that only scrolls doesn't rebuild the layers.
    if (isLayerRebuildRequested || layerSize != _layerSize) {
      contentLayersLog.fine("Building layers");
      invokeLayoutCallback((constraints) {
        // Usually, widgets are built during the build phase, but we're building the layers
        // during layout phase, so we need to explicitly tell Flutter to build all elements.
        _element!.owner!.buildScope(_element!, () {
          _element!.buildLayers();
        });
      });
      contentLayersLog.finer("Done building layers");
    }
    _layerSize = layerSize;

    contentLayersLog.fine("Laying out layers (${_underlays.length} underlays, ${_overlays.length} overlays)");
    // Layout the layers below and above the content.
    //
    // The layer constraints don't include the scroll offset, so that a scroll doesn't
    // re-layout the layers. The layers are moved with the content by their layout offset.
    final layerConstraints = BoxConstraints.tight(layerSize);

    for (final underlay in _underlays) {
      final childParentData = underlay.parentData! as SliverLogicalParentData;
      childParentData.layoutOffset = -constraints.scrollOffset;
      contentLayersLog.fine("Laying out underlay: $underlay");
      underlay.layout(layerConstraints);
    }
    for (final overlay in _overlays) {
      final childParentData = overlay.parentData! as SliverLogicalParentData;
      childParentData.layoutOffset = -constraints.scrollOffset;
      contentLayersLog.fine("Laying out overlay: $overlay");
      overlay.layout(layerConstraints);
    }

    contentLayersLog.finer("Done laying out layers");
  }

  @override
  bool hitTestChildren(
    SliverHitTestResult result, {
    required double mainAxisPosition,
    required double crossAxisPosition,
  }) {
    if (_content == null) {
      return false;
    }

    // Run hit tests in reverse-paint order.
    bool didHit = false;

    final boxResult = BoxHitTestResult.wrap(result);

    // First, hit-test overlays.
    for (final overlay in _overlays) {
      didHit =
          hitTestBoxChild(boxResult, overlay, mainAxisPosition: mainAxisPosition, crossAxisPosition: crossAxisPosition);
      if (didHit) {
        return true;
      }
    }

    // Second, hit-test the content.
    didHit = _content!.hitTest(result, mainAxisPosition: mainAxisPosition, crossAxisPosition: crossAxisPosition);
    if (didHit) {
      return true;
    }

    // Third, hit-test the underlays.
    for (final underlay in _underlays) {
      didHit = hitTestBoxChild(boxResult, underlay,
          mainAxisPosition: mainAxisPosition, crossAxisPosition: crossAxisPosition);
      if (didHit) {
        return true;
      }
    }

    return false;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (_content == null) {
      return;
    }

    void paintChild(RenderObject child) {
      final childParentData = child.parentData! as SliverLogicalParentData;
      context.paintChild(
        child,
        offset + Offset(0, childParentData.layoutOffset!),
      );
    }

    // First, paint the underlays.
    for (final underlay in _underlays) {
      paintChild(underlay);
    }

    // Second, paint the content.
    paintChild(_content!);

    // Third, paint the overlays.
    for (final overlay in _overlays) {
      paintChild(overlay);
    }
  }

  @override
  void applyPaintTransform(covariant RenderObject child, Matrix4 transform) {
    final childParentData = child.parentData! as SliverLogicalParentData;
    transform.translate(0.0, childParentData.layoutOffset!);
  }

  @override
  double childMainAxisPosition(covariant RenderObject child) {
    final childParentData = child.parentData! as SliverLogicalParentData;
    return childParentData.layoutOffset!;
  }

  @override
  void setupParentData(covariant RenderObject child) {
    child.parentData = _ChildParentData();
  }
}

class _ChildParentData extends SliverLogicalParentData with ContainerParentDataMixin<RenderObject> {}
