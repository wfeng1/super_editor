import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_test_runners/flutter_test_runners.dart';
import 'package:super_editor/super_editor.dart';
import 'package:super_editor/super_reader_test.dart';
import 'package:super_text_layout/super_text_layout.dart';

import 'package:super_editor/src/test/flutter_extensions/test_documents.dart';

void main() {
  group("SuperReader stylesheets", () {
    group("when only the stylesheet changes >", () {
      testWidgets("updates the document padding without building every text component again", (tester) async {
        final builds = <String, int>{};
        final stylesheet = ValueNotifier(readOnlyDefaultStylesheet.copyWith(documentPadding: const EdgeInsets.all(16)));
        addTearDown(stylesheet.dispose);
        await _pumpReaderWithStylesheet(tester, stylesheet: stylesheet, builds: builds);
        final builtBefore = {...builds};
        expect(builtBefore, isNotEmpty);
        final topBefore = SuperReaderInspector.findComponentOffset("0", Alignment.topLeft).dy;

        stylesheet.value = stylesheet.value.copyWith(documentPadding: const EdgeInsets.all(40));
        await tester.pump();

        // The padding moved the components down...
        expect(SuperReaderInspector.findComponentOffset("0", Alignment.topLeft).dy, moreOrLessEquals(topBefore + 24));
        // ...without building any of them again.
        for (final entry in builtBefore.entries) {
          expect(builds[entry.key], entry.value, reason: "Node ${entry.key} was built again");
        }
      });

      testWidgets("builds the components whose text style changed again, and only those", (tester) async {
        final builds = <String, int>{};
        final stylesheet =
            ValueNotifier(readOnlyDefaultStylesheet.copyWith(addRulesAfter: [_header1Color(Colors.red)]));
        addTearDown(stylesheet.dispose);
        await _pumpReaderWithStylesheet(tester, stylesheet: stylesheet, builds: builds);
        final builtBefore = {...builds};
        expect(SuperReaderInspector.findParagraphStyle("0")!.color, Colors.red);

        stylesheet.value = readOnlyDefaultStylesheet.copyWith(addRulesAfter: [_header1Color(Colors.green)]);
        await tester.pump();

        // The header has the new style...
        expect(SuperReaderInspector.findParagraphStyle("0")!.color, Colors.green);
        expect(builds["0"], builtBefore["0"]! + 1);
        // ...and the paragraphs, whose styles didn't change, weren't built again.
        for (final entry in builtBefore.entries.where((entry) => entry.key != "0")) {
          expect(builds[entry.key], entry.value, reason: "Node ${entry.key} was built again");
        }
      });
    });

    group("when the style phases change >", () {
      testWidgets("applies the style phases that come with a new stylesheet", (tester) async {
        final stylesheet = ValueNotifier(readOnlyDefaultStylesheet);
        addTearDown(stylesheet.dispose);
        final phases = ValueNotifier<List<SingleColumnLayoutStylePhase>>([_LeftPaddingPhase(10)]);
        addTearDown(phases.dispose);
        await _pumpReaderWithStyles(tester, stylesheet: stylesheet, phases: phases);
        final leftBefore = SuperReaderInspector.findComponentOffset("1", Alignment.topLeft).dx;

        // Give the reader a new stylesheet and new style phases in the same build, as an app
        // does when its text scale changes.
        stylesheet.value = readOnlyDefaultStylesheet.copyWith(addRulesAfter: [_header1Color(Colors.green)]);
        phases.value = [_LeftPaddingPhase(30)];
        await tester.pump();

        // Ensure that both the new stylesheet and the new style phase applied.
        expect(SuperReaderInspector.findParagraphStyle("0")!.color, Colors.green);
        expect(
          SuperReaderInspector.findComponentOffset("1", Alignment.topLeft).dx,
          moreOrLessEquals(leftBefore + 20),
          reason: "The new style phase's padding didn't apply",
        );
      });

      testWidgets("applies new style phases with the same stylesheet", (tester) async {
        final stylesheet = ValueNotifier(readOnlyDefaultStylesheet);
        addTearDown(stylesheet.dispose);
        final phases = ValueNotifier<List<SingleColumnLayoutStylePhase>>([_LeftPaddingPhase(10)]);
        addTearDown(phases.dispose);
        await _pumpReaderWithStyles(tester, stylesheet: stylesheet, phases: phases);
        final leftBefore = SuperReaderInspector.findComponentOffset("1", Alignment.topLeft).dx;

        // Give the reader new style phases.
        phases.value = [_LeftPaddingPhase(30)];
        await tester.pump();

        // Ensure that the new style phase applied.
        expect(
          SuperReaderInspector.findComponentOffset("1", Alignment.topLeft).dx,
          moreOrLessEquals(leftBefore + 20),
          reason: "The new style phase's padding didn't apply",
        );
      });
    });

    group("style text", () {
      testWidgetsOnArbitraryDesktop("with left alignment", (tester) async {
        await _pumpReader(tester, stylesheet: _stylesheetWithTextAlignment(TextAlign.left));

        expect(_findTextWithAlignment(TextAlign.left), findsOneWidget);
      });

      testWidgetsOnArbitraryDesktop("with center alignment", (tester) async {
        await _pumpReader(tester, stylesheet: _stylesheetWithTextAlignment(TextAlign.center));

        expect(_findTextWithAlignment(TextAlign.center), findsOneWidget);
      });

      testWidgetsOnArbitraryDesktop("with right alignment", (tester) async {
        await _pumpReader(tester, stylesheet: _stylesheetWithTextAlignment(TextAlign.right));

        expect(_findTextWithAlignment(TextAlign.right), findsOneWidget);
      });

      testWidgetsOnArbitraryDesktop("with justify alignment", (tester) async {
        await _pumpReader(tester, stylesheet: _stylesheetWithTextAlignment(TextAlign.justify));

        expect(_findTextWithAlignment(TextAlign.justify), findsOneWidget);
      });
    });
  });
}

Finder _findTextWithAlignment(TextAlign textAlign) =>
    find.byWidgetPredicate((widget) => (widget is SuperText) && widget.textAlign == textAlign);

Future<void> _pumpReader(
  WidgetTester tester, {
  required Stylesheet stylesheet,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SuperReader(
          editor: createDefaultDocumentEditor(
            document: singleParagraphDoc(),
            composer: MutableDocumentComposer(),
          ),
          stylesheet: stylesheet,
        ),
      ),
    ),
  );
}

Stylesheet _stylesheetWithTextAlignment(TextAlign textAlign) {
  return Stylesheet(
    inlineTextStyler: defaultInlineTextStyler,
    rules: [
      StyleRule(
        BlockSelector.all,
        (doc, docNode) {
          return {
            "textAlign": textAlign,
          };
        },
      ),
    ],
  );
}

/// Pumps a [SuperReader] with the [stylesheet], which builds every component with a
/// builder that counts, in [builds], how many times it built the component of each node.
Future<void> _pumpReaderWithStylesheet(
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
  final componentBuilders = [_BuildCountingComponentBuilder(builds), ...readOnlyDefaultComponentBuilders];

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ValueListenableBuilder<Stylesheet>(
          valueListenable: stylesheet,
          builder: (context, stylesheet, child) => SuperReader(
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
/// Pumps a [SuperReader] with the [stylesheet] and the custom style [phases], each of
/// which the test can replace.
Future<void> _pumpReaderWithStyles(
  WidgetTester tester, {
  required ValueNotifier<Stylesheet> stylesheet,
  required ValueNotifier<List<SingleColumnLayoutStylePhase>> phases,
}) async {
  final editor = createDefaultDocumentEditor(
    document: MutableDocument(
      nodes: [
        ParagraphNode(
          id: "0",
          text: AttributedText("A header"),
          metadata: const {"blockType": header1Attribution},
        ),
        ParagraphNode(id: "1", text: AttributedText("A paragraph")),
      ],
    ),
    composer: MutableDocumentComposer(),
  );

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ListenableBuilder(
          listenable: Listenable.merge([stylesheet, phases]),
          builder: (context, child) => SuperReader(
            editor: editor,
            stylesheet: stylesheet.value,
            customStylePhases: phases.value,
          ),
        ),
      ),
    ),
  );
}

/// A style phase that pads every component on its left by [left].
class _LeftPaddingPhase extends SingleColumnLayoutStylePhase {
  _LeftPaddingPhase(this.left);

  final double left;

  @override
  SingleColumnLayoutViewModel style(Document document, SingleColumnLayoutViewModel viewModel) {
    return SingleColumnLayoutViewModel(
      padding: viewModel.padding,
      componentViewModels: [
        for (final component in viewModel.componentViewModels) //
          component.copy()..padding = EdgeInsets.only(left: left),
      ],
    );
  }
}

StyleRule _header1Color(Color color) => StyleRule(
      const BlockSelector("header1"),
      (document, node) => {Styles.textStyle: TextStyle(color: color)},
    );

/// Builds the default read-only components, and counts how many times it built the
/// component of each node.
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
    for (final builder in readOnlyDefaultComponentBuilders) {
      final component = builder.createComponent(componentContext, componentViewModel);
      if (component != null) {
        builds[componentViewModel.nodeId] = (builds[componentViewModel.nodeId] ?? 0) + 1;
        return component;
      }
    }
    return null;
  }
}
