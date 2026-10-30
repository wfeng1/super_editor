import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_test_robots/flutter_test_robots.dart';
import 'package:flutter_test_runners/flutter_test_runners.dart';
import 'package:super_editor/super_editor.dart';
import 'package:super_editor/super_editor_test.dart';
import 'package:super_text_layout/super_text_layout.dart';

void main() {
  group('SuperEditor', () {
    testWidgets("re-runs its presenter when the stylesheet changes", (tester) async {
      // Configure and render a document.
      final testDocumentContext = await tester //
          .createDocument()
          .withSingleParagraph()
          .useStylesheet(_stylesheetWithBlackText)
          .pump();

      // Ensure that the initial text is black
      expect(SuperEditorInspector.findParagraphStyle("1")!.color, Colors.black);

      // Configure and render a document with a different stylesheet.
      await tester //
          .updateDocument(testDocumentContext.configuration)
          .useStylesheet(_stylesheetWithWhiteText)
          .pump();

      // Expect the paragraph to now be white.
      expect(SuperEditorInspector.findParagraphStyle("1")!.color, Colors.white);
    });

    testWidgetsOnArbitraryDesktop('changes visual text style when attributions change', (tester) async {
      final testContext = await tester
          .createDocument() //
          .withSingleParagraph()
          .pump();

      // Double tap to select the first word.
      await tester.doubleTapInParagraph('1', 0);

      // Apply italic to the word.
      testContext.findEditContext().commonOps.toggleAttributionsOnSelection({italicsAttribution});
      await tester.pump();

      // Ensure italic was applied.
      expect(
        _findSpanAtOffset(tester, offset: 0).style!.fontStyle,
        FontStyle.italic,
      );
    });

    testWidgetsOnArbitraryDesktop('changes visual text style when style rule changes', (tester) async {
      final testContext = await tester //
          .createDocument()
          .withTwoEmptyParagraphs()
          .useStylesheet(_stylesheetWithNodePositionRule)
          .pump();

      final doc = testContext.findEditContext().document;

      final firstParagraphId = doc.getNodeAt(0)!.id;
      final secondParagraphId = doc.getNodeAt(1)!.id;

      // Ensure the rule for paragraph is applied.
      expect(SuperEditorInspector.findParagraphStyle(firstParagraphId)!.color, Colors.red);

      // Remove the second paragraph.
      testContext.findEditContext().editor.execute([
        DeleteNodeRequest(nodeId: secondParagraphId),
      ]);
      await tester.pump();

      // The first paragraph is now the only paragraph in the document.
      // Therefore, the rule for "last paragraph" should be applied.
      expect(SuperEditorInspector.findParagraphStyle(firstParagraphId)!.color, Colors.blue);
    });

    testWidgetsOnArbitraryDesktop('retains visual text style when combining a list item with a paragraph',
        (tester) async {
      await tester //
          .createDocument()
          .fromMarkdown("""
* 1
* 2

A paragraph
          """)
          .useStylesheet(Stylesheet(
            inlineTextStyler: inlineTextStyler,
            rules: [
              StyleRule(
                const BlockSelector("listItem"),
                (doc, docNode) {
                  return {
                    Styles.textStyle: const TextStyle(
                      color: Colors.blue,
                      fontSize: 16,
                    ),
                  };
                },
              ),
              StyleRule(
                const BlockSelector("paragraph"),
                (doc, docNode) {
                  return {
                    Styles.textStyle: const TextStyle(
                      color: Colors.red,
                      fontSize: 16,
                    ),
                  };
                },
              ),
            ],
          ))
          .pump();

      // Ensure the correct style was applied to the list item.
      expect(
        SuperEditorInspector.findParagraphStyle(SuperEditorInspector.getNodeAt(1).id)!.color,
        Colors.blue,
      );

      // Ensure the correct style was applied to the paragraph.
      expect(
        SuperEditorInspector.findParagraphStyle(SuperEditorInspector.getNodeAt(2).id)!.color,
        Colors.red,
      );

      // Place the caret at the end of the second list item.
      final secondListItem = SuperEditorInspector.getNodeAt<ListItemNode>(1);
      await tester.placeCaretInParagraph(secondListItem.id, 1);

      // Press backspace to delete the list item text. The content will be empty.
      await tester.pressBackspace();

      // Place the caret at the beginning of the paragraph.
      final paragraph = SuperEditorInspector.getNodeAt<ParagraphNode>(2);
      await tester.placeCaretInParagraph(paragraph.id, 0);

      // Press backspace to combine the list item and the paragraph.
      await tester.pressBackspace();

      // Ensure the list item retained the correct style.
      expect(
        SuperEditorInspector.findParagraphStyle(SuperEditorInspector.getNodeAt(1).id)!.color,
        Colors.blue,
      );
    });

    group("when only the stylesheet changes >", () {
      testWidgets("updates the document padding without building every text component again", (tester) async {
        final builds = <String, int>{};
        final stylesheet = ValueNotifier(defaultStylesheet.copyWith(documentPadding: const EdgeInsets.all(16)));
        addTearDown(stylesheet.dispose);
        await _pumpEditorWithStylesheet(tester, stylesheet: stylesheet, builds: builds);
        final builtBefore = {...builds};
        expect(builtBefore, isNotEmpty);
        final topBefore = SuperEditorInspector.findComponentOffset("0", Alignment.topLeft).dy;

        stylesheet.value = stylesheet.value.copyWith(documentPadding: const EdgeInsets.all(40));
        await tester.pump();

        // The padding moved the components down...
        expect(SuperEditorInspector.findComponentOffset("0", Alignment.topLeft).dy, moreOrLessEquals(topBefore + 24));
        // ...without building any of them again.
        for (final entry in builtBefore.entries) {
          expect(builds[entry.key], entry.value, reason: "Node ${entry.key} was built again");
        }
      });

      testWidgets("builds the components whose text style changed again, and only those", (tester) async {
        final builds = <String, int>{};
        final stylesheet = ValueNotifier(defaultStylesheet.copyWith(addRulesAfter: [_header1Color(Colors.red)]));
        addTearDown(stylesheet.dispose);
        await _pumpEditorWithStylesheet(tester, stylesheet: stylesheet, builds: builds);
        final builtBefore = {...builds};
        expect(SuperEditorInspector.findParagraphStyle("0")!.color, Colors.red);

        stylesheet.value = defaultStylesheet.copyWith(addRulesAfter: [_header1Color(Colors.green)]);
        await tester.pump();

        // The header has the new style...
        expect(SuperEditorInspector.findParagraphStyle("0")!.color, Colors.green);
        expect(builds["0"], builtBefore["0"]! + 1);
        // ...and the paragraphs, whose styles didn't change, weren't built again.
        for (final entry in builtBefore.entries.where((entry) => entry.key != "0")) {
          expect(builds[entry.key], entry.value, reason: "Node ${entry.key} was built again");
        }
      });
    });

    testWidgetsOnArbitraryDesktop('rebuilds only changed nodes', (tester) async {
      int componentChangedCount = 0;

      await tester
          .createDocument() //
          .withLongTextContent()
          .pump();

      await tester.placeCaretInParagraph(SuperEditorInspector.findDocument()!.last.id, 0);

      final presenter = tester.state<SuperEditorState>(find.byType(SuperEditor)).presenter;
      presenter.addChangeListener(SingleColumnLayoutPresenterChangeListener(
        onViewModelChange: ({
          required addedComponents,
          required movedComponents,
          required changedComponents,
          required removedComponents,
        }) {
          if (componentChangedCount != 0) {
            // The listener is called two times. The first one for the text change, which is the one
            // we care about, and the second one for the selection change.
            // Return early to avoid overriding the value.
            return;
          }
          componentChangedCount = changedComponents.length;
        },
      ));

      // Type text, changing only one node.
      await tester.typeKeyboardText('a');

      // Ensure only the changed component was marked as dirty.
      expect(componentChangedCount, 1);
    });

    testWidgetsOnArbitraryDesktop('rebuilds moved nodes', (tester) async {
      int componentAddedCount = 0;
      int componentMoveCount = 0;
      int componentChangedCount = 0;
      int componentRemovedCount = 0;

      final testContext = await tester
          .createDocument() //
          .withLongTextContent()
          .pump();

      final presenter = tester.state<SuperEditorState>(find.byType(SuperEditor)).presenter;
      presenter.addChangeListener(SingleColumnLayoutPresenterChangeListener(
        onViewModelChange: ({
          required addedComponents,
          required movedComponents,
          required changedComponents,
          required removedComponents,
        }) {
          if (componentChangedCount != 0) {
            throw Exception("Expected only one view model change, but there was more than one.");
          }

          componentAddedCount = addedComponents.length;
          componentMoveCount = movedComponents.length;
          componentChangedCount = changedComponents.length;
          componentRemovedCount = removedComponents.length;
        },
      ));

      // Move the 2nd node to the end of the document. This should impact nodes 2, 3, and 4,
      // but not node 1.
      testContext.findEditContext().editor.execute([
        const MoveNodeRequest(nodeId: "2", newIndex: 3),
      ]);
      await tester.pumpAndSettle();

      // Ensure that the relevant nodes were moved, but nothing was added or removed.
      expect(componentAddedCount, 0);
      expect(componentRemovedCount, 0);
      expect(componentChangedCount, 0);
      expect(componentMoveCount, 3);

      // Ensure the visual layout was updated, by inspecting the y-offset of the
      // visual components.
      expect(
        SuperEditorInspector.findComponentOffset("1", Alignment.bottomLeft).dy,
        lessThanOrEqualTo(SuperEditorInspector.findComponentOffset("3", Alignment.topLeft).dy),
      );
      expect(
        SuperEditorInspector.findComponentOffset("3", Alignment.bottomLeft).dy,
        lessThanOrEqualTo(SuperEditorInspector.findComponentOffset("4", Alignment.topLeft).dy),
      );
      expect(
        SuperEditorInspector.findComponentOffset("4", Alignment.bottomLeft).dy,
        lessThanOrEqualTo(SuperEditorInspector.findComponentOffset("2", Alignment.topLeft).dy),
      );
    });
  });
}

/// Pumps a [SuperEditor] with the [stylesheet], which builds every component with a
/// builder that counts, in [builds], how many times it built the component of each node.
Future<void> _pumpEditorWithStylesheet(
  WidgetTester tester, {
  required ValueNotifier<Stylesheet> stylesheet,
  required Map<String, int> builds,
}) async {
  final editor = createDefaultDocumentEditor(
    document: MutableDocument(
      nodes: [
        ParagraphNode(
          id: "0",
          text: AttributedText("A header"),
          metadata: const {"blockType": header1Attribution},
        ),
        for (int i = 1; i < 10; i += 1)
          ParagraphNode(id: "$i", text: AttributedText("Paragraph $i. Lorem ipsum dolor sit amet.")),
      ],
    ),
    composer: MutableDocumentComposer(),
  );
  // The same builders in every build, so that only the stylesheet changes.
  final componentBuilders = [_BuildCountingComponentBuilder(builds), ...defaultComponentBuilders];

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ValueListenableBuilder<Stylesheet>(
          valueListenable: stylesheet,
          builder: (context, stylesheet, child) => SuperEditor(
            editor: editor,
            stylesheet: stylesheet,
            componentBuilders: componentBuilders,
          ),
        ),
      ),
    ),
  );
}

/// A rule that colors the text of level one headers.
StyleRule _header1Color(Color color) => StyleRule(
      const BlockSelector("header1"),
      (document, node) => {Styles.textStyle: TextStyle(color: color)},
    );

/// Builds the default components, and counts how many times it built the component of
/// each node.
class _BuildCountingComponentBuilder implements ComponentBuilder {
  const _BuildCountingComponentBuilder(this.builds);

  final Map<String, int> builds;

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
        builds[componentViewModel.nodeId] = (builds[componentViewModel.nodeId] ?? 0) + 1;
        return component;
      }
    }
    return null;
  }
}

InlineSpan _findSpanAtOffset(
  WidgetTester tester, {
  required int offset,
}) {
  final superText = tester.widget<SuperText>(find.byType(SuperText));
  return superText.richText.getSpanForPosition(TextPosition(offset: offset))!;
}

final _stylesheetWithNodePositionRule = Stylesheet(
  inlineTextStyler: inlineTextStyler,
  rules: [
    StyleRule(
      const BlockSelector("paragraph"),
      (doc, docNode) {
        return {
          Styles.textStyle: const TextStyle(
            color: Colors.red,
          ),
        };
      },
    ),
    StyleRule(
      const BlockSelector("paragraph").last(),
      (doc, docNode) {
        return {
          Styles.textStyle: const TextStyle(
            color: Colors.blue,
          )
        };
      },
    ),
  ],
);

final _stylesheetWithBlackText = Stylesheet(
  inlineTextStyler: inlineTextStyler,
  rules: [
    StyleRule(BlockSelector.all, (document, node) {
      return {
        Styles.textStyle: const TextStyle(
          color: Colors.black,
        ),
      };
    }),
  ],
);

final _stylesheetWithWhiteText = Stylesheet(
  inlineTextStyler: inlineTextStyler,
  rules: [
    StyleRule(BlockSelector.all, (document, node) {
      return {
        Styles.textStyle: const TextStyle(
          color: Colors.white,
        ),
      };
    }),
  ],
);

TextStyle inlineTextStyler(Set<Attribution> attributions, TextStyle base) {
  return base;
}
