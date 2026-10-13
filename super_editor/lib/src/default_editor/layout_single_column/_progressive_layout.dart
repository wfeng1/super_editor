part of '_layout.dart';

/// Configures a [SingleColumnDocumentLayout] to show its first frame before it builds
/// every component, and to build the rest over the following frames.
///
/// The first frame builds the components around the initial scroll offset, from half a
/// screen above it to one and a half screens below it, plus the first node, the last
/// node, and the nodes after the last selectable one. Every other node is a placeholder
/// of estimated height, until a later frame builds it. Those frames build the nodes below
/// the viewport first, nearest first, and then the nodes above it, a batch at a time.
///
/// Each batch is sized so that its whole frame, including the frame's other work, takes
/// about [frameBudget]. The layout measures every frame that builds a batch, and how long
/// the batch took, and grows the next batch while the frames stay under the budget. Once
/// [safetyTimeout] has passed, the batches are sized to [catchUpFrameBudget] instead, and
/// they go on while the user scrolls, so that the layout always finishes, without a frame
/// that builds everything at once.
///
/// The visible content doesn't move while the rest is built:
///
///  * a frame builds every placeholder that becomes visible, e.g., after a jump, or a
///    fling, before it paints;
///  * when the nodes that are built above the visible content are taller, or shorter,
///    than their estimates, the layout corrects the scroll offset by the difference;
///  * while the user scrolls, only the nodes around the viewport are built, until
///    [safetyTimeout] has passed, and while an animation drives the scroll offset, e.g.,
///    `ScrollPosition.animateTo()`, no node above the viewport is built, so that the
///    animation lands where it was aimed.
///
/// Until every node is built, a node that isn't built has no [DocumentComponent], so
/// [DocumentLayout.getComponentByNodeId] returns `null` for it, the position lookups skip
/// it, and every position that the layout returns is in a node that's built. Editing
/// should wait for [SingleColumnProgressiveLayoutController.isComplete], because the
/// editing paths, e.g., the IME, caret movement, and deletions across nodes, expect
/// every node to have a component. Call [SingleColumnProgressiveLayoutController.completeNow]
/// to build everything at once, e.g., when the user taps to edit.
///
/// The layout builds every node at once, as if this configuration weren't given, when it
/// shrink-wraps its content, when it isn't wrapped with a sliver adapter, when it isn't in
/// a vertical viewport, and in a `SuperEditorDryLayout`.
class SingleColumnProgressiveLayout {
  const SingleColumnProgressiveLayout({
    this.estimateHeight,
    this.frameBudget = const Duration(milliseconds: 12),
    this.initialScrollOffset,
    this.controller,
    this.safetyTimeout = const Duration(seconds: 1),
    this.catchUpFrameBudget = const Duration(milliseconds: 50),
    this.buildTogether,
  })  : _windowExtentAboveOffset = 0.5,
        _windowExtentBelowOffset = 1.5,
        _initialBatchUnits = 4000;

  /// The configuration that [debugProgressiveByDefault] gives every layout that isn't
  /// configured: a first frame that builds only what's visible, and batches of one node,
  /// until the [safetyTimeout].
  const SingleColumnProgressiveLayout._debugDefault()
      : estimateHeight = null,
        frameBudget = Duration.zero,
        initialScrollOffset = null,
        controller = null,
        safetyTimeout = const Duration(seconds: 3),
        catchUpFrameBudget = const Duration(milliseconds: 50),
        buildTogether = null,
        _windowExtentAboveOffset = 0,
        _windowExtentBelowOffset = 0,
        _initialBatchUnits = 1;

  /// When `true`, every [SingleColumnDocumentLayout] that isn't given a configuration, and
  /// that could lay out progressively, lays out progressively, with a first frame that
  /// builds only what's visible, and batches of one node, so that tests exercise the
  /// layout while most nodes aren't built.
  @visibleForTesting
  static bool debugProgressiveByDefault = false;

  /// Estimates the height of the component for [viewModel], when it's laid out at the
  /// given content [width], which excludes the view model's padding, or returns `null`
  /// to use the built-in estimate.
  ///
  /// The layout adds the view model's vertical padding to the estimate.
  ///
  /// A height that the layout measured for the node earlier takes precedence over this
  /// estimate. The built-in estimate counts the lines of a text component from its
  /// length, and its line breaks, at its base text style, and uses 24 pixels for every
  /// other component.
  ///
  /// Good estimates keep the scroll extent, and the scroll bar, stable while the layout
  /// builds the rest of the document, and put the initial scroll offset closer to the
  /// content that it was taken at.
  final double? Function(SingleColumnLayoutComponentViewModel viewModel, double width)? estimateHeight;

  /// About how long each frame that builds a batch of nodes should take, in all, until
  /// [safetyTimeout] has passed.
  ///
  /// The budget covers the whole frame, i.e., the batch, and everything else that the
  /// frame does, e.g., laying out, and painting, the rest of the app. The layout measures
  /// every frame that builds a batch, and how long the batch took, and sizes the next
  /// batch to what's left of the budget after the rest of the frame. A batch grows by at
  /// most twice from one frame to the next. Every batch builds at least one node, so a
  /// budget of zero builds one node per frame.
  final Duration frameBudget;

  /// Returns the scroll offset, within the document layout, that the first frame shows,
  /// or `null` to use the scroll offset of the enclosing `Scrollable`.
  ///
  /// The first frame builds the nodes that the estimates place around this offset. Give
  /// it when the document isn't the first sliver in its viewport, e.g., the offset of the
  /// `Scrollable` minus the extent of the slivers above the document.
  final double Function()? initialScrollOffset;

  /// A controller that reports when every node is built, and that builds nodes on demand.
  final SingleColumnProgressiveLayoutController? controller;

  /// How long, after its first frame, the layout sizes its batches to [frameBudget], and,
  /// while the user scrolls, builds only the nodes around the viewport.
  ///
  /// After that, the batches are sized to [catchUpFrameBudget], or to [frameBudget] while
  /// the user scrolls, and they go on while the user scrolls, so that the layout finishes
  /// even when the user scrolls for a long time. No frame builds everything at once, unless
  /// the app calls [SingleColumnProgressiveLayoutController.completeNow].
  ///
  /// The default lets the frames right after the first one, e.g., those of a page
  /// transition, stay short, and then finishes about as soon as building everything in the
  /// first frame would have.
  final Duration safetyTimeout;

  /// About how long each frame that builds a batch of nodes should take, in all, once
  /// [safetyTimeout] has passed, unless the user scrolls.
  ///
  /// A larger budget finishes sooner, because each frame has a fixed cost, besides its
  /// batch, while a smaller one keeps animations smoother in the meantime.
  final Duration catchUpFrameBudget;

  /// Returns the IDs of the nodes that must be built in the same frame as the node with
  /// the given [nodeId], or `null`, or an empty iterable, when there are none.
  ///
  /// Whenever the layout builds a node, for any reason, e.g., because it's in the first
  /// frame's window, because it became visible, or in the cache extent, because someone
  /// asked for it with [SingleColumnProgressiveLayoutController.ensureBuilt], or in a
  /// batch, it also builds the nodes that this returns for it, and the nodes that this
  /// returns for those, in the same frame. Use it for nodes that paint together, e.g., the
  /// nodes of a row of columns, which paint side by side, where the layout would otherwise
  /// build a row's first column, and not its next ones, whose layout boxes are farther
  /// down.
  ///
  /// The scroll offset correction that keeps the visible content still applies to every
  /// node that a frame builds, so a group that's built above the visible content doesn't
  /// move it. While an animation drives the scroll offset, there's no correction, so the
  /// batches, and the cache extent below the viewport, skip the groups that reach above
  /// the viewport, as the batches skip the nodes above it. A node that becomes visible
  /// during the animation, or that was asked for, is still built with its group.
  ///
  /// The layout calls it for every node that it builds, and, while an animation scrolls,
  /// for the nodes that it considers building, so it should be cheap, e.g., a lookup.
  final Iterable<String>? Function(String nodeId)? buildTogether;

  /// The extents of the first frame's window, above and below the initial scroll offset,
  /// as fractions of the screen height.
  final double _windowExtentAboveOffset;
  final double _windowExtentBelowOffset;

  /// The work in the first batch after the first frame, in the units of
  /// [_ProgressiveFill._workUnitsOf]: about 16 nodes of 150 characters each.
  final double _initialBatchUnits;
}

/// Reports when a [SingleColumnDocumentLayout] that lays out progressively has built every
/// node, and builds nodes on demand.
///
/// Give this controller to a [SingleColumnProgressiveLayout]. A layout that builds every
/// node at once, e.g., because it shrink-wraps its content, reports [isComplete] after its
/// first frame.
class SingleColumnProgressiveLayoutController {
  SingleColumnProgressiveLayoutController();

  /// Whether the layout has built every node.
  ///
  /// The value is `false` until the layout's first frame, and while the layout builds
  /// the rest of the document. It becomes `true` once, at the end of the frame that built
  /// the last node, and listeners are notified after that frame. Editing should wait for
  /// it.
  ValueListenable<bool> get isComplete => _isComplete;
  final _isComplete = _ProgressiveCompletionNotifier();

  /// Builds the components of the given nodes in the next frame, if they aren't built yet.
  ///
  /// Use it before scrolling to a node that might not be built, e.g., to reveal a comment,
  /// then measure the node after that frame.
  void ensureBuilt(Iterable<String> nodeIds) => _fill?.ensureBuilt(nodeIds);

  /// Builds every node that isn't built yet, in the next frame.
  ///
  /// [isComplete] becomes `true` after that frame.
  void completeNow() => _fill?.completeNow();

  /// The number of batches of nodes that the layout built after its first frame, so far,
  /// which, once [isComplete], is the number of frames that it took to build the rest of
  /// the document, besides the frames that built nodes because they became visible.
  int get batchCount => _fill?._batchCount ?? _batchCount;
  int _batchCount = 0;

  void dispose() {
    _isComplete.dispose();
  }

  /// The heights that layouts measured for nodes, by node ID, which a later layout with
  /// this controller uses as estimates, e.g., after the app swaps a reader for an editor.
  final Map<String, double> _measuredHeights = {};

  /// The progressive fill of the layout that this controller is attached to, if any.
  _ProgressiveFill? _fill;
}

/// A [ValueListenable] whose value is always current, but whose listeners are notified
/// only outside of a frame's build, layout, and paint, so that they can call `setState()`.
class _ProgressiveCompletionNotifier extends ChangeNotifier implements ValueListenable<bool> {
  @override
  bool get value => _value;
  bool _value = false;

  /// The value that listeners were last notified of.
  bool _notifiedValue = false;

  bool _isNotificationScheduled = false;
  bool _isDisposed = false;

  void _set(bool value) {
    _value = value;
    if (_isNotificationScheduled) {
      return;
    }

    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      // We're in a build, layout, or paint. Notify after the frame.
      _isNotificationScheduled = true;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        _isNotificationScheduled = false;
        _notify();
      });
      return;
    }
    _notify();
  }

  void _notify() {
    if (_isDisposed || _notifiedValue == _value) {
      return;
    }
    _notifiedValue = _value;
    notifyListeners();
  }

  @override
  void dispose() {
    _isDisposed = true;
    super.dispose();
  }
}

/// A [DocumentLayout] that might not have built the component of every node yet, because
/// it lays out progressively.
///
/// See [SingleColumnProgressiveLayout].
abstract interface class ProgressiveDocumentLayout {
  /// Whether the node with the given [nodeId] isn't built yet, so it has no component.
  bool isComponentDeferred(String nodeId);

  /// Builds the components of the given nodes in the next frame, if they aren't built yet.
  void ensureComponentsBuilt(Iterable<String> nodeIds);
}

/// The anchor of a progressive layout: the child of the column of components whose top
/// edge shouldn't move on screen while the layout builds more nodes.
class _ProgressiveAnchor {
  const _ProgressiveAnchor(this.index, this.top);

  /// The index of the child in the column of components.
  final int index;

  /// The top edge of the child in the sliver, before the layout built more nodes.
  final double top;
}

/// The nodes of a [SingleColumnDocumentLayout] that aren't built yet, and the scheduling
/// of the frames that build them.
///
/// Every node that isn't built is in [_deferred]. Its component builder builds a
/// [_ComponentSlot] without a child, which is a placeholder of the component's estimated
/// size. The nodes are built during the layout of the layout's
/// [_RenderSliverProgressiveAdapter], in a layout callback, so that the frame that builds
/// them lays them out, and paints them. Building a node gives its slot the node's
/// component, so the column of components keeps its children, and lays out only the slots
/// that changed.
class _ProgressiveFill {
  _ProgressiveFill({
    required _SingleColumnDocumentLayoutState layout,
    required SingleColumnProgressiveLayout config,
    required Set<String> deferred,
    required Set<String> built,
  })  : _layout = layout,
        _config = config,
        _deferred = deferred,
        _builtSinceMeasuring = built,
        // Until a batch is measured, the first one is a guess, except for a budget of zero.
        _batchUnits = config.frameBudget > Duration.zero ? config._initialBatchUnits : 1 {
    _attachController(config.controller);
  }

  final _SingleColumnDocumentLayoutState _layout;

  SingleColumnProgressiveLayout get config => _config;
  SingleColumnProgressiveLayout _config;
  set config(SingleColumnProgressiveLayout config) {
    if (identical(config.controller, _config.controller)) {
      _config = config;
      return;
    }
    _detachController();
    _config = config;
    _attachController(config.controller);
  }

  /// The heights that were measured for nodes, by node ID.
  Map<String, double> _measuredHeights = {};

  /// The IDs of the nodes that aren't built.
  final Set<String> _deferred;

  /// The indices, in the column of components, of the children whose nodes might be
  /// deferred, in ascending order, or `null` if they need to be found again, after nodes
  /// were added, removed, or moved.
  ///
  /// The batches pick their nodes from this list, so that they don't scan the nodes that
  /// are built. A node leaves the list when it's built.
  List<int>? _deferredIndices;

  /// The IDs of the deferred nodes that were asked for, which the next layout builds.
  final Set<String> _pending = {};

  /// The IDs of the deferred nodes that the scheduler chose to build in the next layout.
  final Set<String> _pendingBatch = {};

  /// The IDs of the nodes that were built since their heights were last measured.
  final Set<String> _builtSinceMeasuring;

  /// The work of the next batch, in the units of [_workUnitsOf].
  double _batchUnits;

  /// The work that the last frame that built a batch built, in the units of [_workUnitsOf],
  /// which the next batch can grow to twice of, and whether that frame was measured since
  /// the batch was last sized.
  double _unitsOfLastBatchFrame = 0;
  bool _hasMeasuredBatchFrameSinceSizing = false;

  /// The measured time that the batches take per unit of work, in microseconds, or `null`
  /// until a batch was measured.
  double? _microsecondsPerUnit;

  /// The measured time that a frame that builds a batch spends on everything but building,
  /// and laying out, its nodes, in microseconds, or `null` until a frame was measured.
  double? _frameOverheadMicroseconds;

  /// Times the frame that builds the next batch, from the start of the frame.
  final _frameStopwatch = Stopwatch();
  int? _frameTimingCallbackId;

  /// Whether [_frameStopwatch] started at the beginning of this frame.
  bool _isFrameTimed = false;

  /// What this frame built, and how long its layouts took to build it.
  bool _didBuildBatchThisFrame = false;
  double _unitsBuiltThisFrame = 0;
  Duration _layoutTimeThisFrame = Duration.zero;

  /// The number of batches that were built after the first frame.
  int _batchCount = 0;

  /// Fires [SingleColumnProgressiveLayout.safetyTimeout] after the first frame.
  Timer? _safetyTimer;
  bool _hasStartedSafetyTimer = false;

  /// Whether the [SingleColumnProgressiveLayout.safetyTimeout] has passed, after which the
  /// batches are sized to [SingleColumnProgressiveLayout.catchUpFrameBudget], and they go
  /// on while the user scrolls.
  bool _isCatchingUp = false;

  bool _isPostFrameCallbackScheduled = false;

  /// The scroll position whose scrolling this fill waits to end before it builds more.
  ScrollPosition? _waitingForScrollEndOf;

  /// Whether every node was built, after which the layout behaves as if it never laid
  /// out progressively.
  bool get isComplete => _isComplete;
  bool _isComplete = false;

  bool _isDisposed = false;

  /// Whether the layout still lays out progressively.
  bool get isActive => !_isComplete && !_isDisposed;

  bool isDeferred(String nodeId) => _deferred.contains(nodeId);

  void _attachController(SingleColumnProgressiveLayoutController? controller) {
    if (controller == null) {
      _measuredHeights = {..._measuredHeights};
      return;
    }
    controller._fill = this;
    controller._measuredHeights.addAll(_measuredHeights);
    _measuredHeights = controller._measuredHeights;
    controller._isComplete._set(_isComplete);
  }

  void _detachController() {
    final controller = _config.controller;
    if (controller != null && identical(controller._fill, this)) {
      controller._batchCount = _batchCount;
      controller._fill = null;
    }
  }

  void dispose() {
    _isDisposed = true;
    _safetyTimer?.cancel();
    _safetyTimer = null;
    _cancelFrameTiming();
    _stopWaitingForScrollEnd();
    _detachController();
  }

  void ensureBuilt(Iterable<String> nodeIds) {
    if (!isActive) {
      return;
    }

    var didAdd = false;
    for (final nodeId in nodeIds) {
      if (_deferred.contains(nodeId) && _pending.add(nodeId)) {
        didAdd = true;
      }
    }
    if (didAdd) {
      _requestLayout();
    }
  }

  void completeNow() {
    if (!isActive) {
      return;
    }

    _safetyTimer?.cancel();
    _safetyTimer = null;
    _hasStartedSafetyTimer = true;
    _pending.addAll(_deferred);
    _pendingBatch.clear();
    _requestLayout();
  }

  /// Starts building the rest in batches sized to the catch-up frame budget, which go on
  /// while the user scrolls.
  void _startCatchingUp() {
    _safetyTimer = null;
    if (!isActive) {
      return;
    }

    _isCatchingUp = true;
    // Choose the next batch after the next frame, even if the fill waits for the scrolling
    // to end.
    _stopWaitingForScrollEnd();
    _schedulePostFrameCallback();
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  /// Returns the estimated height of the child, in the column of components, of the node
  /// for [viewModel], including its padding, when the column is [columnWidth] wide.
  double estimateHeight(SingleColumnLayoutComponentViewModel viewModel, double columnWidth) {
    return _estimateChildHeight(_config, _measuredHeights, viewModel, columnWidth);
  }

  /// Returns the estimated height of the child, in the column of components, of the node
  /// for [viewModel], including its padding, when the column is [columnWidth] wide.
  ///
  /// The estimate is, in order, the height measured earlier for the node, the
  /// [SingleColumnProgressiveLayout.estimateHeight] of the [config], the built-in estimate
  /// for text, or 24 pixels, plus the view model's vertical padding.
  static double _estimateChildHeight(
    SingleColumnProgressiveLayout config,
    Map<String, double> measuredHeights,
    SingleColumnLayoutComponentViewModel viewModel,
    double columnWidth,
  ) {
    final measuredHeight = measuredHeights[viewModel.nodeId];
    if (measuredHeight != null) {
      return measuredHeight;
    }

    final padding = viewModel.padding;
    final maxWidth = viewModel.maxWidth ?? double.infinity;
    final componentWidth = columnWidth.isFinite ? min(columnWidth, maxWidth) : maxWidth;
    final contentWidth = componentWidth.isFinite ? max(componentWidth - padding.horizontal, 1.0) : 1000.0;

    final contentHeight =
        config.estimateHeight?.call(viewModel, contentWidth) ?? _estimateContentHeight(viewModel, contentWidth);
    return max(contentHeight + padding.vertical, 0.0);
  }

  static double _estimateContentHeight(SingleColumnLayoutComponentViewModel viewModel, double width) {
    if (viewModel is! TextComponentViewModel) {
      return 24;
    }

    final style = viewModel.textStyleBuilder(const {});
    final fontSize = style.fontSize ?? 16;
    final lineHeight = fontSize * (style.height ?? 1.2);

    // Count the characters with the text's length, and the line breaks in its string,
    // which toPlainText() returns without copying when it excludes placeholders.
    final text = viewModel.text;
    var lineBreaks = 0;
    final plainText = text.toPlainText(includePlaceholders: false);
    for (var index = plainText.indexOf('\n'); index >= 0; index = plainText.indexOf('\n', index + 1)) {
      lineBreaks += 1;
    }
    final wrappedLines = (text.length * 0.5 * fontSize / width).ceil();
    return max(wrappedLines + lineBreaks, 1) * lineHeight;
  }

  /// The work of building the component for [viewModel], in units that the batches are
  /// measured in: a fixed amount for the component, plus one unit per text character.
  static double _workUnitsOf(SingleColumnLayoutComponentViewModel? viewModel) {
    return _workUnitsPerComponent + (viewModel is TextComponentViewModel ? viewModel.text.length : 0);
  }

  /// The work of building a component, besides its text, in characters' worth of work.
  static const _workUnitsPerComponent = 100.0;

  /// Updates the deferred nodes after the layout built its components for a new list of
  /// nodes, before the components build.
  ///
  /// The nodes that were added between a node that's built and another node are built, so
  /// that nodes added to content that was built, e.g., on screen, appear there, and nodes
  /// added between two deferred nodes are deferred. Nodes that were removed leave the
  /// deferred set. The first and last nodes are always built.
  void onNodesChanged({
    required List<String> nodeIds,
    required List<int> addedIndices,
    required Map<String, GlobalKey> componentKeys,
  }) {
    if (!isActive) {
      return;
    }

    // The nodes moved, so find their indices again before the next batch.
    _deferredIndices = null;

    _deferred.removeWhere((nodeId) => !componentKeys.containsKey(nodeId));
    _pending.removeWhere((nodeId) => !_deferred.contains(nodeId));
    _pendingBatch.removeWhere((nodeId) => !_deferred.contains(nodeId));
    _builtSinceMeasuring.removeWhere((nodeId) => !componentKeys.containsKey(nodeId));

    // Decide for each run of consecutive added nodes, by the nodes around the run.
    int runStart = 0;
    while (runStart < addedIndices.length) {
      int runEnd = runStart;
      while (runEnd + 1 < addedIndices.length && addedIndices[runEnd + 1] == addedIndices[runEnd] + 1) {
        runEnd += 1;
      }

      final firstIndex = addedIndices[runStart];
      final lastIndex = addedIndices[runEnd];
      final isNextToBuiltNode = firstIndex == 0 ||
          lastIndex == nodeIds.length - 1 ||
          !_deferred.contains(nodeIds[firstIndex - 1]) ||
          !_deferred.contains(nodeIds[lastIndex + 1]);
      for (int index = firstIndex; index <= lastIndex; index += 1) {
        if (isNextToBuiltNode) {
          _builtSinceMeasuring.add(nodeIds[index]);
        } else {
          _deferred.add(nodeIds[index]);
        }
      }

      runStart = runEnd + 1;
    }

    if (nodeIds.isNotEmpty) {
      _deferred.remove(nodeIds.first);
      _deferred.remove(nodeIds.last);
    }

    // An added node that's built, or that must be built with a node that's built, builds
    // the rest of its group in this frame's layout.
    final buildTogether = _config.buildTogether;
    if (buildTogether != null && addedIndices.isNotEmpty) {
      for (final index in addedIndices) {
        final nodeId = nodeIds[index];
        final group = {nodeId, ...?buildTogether(nodeId)};
        if (group.any((member) => componentKeys.containsKey(member) && !_deferred.contains(member))) {
          _pending.addAll(group.where(_deferred.contains));
        }
      }
      if (_pending.isNotEmpty) {
        // We're in the layout's build, before its layout.
        _markAdapterNeedsLayout();
      }
    }
  }

  /// Requests a layout of the progressive adapter, which builds the pending nodes, now,
  /// or, during a frame's build, layout, or paint, after that frame.
  void _requestLayout() {
    if (!isActive) {
      return;
    }
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      _schedulePostFrameCallback();
      return;
    }
    _markAdapterNeedsLayout();
  }

  void _markAdapterNeedsLayout() {
    final adapter = _layout._progressiveAdapter;
    if (adapter != null && adapter.attached) {
      adapter.markNeedsLayout();
    }
  }

  void _schedulePostFrameCallback() {
    if (_isPostFrameCallbackScheduled) {
      return;
    }
    _isPostFrameCallbackScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback(_onPostFrame);
  }

  /// Lays out the [adapter], building the nodes that it needs, and returns after it set
  /// the adapter's geometry.
  ///
  /// Before the layout, it builds the nodes that were asked for, the [_pendingBatch], the
  /// deferred nodes that the last layout put in the visible region, or in the cache extent
  /// below it, the first and last nodes, and the nodes after the last selectable one, and
  /// the nodes that must be built with any of them. After the layout, it builds the
  /// deferred nodes that are still visible, or in the cache extent, until there are none,
  /// and lays out again. When a child above the visible content changed its height, it
  /// corrects the scroll offset so that the visible content stays where it was on screen.
  ///
  /// While an animation drives the scroll offset, there's no correction, because the
  /// animation sets the scroll offset again in the next frame, so the batch, and the
  /// nodes in the cache extent, skip the nodes whose groups reach above the viewport, which
  /// would move the visible content. The nodes that are visible, and the ones that were
  /// asked for, are built with their groups.
  ///
  /// Everything that reads the geometry of the column's children runs in a layout
  /// callback, in which the adapter may read the sizes of its descendants.
  void layoutSliver(_RenderSliverProgressiveAdapter adapter) {
    final constraints = adapter.constraints;
    final stopwatch = Stopwatch()..start();
    final isAnimating = _isAnimationDrivingScrollOffset;

    final requestedNodes = <String>{..._pending};
    _pending.clear();
    final batch = <String>{..._pendingBatch};
    _pendingBatch.clear();

    // Builds the deferred nodes in the visible region, and in the cache extent below it,
    // and returns whether it built any, or `null` if the column's children can't be read.
    bool? buildVisibleNodes({Iterable<String> requestedNodes = const [], Iterable<String> batch = const []}) {
      final column = _layout._componentColumn;
      if (column == null || !_canReadLastLayoutOf(column)) {
        return null;
      }
      // Read the column's children before building, which changes the sizes of some.
      final columnTop = _columnTopInSliver(column);
      final visibleTop = constraints.scrollOffset - columnTop;
      final visibleBottom = visibleTop + constraints.remainingPaintExtent;
      final visibleNodes = _deferredNodesBetween(column, visibleTop, visibleBottom);
      final cacheNodes = _deferredNodesBetween(column, visibleBottom, _buildRegionBottom(constraints, columnTop));
      final viewportTopIndex = _firstChildEndingBelow(column, visibleTop);

      var didBuild = _buildNodes([...requestedNodes, ...visibleNodes]);
      final optionalNodes = [...batch, ...cacheNodes];
      didBuild = _buildNodes(
            isAnimating
                ? optionalNodes.where((nodeId) => !_doesGroupReachAbove(nodeId, viewportTopIndex))
                : optionalNodes,
          ) ||
          didBuild;
      return didBuild;
    }

    _ProgressiveAnchor? anchor;
    var didBuild = false;
    adapter.runLayoutCallback(() {
      final column = _layout._componentColumn;
      if (column != null && _canReadLastLayoutOf(column)) {
        final columnTop = _columnTopInSliver(column);
        final visibleTop = constraints.scrollOffset - columnTop;
        final visibleBottom = visibleTop + constraints.remainingPaintExtent;
        anchor = _findAnchor(column, visibleTop, visibleBottom, columnTop);
      }

      didBuild = buildVisibleNodes(requestedNodes: requestedNodes, batch: batch) ??
          // We don't know where the nodes are, yet, e.g., in the first layout.
          _buildNodes([...requestedNodes, ...batch]);
      didBuild = _buildEnds() || didBuild;
    });
    adapter.layoutChild();

    // Build what's still visible, e.g., because the nodes that were just built are
    // shorter than their estimates.
    for (int pass = 0; pass < _maxBuildPassesPerLayout; pass += 1) {
      var didBuildVisibleNodes = false;
      adapter.runLayoutCallback(() {
        didBuildVisibleNodes = buildVisibleNodes() ?? false;
      });
      if (!didBuildVisibleNodes) {
        break;
      }
      didBuild = true;
      adapter.layoutChild();
    }

    if (batch.isNotEmpty) {
      _batchCount += 1;
      _didBuildBatchThisFrame = true;
    }
    _schedulePostFrameCallback();

    double correction = 0;
    adapter.runLayoutCallback(() {
      if (didBuild) {
        _measureBuiltNodes();
      }

      final column = _layout._componentColumn;
      final anchorBeforeLayout = anchor;
      if (anchorBeforeLayout == null ||
          column == null ||
          !_canReadLastLayoutOf(column) ||
          anchorBeforeLayout.index >= column.childCount ||
          constraints.scrollOffset <= 0 ||
          isAnimating) {
        return;
      }
      final anchorTop = _columnTopInSliver(column) + column.childRectAt(anchorBeforeLayout.index).top;
      correction = max(anchorTop - anchorBeforeLayout.top, -constraints.scrollOffset);
    });
    _layoutTimeThisFrame += stopwatch.elapsed;

    if (didBuild) {
      adapter._didBuildDuringLayout = true;
    }
    if (correction.abs() > _scrollOffsetCorrectionTolerance) {
      adapter.geometry = SliverGeometry(scrollOffsetCorrection: correction);
    }
  }

  /// The most times that a layout builds what's still visible and lays out again.
  static const _maxBuildPassesPerLayout = 8;

  static const _scrollOffsetCorrectionTolerance = 1e-6;

  /// Whether the positions of [column]'s children are those of its children now, which is
  /// the case once it was laid out, until its children change.
  bool _canReadLastLayoutOf(RenderDocumentComponentColumn column) {
    return column.hasSize &&
        !column.childrenChangedSinceLayout &&
        column.childCount == _layout._topToBottomNodeIds.length;
  }

  double _columnTopInSliver(RenderDocumentComponentColumn column) {
    return (column.parentData! as BoxParentData).offset.dy;
  }

  /// The bottom of the region, in the column's coordinates, in which every node is built
  /// during layout: the bottom of the visible region, or of the cache extent below it.
  double _buildRegionBottom(SliverConstraints constraints, double columnTop) {
    final visibleBottom = constraints.scrollOffset + constraints.remainingPaintExtent;
    final cacheBottom = constraints.scrollOffset + constraints.cacheOrigin + constraints.remainingCacheExtent;
    return max(visibleBottom, cacheBottom) - columnTop;
  }

  /// Returns the anchor for a layout that shows the region from [visibleTop] to
  /// [visibleBottom], in the column's coordinates: the first child that's built and
  /// visible, or else the child at the top of the visible region.
  _ProgressiveAnchor? _findAnchor(
    RenderDocumentComponentColumn column,
    double visibleTop,
    double visibleBottom,
    double columnTop,
  ) {
    final childCount = column.childCount;
    final firstVisibleIndex = _firstChildEndingBelow(column, visibleTop);
    if (firstVisibleIndex >= childCount) {
      return null;
    }

    for (int index = firstVisibleIndex; index < childCount; index += 1) {
      final rect = column.childRectAt(index);
      if (rect.top >= visibleBottom) {
        break;
      }
      if (!_isPlaceholder(column.childAt(index))) {
        return _ProgressiveAnchor(index, columnTop + rect.top);
      }
    }
    return _ProgressiveAnchor(firstVisibleIndex, columnTop + column.childRectAt(firstVisibleIndex).top);
  }

  /// Whether [child], a child of the column of components, is the placeholder of a node
  /// that isn't built.
  static bool _isPlaceholder(RenderBox child) => child is _RenderComponentSlot && child.isPlaceholder;

  /// Returns the index of the first child of [column] whose bottom edge is below [dy], or
  /// the number of children if there's none.
  static int _firstChildEndingBelow(RenderDocumentComponentColumn column, double dy) {
    int low = 0;
    int high = column.childCount;
    while (low < high) {
      final middle = (low + high) >> 1;
      if (column.childRectAt(middle).bottom > dy) {
        high = middle;
      } else {
        low = middle + 1;
      }
    }
    return low;
  }

  /// Returns the IDs of the deferred nodes whose placeholders overlap the region from
  /// [top] to [bottom] in [column].
  List<String> _deferredNodesBetween(RenderDocumentComponentColumn column, double top, double bottom) {
    final nodeIds = <String>[];
    final childCount = column.childCount;
    for (int index = _firstChildEndingBelow(column, top); index < childCount; index += 1) {
      final child = column.childAt(index);
      if ((child.parentData! as FlexParentData).offset.dy >= bottom) {
        break;
      }
      if (child is _RenderComponentSlot && child.isPlaceholder && _deferred.contains(child.nodeId)) {
        nodeIds.add(child.nodeId);
      }
    }
    return nodeIds;
  }

  /// Builds the components of the given deferred nodes, and of the nodes that must be
  /// built with them, now, and returns whether it built any.
  ///
  /// Must be called in a layout callback of the layout's progressive adapter, or outside
  /// of a frame.
  bool _buildNodes(Iterable<String> nodeIds) {
    final builders = <_PresenterComponentBuilderState>[];
    final buildTogether = _config.buildTogether;
    final viewModel = _layout.widget.presenter.viewModel;
    final nodesToBuild = [...nodeIds];
    while (nodesToBuild.isNotEmpty) {
      final nodeId = nodesToBuild.removeLast();
      if (!_deferred.remove(nodeId)) {
        continue;
      }
      _removeDeferredIndex(nodeId);
      _builtSinceMeasuring.add(nodeId);
      _unitsBuiltThisFrame += _workUnitsOf(viewModel.getComponentViewModelByNodeId(nodeId));
      builders.addAll(_layout._componentBuilderRegistry.buildersOf(nodeId));

      // Build the nodes that must be built with this one, in this frame, too.
      final group = buildTogether?.call(nodeId);
      if (group != null) {
        nodesToBuild.addAll(group.where(_deferred.contains));
      }
    }
    if (builders.isEmpty) {
      return false;
    }

    final layoutElement = _layout.context as Element;
    layoutElement.owner!.buildScope(layoutElement, () {
      for (final builder in builders) {
        if (builder.mounted) {
          builder._rebuild();
        }
      }
    });
    return true;
  }

  /// Returns the indices of the children whose nodes might be deferred, finding them if
  /// they need to be found.
  List<int> _obtainDeferredIndices() {
    final nodeIds = _layout._topToBottomNodeIds;
    return _deferredIndices ??= [
      for (int index = 0; index < nodeIds.length; index += 1)
        if (_deferred.contains(nodeIds[index])) index,
    ];
  }

  /// Removes the index of the node with the given [nodeId], which was just built, from
  /// [_deferredIndices].
  void _removeDeferredIndex(String nodeId) {
    final indices = _deferredIndices;
    final index = _layout._nodeIndicesById[nodeId];
    if (indices == null || index == null) {
      return;
    }
    final position = _lowerBound(indices, index);
    if (position < indices.length && indices[position] == index) {
      indices.removeAt(position);
    }
  }

  /// Returns the position of the first value in the ascending [values] that's at least
  /// [value], or the length of [values] if there's none.
  static int _lowerBound(List<int> values, int value) {
    int low = 0;
    int high = values.length;
    while (low < high) {
      final middle = (low + high) >> 1;
      if (values[middle] < value) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low;
  }

  /// Builds the first and last nodes, and the nodes after the last selectable one, if
  /// they aren't built, and returns whether it built any.
  ///
  /// Must be called in a layout callback of the layout's progressive adapter.
  bool _buildEnds() {
    final nodeIds = _layout._topToBottomNodeIds;
    if (nodeIds.isEmpty) {
      return false;
    }

    var didBuild = _buildNodes([nodeIds.first, nodeIds.last]);

    // Build the nodes from the end back to the last one that's visually selectable, so
    // that the layout can find the last selectable position.
    for (int index = nodeIds.length - 1; index >= 0; index -= 1) {
      final nodeId = nodeIds[index];
      if (_deferred.contains(nodeId)) {
        didBuild = _buildNodes([nodeId]) || didBuild;
      }

      final component = _layout._nodeIdsToComponentKeys[nodeId]?.currentState;
      if (component is DocumentComponent && component.isVisualSelectionSupported()) {
        break;
      }
    }
    return didBuild;
  }

  /// Records the heights of the nodes that were built since this was last called.
  void _measureBuiltNodes() {
    final column = _layout._componentColumn;
    if (column == null || !_canReadLastLayoutOf(column)) {
      return;
    }

    for (final nodeId in _builtSinceMeasuring) {
      final index = _layout._nodeIndicesById[nodeId];
      if (index == null || index >= column.childCount) {
        continue;
      }
      if (_isPlaceholder(column.childAt(index))) {
        continue;
      }
      _measuredHeights[nodeId] = column.childRectAt(index).height;
    }
    _builtSinceMeasuring.clear();
  }

  /// Starts [_frameStopwatch] at the beginning of the next frame, which builds a batch.
  void _timeNextFrame() {
    if (_frameTimingCallbackId != null) {
      return;
    }
    _frameTimingCallbackId = SchedulerBinding.instance.scheduleFrameCallback((_) {
      _frameTimingCallbackId = null;
      _frameStopwatch
        ..reset()
        ..start();
      _isFrameTimed = true;
    });
  }

  void _cancelFrameTiming() {
    final callbackId = _frameTimingCallbackId;
    if (callbackId != null) {
      SchedulerBinding.instance.cancelFrameCallbackWithId(callbackId);
      _frameTimingCallbackId = null;
    }
    _isFrameTimed = false;
  }

  /// Learns from the frame that just ended how long a unit of work takes, and how long
  /// the rest of a frame takes, if that frame built a batch, and then resets what this
  /// frame built.
  void _measureFrame() {
    final frameTime = _isFrameTimed ? _frameStopwatch.elapsed : null;
    _isFrameTimed = false;
    _frameStopwatch.stop();

    if (_didBuildBatchThisFrame && _unitsBuiltThisFrame > 0) {
      _unitsOfLastBatchFrame = _unitsBuiltThisFrame;
      _hasMeasuredBatchFrameSinceSizing = true;

      final work = max(_layoutTimeThisFrame.inMicroseconds, 1);
      final microsecondsPerUnit = work / _unitsBuiltThisFrame;
      final previousMicrosecondsPerUnit = _microsecondsPerUnit;
      _microsecondsPerUnit = previousMicrosecondsPerUnit == null
          ? microsecondsPerUnit
          : (previousMicrosecondsPerUnit + microsecondsPerUnit) / 2;

      if (frameTime != null) {
        final overhead = max(frameTime.inMicroseconds - work, 0).toDouble();
        final previousOverhead = _frameOverheadMicroseconds;
        _frameOverheadMicroseconds = previousOverhead == null ? overhead : (previousOverhead + overhead) / 2;
      }
    }

    _didBuildBatchThisFrame = false;
    _unitsBuiltThisFrame = 0;
    _layoutTimeThisFrame = Duration.zero;
  }

  /// Sizes the next batch so that its frame takes about [frameBudget], given what the last
  /// frames took, and the rest of those frames, to at most twice what the last frame that
  /// built a batch built, and to at least one node.
  ///
  /// The size changes only after a frame that built a batch was measured, so that a batch
  /// grows by at most twice per frame that built one.
  void _sizeNextBatch(Duration frameBudget) {
    final microsecondsPerUnit = _microsecondsPerUnit;
    if (microsecondsPerUnit == null || !_hasMeasuredBatchFrameSinceSizing) {
      // Nothing was measured since the last batch was sized. Build what was chosen then.
      return;
    }
    _hasMeasuredBatchFrameSinceSizing = false;

    final available = frameBudget.inMicroseconds - (_frameOverheadMicroseconds ?? 0);
    final units = available / microsecondsPerUnit;
    _batchUnits = units.clamp(1.0, max(_unitsOfLastBatchFrame * 2, 1.0));
  }

  void _onPostFrame(Duration _) {
    _isPostFrameCallbackScheduled = false;
    _measureFrame();
    if (!isActive) {
      return;
    }
    if (!_layout.mounted) {
      return;
    }

    if (!_hasStartedSafetyTimer) {
      // This is the end of the first frame.
      _hasStartedSafetyTimer = true;
      _safetyTimer = Timer(_config.safetyTimeout, _startCatchingUp);
    }

    if (_deferred.isEmpty) {
      _complete();
      return;
    }

    if (_pending.isNotEmpty) {
      // Something asked for nodes during the last frame.
      _markAdapterNeedsLayout();
      return;
    }

    final batch = _chooseNextBatch();
    if (batch.isEmpty) {
      return;
    }
    _pendingBatch.addAll(batch);
    _markAdapterNeedsLayout();
    _timeNextFrame();
  }

  void _complete() {
    _isComplete = true;
    _safetyTimer?.cancel();
    _safetyTimer = null;
    _cancelFrameTiming();
    _stopWaitingForScrollEnd();
    _pending.clear();
    _pendingBatch.clear();
    _deferredIndices = null;
    _config.controller?._isComplete._set(true);
  }

  /// The scroll position of the enclosing `Scrollable`, if any.
  ScrollPosition? get _scrollPosition {
    if (!_layout.mounted) {
      return null;
    }
    final scrollable = _layout.context.findAncestorStateOfType<ScrollableState>();
    return scrollable != null && scrollable.position.hasPixels ? scrollable.position : null;
  }

  /// Whether an animation, e.g., `ScrollPosition.animateTo()`, drives the scroll offset.
  bool get _isAnimationDrivingScrollOffset {
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    return _scrollPosition?.activity is DrivenScrollActivity;
  }

  /// Chooses the deferred nodes to build in the next frame, or returns none when nothing
  /// should be built until the scrolling ends.
  ///
  /// The nodes around the viewport, from half a viewport above it to a viewport below it,
  /// come first, then the rest of the nodes below the viewport, and then the rest above
  /// it, each nearest first. While the user scrolls, only the nodes around the viewport
  /// are built, until the safety timeout has passed. While an animation drives the scroll
  /// offset, no node above the viewport is built.
  ///
  /// The batch takes nodes until it reaches the work that [_sizeNextBatch] chose for the
  /// frame budget that applies.
  List<String> _chooseNextBatch() {
    final position = _scrollPosition;
    final isScrolling = position?.isScrollingNotifier.value ?? false;
    final isAnimating = _isAnimationDrivingScrollOffset;
    _sizeNextBatch(_isCatchingUp && !isScrolling ? _config.catchUpFrameBudget : _config.frameBudget);

    final column = _layout._componentColumn;
    final adapter = _layout._progressiveAdapter;
    if (column == null || adapter == null || !_canReadLastLayoutOf(column) || adapter.geometry == null) {
      // We don't know where the nodes are. Build them in order.
      return _fillBatch(_deferred);
    }

    final constraints = adapter.constraints;
    final columnTop = _columnTopInSliver(column);
    final viewportExtent = constraints.viewportMainAxisExtent;
    final viewportTop = constraints.scrollOffset - columnTop;
    final windowTop = viewportTop - viewportExtent * 0.5;
    final windowBottom = viewportTop + viewportExtent * 1.5;

    final firstIndexBelow = _firstChildEndingBelow(column, viewportTop);
    final deferredIndices = _obtainDeferredIndices();
    final firstDeferredBelow = _lowerBound(deferredIndices, firstIndexBelow);

    final batch = <String>[];
    var units = 0.0;
    bool isFull() => units >= _batchUnits;
    void consider(int index) {
      if (index >= column.childCount) {
        return;
      }
      final child = column.childAt(index);
      if (child is! _RenderComponentSlot || !child.isPlaceholder || !_deferred.contains(child.nodeId)) {
        return;
      }
      if (isAnimating && _doesGroupReachAbove(child.nodeId, firstIndexBelow)) {
        // Building the group would move the content that the animation scrolls to.
        return;
      }
      batch.add(child.nodeId);
      units += _workUnitsOf(child.viewModel);
    }

    // The window around the viewport, below it first.
    int below = firstDeferredBelow;
    while (below < deferredIndices.length &&
        !isFull() &&
        deferredIndices[below] < column.childCount &&
        column.childRectAt(deferredIndices[below]).top < windowBottom) {
      consider(deferredIndices[below]);
      below += 1;
    }
    int above = firstDeferredBelow - 1;
    if (!isAnimating) {
      while (above >= 0 &&
          !isFull() &&
          deferredIndices[above] < column.childCount &&
          column.childRectAt(deferredIndices[above]).bottom > windowTop) {
        consider(deferredIndices[above]);
        above -= 1;
      }
    }

    if (!isScrolling || _isCatchingUp) {
      while (below < deferredIndices.length && !isFull()) {
        consider(deferredIndices[below]);
        below += 1;
      }
      if (!isAnimating) {
        while (above >= 0 && !isFull()) {
          consider(deferredIndices[above]);
          above -= 1;
        }
      }
    }

    if (batch.isEmpty) {
      if (position != null && (isScrolling || isAnimating)) {
        _waitForScrollEnd(position);
        return batch;
      }

      // Every deferred node should have a placeholder in the column, but if one doesn't,
      // build it anyway, so that the fill always completes.
      return _fillBatch(_deferred);
    }
    return batch;
  }

  /// Whether any deferred node that must be built with the node with the given [nodeId]
  /// sits above the child at [index] in the column of components.
  bool _doesGroupReachAbove(String nodeId, int index) {
    final buildTogether = _config.buildTogether;
    if (buildTogether == null) {
      return false;
    }

    final visited = {nodeId};
    final nodesToVisit = [nodeId];
    while (nodesToVisit.isNotEmpty) {
      final group = buildTogether(nodesToVisit.removeLast());
      if (group == null) {
        continue;
      }
      for (final member in group) {
        if (!_deferred.contains(member) || !visited.add(member)) {
          continue;
        }
        final memberIndex = _layout._nodeIndicesById[member];
        if (memberIndex != null && memberIndex < index) {
          return true;
        }
        nodesToVisit.add(member);
      }
    }
    return false;
  }

  /// Returns the first of the [candidates] that fit in the next batch.
  List<String> _fillBatch(Iterable<String> candidates) {
    final batch = <String>[];
    var units = 0.0;
    final viewModel = _layout.widget.presenter.viewModel;
    for (final nodeId in candidates) {
      if (units >= _batchUnits) {
        break;
      }
      batch.add(nodeId);
      units += _workUnitsOf(viewModel.getComponentViewModelByNodeId(nodeId));
    }
    return batch;
  }

  void _waitForScrollEnd(ScrollPosition position) {
    if (identical(_waitingForScrollEndOf, position)) {
      return;
    }
    _stopWaitingForScrollEnd();
    _waitingForScrollEndOf = position;
    position.isScrollingNotifier.addListener(_onScrollingChange);
  }

  void _stopWaitingForScrollEnd() {
    _waitingForScrollEndOf?.isScrollingNotifier.removeListener(_onScrollingChange);
    _waitingForScrollEndOf = null;
  }

  void _onScrollingChange() {
    final position = _waitingForScrollEndOf;
    if (position == null || position.isScrollingNotifier.value) {
      return;
    }
    _stopWaitingForScrollEnd();
    if (!isActive) {
      return;
    }

    // Choose the next batch after the next frame, which also lets us find out if the
    // scroll position is still driven by an animation.
    _schedulePostFrameCallback();
    SchedulerBinding.instance.ensureVisualUpdate();
  }
}

/// The child of the column of components of a progressive [SingleColumnDocumentLayout]
/// for one node: a placeholder of the component's estimated size while the node isn't
/// built, and the node's component, its [child], once it is.
///
/// The slot stays in the column when its node is built, and after every node is built, so
/// that building a node doesn't replace a child of the column, which then lays out only
/// the slots that changed. See [RenderDocumentComponentColumn].
class _ComponentSlot extends SingleChildRenderObjectWidget {
  const _ComponentSlot({
    required this.nodeId,
    required this.viewModel,
    required this.fill,
    super.child,
  });

  final String nodeId;

  /// The view model that the placeholder estimates its height from, while there's no
  /// [child].
  final SingleColumnLayoutComponentViewModel? viewModel;

  final _ProgressiveFill fill;

  @override
  _RenderComponentSlot createRenderObject(BuildContext context) {
    return _RenderComponentSlot(nodeId: nodeId, viewModel: viewModel, fill: fill);
  }

  @override
  void updateRenderObject(BuildContext context, _RenderComponentSlot renderObject) {
    renderObject
      ..nodeId = nodeId
      ..viewModel = viewModel
      ..fill = fill;
  }
}

class _RenderComponentSlot extends RenderProxyBox {
  _RenderComponentSlot({
    required String nodeId,
    required SingleColumnLayoutComponentViewModel? viewModel,
    required _ProgressiveFill fill,
  })  : _nodeId = nodeId,
        _viewModel = viewModel,
        _fill = fill;

  /// Whether this slot stands in for the component of a node that isn't built, at the
  /// component's estimated size.
  bool get isPlaceholder => child == null;

  String get nodeId => _nodeId;
  String _nodeId;
  set nodeId(String nodeId) {
    if (nodeId == _nodeId) {
      return;
    }
    _nodeId = nodeId;
    _onEstimateChanged();
  }

  SingleColumnLayoutComponentViewModel? get viewModel => _viewModel;
  SingleColumnLayoutComponentViewModel? _viewModel;
  set viewModel(SingleColumnLayoutComponentViewModel? viewModel) {
    final previousViewModel = _viewModel;
    if (identical(viewModel, previousViewModel)) {
      return;
    }
    if (!isPlaceholder) {
      // The estimate isn't used while the slot holds its component.
      _viewModel = viewModel;
      _estimatedHeights.clear();
      return;
    }
    final isSame = viewModel != null &&
        previousViewModel != null &&
        viewModel == previousViewModel &&
        (viewModel is! TextComponentViewModel ||
            viewModel.textStyleBuilder(const {}) ==
                (previousViewModel as TextComponentViewModel).textStyleBuilder(const {}));
    _viewModel = viewModel;
    if (!isSame) {
      _onEstimateChanged();
    }
  }

  _ProgressiveFill get fill => _fill;
  _ProgressiveFill _fill;
  set fill(_ProgressiveFill fill) {
    if (identical(fill, _fill)) {
      return;
    }
    _fill = fill;
    _onEstimateChanged();
  }

  void _onEstimateChanged() {
    _estimatedHeights.clear();
    if (isPlaceholder) {
      markNeedsLayout();
    }
  }

  /// The estimated heights, by the width of the column.
  final _estimatedHeights = <double, double>{};

  double _estimateHeight(double columnWidth) {
    final viewModel = _viewModel;
    if (viewModel == null) {
      return 0;
    }
    return _estimatedHeights[columnWidth] ??= _fill.estimateHeight(viewModel, columnWidth);
  }

  @override
  void markNeedsLayout() {
    final column = parent;
    if (column is! RenderDocumentComponentColumn) {
      super.markNeedsLayout();
      return;
    }

    // Tell the column that this slot needs layout, so that it lays out only the slots
    // that do.
    column._markSlotNeedsLayout(this, super.markNeedsLayout);
  }

  @override
  Size computeSizeForNoChild(BoxConstraints constraints) {
    final maxWidth = _viewModel?.maxWidth ?? double.infinity;
    final width =
        constraints.hasBoundedWidth ? min(maxWidth, constraints.maxWidth) : (maxWidth.isFinite ? maxWidth : 0.0);
    return constraints.constrain(Size(width, _estimateHeight(constraints.maxWidth)));
  }

  @override
  double computeMinIntrinsicHeight(double width) =>
      isPlaceholder ? _estimateHeight(width) : super.computeMinIntrinsicHeight(width);

  @override
  double computeMaxIntrinsicHeight(double width) =>
      isPlaceholder ? _estimateHeight(width) : super.computeMaxIntrinsicHeight(width);

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties.add(StringProperty("nodeId", _nodeId));
    properties.add(FlagProperty("isPlaceholder", value: isPlaceholder, ifTrue: "placeholder"));
  }
}

/// A [SliverToBoxAdapter] for a progressive [SingleColumnDocumentLayout], which builds the
/// nodes that the layout needs during its own layout, and corrects the scroll offset so
/// that the visible content doesn't move.
class _SliverProgressiveAdapter extends SingleChildRenderObjectWidget {
  const _SliverProgressiveAdapter({
    required this.fill,
    required super.child,
  });

  final _ProgressiveFill? fill;

  @override
  _RenderSliverProgressiveAdapter createRenderObject(BuildContext context) {
    return _RenderSliverProgressiveAdapter(fill: fill);
  }

  @override
  void updateRenderObject(BuildContext context, _RenderSliverProgressiveAdapter renderObject) {
    renderObject.fill = fill;
  }
}

class _RenderSliverProgressiveAdapter extends RenderSliverToBoxAdapter implements ContentLayersContentLayoutReporter {
  _RenderSliverProgressiveAdapter({
    _ProgressiveFill? fill,
  }) : _fill = fill;

  _ProgressiveFill? get fill => _fill;
  _ProgressiveFill? _fill;
  set fill(_ProgressiveFill? fill) {
    if (identical(fill, _fill)) {
      return;
    }
    _fill = fill;
    markNeedsLayout();
  }

  /// Whether a layout built components since the last time that the enclosing
  /// `ContentLayers` asked.
  bool _didBuildDuringLayout = false;

  @override
  bool takeLayerRebuildRequest() {
    final didBuild = _didBuildDuringLayout;
    _didBuildDuringLayout = false;
    return didBuild;
  }

  @override
  void performLayout() {
    final fill = _fill;
    if (fill == null || !fill.isActive || child == null) {
      super.performLayout();
      return;
    }

    fill.layoutSliver(this);
  }

  /// Lays out the child, and sets the geometry, as a [RenderSliverToBoxAdapter] does.
  void layoutChild() => super.performLayout();

  /// Runs [callback] during this sliver's layout, in a layout callback, in which it may
  /// build widgets below this sliver.
  void runLayoutCallback(VoidCallback callback) {
    invokeLayoutCallback<SliverConstraints>((_) => callback());
  }
}
