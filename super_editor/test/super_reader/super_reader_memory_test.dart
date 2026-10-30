import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_test_runners/flutter_test_runners.dart';
import 'package:leak_tracker/leak_tracker.dart';
import 'package:super_editor/src/infrastructure/platforms/android/selection_handles.dart';
import 'package:super_editor/super_editor.dart';
import 'package:super_editor/super_editor_test.dart' show SuperEditorRobot;
import 'package:super_editor/super_reader_test.dart';

void main() {
  group('SuperReader > memory >', () {
    testWidgetsOnMobile('frees its page, with the reader, its document and its presenter, once the page closes',
        (tester) async {
      // Flutter 3.44 keeps every disposed OverlayPortal's state while semantics are on, and
      // SuperReader's overlay managers build their toolbar, magnifier and handles in
      // OverlayPortals.
      expect(SemanticsBinding.instance.semanticsEnabled, isTrue);

      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(navigatorKey: navigator, home: const SizedBox()));

      final page = await _openReaderPage(tester, navigator.currentState!);

      // Select a word, which shows the drag handles in the overlay.
      await tester.longPressInParagraph('1', 8);
      await tester.pumpAndSettle();
      expect(SuperReaderInspector.findDocumentSelection()?.isCollapsed, isFalse);
      expect(
        defaultTargetPlatform == TargetPlatform.android
            ? find.byType(AndroidSelectionHandle)
            : SuperReaderInspector.findAllMobileDragHandles(),
        findsWidgets,
      );

      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.byType(SuperReader), findsNothing);

      await tester.runAsync(() => forceGC(fullGcCycles: 10));

      expect(page.page.target, isNull, reason: "The page is still reachable");
      expect(page.readerState.target, isNull, reason: "The SuperReaderState is still reachable");
      expect(page.document.target, isNull, reason: "The document is still reachable");
      expect(page.presenter.target, isNull, reason: "The presenter is still reachable");
    });

    testWidgetsOnAllPlatforms("disposes its presenter, which a document that outlives the reader doesn't keep",
        (tester) async {
      final document = _ListenerCountingDocument(nodes: _paragraphs());
      final composer = MutableDocumentComposer();
      final editor = createDefaultDocumentEditor(document: document, composer: composer);
      final documentListenersWithoutReader = document.listenerCount;

      final readerReferences = await _pumpReader(tester, editor);
      expect(document.listenerCount, greaterThan(documentListenersWithoutReader));

      // Remove the reader, and keep its document, e.g., to edit it in a SuperEditor.
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      // Run the frame callbacks that the reader's widgets scheduled as they were disposed.
      await tester.pump();

      expect(document.listenerCount, documentListenersWithoutReader);

      await tester.runAsync(() => forceGC(fullGcCycles: 10));
      expect(readerReferences.readerState.target, isNull, reason: "The SuperReaderState is still reachable");
      expect(readerReferences.presenter.target, isNull, reason: "The presenter is still reachable");

      // The document and composer are still in use.
      expect(document.nodeCount, 50);
      expect(composer.selection, isNull);
      editor.dispose();
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

/// The presenter of the [SuperReader] that [tester] shows.
SingleColumnLayoutPresenter _findPresenter(WidgetTester tester) {
  return tester.widget<SingleColumnDocumentLayout>(find.byType(SingleColumnDocumentLayout)).presenter;
}

/// Pumps a [SuperReader] for [editor], and returns weak references to what the reader
/// shouldn't keep alive once it's removed.
///
/// No local variable of the test keeps the reader's `State` or presenter.
Future<_ReaderReferences> _pumpReader(WidgetTester tester, Editor editor) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SuperReader(editor: editor),
      ),
    ),
  );

  return _ReaderReferences(
    readerState: WeakReference(tester.state<SuperReaderState>(find.byType(SuperReader))),
    presenter: WeakReference(_findPresenter(tester)),
  );
}

class _ReaderReferences {
  const _ReaderReferences({
    required this.readerState,
    required this.presenter,
  });

  final WeakReference<SuperReaderState> readerState;
  final WeakReference<SingleColumnLayoutPresenter> presenter;
}

/// Pushes a page with a [SuperReader] and returns weak references to what it shouldn't keep
/// alive once it closes.
///
/// No local variable of the test keeps anything that reaches the reader.
Future<_PageReferences> _openReaderPage(WidgetTester tester, NavigatorState navigator) async {
  navigator.push(
    MaterialPageRoute<void>(
      builder: (_) {
        return Scaffold(
          body: _ReaderPage(document: MutableDocument(nodes: _paragraphs())),
        );
      },
    ),
  );
  await tester.pumpAndSettle();

  final readerState = tester.state<SuperReaderState>(find.byType(SuperReader));
  return _PageReferences(
    page: WeakReference(tester.state<_ReaderPageState>(find.byType(_ReaderPage))),
    readerState: WeakReference(readerState),
    document: WeakReference(readerState.widget.editor.document),
    presenter: WeakReference(_findPresenter(tester)),
  );
}

/// A page that owns the editor of its reader, as an app's page does.
class _ReaderPage extends StatefulWidget {
  const _ReaderPage({required this.document});

  final MutableDocument document;

  @override
  State<_ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<_ReaderPage> {
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
    return SuperReader(editor: _editor);
  }
}

class _PageReferences {
  const _PageReferences({
    required this.page,
    required this.readerState,
    required this.document,
    required this.presenter,
  });

  final WeakReference<State> page;
  final WeakReference<SuperReaderState> readerState;
  final WeakReference<Document> document;
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
