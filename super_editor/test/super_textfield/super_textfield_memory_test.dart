import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_test_runners/flutter_test_runners.dart';
import 'package:leak_tracker/leak_tracker.dart';
import 'package:super_editor/super_editor.dart';

void main() {
  group('SuperTextField > memory >', () {
    testWidgetsOnMobile('frees the text field once its page closes', (tester) async {
      // Flutter 3.44 keeps every disposed OverlayPortal's state while semantics are on, and
      // the mobile text fields build their editing controls in an OverlayPortal.
      expect(SemanticsBinding.instance.semanticsEnabled, isTrue);

      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(navigatorKey: navigator, home: const SizedBox()));

      final textField = await _openTextFieldPage(tester, navigator.currentState!);

      // Focus the text field, which shows its editing controls.
      await tester.tap(find.byType(SuperTextField));
      await tester.pumpAndSettle();

      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.byType(SuperTextField), findsNothing);

      await tester.runAsync(() => forceGC(fullGcCycles: 10));
      expect(textField.target, isNull, reason: "The text field's State is still reachable");
    });
  });
}

/// Pushes a page with a [SuperTextField] and returns a weak reference to the `State` of the
/// platform's text field.
///
/// No local variable of the test keeps anything that reaches the text field.
Future<WeakReference<State>> _openTextFieldPage(WidgetTester tester, NavigatorState navigator) async {
  navigator.push(
    MaterialPageRoute<void>(
      builder: (_) {
        return const Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              child: _TextFieldPage(),
            ),
          ),
        );
      },
    ),
  );
  await tester.pumpAndSettle();

  return WeakReference(
    tester.state(find.byWidgetPredicate((widget) => widget is SuperIOSTextField || widget is SuperAndroidTextField)),
  );
}

/// A page that owns the controller of its text field, as an app's page does.
class _TextFieldPage extends StatefulWidget {
  const _TextFieldPage();

  @override
  State<_TextFieldPage> createState() => _TextFieldPageState();
}

class _TextFieldPageState extends State<_TextFieldPage> {
  final _controller = AttributedTextEditingController(text: AttributedText('Some text to edit'));

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SuperTextField(textController: _controller);
  }
}
