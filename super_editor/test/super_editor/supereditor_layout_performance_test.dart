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
      _pinEagerLayout();

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
      _pinEagerLayout();

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

      testWidgets("every component for a painting context that can't report its clip", (tester) async {
        final scrollController = ScrollController();
        addTearDown(scrollController.dispose);
        final painted = <String>[];
        final document = _createParagraphs(150);

        await _pumpEditorInCustomScrollView(
          tester,
          document: document,
          scrollController: scrollController,
          componentBuilders: [
            _PaintProbeComponentBuilder(painted),
            ...defaultComponentBuilders,
          ],
        );
        painted.clear();

        // flutter_test's `paints` matcher paints with a recording context whose canvas can't
        // report its clip.
        expect(_findComponentColumn(tester), paints..paragraph());
        expect(painted.toSet(), hasLength(document.nodeCount));

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

    group("reports semantics of", () {
      _pinEagerLayout();

      testWidgets("the components around the viewport, as if it reported every component, as the viewport scrolls", (
        tester,
      ) async {
        final scrollController = ScrollController();
        addTearDown(scrollController.dispose);
        final document = _createParagraphs(150);
        final semanticsVisits = <String>[];

        await _pumpEditorInCustomScrollView(
          tester,
          document: document,
          scrollController: scrollController,
          componentBuilders: [
            _SemanticsProbeComponentBuilder(semanticsVisits),
            ...defaultComponentBuilders,
          ],
        );
        _expectSemanticsOfComponentsAroundViewport(tester, document);
        expect(semanticsVisits.toSet().length, lessThan(document.nodeCount ~/ 2));

        for (final scrollOffset in [1500.0, 4000.0, 2600.0, 0.0]) {
          semanticsVisits.clear();
          scrollController.jumpTo(scrollOffset);
          await tester.pump();

          _expectSemanticsOfComponentsAroundViewport(tester, document);
          expect(semanticsVisits.toSet().length, lessThan(document.nodeCount ~/ 2));
        }

        // Scroll a bit at a time, so that the column reports more components only once the
        // viewport has moved far enough.
        for (double scrollOffset = 1000; scrollOffset <= 3000; scrollOffset += 150) {
          scrollController.jumpTo(scrollOffset);
          await tester.pump();

          _expectSemanticsOfComponentsAroundViewport(tester, document);
        }

        // Scroll with a drag, too.
        await tester.drag(find.byType(CustomScrollView), const Offset(0, -700));
        await tester.pump();
        _expectSemanticsOfComponentsAroundViewport(tester, document);

        // Let the editor's tap timers expire.
        await tester.pump(kDoubleTapTimeout);
      });

      testWidgets("the components that an assistive technology scrolls into view, or shows on screen", (
        tester,
      ) async {
        final scrollController = ScrollController();
        addTearDown(scrollController.dispose);
        final document = _createParagraphs(150);

        await _pumpEditorInCustomScrollView(
          tester,
          document: document,
          scrollController: scrollController,
          componentBuilders: defaultComponentBuilders,
        );

        // Scroll forward, a page at a time, and back, with the viewport's semantic actions.
        for (final action in [
          SemanticsAction.scrollUp,
          SemanticsAction.scrollUp,
          SemanticsAction.scrollUp,
          SemanticsAction.scrollDown,
        ]) {
          final scrollOffset = scrollController.offset;
          final scrollNode = _findSemanticsNode(tester, (node) => node.getSemanticsData().hasAction(action));
          scrollNode.owner!.performAction(scrollNode.id, action);
          await tester.pumpAndSettle();

          expect(scrollController.offset, isNot(scrollOffset));
          _expectSemanticsOfComponentsAroundViewport(tester, document);
        }

        // Show a component on screen that's in the viewport's cache extent, below the viewport.
        final viewportRect = tester.getRect(find.byType(CustomScrollView));
        final nodeId = document.map((node) => node.id).firstWhere((nodeId) {
          final rect = _componentGlobalRect(tester, nodeId);
          return rect.top > viewportRect.bottom + 20 &&
              rect.bottom < viewportRect.bottom + RenderAbstractViewport.defaultCacheExtent - 20;
        });
        final paragraphNode = _findSemanticsNode(tester, (node) => _paragraphIdOf(node) == nodeId);
        expect(paragraphNode.flagsCollection.isHidden, isTrue);
        paragraphNode.owner!.performAction(paragraphNode.id, SemanticsAction.showOnScreen);
        await tester.pumpAndSettle();

        expect(_paragraphsInSemanticsTree(tester)[nodeId], isFalse, reason: "Node $nodeId isn't on screen");
        _expectSemanticsOfComponentsAroundViewport(tester, document);
      });

      testWidgets("every component when a repaint boundary sits between the column and the viewport", (
        tester,
      ) async {
        final scrollController = ScrollController();
        addTearDown(scrollController.dispose);
        final document = _createParagraphs(150);
        final semanticsVisits = <String>[];

        await _pumpEditorInCustomScrollView(
          tester,
          document: document,
          scrollController: scrollController,
          componentBuilders: [
            _SemanticsProbeComponentBuilder(semanticsVisits),
            ...defaultComponentBuilders,
          ],
          // A fade is a repaint boundary, whose picture of the column the viewport can show at
          // another scroll offset, without painting the column again.
          wrapEditor: (editor) => SliverFadeTransition(opacity: const AlwaysStoppedAnimation(1.0), sliver: editor),
        );
        expect(semanticsVisits.toSet().length, document.nodeCount);
        _expectSemanticsOfComponentsAroundViewport(tester, document);

        semanticsVisits.clear();
        scrollController.jumpTo(3000);
        await tester.pump();
        expect(semanticsVisits.toSet().length, document.nodeCount);
        _expectSemanticsOfComponentsAroundViewport(tester, document);
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

    group("finds the component at an offset", () {
      _pinEagerLayout();

      testWidgets("as a linear scan does, when components sit side by side", (tester) async {
        final document = _createParagraphs(40);
        // Paint the components in pairs, side by side, the way an app's columns might,
        // and shift a few of them farther, so that their bounds overlap, and aren't sorted
        // by their top edges.
        final shifts = <String, Offset>{
          for (int i = 1; i < 40; i += 2) "$i": const Offset(260, -30),
          "8": const Offset(40, -95),
          "21": const Offset(-80, 45),
          "30": const Offset(0, -400),
        };
        await tester //
            .createDocument()
            .withCustomContent(document)
            .withEditorSize(const Size(600, 4000))
            .withComponentBuilders([
          _PaintProbeComponentBuilder([], shifts: shifts),
          ...defaultComponentBuilders,
        ]).pump();

        final layout = SuperEditorInspector.findDocumentLayout();

        // Make sure that the component bounds really aren't sorted.
        final componentTops = [
          for (int i = 0; i < 40; i += 1)
            (layout.getComponentByNodeId("$i")!.context.findRenderObject() as RenderBox).localToGlobal(Offset.zero).dy,
        ];
        expect(
          [for (int i = 1; i < componentTops.length; i += 1) componentTops[i] < componentTops[i - 1]],
          contains(true),
        );

        // The layout's offsets are relative to the box around the column of components.
        final layoutSize = (_findComponentColumn(tester).parent! as RenderBox).size;

        int comparisons = 0;
        for (double y = -60; y < layoutSize.height + 60; y += 2.5) {
          for (final x in [-20.0, 0.0, 10.0, 100.0, 250.0, 290.0, 400.0, 599.0, 700.0, 900.0]) {
            final offset = Offset(x, y);

            debugSingleColumnLayoutUseLinearLookups = false;
            final atOffset = layout.getDocumentPositionAtOffset(offset);
            final nearestToOffset = layout.getDocumentPositionNearestToOffset(offset);
            final cursor = layout.getDesiredCursorAtOffset(offset);

            debugSingleColumnLayoutUseLinearLookups = true;
            final linearAtOffset = layout.getDocumentPositionAtOffset(offset);
            final linearNearestToOffset = layout.getDocumentPositionNearestToOffset(offset);
            final linearCursor = layout.getDesiredCursorAtOffset(offset);
            debugSingleColumnLayoutUseLinearLookups = false;

            expect(atOffset, linearAtOffset, reason: "getDocumentPositionAtOffset($offset)");
            expect(nearestToOffset, linearNearestToOffset, reason: "getDocumentPositionNearestToOffset($offset)");
            expect(cursor, linearCursor, reason: "getDesiredCursorAtOffset($offset)");
            comparisons += 1;
          }
        }
        expect(comparisons, greaterThan(1000));
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
  Widget Function(Widget editor)? wrapEditor,
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
            (wrapEditor ?? (editor) => editor)(
              SuperEditor(
                editor: editor,
                componentBuilders: componentBuilders,
              ),
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

/// Expects that the semantics tree holds the paragraphs that it would hold if the column of
/// components reported the semantics of every component: the ones on screen, the ones in
/// the viewport's cache extent, hidden, and none farther away.
///
/// The paragraphs within a few pixels of those regions' edges, where the text that reports
/// the semantics doesn't fill its component, aren't checked.
void _expectSemanticsOfComponentsAroundViewport(WidgetTester tester, Document document) {
  const cacheExtent = RenderAbstractViewport.defaultCacheExtent;
  const tolerance = 20.0;
  final viewportRect = tester.getRect(find.byType(CustomScrollView));
  final reported = _paragraphsInSemanticsTree(tester);

  int visibleCount = 0;
  for (final node in document) {
    final rect = _componentGlobalRect(tester, node.id);
    final isVisible = rect.bottom > viewportRect.top + tolerance && rect.top < viewportRect.bottom - tolerance;
    final isInCacheExtent =
        (rect.bottom < viewportRect.top - tolerance && rect.bottom > viewportRect.top - cacheExtent + tolerance) ||
            (rect.top > viewportRect.bottom + tolerance && rect.top < viewportRect.bottom + cacheExtent - tolerance);
    final isFarAway = rect.bottom < viewportRect.top - cacheExtent - tolerance ||
        rect.top > viewportRect.bottom + cacheExtent + tolerance;

    if (isVisible) {
      visibleCount += 1;
      expect(reported[node.id], isFalse, reason: "Node ${node.id} is on screen at $rect, but its semantics aren't");
    } else if (isInCacheExtent) {
      expect(reported[node.id], isTrue, reason: "Node ${node.id} is in the cache extent at $rect, but not hidden");
    } else if (isFarAway) {
      expect(reported.containsKey(node.id), isFalse, reason: "Node ${node.id} is far away at $rect, but reported");
    }
  }
  expect(visibleCount, greaterThan(0));
}

/// Returns whether each paragraph in the semantics tree, by node ID, is hidden, i.e., off
/// screen, in the viewport's cache extent.
Map<String, bool> _paragraphsInSemanticsTree(WidgetTester tester) {
  final paragraphs = <String, bool>{};
  _visitSemanticsNodes(tester, (node) {
    final nodeId = _paragraphIdOf(node);
    if (nodeId != null) {
      paragraphs[nodeId] = node.flagsCollection.isHidden;
    }
  });
  return paragraphs;
}

/// The node ID of the paragraph from [_createParagraphs] whose semantics are [node], if any.
String? _paragraphIdOf(SemanticsNode node) => RegExp(r"^Paragraph (\d+)\.").firstMatch(node.label)?.group(1);

SemanticsNode _findSemanticsNode(WidgetTester tester, bool Function(SemanticsNode node) test) {
  final nodes = <SemanticsNode>[];
  _visitSemanticsNodes(tester, (node) {
    if (test(node)) {
      nodes.add(node);
    }
  });
  expect(nodes, isNotEmpty);
  return nodes.first;
}

void _visitSemanticsNodes(WidgetTester tester, void Function(SemanticsNode node) visitor) {
  void visit(SemanticsNode node) {
    visitor(node);
    node.visitChildren((child) {
      visit(child);
      return true;
    });
  }

  visit(tester.binding.renderViews.first.owner!.semanticsOwner!.rootSemanticsNode!);
}

Rect _componentGlobalRect(WidgetTester tester, String nodeId) {
  final layout = tester.state(find.byType(SingleColumnDocumentLayout)) as DocumentLayout;
  final componentBox = layout.getComponentByNodeId(nodeId)!.context.findRenderObject() as RenderBox;
  return componentBox.localToGlobal(Offset.zero) & componentBox.size;
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

/// Wraps every default component in a [_SemanticsProbe], which records the node ID of its
/// component in [semanticsVisits] whenever a semantics update visits the component.
class _SemanticsProbeComponentBuilder implements ComponentBuilder {
  const _SemanticsProbeComponentBuilder(this.semanticsVisits);

  final List<String> semanticsVisits;

  @override
  SingleColumnLayoutComponentViewModel? createViewModel(Document document, DocumentNode node) => null;

  @override
  Widget? createComponent(
      SingleColumnDocumentComponentContext componentContext, SingleColumnLayoutComponentViewModel componentViewModel) {
    for (final builder in defaultComponentBuilders) {
      final component = builder.createComponent(componentContext, componentViewModel);
      if (component != null) {
        return _SemanticsProbe(nodeId: componentViewModel.nodeId, semanticsVisits: semanticsVisits, child: component);
      }
    }
    return null;
  }
}

class _SemanticsProbe extends SingleChildRenderObjectWidget {
  const _SemanticsProbe({
    required this.nodeId,
    required this.semanticsVisits,
    required super.child,
  });

  final String nodeId;
  final List<String> semanticsVisits;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderSemanticsProbe(nodeId, semanticsVisits);

  @override
  void updateRenderObject(BuildContext context, _RenderSemanticsProbe renderObject) {
    renderObject
      ..nodeId = nodeId
      ..semanticsVisits = semanticsVisits;
  }
}

/// Records its node ID whenever a semantics update finds the semantics of its child, which
/// asks this box for its clip.
class _RenderSemanticsProbe extends RenderProxyBox {
  _RenderSemanticsProbe(this.nodeId, this.semanticsVisits);

  String nodeId;
  List<String> semanticsVisits;

  @override
  Rect? describeSemanticsClip(RenderObject? child) {
    semanticsVisits.add(nodeId);
    return super.describeSemanticsClip(child);
  }
}

class _EmptyLayerBuilder implements SuperEditorLayerBuilder {
  const _EmptyLayerBuilder();

  @override
  ContentLayerWidget build(BuildContext context, SuperEditorContext editorContext) {
    return const ContentLayerProxyWidget(child: SizedBox());
  }
}

/// Makes the tests in the enclosing group build every component in the first frame, even
/// when the suite runs with progressive layout on by default, because they check how the
/// eager layout builds, paints, and finds every component.
void _pinEagerLayout() {
  late bool wasProgressiveByDefault;
  setUp(() {
    wasProgressiveByDefault = SingleColumnProgressiveLayout.debugProgressiveByDefault;
    SingleColumnProgressiveLayout.debugProgressiveByDefault = false;
  });
  tearDown(() {
    SingleColumnProgressiveLayout.debugProgressiveByDefault = wasProgressiveByDefault;
  });
}
