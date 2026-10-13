import 'package:flutter/material.dart';
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

class _EmptyLayerBuilder implements SuperEditorLayerBuilder {
  const _EmptyLayerBuilder();

  @override
  ContentLayerWidget build(BuildContext context, SuperEditorContext editorContext) {
    return const ContentLayerProxyWidget(child: SizedBox());
  }
}
