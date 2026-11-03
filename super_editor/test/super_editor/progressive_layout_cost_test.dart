@Tags(["benchmark"])
library;

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:super_editor/super_editor.dart';

/// A bench that compares the cost of building a long document eagerly, and progressively.
///
/// It's skipped unless it's asked for, because it's slow:
///
///     flutter test test/super_editor/progressive_layout_cost_test.dart \
///       --dart-define=SUPER_EDITOR_BENCHMARK=true \
///       [--dart-define=SUPER_EDITOR_BENCHMARK_BLOCKS=8000] \
///       [--dart-define=SUPER_EDITOR_BENCHMARK_RUNS=3]
///
/// Every frame is timed with a [Stopwatch] around the pump, and broken down by phase. The
/// fake clock advances by the time that each frame takes, before the frame's post-frame
/// callbacks, and then to the next vsync of a 60 Hz display, as a device's clock would, so
/// that the timers of a progressive layout fire when they would on a device as slow as
/// this machine. Each scenario runs a few times, and reports the run with the median.
///
/// "Wall" is the time that the frames would take on a 60 Hz display, where each frame
/// starts at a vsync: every frame takes a whole number of 16.7 millisecond intervals.
///
/// The numbers are those of a debug build, with assertions, as `flutter test` runs.
void main() {
  // Time each phase of every frame.
  final binding = _PhaseTimingBinding();

  group("Progressive layout cost >", () {
    late bool wasProgressiveByDefault;
    setUp(() {
      wasProgressiveByDefault = SingleColumnProgressiveLayout.debugProgressiveByDefault;
      SingleColumnProgressiveLayout.debugProgressiveByDefault = false;
    });
    tearDown(() {
      SingleColumnProgressiveLayout.debugProgressiveByDefault = wasProgressiveByDefault;
    });

    _benchWidgets("presenter styles every node", (tester) async {
      // Warm up.
      _createPresenter(_createDocument(200)).dispose();

      final runs = <Duration>[];
      for (int run = 0; run < _runCount; run += 1) {
        final document = _createDocument(_blockCount);
        final stopwatch = Stopwatch()..start();
        final presenter = _createPresenter(document);
        stopwatch.stop();
        presenter.dispose();
        runs.add(stopwatch.elapsed);
      }
      final median = _median(runs, (run) => run);

      _report("presenter, all nodes", [
        "${_ms(median)} total, ${_us(median, _blockCount)}/block",
      ]);
    });

    _benchWidgets("Flutter's debug checks of a long child list", (tester) async {
      // Every insertion of a child after another one walks the whole child list, in a debug
      // build, to check it, so inserting every child of a long column takes quadratic time.
      Duration insertChildren({required bool atTheEnd}) {
        final column = RenderFlex(direction: Axis.vertical);
        final stopwatch = Stopwatch()..start();
        for (int i = 0; i < _blockCount; i += 1) {
          column.insert(RenderConstrainedBox(additionalConstraints: const BoxConstraints()),
              after: atTheEnd ? column.lastChild : null);
        }
        stopwatch.stop();
        return stopwatch.elapsed;
      }

      insertChildren(atTheEnd: true);
      final atTheEnd = _median([for (int run = 0; run < _runCount; run += 1) insertChildren(atTheEnd: true)], (d) => d);
      final atTheStart =
          _median([for (int run = 0; run < _runCount; run += 1) insertChildren(atTheEnd: false)], (d) => d);
      _report("debug checks of the child list", [
        "inserting every child after the last one: ${_ms(atTheEnd)}",
        "inserting every child before the first one, which isn't checked: ${_ms(atTheStart)}",
      ]);
    });

    _benchWidgets("eager first frame", (tester) async {
      await _warmUp(tester);

      final runs = <_BenchEditor>[];
      for (int run = 0; run < _runCount; run += 1) {
        runs.add(await _pumpEditor(tester, progressive: false));
        await _tearDownEditor(tester);
      }
      final result = _median(runs, (run) => run.frames.first.elapsed);

      _report("eager", [
        "first frame: ${result.frames.first}",
        "per block: ${_us(result.frames.first.elapsed, _blockCount)}",
        "runs: ${runs.map((run) => _ms(run.frames.first.elapsed)).join(", ")}",
      ]);
    });

    _benchWidgets("progressive, then completeNow()", (tester) async {
      await _warmUp(tester);

      final runs = <(_BenchEditor, int)>[];
      for (int run = 0; run < _runCount; run += 1) {
        final result = await _pumpEditor(tester, progressive: true);
        final deferredBefore = result.deferredCount();
        result.controller!.completeNow();
        await result.pumpFrame(tester);
        expect(result.controller!.isComplete.value, isTrue);
        runs.add((result, deferredBefore));
        await _tearDownEditor(tester);
      }
      final (result, deferredBefore) = _median(runs, (run) => run.$1.totalTime);
      final firstFrame = result.frames.first;
      final completeFrame = result.frames.last;

      _report("progressive + completeNow()", [
        "first frame: $firstFrame",
        "completeNow() frame: $completeFrame",
        "per deferred block: ${_us(completeFrame.elapsed, deferredBefore)}",
        "total: ${_ms(result.totalTime)}",
        "runs: ${runs.map((run) => _ms(run.$1.totalTime)).join(", ")}",
      ]);
    });

    for (final (name, safetyTimeout) in [
      ("the default configuration", null),
      ("no safety timeout", const Duration(minutes: 10)),
    ]) {
      _benchWidgets("progressive, filled by batches, with $name", (tester) async {
        await _warmUp(tester);

        final runs = <_BenchEditor>[];
        for (int run = 0; run < _runCount; run += 1) {
          final result = await _pumpEditor(tester, progressive: true, safetyTimeout: safetyTimeout);
          while (!result.controller!.isComplete.value) {
            if (result.frames.length > 20000) {
              fail("The fill didn't finish");
            }
            await result.pumpFrame(tester);
          }
          runs.add(result);
          await _tearDownEditor(tester);
        }
        final result = _median(runs, (run) => run.wallTime);

        final firstFrame = result.frames.first;
        final fillFrames = result.frames.skip(1).toList();
        final fillTime = fillFrames.fold(Duration.zero, (total, frame) => total + frame.elapsed);
        final slowest = fillFrames.reduce((a, b) => a.elapsed > b.elapsed ? a : b);
        final builtInFill = fillFrames.fold(0, (total, frame) => total + frame.builtCount);
        final framesOver = {
          for (final limit in [50, 100, 150])
            limit: fillFrames.where((frame) => frame.elapsed.inMilliseconds > limit).length,
        };
        _report("progressive, batches, $name", [
          "first frame: $firstFrame",
          "fill: ${fillFrames.length} frames, ${_ms(fillTime)}, ${_us(fillTime, builtInFill)}/block",
          "slowest fill frame: $slowest",
          "fill frames over 50/100/150 ms: ${framesOver[50]}/${framesOver[100]}/${framesOver[150]}",
          "batches: ${result.controller!.batchCount}",
          "total: ${_ms(result.totalTime)}, wall at 60 Hz: ${_ms(result.wallTime)}",
          "runs, wall: ${runs.map((run) => _ms(run.wallTime)).join(", ")}",
          "frames: ${[
            for (final frame in fillFrames.take(12)) "${frame.elapsed.inMilliseconds}ms/${frame.builtCount}",
          ].join(", ")}, ...",
          "last frames:",
          for (final frame in fillFrames.skip(max(fillFrames.length - 4, 0))) "  $frame",
        ]);
      });
    }
  }, skip: _runBenchmark ? false : "Run with --dart-define=SUPER_EDITOR_BENCHMARK=true");

  // Keep a reference to the binding, which must be created before the tests run.
  assert(identical(binding, TestWidgetsFlutterBinding.instance));
}

/// Runs a bench without semantics, which a device builds only when an assistive
/// technology asks for them.
void _benchWidgets(String description, WidgetTesterCallback callback) {
  testWidgets(description, callback, semanticsEnabled: false);
}

const _runBenchmark = bool.fromEnvironment("SUPER_EDITOR_BENCHMARK");
const _blockCount = int.fromEnvironment("SUPER_EDITOR_BENCHMARK_BLOCKS", defaultValue: 3000);
const _runCount = int.fromEnvironment("SUPER_EDITOR_BENCHMARK_RUNS", defaultValue: 3);

/// Returns the item of [items] with the median [value].
T _median<T>(List<T> items, Duration Function(T item) value) {
  final sorted = [...items]..sort((a, b) => value(a).compareTo(value(b)));
  return sorted[sorted.length ~/ 2];
}

/// Removes the editor that a run pumped, so that the next run starts from scratch.
Future<void> _tearDownEditor(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
}

/// The time between two vsyncs of a 60 Hz display.
const _vsyncMicroseconds = 1000000 / 60;

/// A phone, in logical pixels.
const _screenSize = Size(390, 844);

void _report(String title, List<String> lines) {
  // ignore: avoid_print
  print(["== $title ($_blockCount blocks)", for (final line in lines) "   $line"].join("\n"));
}

String _ms(Duration duration) => "${(duration.inMicroseconds / 1000).toStringAsFixed(1)} ms";

String _us(Duration duration, int count) => "${(duration.inMicroseconds / max(count, 1)).toStringAsFixed(0)} µs";

/// Builds a small document first, so that the code that the bench times is compiled.
Future<void> _warmUp(WidgetTester tester) async {
  final warmUp = await _pumpEditor(tester, progressive: true, document: _createDocument(300));
  await warmUp.pumpFrame(tester);
  warmUp.controller!.completeNow();
  await tester.pump();
  await _tearDownEditor(tester);
  await _pumpEditor(tester, progressive: false, document: _createDocument(300));
  await _tearDownEditor(tester);
}

SingleColumnLayoutPresenter _createPresenter(Document document) {
  return SingleColumnLayoutPresenter(
    document: document,
    componentBuilders: defaultComponentBuilders,
    pipeline: [
      SingleColumnStylesheetStyler(stylesheet: defaultStylesheet),
      SingleColumnLayoutCustomComponentStyler(),
      SingleColumnLayoutSelectionStyler(
        document: document,
        selection: ValueNotifier(null),
        selectionStyles: defaultSelectionStyle,
      ),
    ],
  );
}

/// A document of paragraphs, list items, and headings, of different lengths.
MutableDocument _createDocument(int blockCount) {
  final random = Random(42);
  String words(int count) => List.generate(count, (i) => _words[random.nextInt(_words.length)]).join(" ");

  return MutableDocument(
    nodes: [
      for (int i = 0; i < blockCount; i += 1)
        switch (i % 20) {
          0 => ParagraphNode(
              id: "$i",
              text: AttributedText("Heading $i ${words(3)}"),
              metadata: {"blockType": i % 40 == 0 ? header1Attribution : header2Attribution},
            ),
          1 || 2 || 3 || 4 => ListItemNode.unordered(id: "$i", text: AttributedText(words(4 + random.nextInt(20)))),
          5 || 6 || 7 => ListItemNode.ordered(
              id: "$i",
              text: AttributedText(words(4 + random.nextInt(20))),
              indent: i % 2,
            ),
          12 => ParagraphNode(
              id: "$i",
              text: AttributedText(words(10 + random.nextInt(30))),
              metadata: const {"blockType": blockquoteAttribution},
            ),
          _ => ParagraphNode(id: "$i", text: AttributedText(words(8 + random.nextInt(80)))),
        },
    ],
  );
}

const _words = [
  "lorem", "ipsum", "dolor", "sit", "amet", "consectetur", "adipiscing", "elit", "sed", "do", //
  "eiusmod", "tempor", "incididunt", "ut", "labore", "et", "dolore", "magna", "aliqua", "enim",
  "ad", "minim", "veniam", "quis", "nostrud", "exercitation", "ullamco", "laboris", "nisi",
];

Future<_BenchEditor> _pumpEditor(
  WidgetTester tester, {
  required bool progressive,
  MutableDocument? document,
  Duration? safetyTimeout,
}) async {
  tester.view
    ..physicalSize = _screenSize * 3
    ..devicePixelRatio = 3;
  addTearDown(tester.view.reset);

  document ??= _createDocument(_blockCount);
  final controller = progressive ? SingleColumnProgressiveLayoutController() : null;
  if (controller != null) {
    addTearDown(controller.dispose);
  }
  final scrollController = ScrollController();
  addTearDown(scrollController.dispose);
  final layoutKey = GlobalKey();

  final bench = _BenchEditor(document: document, controller: controller, layoutKey: layoutKey);
  await bench.pumpFrame(
    tester,
    pump: () => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            controller: scrollController,
            slivers: [
              SuperEditor(
                editor: createDefaultDocumentEditor(document: document!, composer: MutableDocumentComposer()),
                documentLayoutKey: layoutKey,
                progressiveLayout: controller != null
                    ? safetyTimeout != null
                        ? SingleColumnProgressiveLayout(controller: controller, safetyTimeout: safetyTimeout)
                        : SingleColumnProgressiveLayout(controller: controller)
                    : null,
              ),
            ],
          ),
        ),
      ),
    ),
  );
  return bench;
}

class _BenchEditor {
  _BenchEditor({
    required this.document,
    required this.controller,
    required this.layoutKey,
  });

  final MutableDocument document;
  final SingleColumnProgressiveLayoutController? controller;
  final GlobalKey layoutKey;

  final frames = <_Frame>[];

  /// The time that every frame took.
  Duration get totalTime => frames.fold(Duration.zero, (total, frame) => total + frame.elapsed);

  /// The time that the frames would take on a 60 Hz display: the first frame, and then a
  /// whole number of vsync intervals for every other frame.
  Duration get wallTime {
    var microseconds = frames.first.elapsed.inMicroseconds.toDouble();
    for (final frame in frames.skip(1)) {
      microseconds += max((frame.elapsed.inMicroseconds / _vsyncMicroseconds).ceil(), 1) * _vsyncMicroseconds;
    }
    return Duration(microseconds: microseconds.round());
  }

  /// The time from the end of the last frame to the next vsync, which the fake clock
  /// advances by before the next frame, as a device's clock would.
  Duration _timeToNextVsync = Duration.zero;

  int deferredCount() {
    final state = layoutKey.currentState;
    if (state is! ProgressiveDocumentLayout) {
      return 0;
    }
    final layout = state as ProgressiveDocumentLayout;
    return document.where((node) => layout.isComponentDeferred(node.id)).length;
  }

  Future<_Frame> pumpFrame(WidgetTester tester, {Future<void> Function()? pump}) async {
    final deferredBefore = frames.isEmpty ? document.nodeCount : deferredCount();
    final phases = _PhaseTimingBinding.instance..resetPhases();

    final stopwatch = Stopwatch()..start();
    if (pump != null) {
      await pump();
    } else {
      await tester.pump(_timeToNextVsync);
    }
    stopwatch.stop();
    final frameMicroseconds = stopwatch.elapsedMicroseconds;
    _timeToNextVsync = Duration(
      microseconds:
          (max((frameMicroseconds / _vsyncMicroseconds).ceil(), 1) * _vsyncMicroseconds - frameMicroseconds).round(),
    );

    final frame = _Frame(
      elapsed: stopwatch.elapsed,
      builtCount: deferredBefore - deferredCount(),
      phases: phases.phaseSummary(),
    );
    frames.add(frame);
    return frame;
  }
}

class _Frame {
  _Frame({
    required this.elapsed,
    required this.builtCount,
    required this.phases,
  });

  final Duration elapsed;
  final int builtCount;
  final String phases;

  @override
  String toString() => "${_ms(elapsed)}, $builtCount blocks built [$phases]";
}

/// A test binding that times the phases of every frame that it draws.
class _PhaseTimingBinding extends AutomatedTestWidgetsFlutterBinding {
  static _PhaseTimingBinding get instance => TestWidgetsFlutterBinding.instance as _PhaseTimingBinding;

  final _phases = <String, Duration>{};

  void resetPhases() => _phases.clear();

  String phaseSummary() => [
        for (final entry in _phases.entries) "${entry.key} ${(entry.value.inMicroseconds / 1000).toStringAsFixed(1)}",
      ].join(", ");

  void _time(String phase, VoidCallback callback) {
    final stopwatch = Stopwatch()..start();
    callback();
    _phases[phase] = (_phases[phase] ?? Duration.zero) + stopwatch.elapsed;
  }

  @override
  void handleBeginFrame(Duration? rawTimeStamp) {
    _time("begin", () => super.handleBeginFrame(rawTimeStamp));
  }

  @override
  void drawFrame() {
    final stopwatch = Stopwatch()..start();
    debugBuildingDirtyElements = true;
    try {
      _time("build", () => buildOwner!.buildScope(rootElement!));
      _time("layout", rootPipelineOwner.flushLayout);
      _time("paint", () {
        rootPipelineOwner.flushCompositingBits();
        rootPipelineOwner.flushPaint();
      });
      _time("composite", () {
        for (final renderView in renderViews) {
          renderView.compositeFrame();
        }
        rootPipelineOwner.flushSemantics();
      });
      _time("finalize", buildOwner!.finalizeTree);
    } finally {
      debugBuildingDirtyElements = false;
    }

    // Let the fake clock catch up with the frame, before its post-frame callbacks, so that
    // a timer that they start counts from the end of the frame, as it would on a device.
    elapseBlocking(stopwatch.elapsed);
  }
}
