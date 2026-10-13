import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_test_robots/flutter_test_robots.dart';
import 'package:follow_the_leader/follow_the_leader.dart';
import 'package:flutter_test_runners/flutter_test_runners.dart';
import 'package:super_editor/src/infrastructure/platforms/ios/selection_handles.dart';
import 'package:super_editor/super_editor.dart';
import 'package:super_editor/super_editor_test.dart';
import 'package:super_editor/super_reader_test.dart';

void main() {
  group("SingleColumnDocumentLayout > progressive layout >", () {
    // These tests choose, for every editor, whether it lays out progressively, even when the
    // suite runs with progressive layout on by default.
    late bool wasProgressiveByDefault;
    setUp(() {
      wasProgressiveByDefault = SingleColumnProgressiveLayout.debugProgressiveByDefault;
      SingleColumnProgressiveLayout.debugProgressiveByDefault = false;
    });
    tearDown(() {
      SingleColumnProgressiveLayout.debugProgressiveByDefault = wasProgressiveByDefault;
    });

    group("first frame >", () {
      testWidgets("builds only the window around the initial scroll offset", (tester) async {
        final harness = await _pumpEditor(tester, document: _createDocument());
        final layout = harness.progressiveLayout;
        final built = harness.builtNodeIds();

        // The first frame builds the nodes in the first one and a half screens, and the
        // last node, and nothing else.
        expect(built, contains("0"));
        expect(built, contains("399"));
        expect(built.length, lessThan(60));
        expect(built.length, greaterThan(5));
        for (final nodeId in built) {
          expect(nodeId == "399" || int.parse(nodeId) < 60, isTrue, reason: "Node $nodeId isn't in the window");
        }

        // The nodes that aren't built have no component, and the layout doesn't throw.
        expect(layout.isComponentDeferred("200"), isTrue);
        expect(harness.layout.getComponentByNodeId("200"), isNull);
        expect(harness.controller.isComplete.value, isFalse);

        // Every visible node is built.
        harness.expectEveryVisibleNodeIsBuilt(tester);

        await harness.pumpUntilComplete(tester);
        expect(harness.builtNodeIds().length, 400);
        expect(harness.layout.getComponentByNodeId("200"), isNotNull);
        expect(layout.isComponentDeferred("200"), isFalse);
      });

      testWidgets("completes after idle frames, in batches", (tester) async {
        final harness = await _pumpEditor(tester, document: _createDocument());

        final frames = await harness.pumpUntilComplete(tester);
        expect(frames, greaterThan(1));
        expect(harness.builtNodeIds().length, 400);
      });

      testWidgets("lays out every node exactly as the eager layout does, once complete", (tester) async {
        final eager = await _pumpEditor(tester, document: _createDocument(), progressive: false);
        expect(eager.builtNodeIds().length, 400);
        final eagerRects = eager.componentRects();
        final eagerScrollExtent = eager.scrollController.position.maxScrollExtent;

        await tester.pumpWidget(const SizedBox());

        final progressive = await _pumpEditor(tester, document: _createDocument());
        await progressive.pumpUntilComplete(tester);

        final progressiveRects = progressive.componentRects();
        expect(progressiveRects.keys, eagerRects.keys);
        for (final nodeId in eagerRects.keys) {
          expect(progressiveRects[nodeId], _rectMoreOrLessEquals(eagerRects[nodeId]!), reason: "Node $nodeId");
        }
        expect(progressive.scrollController.position.maxScrollExtent, moreOrLessEquals(eagerScrollExtent));
      });

      testWidgets("builds the window at the initial scroll offset that the app gives, below other slivers", (
        tester,
      ) async {
        // The document sits below a header that's exactly as tall as the initial scroll
        // offset, so the top of the document is at the top of the viewport.
        const headerHeight = 3000.0;
        final document = _createDocument();
        final controller = SingleColumnProgressiveLayoutController();
        addTearDown(controller.dispose);
        final scrollController = ScrollController(initialScrollOffset: headerHeight);
        addTearDown(scrollController.dispose);
        final layoutKey = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: CustomScrollView(
                controller: scrollController,
                slivers: [
                  const SliverToBoxAdapter(child: SizedBox(height: headerHeight)),
                  SuperEditor(
                    editor: createDefaultDocumentEditor(document: document, composer: MutableDocumentComposer()),
                    documentLayoutKey: layoutKey,
                    progressiveLayout: SingleColumnProgressiveLayout(
                      controller: controller,
                      initialScrollOffset: () => max(scrollController.offset - headerHeight, 0),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );

        final layout = layoutKey.currentState as ProgressiveDocumentLayout;
        expect(scrollController.offset, headerHeight);
        // The top of the document is built...
        expect(layout.isComponentDeferred("0"), isFalse);
        expect(layout.isComponentDeferred("5"), isFalse);
        // ...and the nodes that the scroll offset of the Scrollable would point to, if the
        // document were the first sliver, aren't.
        final deferredNodeIds = [
          for (final node in document)
            if (layout.isComponentDeferred(node.id)) node.id,
        ];
        expect(deferredNodeIds.length, greaterThan(300));
        // The nodes that are built are the ones at the top, and the last one.
        final firstDeferredIndex = int.parse(deferredNodeIds.first);
        expect(firstDeferredIndex, lessThan(40));
        expect(deferredNodeIds.length, document.nodeCount - firstDeferredIndex - 1);

        await _pumpUntil(tester, () => controller.isComplete.value);
      });

      testWidgets("reports completion once", (tester) async {
        final harness = await _pumpEditor(tester, document: _createDocument());
        final notifications = <bool>[];
        harness.controller.isComplete.addListener(() => notifications.add(harness.controller.isComplete.value));

        await harness.pumpUntilComplete(tester);
        // Pump a few more frames, and change the document.
        await tester.pump();
        harness.editor.execute([
          InsertTextRequest(
            documentPosition: const DocumentPosition(nodeId: "1", nodePosition: TextNodePosition(offset: 0)),
            textToInsert: "Hello ",
            attributions: {},
          ),
        ]);
        await tester.pump();
        await tester.pump();

        expect(notifications, [true]);
      });

      testWidgets("reports completion after the first frame when it builds everything at once", (tester) async {
        final harness = await _pumpEditor(tester, document: _createDocument(paragraphCount: 2));
        expect(harness.builtNodeIds().length, 2);

        await tester.pump();
        expect(harness.controller.isComplete.value, isTrue);
      });
    });

    group("keeps the visible content still >", () {
      testWidgets("while it builds the nodes below the viewport", (tester) async {
        final harness = await _pumpEditor(tester, document: _createDocument());

        final visibleRects = harness.visibleComponentGlobalRects(tester);
        expect(visibleRects, isNotEmpty);

        while (!harness.controller.isComplete.value) {
          await tester.pump();
          expect(harness.scrollController.offset, 0);
          for (final entry in visibleRects.entries) {
            expect(harness.componentGlobalRect(entry.key), _rectMoreOrLessEquals(entry.value), reason: entry.key);
          }
        }
      });

      testWidgets("while it builds the nodes above the viewport, from a non-zero initial offset", (tester) async {
        final harness = await _pumpEditor(tester, document: _createDocument(), initialScrollOffset: 6000);
        expect(harness.scrollController.offset, 6000);

        // The visible region is built.
        harness.expectEveryVisibleNodeIsBuilt(tester);
        final visibleRects = harness.visibleComponentGlobalRects(tester);
        expect(visibleRects, isNotEmpty);
        // The window doesn't include the top of the document.
        expect(harness.progressiveLayout.isComponentDeferred("5"), isTrue);

        while (!harness.controller.isComplete.value) {
          await tester.pump();
          for (final entry in visibleRects.entries) {
            expect(harness.componentGlobalRect(entry.key), _rectMoreOrLessEquals(entry.value), reason: entry.key);
          }
        }

        // The nodes above were taller, or shorter, than their estimates, so the scroll offset
        // was corrected to keep the visible content where it was.
        expect(harness.scrollController.offset, isNot(moreOrLessEquals(6000)));
        expect(harness.builtNodeIds().length, 400);
      });

      testWidgets("when it jumps into content that isn't built", (tester) async {
        final harness = await _pumpEditor(tester, document: _createDocument());
        expect(harness.progressiveLayout.isComponentDeferred("250"), isTrue);

        // Find the placeholder that the jump aims at.
        final targetIndex = harness.childIndexAtDocumentOffset(9000);
        final targetNodeId = harness.document.getNodeAt(targetIndex)!.id;
        expect(harness.progressiveLayout.isComponentDeferred(targetNodeId), isTrue);
        final targetOffsetFromViewportTop = harness.childRectInDocument(targetIndex).top - 9000;

        harness.scrollController.jumpTo(9000);
        await tester.pump();

        // The frame after the jump builds what it shows, and shows the node that the jump
        // aimed at where the jump put it, even though the nodes above it, that the layout
        // built in the meantime, changed its offset in the document.
        harness.expectEveryVisibleNodeIsBuilt(tester);
        expect(harness.progressiveLayout.isComponentDeferred(targetNodeId), isFalse);
        expect(
          harness.childRectInDocument(targetIndex).top - harness.scrollController.offset,
          moreOrLessEquals(targetOffsetFromViewportTop),
        );
        final visibleRects = harness.visibleComponentGlobalRects(tester);
        expect(visibleRects, isNotEmpty);

        // The rest of the fill doesn't move it.
        while (!harness.controller.isComplete.value) {
          await tester.pump();
          for (final entry in visibleRects.entries) {
            expect(harness.componentGlobalRect(entry.key), _rectMoreOrLessEquals(entry.value), reason: entry.key);
          }
        }
      });

      testWidgets("and lands an animated scroll exactly where it was aimed", (tester) async {
        final harness = await _pumpEditor(tester, document: _createDocument());

        var isAnimationDone = false;
        harness.scrollController
            .animateTo(9000, duration: const Duration(milliseconds: 500), curve: Curves.easeInOut)
            .then((_) => isAnimationDone = true);
        while (!isAnimationDone) {
          await tester.pump(const Duration(milliseconds: 16));
          harness.expectEveryVisibleNodeIsBuilt(tester);
        }

        // The animation landed where it was aimed, while the layout was still building.
        expect(harness.scrollController.offset, 9000);
        expect(harness.controller.isComplete.value, isFalse);

        // Building the rest doesn't move what's visible.
        final visibleRects = harness.visibleComponentGlobalRects(tester);
        expect(visibleRects, isNotEmpty);
        while (!harness.controller.isComplete.value) {
          await tester.pump();
          for (final entry in visibleRects.entries) {
            expect(harness.componentGlobalRect(entry.key), _rectMoreOrLessEquals(entry.value), reason: entry.key);
          }
        }
      });

      testWidgets("while the user drags, and builds only around the viewport until the drag ends", (tester) async {
        final harness = await _pumpEditor(tester, document: _createDocument());

        final gesture = await tester.startGesture(const Offset(400, 500));
        for (int i = 0; i < 20; i += 1) {
          await gesture.moveBy(const Offset(0, -40));
          await tester.pump();
          harness.expectEveryVisibleNodeIsBuilt(tester);
        }

        // While the finger is down, the layout only builds around the viewport, so the
        // end of the document isn't built.
        for (int i = 0; i < 50; i += 1) {
          await tester.pump();
        }
        expect(harness.controller.isComplete.value, isFalse);
        expect(harness.progressiveLayout.isComponentDeferred("300"), isTrue);

        await gesture.up();
        await tester.pumpAndSettle();
        await harness.pumpUntilComplete(tester);
      });
    });

    group("layout queries while it builds >", () {
      testWidgets("report no component for a node that isn't built", (tester) async {
        final harness = await _pumpEditor(tester, document: _createDocument());

        expect(harness.progressiveLayout.isComponentDeferred("200"), isTrue);
        expect(harness.layout.getComponentByNodeId("200"), isNull);
        expect(
          harness.layout.getRectForPosition(
            const DocumentPosition(nodeId: "200", nodePosition: TextNodePosition(offset: 0)),
          ),
          isNull,
        );
      });

      testWidgets("report the rect of a selection across nodes that aren't built", (tester) async {
        final harness = await _pumpEditor(tester, document: _createDocument());
        final layout = harness.layout;
        final lastNode = harness.document.last as ParagraphNode;

        final rect = layout.getRectForSelection(
          const DocumentPosition(nodeId: "0", nodePosition: TextNodePosition(offset: 0)),
          DocumentPosition(nodeId: lastNode.id, nodePosition: lastNode.endPosition),
        );
        expect(rect, isNotNull);

        // The rect spans from the first line of the first node to the last line of the last
        // node, across the placeholders.
        final firstRect = harness.componentRectInDocument("0");
        final lastRect = harness.componentRectInDocument(lastNode.id);
        expect(rect!.top, inInclusiveRange(firstRect.top, firstRect.top + 20));
        expect(rect.bottom, inInclusiveRange(lastRect.bottom - 20, lastRect.bottom));

        // A selection that starts, or ends, in a node that isn't built has no rect.
        expect(
          layout.getRectForSelection(
            const DocumentPosition(nodeId: "0", nodePosition: TextNodePosition(offset: 0)),
            const DocumentPosition(nodeId: "200", nodePosition: TextNodePosition(offset: 1)),
          ),
          isNull,
        );
      });

      testWidgets("find the nearest built node over a placeholder, and build the placeholder's node", (tester) async {
        final harness = await _pumpEditor(tester, document: _createDocument());
        final layout = harness.layout;

        const placeholderIndex = 200;
        const placeholderNodeId = "$placeholderIndex";
        expect(harness.progressiveLayout.isComponentDeferred(placeholderNodeId), isTrue);
        final placeholderRect = harness.childRectInDocument(placeholderIndex);

        // Nothing is at the offset of a placeholder.
        expect(layout.getDocumentPositionAtOffset(placeholderRect.center), isNull);

        // The nearest position is in a node that's built.
        final nearest = layout.getDocumentPositionNearestToOffset(placeholderRect.center);
        expect(nearest, isNotNull);
        expect(harness.progressiveLayout.isComponentDeferred(nearest!.nodeId), isFalse);
        expect(layout.getComponentByNodeId(nearest.nodeId), isNotNull);

        // Both lookups asked for the placeholder's node, which the next frame builds.
        await tester.pump();
        expect(harness.progressiveLayout.isComponentDeferred(placeholderNodeId), isFalse);
        expect(layout.getComponentByNodeId(placeholderNodeId), isNotNull);
      });

      testWidgets("find the last selectable position", (tester) async {
        final harness = await _pumpEditor(tester, document: _createDocument());
        final lastNode = harness.document.last as ParagraphNode;

        expect(
          harness.layout.findLastSelectablePosition(),
          DocumentPosition(nodeId: lastNode.id, nodePosition: lastNode.endPosition),
        );
      });

      testWidgets("find the last selectable position before nodes that can't be selected", (tester) async {
        final document = _createDocument();
        for (int i = 0; i < 3; i += 1) {
          document.add(HorizontalRuleNode(id: "hr-$i"));
        }
        final harness = await _pumpEditor(
          tester,
          document: document,
          componentBuilders: [const _UnselectableHorizontalRuleComponentBuilder(), ...defaultComponentBuilders],
        );

        // The layout builds the nodes from the end back to the last selectable one.
        final lastParagraph = document.getNodeById("399") as ParagraphNode;
        expect(harness.progressiveLayout.isComponentDeferred("399"), isFalse);
        expect(
          harness.layout.findLastSelectablePosition(),
          DocumentPosition(nodeId: "399", nodePosition: lastParagraph.endPosition),
        );
      });

      testWidgets("find the first and last positions above and below the content", (tester) async {
        final harness = await _pumpEditor(tester, document: _createDocument());
        final layout = harness.layout;
        final lastNode = harness.document.last as ParagraphNode;

        expect(
          layout.getDocumentPositionNearestToOffset(const Offset(10, -100)),
          const DocumentPosition(nodeId: "0", nodePosition: TextNodePosition(offset: 0)),
        );
        expect(
          layout.getDocumentPositionNearestToOffset(Offset(10, harness.childRectInDocument(399).bottom + 100)),
          DocumentPosition(nodeId: lastNode.id, nodePosition: lastNode.endPosition),
        );
      });

      testWidgets("build the nodes that the controller asks for in the next frame", (tester) async {
        final harness = await _pumpEditor(tester, document: _createDocument());
        expect(harness.progressiveLayout.isComponentDeferred("300"), isTrue);

        harness.controller.ensureBuilt(["300", "301"]);
        await tester.pump();

        expect(harness.layout.getComponentByNodeId("300"), isNotNull);
        expect(harness.layout.getComponentByNodeId("301"), isNotNull);
      });

      testWidgets("build everything in the next frame on completeNow()", (tester) async {
        final harness = await _pumpEditor(tester, document: _createDocument());

        harness.controller.completeNow();
        await tester.pump();

        expect(harness.builtNodeIds().length, 400);
        expect(harness.controller.isComplete.value, isTrue);
      });
    });

    group("schedules batches >", () {
      testWidgets("of one node per frame for a frame budget of zero", (tester) async {
        final harness = await _pumpEditor(tester, document: _createDocument(), frameBudget: Duration.zero);

        for (int frame = 0; frame < 20; frame += 1) {
          final builtBefore = harness.builtNodeIds().length;
          await tester.pump(const Duration(milliseconds: 16));
          expect(harness.builtNodeIds().length - builtBefore, 1, reason: "Frame $frame");
        }
        expect(harness.controller.isComplete.value, isFalse);
      });

      testWidgets("that grow, twice per frame at most, while the frames stay under the budget", (tester) async {
        // A budget that no frame of this test reaches.
        final harness = await _pumpEditor(tester, document: _createDocument(), frameBudget: const Duration(seconds: 5));

        final builtPerFrame = await harness.pumpUntilCompleteCountingBuilds(tester);

        // The batches doubled, until the last one, which built what was left.
        expect(builtPerFrame.length, inInclusiveRange(3, 8));
        for (int frame = 1; frame < builtPerFrame.length - 1; frame += 1) {
          expect(builtPerFrame[frame], greaterThan(builtPerFrame[frame - 1]), reason: "Frame $frame: $builtPerFrame");
          // The batches double their work, which is about twice the nodes, unless the nodes
          // of a batch are shorter than those of the last one.
          expect(builtPerFrame[frame], lessThanOrEqualTo(builtPerFrame[frame - 1] * 3),
              reason: "Frame $frame: $builtPerFrame");
        }
      });

      testWidgets("that leave room for the rest of the frame", (tester) async {
        // The frames spend 40 milliseconds painting something else, besides the document.
        Future<int> largestBatch({required bool withSlowPainter}) async {
          final harness = await _pumpEditor(
            tester,
            document: _createDocument(paragraphCount: 1000),
            frameBudget: const Duration(milliseconds: 60),
            above: withSlowPainter ? const _SlowPainter(paintTime: Duration(milliseconds: 40)) : null,
          );
          final builtPerFrame = await harness.pumpUntilCompleteCountingBuilds(tester);
          await tester.pumpWidget(const SizedBox());
          return builtPerFrame.reduce(max);
        }

        final withoutSlowPainter = await largestBatch(withSlowPainter: false);
        final withSlowPainter = await largestBatch(withSlowPainter: true);

        // The batches leave the time that the rest of the frame takes, so they're about a third.
        expect(withSlowPainter, lessThan(withoutSlowPainter * 0.75));
      });

      testWidgets("after the safety timeout, that grow, and finish without a frame that builds everything", (
        tester,
      ) async {
        final harness = await _pumpEditor(
          tester,
          document: _createDocument(),
          safetyTimeout: const Duration(milliseconds: 500),
          // Batches of one node until the timeout.
          frameBudget: Duration.zero,
        );

        // Until the timeout, which counts from the end of the first frame, the frames build
        // a node each.
        final firstFrameEnd = tester.binding.clock.now();
        while (tester.binding.clock.now().difference(firstFrameEnd) < const Duration(milliseconds: 500)) {
          final builtBefore = harness.builtNodeIds().length;
          await tester.pump(const Duration(milliseconds: 16));
          expect(harness.builtNodeIds().length - builtBefore, lessThanOrEqualTo(1));
        }
        await tester.pump(const Duration(milliseconds: 16));
        final remainingAtTimeout = 400 - harness.builtNodeIds().length;
        expect(remainingAtTimeout, greaterThan(300));

        // After it, the batches grow, from the size of the batches before it, and finish
        // over several frames.
        final builtPerFrame = await harness.pumpUntilCompleteCountingBuilds(tester);
        expect(builtPerFrame.first, lessThan(10));
        expect(builtPerFrame.reduce(max), lessThan(remainingAtTimeout));
        expect(builtPerFrame.reduce(max), greaterThan(builtPerFrame.first * 4));
        expect(builtPerFrame.length, lessThan(30));
        expect(harness.builtNodeIds().length, 400);
      });

      testWidgets(
          "after the safety timeout, that finish in a few frames, when the rest of every frame takes longer than "
          "the catch-up budget", (tester) async {
        // Every frame spends 70 milliseconds on something else, more than the catch-up budget of
        // 50 milliseconds, as the frames of a long document do in a debug build that updates its
        // semantics.
        final harness = await _pumpEditor(
          tester,
          document: _createDocument(),
          safetyTimeout: const Duration(milliseconds: 100),
          above: const _SlowPainter(paintTime: Duration(milliseconds: 70)),
        );

        // Until the timeout, which counts from the end of the first frame, the batches leave the
        // frame budget to the rest of the frame, which takes all of it, so they build a node each.
        final firstFrameEnd = tester.binding.clock.now();
        await _pumpUntil(
          tester,
          () => tester.binding.clock.now().difference(firstFrameEnd) > const Duration(milliseconds: 100),
        );
        final remainingAtTimeout = 400 - harness.builtNodeIds().length;
        expect(remainingAtTimeout, greaterThan(300));

        // After it, the batches take as long as the rest of the frame, up to the catch-up budget,
        // rather than a node each, and they finish in a few frames.
        final builtPerFrame = await harness.pumpUntilCompleteCountingBuilds(tester);
        expect(builtPerFrame.length, lessThan(40), reason: "$builtPerFrame");
        expect(builtPerFrame.reduce(max), greaterThan(10), reason: "$builtPerFrame");
        expect(harness.builtNodeIds().length, 400);
      });

      testWidgets("after the safety timeout, while the user drags, and keeps the visible content still", (
        tester,
      ) async {
        final harness = await _pumpEditor(
          tester,
          document: _createDocument(),
          initialScrollOffset: 6000,
          safetyTimeout: const Duration(milliseconds: 500),
        );

        // Drag, and hold the finger down, so that the user scrolls until the fill finishes.
        final gesture = await tester.startGesture(const Offset(400, 300));
        for (int i = 0; i < 5; i += 1) {
          await gesture.moveBy(const Offset(0, 40));
          await tester.pump(const Duration(milliseconds: 16));
        }
        // Before the timeout, the layout builds only around the viewport.
        for (int i = 0; i < 20; i += 1) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(harness.controller.isComplete.value, isFalse);

        // After it, the layout builds the rest, while the finger is still down, without
        // moving what's visible.
        await tester.pump(const Duration(milliseconds: 500));
        final visibleRects = harness.visibleComponentGlobalRects(tester);
        expect(visibleRects, isNotEmpty);
        var frames = 0;
        while (!harness.controller.isComplete.value) {
          await tester.pump(const Duration(milliseconds: 16));
          frames += 1;
          expect(frames, lessThan(500));
          for (final entry in visibleRects.entries) {
            expect(harness.componentGlobalRect(entry.key), _rectMoreOrLessEquals(entry.value), reason: entry.key);
          }
        }

        await gesture.up();
        await tester.pumpAndSettle();
      });

      testWidgets("and completeNow() still builds everything in the next frame", (tester) async {
        final harness = await _pumpEditor(tester, document: _createDocument(), frameBudget: Duration.zero);
        await tester.pump(const Duration(milliseconds: 16));
        await tester.pump(const Duration(milliseconds: 16));

        harness.controller.completeNow();
        await tester.pump();

        expect(harness.builtNodeIds().length, 400);
        expect(harness.controller.isComplete.value, isTrue);
      });

      testWidgets("that build the rest in document order, in batches, when they stop building nodes", (
        tester,
      ) async {
        // The layout chooses its batches, and then doesn't build them.
        SingleColumnProgressiveLayout.debugIgnoreChosenBatches = true;
        addTearDown(() => SingleColumnProgressiveLayout.debugIgnoreChosenBatches = false);
        final harness = await _pumpEditor(tester, document: _createDocument(), initialScrollOffset: 3000);
        final visibleRects = harness.visibleComponentGlobalRects(tester);
        expect(visibleRects, isNotEmpty);

        final builtPerFrame = <int>[];
        while (!harness.controller.isComplete.value) {
          expect(builtPerFrame.length, lessThan(100), reason: "$builtPerFrame");
          final builtBefore = harness.builtNodeIds().length;
          await tester.pump(const Duration(milliseconds: 16));
          builtPerFrame.add(harness.builtNodeIds().length - builtBefore);
          for (final entry in visibleRects.entries) {
            expect(harness.componentGlobalRect(entry.key), _rectMoreOrLessEquals(entry.value), reason: entry.key);
          }
        }

        // A few frames build nothing, and then the layout builds the rest, above the visible
        // content, too, a batch of several nodes at a time.
        final framesWithoutProgress = builtPerFrame.takeWhile((built) => built == 0).length;
        expect(framesWithoutProgress, inInclusiveRange(2, 4), reason: "$builtPerFrame");
        expect(builtPerFrame.skip(framesWithoutProgress).first, greaterThan(5), reason: "$builtPerFrame");
        expect(harness.builtNodeIds().length, 400);
        expect(tester.takeException(), isNull);
      });

      testWidgets("that build the hidden nodes, which have an estimate of zero, and draw nothing", (tester) async {
        // Five nodes that draw nothing after every ten paragraphs, like the lines of a collapsed
        // toggle, and at the end of the document.
        final document = MutableDocument(
          nodes: [
            for (int i = 0; i < 400; i += 1)
              i % 15 >= 10 || i >= 395
                  ? HorizontalRuleNode(id: "$i")
                  : ParagraphNode(id: "$i", text: AttributedText("Paragraph $i. ${"Lorem ipsum. " * (i % 7)}")),
          ],
        );
        final harness = await _pumpEditor(
          tester,
          document: document,
          componentBuilders: [const _HiddenHorizontalRuleComponentBuilder(), ...defaultComponentBuilders],
          estimateHeight: (viewModel, width) => viewModel is HorizontalRuleComponentViewModel ? 0 : null,
          safetyTimeout: const Duration(milliseconds: 500),
        );
        expect(harness.builtNodeIds().length, lessThan(100));

        await harness.pumpUntilComplete(tester);

        expect(harness.builtNodeIds().length, 400);
        harness.expectColumnIsStacked();
        expect(harness.column.childRectAt(397).height, 0);
      });
    });

    group("column of components >", () {
      testWidgets("stacks every child while it builds, and lays out as the eager layout does", (tester) async {
        final harness = await _pumpEditor(tester, document: _createDocument(), initialScrollOffset: 3000);
        harness.expectColumnIsStacked();
        while (!harness.controller.isComplete.value) {
          await tester.pump(const Duration(milliseconds: 16));
          harness.expectColumnIsStacked();
        }
      });

      testWidgets("lays out every child again when its width changes while it builds", (tester) async {
        final harness = await _pumpEditor(tester, document: _createDocument(), frameBudget: Duration.zero);
        await tester.pump(const Duration(milliseconds: 16));

        tester.view.physicalSize = tester.view.physicalSize - const Offset(300, 0) as Size;
        addTearDown(tester.view.reset);
        await tester.pump(const Duration(milliseconds: 16));
        harness.expectColumnIsStacked();

        harness.controller.completeNow();
        await tester.pump();
        harness.expectColumnIsStacked();
        final progressiveRects = harness.componentRects();

        await tester.pumpWidget(const SizedBox());
        final eager = await _pumpEditor(tester, document: _createDocument(), progressive: false);
        final eagerRects = eager.componentRects();
        for (final nodeId in eagerRects.keys) {
          expect(progressiveRects[nodeId], _rectMoreOrLessEquals(eagerRects[nodeId]!), reason: "Node $nodeId");
        }
      });
    });

    group("builds nodes together >", () {
      testWidgets("with a node in the first window, however far below the window they are", (tester) async {
        // Node 2 is so long that node 3's box starts far below the first frame's window.
        MutableDocument createDocument() {
          final document = _createDocument();
          document.replaceNodeById(
            "2",
            ParagraphNode(id: "2", text: AttributedText("A very long paragraph. " * 600)),
          );
          return document;
        }

        Iterable<String>? buildTogether(String nodeId) => switch (nodeId) {
              "2" => ["3"],
              "3" => ["2"],
              _ => null,
            };

        // Without the group, node 3 isn't built in the first frame.
        final ungrouped = await _pumpEditor(tester, document: createDocument());
        expect(ungrouped.progressiveLayout.isComponentDeferred("2"), isFalse);
        expect(ungrouped.progressiveLayout.isComponentDeferred("3"), isTrue);
        expect(ungrouped.childRectInDocument(3).top, greaterThan(2000));

        await tester.pumpWidget(const SizedBox());

        // With the group, it is.
        final grouped = await _pumpEditor(tester, document: createDocument(), buildTogether: buildTogether);
        expect(grouped.progressiveLayout.isComponentDeferred("2"), isFalse);
        expect(grouped.progressiveLayout.isComponentDeferred("3"), isFalse);
        expect(grouped.layout.getComponentByNodeId("3"), isNotNull);
        expect(grouped.componentRectInDocument("3").top, greaterThan(2000));
        // The nodes after it aren't.
        expect(grouped.progressiveLayout.isComponentDeferred("4"), isTrue);

        await grouped.pumpUntilComplete(tester);
      });

      testWidgets("with a node that becomes visible, in the same frame", (tester) async {
        Iterable<String>? buildTogether(String nodeId) => switch (nodeId) {
              "200" => ["260"],
              "260" => ["200"],
              _ => null,
            };
        final harness = await _pumpEditor(tester, document: _createDocument(), buildTogether: buildTogether);
        expect(harness.progressiveLayout.isComponentDeferred("200"), isTrue);
        expect(harness.progressiveLayout.isComponentDeferred("260"), isTrue);

        harness.scrollController.jumpTo(harness.childRectInDocument(200).top);
        await tester.pump();

        expect(harness.progressiveLayout.isComponentDeferred("200"), isFalse);
        expect(harness.progressiveLayout.isComponentDeferred("260"), isFalse);
        expect(harness.layout.getComponentByNodeId("260"), isNotNull);
        expect(harness.progressiveLayout.isComponentDeferred("240"), isTrue);
      });

      testWidgets("with a node that the controller asks for", (tester) async {
        Iterable<String>? buildTogether(String nodeId) => switch (nodeId) {
              "200" || "201" || "350" => ["200", "201", "350"],
              _ => null,
            };
        final harness = await _pumpEditor(tester, document: _createDocument(), buildTogether: buildTogether);
        for (final nodeId in ["200", "201", "350"]) {
          expect(harness.progressiveLayout.isComponentDeferred(nodeId), isTrue);
        }

        harness.controller.ensureBuilt(["201"]);
        await tester.pump();

        for (final nodeId in ["200", "201", "350"]) {
          expect(harness.progressiveLayout.isComponentDeferred(nodeId), isFalse, reason: nodeId);
          expect(harness.layout.getComponentByNodeId(nodeId), isNotNull, reason: nodeId);
        }
        expect(harness.progressiveLayout.isComponentDeferred("202"), isTrue);
      });

      testWidgets("in every frame, and lays out every node as the eager layout does, once complete", (tester) async {
        final eager = await _pumpEditor(tester, document: _createDocument(), progressive: false);
        final eagerRects = eager.componentRects();
        await tester.pumpWidget(const SizedBox());

        final harness = await _pumpEditor(tester, document: _createDocument(), buildTogether: _rowsOfThree);
        harness.expectEveryGroupIsBuiltTogether(_rowsOfThree);
        while (!harness.controller.isComplete.value) {
          await tester.pump();
          harness.expectEveryGroupIsBuiltTogether(_rowsOfThree);
        }

        final rects = harness.componentRects();
        for (final nodeId in eagerRects.keys) {
          expect(rects[nodeId], _rectMoreOrLessEquals(eagerRects[nodeId]!), reason: "Node $nodeId");
        }
      });

      testWidgets("above the viewport, without moving the visible content", (tester) async {
        final harness = await _pumpEditor(
          tester,
          document: _createDocument(),
          initialScrollOffset: 6000,
          buildTogether: _rowsOfThree,
        );
        harness.expectEveryVisibleNodeIsBuilt(tester);
        harness.expectEveryGroupIsBuiltTogether(_rowsOfThree);
        final visibleRects = harness.visibleComponentGlobalRects(tester);
        expect(visibleRects, isNotEmpty);

        while (!harness.controller.isComplete.value) {
          await tester.pump();
          for (final entry in visibleRects.entries) {
            expect(harness.componentGlobalRect(entry.key), _rectMoreOrLessEquals(entry.value), reason: entry.key);
          }
        }
        expect(harness.scrollController.offset, isNot(moreOrLessEquals(6000)));
      });

      testWidgets("when it jumps into content whose groups reach above the viewport", (tester) async {
        final harness = await _pumpEditor(tester, document: _createDocument(), buildTogether: _rowsOfThree);

        // Jump to the middle of a row, so that its first node is above the viewport.
        const targetIndex = 251;
        final jumpOffset = harness.childRectInDocument(targetIndex).top;
        expect(harness.progressiveLayout.isComponentDeferred("$targetIndex"), isTrue);

        harness.scrollController.jumpTo(jumpOffset);
        await tester.pump();

        // The row's first node, above the viewport, was built with it, and the node that the
        // jump aimed at is still at the top of the viewport.
        expect(harness.progressiveLayout.isComponentDeferred("250"), isFalse);
        expect(harness.childRectInDocument(targetIndex).top - harness.scrollController.offset, moreOrLessEquals(0));
        harness.expectEveryVisibleNodeIsBuilt(tester);
        harness.expectEveryGroupIsBuiltTogether(_rowsOfThree);

        final visibleRects = harness.visibleComponentGlobalRects(tester);
        while (!harness.controller.isComplete.value) {
          await tester.pump();
          for (final entry in visibleRects.entries) {
            expect(harness.componentGlobalRect(entry.key), _rectMoreOrLessEquals(entry.value), reason: entry.key);
          }
        }
      });

      testWidgets("and lands an animated scroll exactly where it was aimed", (tester) async {
        final harness = await _pumpEditor(tester, document: _createDocument(), buildTogether: _rowsOfThree);

        var isAnimationDone = false;
        harness.scrollController
            .animateTo(9000, duration: const Duration(milliseconds: 500), curve: Curves.easeInOut)
            .then((_) => isAnimationDone = true);
        while (!isAnimationDone) {
          await tester.pump(const Duration(milliseconds: 16));
          harness.expectEveryVisibleNodeIsBuilt(tester);
          harness.expectEveryGroupIsBuiltTogether(_rowsOfThree);
        }
        expect(harness.scrollController.offset, 9000);

        final visibleRects = harness.visibleComponentGlobalRects(tester);
        while (!harness.controller.isComplete.value) {
          await tester.pump();
          for (final entry in visibleRects.entries) {
            expect(harness.componentGlobalRect(entry.key), _rectMoreOrLessEquals(entry.value), reason: entry.key);
          }
        }
      });

      testWidgets("but not a group that reaches above the viewport while an animation scrolls", (tester) async {
        // Node 5, far above the viewport, is grouped with a node that's chosen below.
        String? partnerOfNode5;
        Iterable<String>? buildTogether(String nodeId) {
          if (partnerOfNode5 == null) {
            return null;
          }
          return nodeId == "5"
              ? [partnerOfNode5]
              : nodeId == partnerOfNode5
                  ? ["5"]
                  : null;
        }

        final harness = await _pumpEditor(
          tester,
          document: _createDocument(),
          initialScrollOffset: 6000,
          buildTogether: buildTogether,
        );
        expect(harness.progressiveLayout.isComponentDeferred("5"), isTrue);

        // Group node 5 with the first node that isn't built, at least 400 pixels below the
        // viewport, which is beyond the cache extent.
        final viewportExtent = tester.getRect(find.byType(Scrollable).first).height;
        final partnerIndex = [
          for (int i = 0; i < harness.document.nodeCount; i += 1)
            if (harness.childRectInDocument(i).top >= 6000 + viewportExtent + 400 &&
                harness.progressiveLayout.isComponentDeferred("$i"))
              i,
        ].first;
        partnerOfNode5 = "$partnerIndex";
        final partnerTop = harness.childRectInDocument(partnerIndex).top;

        // Animate so that the node enters the cache extent below the viewport, but not the
        // viewport.
        final animationTarget = partnerTop - viewportExtent - 100;
        var isAnimationDone = false;
        harness.scrollController
            .animateTo(animationTarget, duration: const Duration(seconds: 1), curve: Curves.linear)
            .then((_) => isAnimationDone = true);
        await tester.pump();

        // While the animation scrolls, the visible content moves exactly as far as the
        // scroll offset, so nothing above it was built.
        var framesWithPartnerInCacheExtent = 0;
        while (true) {
          final offsetBefore = harness.scrollController.offset;
          final rectsBefore = harness.visibleComponentGlobalRects(tester);
          await tester.pump(const Duration(milliseconds: 16));
          if (isAnimationDone) {
            break;
          }

          final scrollDelta = harness.scrollController.offset - offsetBefore;
          for (final entry in rectsBefore.entries) {
            expect(
              harness.componentGlobalRect(entry.key),
              _rectMoreOrLessEquals(entry.value.translate(0, -scrollDelta)),
              reason: entry.key,
            );
          }
          expect(harness.progressiveLayout.isComponentDeferred("5"), isTrue);
          expect(harness.progressiveLayout.isComponentDeferred(partnerOfNode5), isTrue);
          if (harness.scrollController.offset + viewportExtent + 250 > partnerTop) {
            framesWithPartnerInCacheExtent += 1;
          }
        }
        expect(framesWithPartnerInCacheExtent, greaterThan(0));

        // Once the animation ends, the layout builds the group, and keeps the visible
        // content still.
        await tester.pump();
        expect(harness.progressiveLayout.isComponentDeferred("5"), isFalse);
        expect(harness.progressiveLayout.isComponentDeferred(partnerOfNode5), isFalse);
        final visibleRects = harness.visibleComponentGlobalRects(tester);
        while (!harness.controller.isComplete.value) {
          await tester.pump();
          for (final entry in visibleRects.entries) {
            expect(harness.componentGlobalRect(entry.key), _rectMoreOrLessEquals(entry.value), reason: entry.key);
          }
        }
      });

      testWidgets("when a node is added next to a node that's built", (tester) async {
        // A node that's added later is grouped with a node far below it.
        Iterable<String>? buildTogether(String nodeId) => switch (nodeId) {
              "new" => ["300"],
              "300" => ["new"],
              _ => null,
            };
        final harness = await _pumpEditor(tester, document: _createDocument(), buildTogether: buildTogether);
        expect(harness.progressiveLayout.isComponentDeferred("300"), isTrue);

        // Add a node near the top, which is built, whose group is far below.
        harness.editor.execute([
          InsertNodeAtIndexRequest(
            nodeIndex: 2,
            newNode: ParagraphNode(id: "new", text: AttributedText("A new paragraph")),
          ),
        ]);
        await tester.pump();

        expect(harness.progressiveLayout.isComponentDeferred("new"), isFalse);
        expect(harness.progressiveLayout.isComponentDeferred("300"), isFalse);
        expect(harness.layout.getComponentByNodeId("300"), isNotNull);
      });
    });

    group("interaction while it builds >", () {
      testWidgetsOnMac("selects all, with the selection leaders, without errors", (tester) async {
        final harness = await _pumpEditor(tester, document: _createDocument(), autofocus: true);
        await tester.pump();

        // Press CMD+A, without settling, which would build everything.
        await tester.sendKeyDownEvent(LogicalKeyboardKey.meta, platform: "macos");
        await tester.sendKeyEvent(LogicalKeyboardKey.keyA, platform: "macos");
        await tester.sendKeyUpEvent(LogicalKeyboardKey.meta, platform: "macos");
        await tester.pump();
        expect(tester.takeException(), isNull);

        final selection = harness.editor.composer.selection!;
        expect(selection.base.nodeId, "0");
        expect(selection.extent.nodeId, "399");
        expect(harness.controller.isComplete.value, isFalse);

        // The leader that spans the selection spans the whole document.
        final expandedLeader = tester.getRect(
          find.byWidgetPredicate(
            (widget) => widget is Leader && widget.link == harness.selectionLinks.expandedSelectionBoundsLink,
          ),
        );
        expect(expandedLeader.height, greaterThan(5000));

        await harness.pumpUntilComplete(tester);
        expect(tester.takeException(), isNull);
      });

      testWidgetsOnIos("shows the expanded handles of a select all, without errors", (tester) async {
        final harness = await _pumpEditor(tester, document: _createDocument());

        final lastNode = harness.document.last as ParagraphNode;
        harness.editor.execute([
          ChangeSelectionRequest(
            DocumentSelection(
              base: const DocumentPosition(nodeId: "0", nodePosition: TextNodePosition(offset: 0)),
              extent: DocumentPosition(nodeId: lastNode.id, nodePosition: lastNode.endPosition),
            ),
            SelectionChangeType.expandSelection,
            SelectionReason.userInteraction,
          ),
        ]);
        await tester.pump();
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(find.byType(IOSSelectionHandle), findsNWidgets(2));

        await harness.pumpUntilComplete(tester);
        expect(tester.takeException(), isNull);
      });

      testWidgetsOnArbitraryDesktop("builds the ends of a selection that the app places in nodes that aren't built", (
        tester,
      ) async {
        final harness = await _pumpEditor(tester, document: _createDocument());
        expect(harness.progressiveLayout.isComponentDeferred("300"), isTrue);
        expect(harness.progressiveLayout.isComponentDeferred("310"), isTrue);

        harness.editor.execute([
          const ChangeSelectionRequest(
            DocumentSelection(
              base: DocumentPosition(nodeId: "300", nodePosition: TextNodePosition(offset: 0)),
              extent: DocumentPosition(nodeId: "310", nodePosition: TextNodePosition(offset: 3)),
            ),
            SelectionChangeType.expandSelection,
            SelectionReason.userInteraction,
          ),
        ]);
        await tester.pump();
        expect(tester.takeException(), isNull);

        // The leaders asked for both ends, which the next frame builds.
        await tester.pump();
        expect(harness.progressiveLayout.isComponentDeferred("300"), isFalse);
        expect(harness.progressiveLayout.isComponentDeferred("310"), isFalse);

        // The leaders are positioned at the selection once both ends are built.
        await tester.pump();
        final upstreamLeader = tester.getRect(
          find.byWidgetPredicate((widget) => widget is Leader && widget.link == harness.selectionLinks.upstreamLink),
        );
        expect(
          upstreamLeader.top,
          moreOrLessEquals(
            harness.layout.getGlobalOffsetFromDocumentOffset(harness.componentRectInDocument("300").topLeft).dy,
            epsilon: 30,
          ),
        );
      });

      testWidgets("inserts and deletes nodes, and lays them out as the eager layout does", (tester) async {
        final harness = await _pumpEditor(tester, document: _createDocument());

        harness.editor.execute([
          // Near the top, where the nodes are built.
          InsertNodeAtIndexRequest(
            nodeIndex: 1,
            newNode: ParagraphNode(id: "new-top", text: AttributedText("A new paragraph near the top")),
          ),
          // Among nodes that aren't built.
          InsertNodeAtIndexRequest(
            nodeIndex: 200,
            newNode: ParagraphNode(id: "new-middle", text: AttributedText("A new paragraph in the middle")),
          ),
          // At the end.
          InsertNodeAtIndexRequest(
            nodeIndex: 402,
            newNode: ParagraphNode(id: "new-end", text: AttributedText("A new paragraph at the end")),
          ),
          DeleteNodeRequest(nodeId: "2"),
          DeleteNodeRequest(nodeId: "300"),
          InsertTextRequest(
            documentPosition: const DocumentPosition(nodeId: "3", nodePosition: TextNodePosition(offset: 0)),
            textToInsert: "Inserted text. ",
            attributions: {},
          ),
        ]);
        await tester.pump();
        expect(tester.takeException(), isNull);

        final layout = harness.progressiveLayout;
        expect(layout.isComponentDeferred("new-top"), isFalse);
        expect(layout.isComponentDeferred("new-middle"), isTrue);
        expect(layout.isComponentDeferred("new-end"), isFalse);
        expect(harness.layout.getComponentByNodeId("new-top"), isNotNull);
        expect(harness.layout.getComponentByNodeId("new-end"), isNotNull);
        expect(find.textContaining("Inserted text. ", findRichText: true), findsOneWidget);

        await harness.pumpUntilComplete(tester);
        final progressiveRects = harness.componentRects();
        final finalDocument = MutableDocument(
          nodes: [
            for (final node in harness.document.cast<ParagraphNode>())
              ParagraphNode(id: node.id, text: node.text.copy(), metadata: node.metadata),
          ],
        );

        await tester.pumpWidget(const SizedBox());
        final eager = await _pumpEditor(tester, document: finalDocument, progressive: false);
        final eagerRects = eager.componentRects();

        expect(progressiveRects.keys, eagerRects.keys);
        for (final nodeId in eagerRects.keys) {
          expect(progressiveRects[nodeId], _rectMoreOrLessEquals(eagerRects[nodeId]!), reason: "Node $nodeId");
        }
      });

      testWidgetsOnIos("SuperReader selects a word with a long press, and copies it", (tester) async {
        tester.simulateClipboard();
        final controller = SingleColumnProgressiveLayoutController();
        addTearDown(controller.dispose);
        final document = _createDocument();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SuperReader(
                editor: createDefaultDocumentEditor(document: document, composer: MutableDocumentComposer()),
                progressiveLayout: SingleColumnProgressiveLayout(controller: controller),
              ),
            ),
          ),
        );
        expect(controller.isComplete.value, isFalse);

        // Long press "Lorem" in the second paragraph.
        await tester.longPressInParagraph("1", 15);
        await tester.pump();
        expect(tester.takeException(), isNull);

        final selection = SuperReaderInspector.findDocumentSelection();
        expect(selection, isNotNull);
        expect(selection!.base.nodeId, "1");
        expect(selection.extent.nodeId, "1");

        await tester.tap(find.text("Copy"));
        await tester.pump();
        expect(tester.getSimulatedClipboardContent(), "Lorem");

        await _pumpUntil(tester, () => controller.isComplete.value);
        expect(tester.takeException(), isNull);
      });
    });

    group("semantics >", () {
      testWidgets("updates the semantics of only the nodes around the viewport, however long the document is", (
        tester,
      ) async {
        final semanticsVisits = <String>[];
        final harness = await _pumpEditor(
          tester,
          document: _createDocument(paragraphCount: 1000),
          initialScrollOffset: 20000,
          componentBuilders: [_SemanticsProbeComponentBuilder(semanticsVisits), ...defaultComponentBuilders],
        );

        // Every frame that builds a batch visits the semantics of the nodes around the
        // viewport, not of every node that's built.
        final visitsPerFrame = <int>[];
        while (!harness.controller.isComplete.value) {
          expect(visitsPerFrame.length, lessThan(2000));
          semanticsVisits.clear();
          await tester.pump(const Duration(milliseconds: 16));
          visitsPerFrame.add(semanticsVisits.toSet().length);
        }
        expect(visitsPerFrame.reduce(max), lessThan(60), reason: "$visitsPerFrame");

        // So does a frame that scrolls far away, once every node is built.
        for (final scrollOffset in [60000.0, 100.0]) {
          semanticsVisits.clear();
          harness.scrollController.jumpTo(scrollOffset);
          await tester.pump();
          expect(semanticsVisits.toSet().length, inInclusiveRange(1, 59));
        }
      });

      testWidgets("builds every node in about as many frames as without semantics", semanticsEnabled: false, (
        tester,
      ) async {
        // A budget that a frame which updates the semantics of every node that's built would
        // soon exceed, in a document this long, so that it would build a node per frame.
        Future<int> framesToComplete() async {
          final harness = await _pumpEditor(
            tester,
            document: _createDocument(paragraphCount: 6000),
            frameBudget: const Duration(milliseconds: 30),
          );
          final frames = await harness.pumpUntilComplete(tester);
          await tester.pumpWidget(const SizedBox());
          return frames;
        }

        final framesWithoutSemantics = await framesToComplete();
        final semantics = tester.ensureSemantics();
        final framesWithSemantics = await framesToComplete();
        semantics.dispose();

        expect(
          framesWithSemantics,
          lessThan(framesWithoutSemantics * 1.25 + 5),
          reason: "$framesWithSemantics frames with semantics, $framesWithoutSemantics without",
        );
      });
    });

    group("builds everything at once >", () {
      testWidgets("when the editor shrink-wraps its content", (tester) async {
        final harness = await _pumpEditor(tester, document: _createDocument(), shrinkWrap: true);

        expect(harness.builtNodeIds().length, 400);
        await tester.pump();
        expect(harness.controller.isComplete.value, isTrue);
      });

      testWidgets("in a dry layout", (tester) async {
        final harness = await _pumpEditor(tester, document: _createDocument(), dryLayout: true);

        expect(harness.builtNodeIds().length, 400);
        await tester.pump();
        expect(harness.controller.isComplete.value, isTrue);
      });

      testWidgets("when progressive layout is forced on by default, but the editor shrink-wraps", (tester) async {
        SingleColumnProgressiveLayout.debugProgressiveByDefault = true;

        final harness = await _pumpEditor(tester, document: _createDocument(), shrinkWrap: true, progressive: false);
        expect(harness.builtNodeIds().length, 400);
      });
    });

    testWidgets("lays out progressively by default when forced, with a first frame of only what's visible", (
      tester,
    ) async {
      SingleColumnProgressiveLayout.debugProgressiveByDefault = true;

      final harness = await _pumpEditor(tester, document: _createDocument(), progressive: false);
      final built = harness.builtNodeIds();
      expect(built.length, lessThan(40));
      harness.expectEveryVisibleNodeIsBuilt(tester);

      await _pumpUntil(tester, () => harness.builtNodeIds().length == 400, maxFrames: 1000);
    });
  });
}

/// A document of paragraphs of different lengths, so that their estimated heights are
/// wrong by different amounts.
/// Groups the nodes of a document from [_createDocument] in threes, as if each three nodes
/// were the columns of a row.
Iterable<String> _rowsOfThree(String nodeId) {
  final index = int.parse(nodeId);
  final rowStart = index - index % 3;
  return [
    for (int i = rowStart; i < rowStart + 3; i += 1) "$i",
  ];
}

MutableDocument _createDocument({int paragraphCount = 400}) {
  return MutableDocument(
    nodes: [
      for (int i = 0; i < paragraphCount; i += 1)
        ParagraphNode(
          id: "$i",
          text: AttributedText("Paragraph $i. ${"Lorem ipsum dolor sit amet. " * (1 + i * 7 % 11)}".trim()),
        ),
    ],
  );
}

Future<_Harness> _pumpEditor(
  WidgetTester tester, {
  required MutableDocument document,
  bool progressive = true,
  double initialScrollOffset = 0,
  bool shrinkWrap = false,
  bool dryLayout = false,
  bool autofocus = false,
  // Longer than any test takes, so that the timeout doesn't hide a fill that stalls.
  Duration safetyTimeout = const Duration(minutes: 5),
  Duration frameBudget = const Duration(milliseconds: 6),
  Iterable<String>? Function(String nodeId)? buildTogether,
  double? Function(SingleColumnLayoutComponentViewModel viewModel, double width)? estimateHeight,
  List<ComponentBuilder>? componentBuilders,
  // A widget above the editor.
  Widget? above,
}) async {
  final controller = SingleColumnProgressiveLayoutController();
  addTearDown(controller.dispose);
  final scrollController = ScrollController(initialScrollOffset: initialScrollOffset);
  addTearDown(scrollController.dispose);
  final layoutKey = GlobalKey();
  final selectionLinks = SelectionLayerLinks();
  final editor = createDefaultDocumentEditor(document: document, composer: MutableDocumentComposer());

  final progressiveLayout = SingleColumnProgressiveLayout(
    controller: controller,
    safetyTimeout: safetyTimeout,
    frameBudget: frameBudget,
    buildTogether: buildTogether,
    estimateHeight: estimateHeight,
  );
  Widget superEditor = SuperEditor(
    editor: editor,
    documentLayoutKey: layoutKey,
    scrollController: dryLayout ? null : scrollController,
    selectionLayerLinks: selectionLinks,
    autofocus: autofocus,
    shrinkWrap: shrinkWrap,
    componentBuilders: componentBuilders,
    progressiveLayout: progressive ? progressiveLayout : null,
  );
  if (dryLayout) {
    superEditor = SuperEditorDryLayout(controller: scrollController, superEditor: superEditor);
  }

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: above != null ? Column(children: [above, Expanded(child: superEditor)]) : superEditor,
      ),
    ),
  );

  return _Harness(
    document: document,
    editor: editor,
    layoutKey: layoutKey,
    controller: controller,
    scrollController: scrollController,
    selectionLinks: selectionLinks,
  );
}

class _Harness {
  _Harness({
    required this.document,
    required this.editor,
    required this.layoutKey,
    required this.controller,
    required this.scrollController,
    required this.selectionLinks,
  });

  final MutableDocument document;
  final Editor editor;
  final GlobalKey layoutKey;
  final SingleColumnProgressiveLayoutController controller;
  final ScrollController scrollController;
  final SelectionLayerLinks selectionLinks;

  DocumentLayout get layout => layoutKey.currentState as DocumentLayout;
  ProgressiveDocumentLayout get progressiveLayout => layoutKey.currentState as ProgressiveDocumentLayout;

  RenderDocumentComponentColumn get column {
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

    visit(layoutKey.currentContext!.findRenderObject()!);
    return column!;
  }

  Set<String> builtNodeIds() => {
        for (final node in document)
          if (!progressiveLayout.isComponentDeferred(node.id)) node.id,
      };

  Future<int> pumpUntilComplete(WidgetTester tester) async {
    final frames = await _pumpUntil(tester, () => controller.isComplete.value);
    expect(tester.takeException(), isNull);
    return frames;
  }

  /// Pumps frames until every node is built, and returns the number of nodes that each
  /// frame built.
  Future<List<int>> pumpUntilCompleteCountingBuilds(WidgetTester tester) async {
    final builtPerFrame = <int>[];
    while (!controller.isComplete.value) {
      if (builtPerFrame.length >= 2000) {
        fail("The layout didn't build every node after 2000 frames");
      }
      final builtBefore = builtNodeIds().length;
      await tester.pump(const Duration(milliseconds: 16));
      final built = builtNodeIds().length - builtBefore;
      if (built > 0 || !controller.isComplete.value) {
        builtPerFrame.add(built);
      }
    }
    expect(tester.takeException(), isNull);
    return builtPerFrame;
  }

  /// Expects that the column of components stacks its children from top to bottom,
  /// centered, without gaps, as a `Column` does, and that it's as tall as its children.
  void expectColumnIsStacked() {
    final column = this.column;
    var top = 0.0;
    for (int index = 0; index < column.childCount; index += 1) {
      final rect = column.childRectAt(index);
      expect(rect.top, moreOrLessEquals(top, epsilon: 0.001), reason: "Child $index");
      expect(rect.center.dx, moreOrLessEquals(column.size.width / 2, epsilon: 0.001), reason: "Child $index");
      top = rect.bottom;
    }
    expect(column.size.height, moreOrLessEquals(top, epsilon: 0.001));
  }

  /// The rect of the child at [index] in the column of components, which is a component
  /// or a placeholder, in document coordinates.
  Rect childRectInDocument(int index) {
    final child = column.childAt(index);
    return layout.getDocumentOffsetFromAncestorOffset(child.localToGlobal(Offset.zero)) & child.size;
  }

  /// The index of the child in the column of components, which is a component or a
  /// placeholder, at the vertical document offset [dy].
  int childIndexAtDocumentOffset(double dy) {
    for (int index = 0; index < column.childCount; index += 1) {
      if (childRectInDocument(index).bottom > dy) {
        return index;
      }
    }
    return column.childCount - 1;
  }

  /// The rect of the component of the node with [nodeId], in document coordinates.
  Rect componentRectInDocument(String nodeId) {
    final componentBox = layout.getComponentByNodeId(nodeId)!.context.findRenderObject() as RenderBox;
    return layout.getDocumentOffsetFromAncestorOffset(componentBox.localToGlobal(Offset.zero)) & componentBox.size;
  }

  Rect componentGlobalRect(String nodeId) {
    final componentBox = layout.getComponentByNodeId(nodeId)!.context.findRenderObject() as RenderBox;
    return componentBox.localToGlobal(Offset.zero) & componentBox.size;
  }

  Map<String, Rect> componentRects() => {for (final node in document) node.id: componentRectInDocument(node.id)};

  Rect _viewportRect(WidgetTester tester) => tester.getRect(find.byType(Scrollable).first);

  /// The global rects of the components of the visible nodes, every one of which must be
  /// built.
  Map<String, Rect> visibleComponentGlobalRects(WidgetTester tester) {
    final viewport = _viewportRect(tester);
    return {
      for (final node in document)
        if (layout.getComponentByNodeId(node.id) != null && componentGlobalRect(node.id).overlaps(viewport))
          node.id: componentGlobalRect(node.id),
    };
  }

  /// Expects that the nodes of every group are either all built, or all not built.
  void expectEveryGroupIsBuiltTogether(Iterable<String>? Function(String nodeId) buildTogether) {
    for (final node in document) {
      final isDeferred = progressiveLayout.isComponentDeferred(node.id);
      for (final member in buildTogether(node.id) ?? const <String>[]) {
        expect(
          progressiveLayout.isComponentDeferred(member),
          isDeferred,
          reason: "Node ${node.id} is ${isDeferred ? "not built" : "built"}, but $member, in its group, isn't",
        );
      }
    }
  }

  void expectEveryVisibleNodeIsBuilt(WidgetTester tester) {
    final viewport = _viewportRect(tester);
    final column = this.column;
    var visibleCount = 0;
    for (int index = 0; index < column.childCount; index += 1) {
      final child = column.childAt(index);
      final childRect = child.localToGlobal(Offset.zero) & child.size;
      if (!childRect.overlaps(viewport)) {
        continue;
      }
      visibleCount += 1;
      final nodeId = document.getNodeAt(index)!.id;
      expect(progressiveLayout.isComponentDeferred(nodeId), isFalse, reason: "Visible node $nodeId isn't built");
    }
    expect(visibleCount, greaterThan(0));
  }
}

/// Pumps frames, 16 milliseconds apart, until [condition] is met.
Future<int> _pumpUntil(WidgetTester tester, bool Function() condition, {int maxFrames = 2000}) async {
  var frames = 0;
  while (!condition()) {
    if (frames >= maxFrames) {
      fail("The condition wasn't met after $maxFrames frames");
    }
    await tester.pump(const Duration(milliseconds: 16));
    frames += 1;
  }
  return frames;
}

Matcher _rectMoreOrLessEquals(Rect expected) => _RectMoreOrLessEquals(expected);

class _RectMoreOrLessEquals extends Matcher {
  const _RectMoreOrLessEquals(this.expected);

  final Rect expected;

  @override
  bool matches(Object? item, Map<dynamic, dynamic> matchState) {
    if (item is! Rect) {
      return false;
    }
    const epsilon = 0.01;
    return (item.left - expected.left).abs() < epsilon &&
        (item.top - expected.top).abs() < epsilon &&
        (item.right - expected.right).abs() < epsilon &&
        (item.bottom - expected.bottom).abs() < epsilon;
  }

  @override
  Description describe(Description description) => description.add("a rect close to $expected");
}

/// Paints nothing, slowly, in every frame.
class _SlowPainter extends LeafRenderObjectWidget {
  const _SlowPainter({required this.paintTime});

  final Duration paintTime;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderSlowPainter(paintTime);
}

class _RenderSlowPainter extends RenderBox {
  _RenderSlowPainter(this.paintTime);

  final Duration paintTime;

  @override
  bool get isRepaintBoundary => true;

  @override
  void performLayout() {
    size = constraints.constrain(const Size(double.infinity, 10));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final stopwatch = Stopwatch()..start();
    while (stopwatch.elapsed < paintTime) {
      // Wait.
    }

    // Paint again in the next frame.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (attached) {
        markNeedsPaint();
      }
    });
  }
}

/// Builds horizontal rules that can't be selected visually.
class _UnselectableHorizontalRuleComponentBuilder implements ComponentBuilder {
  const _UnselectableHorizontalRuleComponentBuilder();

  @override
  SingleColumnLayoutComponentViewModel? createViewModel(Document document, DocumentNode node) {
    return const HorizontalRuleComponentBuilder().createViewModel(document, node);
  }

  @override
  Widget? createComponent(
    SingleColumnDocumentComponentContext componentContext,
    SingleColumnLayoutComponentViewModel componentViewModel,
  ) {
    if (componentViewModel is! HorizontalRuleComponentViewModel) {
      return null;
    }

    return BoxComponent(
      key: componentContext.componentKey,
      isVisuallySelectable: false,
      child: const SizedBox(height: 40),
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
    SingleColumnDocumentComponentContext componentContext,
    SingleColumnLayoutComponentViewModel componentViewModel,
  ) {
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

/// Builds horizontal rules that draw nothing, and can't be selected, like the lines that an
/// app hides, e.g., in a collapsed toggle.
class _HiddenHorizontalRuleComponentBuilder implements ComponentBuilder {
  const _HiddenHorizontalRuleComponentBuilder();

  @override
  SingleColumnLayoutComponentViewModel? createViewModel(Document document, DocumentNode node) {
    return const HorizontalRuleComponentBuilder().createViewModel(document, node);
  }

  @override
  Widget? createComponent(
    SingleColumnDocumentComponentContext componentContext,
    SingleColumnLayoutComponentViewModel componentViewModel,
  ) {
    if (componentViewModel is! HorizontalRuleComponentViewModel) {
      return null;
    }

    return BoxComponent(
      key: componentContext.componentKey,
      isVisuallySelectable: false,
      child: const SizedBox(),
    );
  }
}
