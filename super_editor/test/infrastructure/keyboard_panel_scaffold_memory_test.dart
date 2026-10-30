import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_test_runners/flutter_test_runners.dart';
import 'package:leak_tracker/leak_tracker.dart';
import 'package:super_editor/super_editor.dart';
import 'package:super_editor/super_editor_test.dart';

void main() {
  group('Keyboard panel scaffold > memory >', () {
    testWidgetsOnMobile('frees its page, with the content and the editor in it, once the page closes', (tester) async {
      // Flutter 3.44 keeps every disposed OverlayPortal's state while semantics are on, and
      // the scaffold shows its toolbar and panels in an OverlayPortal, whose child is the
      // page's content.
      expect(SemanticsBinding.instance.semanticsEnabled, isTrue);

      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(navigatorKey: navigator, home: const SizedBox()));

      final page = await _openPage(tester, navigator.currentState!);

      // Type, which connects the editor to the IME, and shows the toolbar above the keyboard.
      await tester.placeCaretInParagraph('1', 0);
      await tester.typeImeText('Typed. ');
      expect(find.byKey(_toolbarKey), findsOneWidget);

      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.byType(SuperEditor), findsNothing);

      await tester.runAsync(() => forceGC(fullGcCycles: 10));
      expect(page.page.target, isNull, reason: "The page is still reachable");
      expect(page.editorState.target, isNull, reason: "The SuperEditorState is still reachable");
    });
  });
}

const _toolbarKey = ValueKey('toolbar');

/// Pushes a page with a [SuperEditor] in a [KeyboardPanelScaffold], and returns weak
/// references to what it shouldn't keep alive once it closes.
///
/// No local variable of the test keeps anything that reaches the page.
Future<_PageReferences> _openPage(WidgetTester tester, NavigatorState navigator) async {
  navigator.push(
    MaterialPageRoute<void>(
      builder: (_) => const _ScaffoldPage(),
    ),
  );
  await tester.pumpAndSettle();

  return _PageReferences(
    page: WeakReference(tester.state(find.byType(_ScaffoldPage))),
    editorState: WeakReference(tester.state<SuperEditorState>(find.byType(SuperEditor))),
  );
}

/// A page that owns its editor and its keyboard panel controller, as an app's page does.
class _ScaffoldPage extends StatefulWidget {
  const _ScaffoldPage();

  @override
  State<_ScaffoldPage> createState() => _ScaffoldPageState();
}

class _ScaffoldPageState extends State<_ScaffoldPage> {
  final _softwareKeyboardController = SoftwareKeyboardController();
  late final _keyboardPanelController = KeyboardPanelController<int>(_softwareKeyboardController);
  final _isImeConnected = ValueNotifier(false);
  late final _editor = createDefaultDocumentEditor(
    document: MutableDocument(
      nodes: [
        for (int i = 1; i <= 20; i += 1) ParagraphNode(id: '$i', text: AttributedText('Paragraph $i')),
      ],
    ),
  );

  @override
  void dispose() {
    _keyboardPanelController.dispose();
    _isImeConnected.dispose();
    _editor.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: KeyboardScaffoldSafeArea(
        child: KeyboardPanelScaffold<int>(
          controller: _keyboardPanelController,
          isImeConnected: _isImeConnected,
          contentBuilder: (context, openPanel) => SuperEditor(
            editor: _editor,
            softwareKeyboardController: _softwareKeyboardController,
            isImeConnected: _isImeConnected,
          ),
          toolbarBuilder: (context, openPanel) => Container(key: _toolbarKey, height: 54),
          fallbackPanelHeight: 300,
          keyboardPanelBuilder: (context, openPanel) => const SizedBox.expand(),
        ),
      ),
    );
  }
}

class _PageReferences {
  const _PageReferences({
    required this.page,
    required this.editorState,
  });

  final WeakReference<State> page;
  final WeakReference<SuperEditorState> editorState;
}
