import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_test_runners/flutter_test_runners.dart';
import 'package:leak_tracker/leak_tracker.dart';
import 'package:super_editor/src/default_editor/document_scrollable.dart';
import 'package:super_editor/super_editor.dart';
import 'package:super_editor/super_editor_test.dart';

void main() {
  group('SuperEditor > memory >', () {
    testWidgetsOnMobile('frees its page, with the editor, its document and its presenter, once the page closes',
        (tester) async {
      // Flutter 3.44 keeps every disposed OverlayPortal's state while semantics are on, and
      // SuperEditor's overlay managers build their toolbar, magnifier and handles in
      // OverlayPortals.
      expect(SemanticsBinding.instance.semanticsEnabled, isTrue);

      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(navigatorKey: navigator, home: const SizedBox()));

      final page = await _openEditorPage(tester, navigator.currentState!);

      // Type, which connects the editor to the IME.
      await tester.placeCaretInParagraph('1', 0);
      await tester.typeImeText('Typed. ');
      expect(SuperEditorInspector.findTextInComponent('1').toPlainText(), startsWith('Typed. '));

      // Select a word, which shows the toolbar.
      await tester.doubleTapInParagraph('1', 8);
      expect(SuperEditorInspector.findDocumentSelection(), isNotNull);
      expect(SuperEditorInspector.wantsMobileToolbarToBeVisible(), isTrue);

      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.byType(SuperEditor), findsNothing);

      await tester.runAsync(() => forceGC(fullGcCycles: 10));

      expect(page.page.target, isNull, reason: "The page is still reachable");
      expect(page.editorState.target, isNull, reason: "The SuperEditorState is still reachable");
      expect(page.document.target, isNull, reason: "The document is still reachable");
      expect(page.presenter.target, isNull, reason: "The presenter is still reachable");
    });

    testWidgetsOnAllPlatforms("disposes its presenter, which a document that outlives the editor doesn't keep",
        (tester) async {
      final document = _ListenerCountingDocument(nodes: _paragraphs());
      final composer = MutableDocumentComposer();
      final editor = createDefaultDocumentEditor(document: document, composer: composer);
      final documentListenersWithoutEditor = document.listenerCount;

      final editorReferences = await _pumpEditor(tester, editor);
      expect(document.listenerCount, greaterThan(documentListenersWithoutEditor));

      // Remove the editor, and keep its document, e.g., to show it in a SuperReader.
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      // Run the frame callbacks that the editor's widgets scheduled as they were disposed.
      await tester.pump();

      expect(document.listenerCount, documentListenersWithoutEditor);

      await tester.runAsync(() => forceGC(fullGcCycles: 10));
      expect(editorReferences.editorState.target, isNull, reason: "The SuperEditorState is still reachable");
      expect(editorReferences.presenter.target, isNull, reason: "The presenter is still reachable");

      // The document and composer are still in use.
      expect(document.nodeCount, 50);
      expect(composer.selection, isNull);
      editor.dispose();
    });

    testWidgetsOnAllPlatforms("isn't kept by an ancestor Scrollable that outlives it", (tester) async {
      final scrollController = ScrollController();
      addTearDown(scrollController.dispose);

      final editorReferences = await _pumpEditorInScrollView(tester, scrollController);

      // Replace the editor in the scroll view, which stays.
      await tester.pumpWidget(_buildScrollView(scrollController, const SliverToBoxAdapter(child: SizedBox())));
      await tester.pump();
      expect(find.byType(SuperEditor), findsNothing);

      await tester.runAsync(() => forceGC(fullGcCycles: 10));
      expect(editorReferences.editorState.target, isNull, reason: "The SuperEditorState is still reachable");
      expect(editorReferences.presenter.target, isNull, reason: "The presenter is still reachable");
      // The ancestor's scroll position doesn't keep listening to the editor's auto-scroller,
      // and so doesn't notify every auto-scroller of every editor it held, on every scroll.
      expect(editorReferences.autoScroller!.target, isNull, reason: "The auto-scroller is still reachable");

      // The scroll view is still in use.
      expect(scrollController.hasClients, isTrue);
    });

    testWidgets("leaves the style phases that the app gives it to the app", (tester) async {
      final editor = createDefaultDocumentEditor(document: MutableDocument(nodes: _paragraphs()));
      final appPhase = _RecordingStylePhase();

      await tester.pumpWidget(_buildEditor(editor, key: const ValueKey("first"), customStylePhases: [appPhase]));
      expect(appPhase.styleCount, greaterThan(0));

      // Replace the editor with another one that uses the same phase. The new editor's
      // presenter takes the phase before the first editor is disposed.
      await tester.pumpWidget(_buildEditor(editor, key: const ValueKey("second"), customStylePhases: [appPhase]));
      expect(appPhase.isDisposed, isFalse);

      // The phase still restyles the editor that uses it.
      final styleCountBeforeChange = appPhase.styleCount;
      appPhase.restyle();
      await tester.pump();
      expect(appPhase.styleCount, greaterThan(styleCountBeforeChange));

      // Once no editor uses the phase, it isn't disposed, either.
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      expect(appPhase.isDisposed, isFalse);
      editor.dispose();
    });
  });

  group('MutableDocument > memory >', () {
    test("lets go of the nodes that edits replace when its editor has no history", () async {
      final document = MutableDocument(nodes: _paragraphs());
      final editor = createDefaultDocumentEditor(document: document, isHistoryEnabled: false);
      final originalNode = WeakReference(document.getNodeById('1')!);

      _typeAtStartOf(editor, '1', 'Typed. ');
      expect(document.getNodeById('1'), isNot(same(originalNode.target)));

      await forceGC(fullGcCycles: 10);
      expect(originalNode.target, isNull, reason: "The document still keeps the node that the edit replaced");

      expect(document.getNodeById('1')!.asTextNode.text.toPlainText(), startsWith('Typed. '));
    });

    test("keeps the nodes it started with when its editor has history, to undo", () async {
      final document = MutableDocument(nodes: _paragraphs());
      final editor = createDefaultDocumentEditor(document: document, isHistoryEnabled: true);
      final originalNode = WeakReference(document.getNodeById('1')!);

      _typeAtStartOf(editor, '1', 'Typed. ');

      await forceGC(fullGcCycles: 10);
      expect(originalNode.target, isNotNull);

      editor.undo();
      expect(document.getNodeById('1')!.asTextNode.text.toPlainText(), 'Paragraph 1 of a document.');
    });

    test("undoes to where an editor with history started, after an editor without history", () {
      final document = MutableDocument(nodes: _paragraphs());
      final editorWithoutHistory = createDefaultDocumentEditor(document: document, isHistoryEnabled: false);
      _typeAtStartOf(editorWithoutHistory, '1', 'Without history. ');

      final editorWithHistory = createDefaultDocumentEditor(document: document, isHistoryEnabled: true);
      _typeAtStartOf(editorWithHistory, '1', 'With history. ');
      expect(
        document.getNodeById('1')!.asTextNode.text.toPlainText(),
        'With history. Without history. Paragraph 1 of a document.',
      );

      editorWithHistory.undo();
      expect(
        document.getNodeById('1')!.asTextNode.text.toPlainText(),
        'Without history. Paragraph 1 of a document.',
      );
    });
  });
}

List<DocumentNode> _paragraphs() {
  return [
    for (int i = 1; i <= 50; i += 1)
      ParagraphNode(
        id: '$i',
        text: AttributedText('Paragraph $i of a document.'),
      ),
  ];
}

void _typeAtStartOf(Editor editor, String nodeId, String text) {
  editor.execute([
    InsertTextRequest(
      documentPosition: DocumentPosition(nodeId: nodeId, nodePosition: const TextNodePosition(offset: 0)),
      textToInsert: text,
      attributions: {},
    ),
  ]);
}

Widget _buildEditor(Editor editor, {Key? key, List<SingleColumnLayoutStylePhase> customStylePhases = const []}) {
  return MaterialApp(
    home: Scaffold(
      body: SuperEditor(
        key: key,
        editor: editor,
        customStylePhases: customStylePhases,
      ),
    ),
  );
}

/// Pumps a [SuperEditor] for [editor], and returns weak references to what the editor
/// shouldn't keep alive once it's removed.
///
/// No local variable of the test keeps the editor's `State` or presenter.
Future<_EditorReferences> _pumpEditor(WidgetTester tester, Editor editor) async {
  await tester.pumpWidget(_buildEditor(editor));

  final editorState = tester.state<SuperEditorState>(find.byType(SuperEditor));
  return _EditorReferences(
    editorState: WeakReference(editorState),
    presenter: WeakReference(editorState.presenter),
  );
}

Widget _buildScrollView(ScrollController scrollController, Widget sliver) {
  return MaterialApp(
    home: Scaffold(
      body: CustomScrollView(
        controller: scrollController,
        slivers: [sliver],
      ),
    ),
  );
}

/// Pumps a [SuperEditor] in a [CustomScrollView] that's controlled by [scrollController],
/// and returns weak references to what the editor shouldn't keep alive once it's removed.
///
/// No local variable of the test keeps the editor.
Future<_EditorReferences> _pumpEditorInScrollView(WidgetTester tester, ScrollController scrollController) async {
  final editor = createDefaultDocumentEditor(document: MutableDocument(nodes: _paragraphs()));
  await tester.pumpWidget(_buildScrollView(scrollController, SuperEditor(editor: editor)));
  // The editor attaches to the ancestor Scrollable after its first frame.
  await tester.pump();

  // Scroll the ancestor, which notifies whoever listens to its position.
  scrollController.jumpTo(100);
  await tester.pump();

  final editorState = tester.state<SuperEditorState>(find.byType(SuperEditor));
  return _EditorReferences(
    editorState: WeakReference(editorState),
    presenter: WeakReference(editorState.presenter),
    autoScroller: WeakReference(tester.widget<DocumentScrollable>(find.byType(DocumentScrollable)).autoScroller),
  );
}

class _EditorReferences {
  const _EditorReferences({
    required this.editorState,
    required this.presenter,
    this.autoScroller,
  });

  final WeakReference<SuperEditorState> editorState;
  final WeakReference<SingleColumnLayoutPresenter> presenter;
  final WeakReference<AutoScrollController>? autoScroller;
}

/// Pushes a page with a [SuperEditor] and returns weak references to what it shouldn't keep
/// alive once it closes.
///
/// No local variable of the test keeps anything that reaches the editor.
Future<_PageReferences> _openEditorPage(WidgetTester tester, NavigatorState navigator) async {
  navigator.push(
    MaterialPageRoute<void>(
      builder: (_) {
        return Scaffold(
          body: _EditorPage(document: MutableDocument(nodes: _paragraphs())),
        );
      },
    ),
  );
  await tester.pumpAndSettle();

  final editorState = tester.state<SuperEditorState>(find.byType(SuperEditor));
  return _PageReferences(
    page: WeakReference(tester.state<_EditorPageState>(find.byType(_EditorPage))),
    editorState: WeakReference(editorState),
    document: WeakReference(editorState.widget.editor.document),
    presenter: WeakReference(editorState.presenter),
  );
}

/// A page that owns its editor, as an app's page does.
class _EditorPage extends StatefulWidget {
  const _EditorPage({required this.document});

  final MutableDocument document;

  @override
  State<_EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<_EditorPage> {
  late final _composer = MutableDocumentComposer();
  late final _editor = createDefaultDocumentEditor(document: widget.document, composer: _composer);

  @override
  void dispose() {
    _editor.dispose();
    _composer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SuperEditor(editor: _editor);
  }
}

class _PageReferences {
  const _PageReferences({
    required this.page,
    required this.editorState,
    required this.document,
    required this.presenter,
  });

  final WeakReference<State> page;
  final WeakReference<SuperEditorState> editorState;
  final WeakReference<MutableDocument> document;
  final WeakReference<SingleColumnLayoutPresenter> presenter;
}

/// A [MutableDocument] that counts its listeners.
class _ListenerCountingDocument extends MutableDocument {
  _ListenerCountingDocument({super.nodes});

  int listenerCount = 0;

  @override
  void addListener(DocumentChangeListener listener) {
    listenerCount += 1;
    super.addListener(listener);
  }

  @override
  void removeListener(DocumentChangeListener listener) {
    listenerCount -= 1;
    super.removeListener(listener);
  }
}

/// An app's style phase, which records how many times it styles, and whether it's disposed.
class _RecordingStylePhase extends SingleColumnLayoutStylePhase {
  int styleCount = 0;
  bool isDisposed = false;

  /// Marks this phase dirty, as a phase whose styles change does.
  void restyle() => markDirty();

  @override
  SingleColumnLayoutViewModel style(Document document, SingleColumnLayoutViewModel viewModel) {
    styleCount += 1;
    return viewModel;
  }

  @override
  void dispose() {
    isDisposed = true;
    super.dispose();
  }
}
