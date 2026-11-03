import 'dart:async';

import 'package:super_editor/src/default_editor/layout_single_column/layout_single_column.dart';
import 'package:super_editor/src/super_textfield/ios/ios_textfield.dart';
import 'package:super_editor/src/test/test_globals.dart';
import 'package:super_text_layout/super_text_layout.dart';

/// Whether every document layout that isn't configured otherwise lays out progressively,
/// with a first frame of only what's visible, and batches of one node, so that the suite
/// exercises the layout while most nodes aren't built:
///
///     flutter test --dart-define=SUPER_EDITOR_PROGRESSIVE_LAYOUT_BY_DEFAULT=true
const _isProgressiveLayoutOnByDefault = bool.fromEnvironment("SUPER_EDITOR_PROGRESSIVE_LAYOUT_BY_DEFAULT");

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  // Disable indeterminate animations
  BlinkController.indeterminateAnimationsEnabled = false;

  // Disable iOS selection heuristics, i.e, place the caret at the exact
  // tapped position instead of placing it at word boundaries.
  IOSTextFieldTouchInteractor.useIosSelectionHeuristics = false;

  Testing.isInTest = true;

  SingleColumnProgressiveLayout.debugProgressiveByDefault = _isProgressiveLayoutOnByDefault;

  return testMain();
}
