import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_test_robots/flutter_test_robots.dart';
import 'package:super_editor/super_editor.dart';
import 'package:super_editor/super_editor_test.dart';

void main() {
  group("SingleColumnDocumentLayout", () {
    group("rebuilds", () {
      testWidgets("listens to its presenter once, and rebuilds only the component that changed", (tester) async {
        final document = _createParagraphs(30);
        final composer = MutableDocumentComposer();
        final editor = createDefaultDocumentEditor(document: document, composer: composer);
        final presenter = SingleColumnLayoutPresenter(
          document: document,
          componentBuilders: defaultComponentBuilders,
          pipeline: [SingleColumnStylesheetStyler(stylesheet: defaultStylesheet)],
        );
        addTearDown(presenter.dispose);
        final builds = <String, int>{};

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: CustomScrollView(
                slivers: [
                  SingleColumnDocumentLayout(
                    presenter: presenter,
                    componentBuilders: [
                      _CountingComponentBuilder(builds),
                      ...defaultComponentBuilders,
                    ],
                  ),
                ],
              ),
            ),
          ),
        );

        // The layout listens to the presenter, but its components don't.
        expect(presenter.debugChangeListenerCount, 1);
        expect(builds.length, 30);
        expect(builds.values.every((count) => count == 1), isTrue);

        editor.execute([
          InsertTextRequest(
            documentPosition: const DocumentPosition(nodeId: "5", nodePosition: TextNodePosition(offset: 0)),
            textToInsert: "Changed: ",
            attributions: {},
          ),
        ]);
        await tester.pump();

        expect(find.textContaining("Changed: ", findRichText: true), findsOneWidget);
        expect(builds["5"], 2);
        expect(builds.entries.where((entry) => entry.key != "5").every((entry) => entry.value == 1), isTrue);
        expect(presenter.debugChangeListenerCount, 1);
      });

      testWidgets("pressing Enter in the middle of a document doesn't rebuild the components after it", (tester) async {
        final builds = <String, int>{};
        final document = _createParagraphs(30);
        final editorContext = await tester //
            .createDocument()
            .withCustomContent(document)
            .withInputSource(TextInputSource.keyboard)
            .withSelection(
              DocumentSelection.collapsed(
                position: DocumentPosition(
                  nodeId: "10",
                  nodePosition: TextNodePosition(offset: (document.getNodeById("10") as ParagraphNode).text.length),
                ),
              ),
            )
            .autoFocus(true)
            .withComponentBuilders([
          _CountingComponentBuilder(builds),
          ...defaultComponentBuilders,
        ]).pump();
        final layout = SuperEditorInspector.findDocumentLayout();

        // Remember each component, and its render box, after the caret's node.
        final buildsBefore = Map.of(builds);
        final componentsBefore = {
          for (int i = 11; i < 30; i += 1) "$i": layout.getComponentByNodeId("$i"),
        };
        final boxesBefore = {
          for (final entry in componentsBefore.entries) entry.key: entry.value!.context.findRenderObject(),
        };

        await tester.pressEnter();
        await tester.pump();

        // A new node was inserted after the caret's node.
        final newNode = editorContext.document.getNodeAt(11)!;
        expect(newNode.id, isNot("11"));
        expect(editorContext.document.getNodeAt(12)!.id, "11");
        expect(builds[newNode.id], 1);

        // Every component after it is the same component, and wasn't built again.
        for (int i = 11; i < 30; i += 1) {
          final nodeId = "$i";
          expect(builds[nodeId], buildsBefore[nodeId], reason: "Component for node $nodeId was rebuilt");
          expect(layout.getComponentByNodeId(nodeId), same(componentsBefore[nodeId]));
          expect(layout.getComponentByNodeId(nodeId)!.context.findRenderObject(), same(boxesBefore[nodeId]));
        }

        // The layout still finds the components where they are, after the insertion.
        final lastComponentOffset = SuperEditorInspector.findComponentOffset("29", Alignment.center);
        final positionAtLastComponent = layout.getDocumentPositionAtOffset(
          layout.getDocumentOffsetFromAncestorOffset(lastComponentOffset),
        );
        expect(positionAtLastComponent?.nodeId, "29");
      });

      testWidgets("rebuilding SuperEditor with new layer lists rebuilds no text component", (tester) async {
        final textComponentBuilds = <String, int>{};
        final componentBuilderBuilds = <int>[0];
        _countTextComponentBuilds(textComponentBuilds, componentBuilderBuilds);

        final rebuildSignal = ValueNotifier<int>(0);
        addTearDown(rebuildSignal.dispose);
        final document = _createParagraphs(20);
        final composer = MutableDocumentComposer();
        final editor = createDefaultDocumentEditor(document: document, composer: composer);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ValueListenableBuilder<int>(
                valueListenable: rebuildSignal,
                builder: (context, rebuildCount, child) {
                  // Create new lists of layers on every build, as an app might.
                  return SuperEditor(
                    editor: editor,
                    documentUnderlayBuilders: [
                      if (rebuildCount.isOdd) const _EmptyLayerBuilder(),
                    ],
                    documentOverlayBuilders: [
                      ...defaultSuperEditorDocumentOverlayBuilders,
                      if (rebuildCount.isOdd) const _EmptyLayerBuilder(),
                    ],
                  );
                },
              ),
            ),
          ),
        );
        expect(textComponentBuilds.length, 20);
        textComponentBuilds.clear();
        componentBuilderBuilds[0] = 0;

        // Rebuild SuperEditor with new layer lists, a few times.
        for (int i = 0; i < 3; i += 1) {
          rebuildSignal.value += 1;
          await tester.pump();
        }

        expect(textComponentBuilds, isEmpty);
        // The layout reused every component's builder widget, so Flutter didn't even rebuild
        // the builders.
        expect(componentBuilderBuilds.single, 0);

        // A component still rebuilds when its node changes.
        editor.execute([
          InsertTextRequest(
            documentPosition: const DocumentPosition(nodeId: "3", nodePosition: TextNodePosition(offset: 0)),
            textToInsert: "Changed: ",
            attributions: {},
          ),
        ]);
        await tester.pump();

        expect(textComponentBuilds.keys, ["3"]);
      });
    });

    group("paints", () {
      testWidgets("the components that scroll into view, and not the ones far away", (tester) async {
        final scrollController = ScrollController();
        addTearDown(scrollController.dispose);
        final paints = <String>[];
        final document = _createParagraphs(150);

        await _pumpEditorInCustomScrollView(
          tester,
          document: document,
          scrollController: scrollController,
          componentBuilders: [
            _PaintProbeComponentBuilder(paints),
            ...defaultComponentBuilders,
          ],
        );

        // Nothing caches a picture of the column between the column and the viewport, which
        // would show a culled picture at a new scroll offset.
        final column = _findComponentColumn(tester);
        RenderObject? ancestor = column;
        while (ancestor is! RenderViewport) {
          expect(ancestor!.isRepaintBoundary, isFalse, reason: "$ancestor is a repaint boundary");
          ancestor = ancestor.parent;
        }

        _expectPaintedExactlyAroundViewport(tester, document, paints);

        for (final scrollOffset in [1500.0, 4000.0, 2600.0, 0.0]) {
          paints.clear();
          scrollController.jumpTo(scrollOffset);
          await tester.pump();

          _expectPaintedExactlyAroundViewport(tester, document, paints);
        }

        // Scroll with a drag, too.
        paints.clear();
        await tester.drag(find.byType(CustomScrollView), const Offset(0, -700));
        await tester.pump();
        _expectPaintedExactlyAroundViewport(tester, document, paints);

        // Let the editor's tap timers expire.
        await tester.pump(kDoubleTapTimeout);
      });

      testWidgets("a component that paints outside of its layout rect when that paint is visible", (tester) async {
        final scrollController = ScrollController();
        addTearDown(scrollController.dispose);
        final paints = <String>[];
        final document = _createParagraphs(150);

        await _pumpEditorInCustomScrollView(
          tester,
          document: document,
          scrollController: scrollController,
          componentBuilders: [
            // Node 60 paints 700 pixels above where it's laid out.
            _PaintProbeComponentBuilder(paints, shifts: {"60": const Offset(0, -700)}),
            ...defaultComponentBuilders,
          ],
        );

        final viewportRect = tester.getRect(find.byType(CustomScrollView));
        final shiftedBox = tester.renderObject<RenderBox>(find.byKey(const ValueKey("probe-60")));

        // Scroll so that node 60's layout rect is far below the viewport, but what it paints
        // is within the viewport.
        final layoutTop = shiftedBox.localToGlobal(Offset.zero).dy;
        scrollController.jumpTo(layoutTop - (viewportRect.bottom + 400));
        await tester.pump();
        paints.clear();
        _findComponentColumn(tester).markNeedsPaint();
        await tester.pump();

        final layoutRect = _layoutRectOf(shiftedBox);
        final paintedRect = (shiftedBox.localToGlobal(Offset.zero) & shiftedBox.size).shift(const Offset(0, -700));
        expect(layoutRect.top - viewportRect.bottom, greaterThan(RenderDocumentComponentColumn.paintCullingMargin));
        expect(paintedRect.overlaps(viewportRect), isTrue);
        expect(paints, contains("60"));

        // The node next to it, which doesn't paint outside of its layout rect, isn't painted.
        expect(paints, isNot(contains("61")));
      });
    });

    group("hit-tests", () {
      testWidgets("the components that scroll into view", (tester) async {
        final scrollController = ScrollController();
        addTearDown(scrollController.dispose);
        final document = _createParagraphs(150);

        await _pumpEditorInCustomScrollView(
          tester,
          document: document,
          scrollController: scrollController,
          componentBuilders: defaultComponentBuilders,
        );

        scrollController.jumpTo(3000);
        await tester.pump();

        // Tap the middle of a component that's in the middle of the viewport.
        final viewportRect = tester.getRect(find.byType(CustomScrollView));
        final layout = SuperEditorInspector.findDocumentLayout();
        final nodeId = layout
            .getDocumentPositionAtOffset(
              layout.getDocumentOffsetFromAncestorOffset(viewportRect.center),
            )!
            .nodeId;
        final componentBox = layout.getComponentByNodeId(nodeId)!.context.findRenderObject() as RenderBox;
        await tester.tapAt(componentBox.localToGlobal(componentBox.size.center(Offset.zero)));
        await tester.pump(kDoubleTapTimeout);

        expect(SuperEditorInspector.findDocumentSelection()!.extent.nodeId, nodeId);
      });

      testWidgets("the same children as a Column", (tester) async {
        final document = _createParagraphs(40);
        await tester //
            .createDocument()
            .withCustomContent(document)
            .withEditorSize(const Size(600, 4000))
            .pump();

        final column = _findComponentColumn(tester);
        for (double y = -10; y < column.size.height + 10; y += 3.5) {
          for (final x in [-5.0, 0.0, 1.0, 300.0, column.size.width - 1, column.size.width + 5]) {
            final position = Offset(x, y);
            final culledResult = BoxHitTestResult();
            column.hitTestChildren(culledResult, position: position);
            final columnResult = BoxHitTestResult();
            column.defaultHitTestChildren(columnResult, position: position);

            expect(
              culledResult.path.map((entry) => entry.target).toList(),
              columnResult.path.map((entry) => entry.target).toList(),
              reason: "Hit test results differ at $position",
            );
          }
        }
      });
    });
  });
}

MutableDocument _createParagraphs(int count) {
  return MutableDocument(
    nodes: [
      for (int i = 0; i < count; i += 1)
        ParagraphNode(
          id: "$i",
          text: AttributedText("Paragraph $i. Lorem ipsum dolor sit amet, consectetur adipiscing elit."),
        ),
    ],
  );
}

Future<void> _pumpEditorInCustomScrollView(
  WidgetTester tester, {
  required MutableDocument document,
  required ScrollController scrollController,
  required List<ComponentBuilder> componentBuilders,
}) async {
  tester.view
    ..physicalSize = const Size(600, 800)
    ..devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final composer = MutableDocumentComposer();
  final editor = createDefaultDocumentEditor(document: document, composer: composer);

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: CustomScrollView(
          controller: scrollController,
          slivers: [
            const SliverToBoxAdapter(child: SizedBox(height: 200)),
            SuperEditor(
              editor: editor,
              componentBuilders: componentBuilders,
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 200)),
          ],
        ),
      ),
    ),
  );
}

RenderDocumentComponentColumn _findComponentColumn(WidgetTester tester) {
  RenderDocumentComponentColumn? column;
  void visit(RenderObject renderObject) {
    if (column != null) {
      return;
    }
    if (renderObject is RenderDocumentComponentColumn) {
      column = renderObject;
      return;
    }
    renderObject.visitChildren(visit);
  }

  visit(tester.renderObject(find.byType(SingleColumnDocumentLayout)));
  return column!;
}

/// Returns the global rect that [componentRoot]'s column child is laid out at.
Rect _layoutRectOf(RenderBox componentRoot) {
  RenderObject child = componentRoot;
  while (child.parent is! RenderDocumentComponentColumn) {
    child = child.parent!;
  }
  final columnChild = child as RenderBox;
  final column = columnChild.parent! as RenderDocumentComponentColumn;
  final offset = (columnChild.parentData! as BoxParentData).offset;
  return column.localToGlobal(offset) & columnChild.size;
}

/// Expects that, in the last frame, every component that overlaps the viewport was painted,
/// and no component far from the viewport was painted.
void _expectPaintedExactlyAroundViewport(WidgetTester tester, Document document, List<String> paints) {
  final viewportRect = tester.getRect(find.byType(CustomScrollView));
  final farAwayRect = viewportRect.inflate(RenderDocumentComponentColumn.paintCullingMargin + 100);

  int visibleCount = 0;
  for (final node in document) {
    final probeBox = tester.renderObject<RenderBox>(find.byKey(ValueKey("probe-${node.id}")));
    final rect = probeBox.localToGlobal(Offset.zero) & probeBox.size;
    if (rect.overlaps(viewportRect)) {
      visibleCount += 1;
      expect(paints, contains(node.id), reason: "Node ${node.id} is visible at $rect but wasn't painted");
    } else if (!rect.overlaps(farAwayRect)) {
      expect(paints, isNot(contains(node.id)), reason: "Node ${node.id} is far away at $rect but was painted");
    }
  }
  expect(visibleCount, greaterThan(0));
  expect(paints.toSet().length, lessThan(document.nodeCount ~/ 2));
}

/// Counts the builds of every paragraph component's widget, and of the text component in
/// it, by node ID, and the builds of the layout's component builders, until the end of
/// the test.
void _countTextComponentBuilds(Map<String, int> builds, List<int> componentBuilderBuilds) {
  final previousCallback = debugOnRebuildDirtyWidget;
  debugOnRebuildDirtyWidget = (Element element, bool builtOnce) {
    previousCallback?.call(element, builtOnce);

    final widget = element.widget;
    if (widget.runtimeType.toString() == "_PresenterComponentBuilder") {
      componentBuilderBuilds[0] += 1;
    }
    final nodeId = switch (widget) {
      ParagraphComponent() => widget.viewModel.nodeId,
      TextComponent() => _findParagraphNodeIdAbove(element),
      _ => null,
    };
    if (nodeId != null) {
      builds[nodeId] = (builds[nodeId] ?? 0) + 1;
    }
  };
  addTearDown(() => debugOnRebuildDirtyWidget = previousCallback);
}

String _findParagraphNodeIdAbove(Element element) {
  String? nodeId;
  element.visitAncestorElements((ancestor) {
    final widget = ancestor.widget;
    if (widget is ParagraphComponent) {
      nodeId = widget.viewModel.nodeId;
      return false;
    }
    return true;
  });
  return nodeId ?? "unknown";
}

/// A [ComponentBuilder] that counts how many times each node's component is built, and
/// otherwise builds the default components.
class _CountingComponentBuilder implements ComponentBuilder {
  const _CountingComponentBuilder(this.builds);

  final Map<String, int> builds;

  @override
  SingleColumnLayoutComponentViewModel? createViewModel(Document document, DocumentNode node) => null;

  @override
  Widget? createComponent(
      SingleColumnDocumentComponentContext componentContext, SingleColumnLayoutComponentViewModel componentViewModel) {
    for (final builder in defaultComponentBuilders) {
      final component = builder.createComponent(componentContext, componentViewModel);
      if (component != null) {
        builds[componentViewModel.nodeId] = (builds[componentViewModel.nodeId] ?? 0) + 1;
        return component;
      }
    }
    return null;
  }
}

/// A [ComponentBuilder] that wraps every default component in a box that records when
/// it paints, and that paints its component shifted by the node's offset in [shifts].
class _PaintProbeComponentBuilder implements ComponentBuilder {
  const _PaintProbeComponentBuilder(this.paints, {this.shifts = const {}});

  final List<String> paints;
  final Map<String, Offset> shifts;

  @override
  SingleColumnLayoutComponentViewModel? createViewModel(Document document, DocumentNode node) => null;

  @override
  Widget? createComponent(
      SingleColumnDocumentComponentContext componentContext, SingleColumnLayoutComponentViewModel componentViewModel) {
    for (final builder in defaultComponentBuilders) {
      final component = builder.createComponent(componentContext, componentViewModel);
      if (component != null) {
        return _PaintProbe(
          key: ValueKey("probe-${componentViewModel.nodeId}"),
          nodeId: componentViewModel.nodeId,
          paints: paints,
          shift: shifts[componentViewModel.nodeId] ?? Offset.zero,
          child: component,
        );
      }
    }
    return null;
  }
}

class _PaintProbe extends SingleChildRenderObjectWidget {
  const _PaintProbe({
    super.key,
    required this.nodeId,
    required this.paints,
    required this.shift,
    required super.child,
  });

  final String nodeId;
  final List<String> paints;
  final Offset shift;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderPaintProbe(nodeId, paints, shift);

  @override
  void updateRenderObject(BuildContext context, _RenderPaintProbe renderObject) {
    renderObject
      ..nodeId = nodeId
      ..paints = paints
      ..shift = shift;
  }
}

/// Records when it paints, and paints, and positions, its child at [shift] from where it's
/// laid out, reporting that in its [paintBounds], as an app's multi-column layout might.
class _RenderPaintProbe extends RenderProxyBox {
  _RenderPaintProbe(this.nodeId, this.paints, this._shift);

  String nodeId;
  List<String> paints;

  Offset get shift => _shift;
  Offset _shift;
  set shift(Offset value) {
    if (value == _shift) {
      return;
    }
    _shift = value;
    markNeedsLayout();
  }

  @override
  Rect get paintBounds => (Offset.zero & size).shift(_shift);

  @override
  void paint(PaintingContext context, Offset offset) {
    paints.add(nodeId);
    if (child != null) {
      context.paintChild(child!, offset + _shift);
    }
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    transform.translateByDouble(_shift.dx, _shift.dy, 0, 1);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final child = this.child;
    if (child == null) {
      return false;
    }
    return result.addWithPaintOffset(
      offset: _shift,
      position: position,
      hitTest: (result, transformed) => child.hitTest(result, position: transformed),
    );
  }
}

class _EmptyLayerBuilder implements SuperEditorLayerBuilder {
  const _EmptyLayerBuilder();

  @override
  ContentLayerWidget build(BuildContext context, SuperEditorContext editorContext) {
    return const ContentLayerProxyWidget(child: SizedBox());
  }
}
