import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:super_editor/super_editor.dart';

void main() {
  group("SliverContentLayers", () {
    testWidgets("doesn't rebuild or re-lay out layers when scrolling", (tester) async {
      final scrollController = ScrollController();
      addTearDown(scrollController.dispose);
      final underlay = _LayerProbe("underlay");
      final overlay = _LayerProbe("overlay");

      await _pumpLayers(
        tester,
        scrollController: scrollController,
        content: (_) => SliverToBoxAdapter(child: SizedBox(key: _contentBoxKey, height: 5000)),
        underlay: underlay,
        overlay: overlay,
      );

      for (final layer in [underlay, overlay]) {
        expect(layer.builderCalls, 1);
        expect(layer.builds, 1);
        expect(layer.layouts, 1);
      }

      // Jump, and also drag, to scroll the content in a few different frames.
      scrollController.jumpTo(1000);
      await tester.pump();
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
      await tester.pump();
      await tester.drag(find.byType(CustomScrollView), const Offset(0, 100));
      await tester.pumpAndSettle();
      expect(scrollController.offset, greaterThan(1000));

      for (final layer in [underlay, overlay]) {
        expect(layer.builderCalls, 1);
        expect(layer.builds, 1);
        expect(layer.layouts, 1);
      }

      // The layers still sit exactly on top of the content, at the content's size.
      final contentBox = tester.renderObject<RenderBox>(find.byKey(_contentBoxKey));
      for (final layer in [underlay, overlay]) {
        final layerBox = tester.renderObject<RenderBox>(find.text(layer.label));
        expect(layerBox.localToGlobal(Offset.zero), contentBox.localToGlobal(Offset.zero));
        expect(layerBox.size, contentBox.size);
      }
    });

    testWidgets("rebuilds each layer exactly once when the content layout changes", (tester) async {
      final contentHeight = ValueNotifier<double>(5000);
      addTearDown(contentHeight.dispose);
      final underlay = _LayerProbe("underlay");
      final overlay = _LayerProbe("overlay");

      await _pumpLayers(
        tester,
        content: (_) => ValueListenableBuilder<double>(
          valueListenable: contentHeight,
          builder: (context, height, _) => SliverToBoxAdapter(child: SizedBox(height: height)),
        ),
        underlay: underlay,
        overlay: overlay,
      );
      for (final layer in [underlay, overlay]) {
        expect(layer.builderCalls, 1);
        expect(layer.builds, 1);
        expect(layer.computedContentHeights, [5000]);
      }

      contentHeight.value = 6000;
      await tester.pump();

      for (final layer in [underlay, overlay]) {
        expect(layer.builderCalls, 2);
        expect(layer.builds, 2);
        // The layer saw the new content layout when it rebuilt.
        expect(layer.computedContentHeights, [5000, 6000]);
        expect(tester.getSize(find.text(layer.label)), const Size(_windowWidth, 6000));
      }
    });

    testWidgets("rebuilds the layers when the content marks itself as needing layout", (tester) async {
      final underlay = _LayerProbe("underlay");
      final overlay = _LayerProbe("overlay");

      await _pumpLayers(
        tester,
        content: (_) => SliverToBoxAdapter(child: SizedBox(key: _contentBoxKey, height: 5000)),
        underlay: underlay,
        overlay: overlay,
      );
      expect(underlay.builderCalls, 1);
      expect(overlay.builderCalls, 1);

      // Re-lay out the content without changing its size.
      tester.renderObject<RenderBox>(find.byKey(_contentBoxKey)).markNeedsLayout();
      await tester.pump();

      expect(underlay.builderCalls, 2);
      expect(underlay.builds, 2);
      expect(overlay.builderCalls, 2);
      expect(overlay.builds, 2);
    });

    testWidgets("rebuilds the layers when told to from outside, even if the content didn't change", (tester) async {
      final underlay = _LayerProbe("underlay");
      final overlay = _LayerProbe("overlay");

      await _pumpLayers(
        tester,
        content: (_) => SliverToBoxAdapter(child: SizedBox(key: _contentBoxKey, height: 5000)),
        underlay: underlay,
        overlay: overlay,
      );
      expect(underlay.builds, 1);
      expect(overlay.builds, 1);

      final renderLayers = tester.renderObject<RenderSliverContentLayers>(find.byType(SliverContentLayers));

      // This is the contract that apps rely on: markNeedsLayout() rebuilds the layers in the next layout.
      renderLayers.markNeedsLayout();
      expect(renderLayers.contentNeedsLayout, isTrue);
      await tester.pump();
      expect(renderLayers.contentNeedsLayout, isFalse);

      expect(underlay.builderCalls, 2);
      expect(underlay.builds, 2);
      expect(overlay.builderCalls, 2);
      expect(overlay.builds, 2);

      // requestLayerRebuild() does the same.
      renderLayers.requestLayerRebuild();
      await tester.pump();

      expect(underlay.builds, 3);
      expect(overlay.builds, 3);

      // Asking twice before the next frame still rebuilds each layer only once.
      renderLayers
        ..markNeedsLayout()
        ..markNeedsLayout();
      await tester.pump();

      expect(underlay.builds, 4);
      expect(overlay.builds, 4);
    });

    testWidgets("rebuilds the layers when the cross-axis extent changes", (tester) async {
      final underlay = _LayerProbe("underlay");

      await _pumpLayers(
        tester,
        content: (_) => SliverToBoxAdapter(child: SizedBox(key: _contentBoxKey, height: 5000)),
        underlay: underlay,
      );
      expect(underlay.builds, 1);

      tester.view.physicalSize = const Size(400, _windowHeight);
      await tester.pump();

      expect(underlay.builds, 2);
      expect(tester.getSize(find.text(underlay.label)), const Size(400, 5000));
    });

    testWidgets("updates a layer that calls its own setState(), without rebuilding the other layers", (tester) async {
      final underlay = _LayerProbe("underlay");
      final overlay = _LayerProbe("overlay");

      await _pumpLayers(
        tester,
        content: (_) => SliverToBoxAdapter(child: SizedBox(key: _contentBoxKey, height: 5000)),
        underlay: underlay,
        overlay: overlay,
      );
      expect(find.text("overlay"), findsOneWidget);

      overlay.state!.setLabelSuffix(" - updated");
      await tester.pump();

      expect(find.text("overlay"), findsNothing);
      expect(find.text("overlay - updated"), findsOneWidget);
      expect(overlay.builds, 2);
      // The layer rebuilt itself, ContentLayers didn't rebuild the layers.
      expect(overlay.builderCalls, 1);
      expect(underlay.builderCalls, 1);
      expect(underlay.builds, 1);
    });

    testWidgets("keeps a requested layer rebuild across a scroll offset correction", (tester) async {
      final scrollController = ScrollController();
      addTearDown(scrollController.dispose);
      final underlay = _LayerProbe("underlay");
      final overlay = _LayerProbe("overlay");
      final correctingSliverKey = GlobalKey();

      await _pumpLayers(
        tester,
        scrollController: scrollController,
        content: (_) => _CorrectingSliver(key: correctingSliverKey, extent: 5000),
        underlay: underlay,
        overlay: overlay,
      );
      scrollController.jumpTo(500);
      await tester.pump();
      expect(underlay.builds, 1);
      expect(overlay.builds, 1);

      final correctingSliver = tester.renderObject<_RenderCorrectingSliver>(find.byKey(correctingSliverKey));
      final renderLayers = tester.renderObject<RenderSliverContentLayers>(find.byType(SliverContentLayers));

      // Change the content, and have its next layout ask the viewport to correct the scroll offset.
      correctingSliver.correctNextLayoutBy(25);
      await tester.pump();

      // The content corrected the scroll offset, and the layers were rebuilt exactly once,
      // in the layout pass that followed the correction.
      expect(correctingSliver.corrections, 1);
      expect(scrollController.offset, 525);
      expect(renderLayers.contentNeedsLayout, isFalse);
      expect(underlay.builds, 2);
      expect(overlay.builds, 2);
      expect(underlay.computedScrollExtents.last, 5000);

      // ContentLayers is no longer stuck in its layout. An outside request still rebuilds the layers...
      renderLayers.markNeedsLayout();
      await tester.pump();
      expect(underlay.builds, 3);
      expect(overlay.builds, 3);

      // ...and scrolling still doesn't.
      scrollController.jumpTo(900);
      await tester.pump();
      expect(underlay.builds, 3);
      expect(overlay.builds, 3);
      expect(underlay.layouts, 1);
    });
  });

  group("ContentLayers", () {
    testWidgets("builds a layer that's dirty while the content rebuilds once, after the content's layout",
        (tester) async {
      final contentHeight = ValueNotifier<double>(5000);
      addTearDown(contentHeight.dispose);
      final overlay = _LayerProbe("overlay");

      await _pumpLayers(
        tester,
        content: (onBuildScheduled) => _ResizableContent(
          height: contentHeight,
          onBuildScheduled: onBuildScheduled,
        ),
        overlay: overlay,
      );
      expect(overlay.builds, 1);

      // Make the layer, and the content, dirty in the same frame, in both orders.
      overlay.state!.setLabelSuffix(" 1");
      contentHeight.value = 6000;
      await tester.pump();

      expect(overlay.builds, 2);
      expect(overlay.computedContentHeights, [5000, 6000]);
      expect(find.text("overlay 1"), findsOneWidget);

      contentHeight.value = 7000;
      overlay.state!.setLabelSuffix(" 2");
      await tester.pump();

      expect(overlay.builds, 3);
      expect(overlay.computedContentHeights, [5000, 6000, 7000]);
      expect(find.text("overlay 2"), findsOneWidget);
    });

    testWidgets("rebuilds a layer that waited for the content's layout, when its builder returns the same widget",
        (tester) async {
      final overlay = _LayerProbe("overlay", reuseWidget: true);

      await _pumpLayers(
        tester,
        content: (_) => SliverToBoxAdapter(child: SizedBox(key: _contentBoxKey, height: 5000)),
        overlay: overlay,
      );
      expect(overlay.builds, 1);

      final renderLayers = tester.renderObject<RenderSliverContentLayers>(find.byType(SliverContentLayers));
      renderLayers.markNeedsLayout();
      overlay.state!.setLabelSuffix(" - updated");
      await tester.pump();

      // The layer's own build waited for the layout, where ContentLayers called the layer's
      // builder, which returned the same widget, so ContentLayers rebuilt the layer itself.
      expect(overlay.builderCalls, 2);
      expect(overlay.builds, 2);
      expect(find.text("overlay - updated"), findsOneWidget);
    });

    testWidgets("doesn't replace the build owner's onBuildScheduled callback", (tester) async {
      final onBuildScheduled = tester.binding.buildOwner!.onBuildScheduled;

      await _pumpLayers(
        tester,
        content: (_) => SliverToBoxAdapter(child: SizedBox(key: _contentBoxKey, height: 5000)),
        overlay: _LayerProbe("overlay"),
      );

      expect(tester.binding.buildOwner!.onBuildScheduled, same(onBuildScheduled));
    });
  });
}

const _windowWidth = 600.0;
const _windowHeight = 1000.0;

final _contentBoxKey = GlobalKey();

Future<void> _pumpLayers(
  WidgetTester tester, {
  ScrollController? scrollController,
  required Widget Function(VoidCallback onBuildScheduled) content,
  _LayerProbe? underlay,
  _LayerProbe? overlay,
}) async {
  tester.view
    ..physicalSize = const Size(_windowWidth, _windowHeight)
    ..devicePixelRatio = 1.0;
  addTearDown(() => tester.platformDispatcher.clearAllTestValues());
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: CustomScrollView(
          controller: scrollController,
          slivers: [
            SliverContentLayers(
              content: content,
              underlays: [if (underlay != null) underlay.builder],
              overlays: [if (overlay != null) overlay.builder],
            ),
          ],
        ),
      ),
    ),
  );
}

/// Records how often ContentLayers calls a layer's builder, how often the layer
/// builds, and how often the layer is laid out.
class _LayerProbe {
  _LayerProbe(this.label, {this.reuseWidget = false});

  final String label;

  /// Whether [builder] returns the same widget instance every time.
  final bool reuseWidget;
  late final _ProbeLayer _widget = _ProbeLayer(this);

  int builderCalls = 0;
  int builds = 0;
  int layouts = 0;

  /// The content's height, or scroll extent, that the layer saw, each time it
  /// computed its layout data.
  final computedContentHeights = <double>[];
  final computedScrollExtents = <double>[];

  _ProbeLayerState? state;

  ContentLayerWidget builder(BuildContext context) {
    builderCalls += 1;
    return reuseWidget ? _widget : _ProbeLayer(this);
  }
}

/// Sliver content whose height follows [height], which tells [ContentLayers] when it
/// schedules a build.
class _ResizableContent extends StatefulWidget {
  const _ResizableContent({
    required this.height,
    required this.onBuildScheduled,
  });

  final ValueListenable<double> height;
  final VoidCallback onBuildScheduled;

  @override
  State<_ResizableContent> createState() => _ResizableContentState();
}

class _ResizableContentState extends State<_ResizableContent> {
  @override
  void initState() {
    super.initState();
    widget.height.addListener(_onHeightChange);
  }

  @override
  void dispose() {
    widget.height.removeListener(_onHeightChange);
    super.dispose();
  }

  void _onHeightChange() {
    setState(() {});
    widget.onBuildScheduled();
  }

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: SizedBox(key: _contentBoxKey, height: widget.height.value),
    );
  }
}

class _ProbeLayer extends ContentLayerStatefulWidget<double> {
  const _ProbeLayer(this.probe);

  final _LayerProbe probe;

  @override
  ContentLayerState<_ProbeLayer, double> createState() => _ProbeLayerState();
}

class _ProbeLayerState extends ContentLayerState<_ProbeLayer, double> {
  String _labelSuffix = "";

  void setLabelSuffix(String suffix) {
    setState(() {
      _labelSuffix = suffix;
    });
  }

  @override
  double? computeLayoutData(Element? contentElement, RenderObject? contentLayout) {
    final sliver = contentLayout is RenderSliver ? contentLayout : null;
    final scrollExtent = sliver?.geometry?.scrollExtent;
    if (scrollExtent != null) {
      widget.probe.computedScrollExtents.add(scrollExtent);
    }

    final box = _findContentBox(contentElement);
    if (box != null && box.hasSize) {
      widget.probe.computedContentHeights.add(box.size.height);
      return box.size.height;
    }
    return null;
  }

  RenderBox? _findContentBox(Element? contentElement) {
    RenderBox? box;
    void visit(Element element) {
      if (box != null) {
        return;
      }
      if (element.renderObject is RenderBox) {
        box = element.renderObject as RenderBox;
        return;
      }
      element.visitChildren(visit);
    }

    contentElement?.visitChildren(visit);
    return box;
  }

  @override
  Widget doBuild(BuildContext context, double? layoutData) {
    widget.probe
      ..state = this
      ..builds += 1;

    return _LayoutCounter(
      onLayout: () => widget.probe.layouts += 1,
      child: Text("${widget.probe.label}$_labelSuffix"),
    );
  }
}

class _LayoutCounter extends SingleChildRenderObjectWidget {
  const _LayoutCounter({
    required this.onLayout,
    required super.child,
  });

  final VoidCallback onLayout;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderLayoutCounter(onLayout);

  @override
  void updateRenderObject(BuildContext context, _RenderLayoutCounter renderObject) {
    renderObject.onLayout = onLayout;
  }
}

class _RenderLayoutCounter extends RenderProxyBox {
  _RenderLayoutCounter(this.onLayout);

  VoidCallback onLayout;

  @override
  void performLayout() {
    onLayout();
    super.performLayout();
  }
}

/// A sliver of a fixed [extent] that can be told to ask its viewport for a scroll
/// offset correction in its next layout.
class _CorrectingSliver extends LeafRenderObjectWidget {
  const _CorrectingSliver({
    super.key,
    required this.extent,
  });

  final double extent;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderCorrectingSliver(extent);
}

class _RenderCorrectingSliver extends RenderSliver {
  _RenderCorrectingSliver(this.extent);

  final double extent;

  double? _pendingCorrection;
  int corrections = 0;

  void correctNextLayoutBy(double correction) {
    _pendingCorrection = correction;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    final correction = _pendingCorrection;
    if (correction != null) {
      _pendingCorrection = null;
      corrections += 1;
      geometry = SliverGeometry(scrollOffsetCorrection: correction);
      return;
    }

    final paintExtent = calculatePaintOffset(constraints, from: 0, to: extent);
    final cacheExtent = calculateCacheOffset(constraints, from: 0, to: extent);
    geometry = SliverGeometry(
      scrollExtent: extent,
      paintExtent: paintExtent,
      maxPaintExtent: extent,
      cacheExtent: cacheExtent,
      hasVisualOverflow: extent > constraints.remainingPaintExtent || constraints.scrollOffset > 0,
    );
  }
}
