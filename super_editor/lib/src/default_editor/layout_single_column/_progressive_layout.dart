part of '_layout.dart';

/// Configures a [SingleColumnDocumentLayout] to show its first frame before it builds
/// every component, and to build the rest over the following frames.
///
/// The first frame builds the components around the initial scroll offset, from half a
/// screen above it to one and a half screens below it, plus the first node, the last
/// node, and the nodes after the last selectable one. Every other node is a placeholder
/// of estimated height, until a later frame builds it. Those frames build the nodes below
/// the viewport first, nearest first, and then the nodes above it, a batch at a time,
/// sized to take about [frameBudget] each.
///
/// The visible content doesn't move while the rest is built:
///
///  * a frame builds every placeholder that becomes visible, e.g., after a jump, or a
///    fling, before it paints;
///  * when the nodes that are built above the visible content are taller, or shorter,
///    than their estimates, the layout corrects the scroll offset by the difference;
///  * while the user scrolls, only the nodes around the viewport are built, and while an
///    animation drives the scroll offset, e.g., `ScrollPosition.animateTo()`, no node
///    above the viewport is built, so that the animation lands where it was aimed.
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
    this.frameBudget = const Duration(milliseconds: 6),
    this.initialScrollOffset,
    this.controller,
    this.safetyTimeout = const Duration(seconds: 3),
  })  : _windowExtentAboveOffset = 0.5,
        _windowExtentBelowOffset = 1.5,
        _initialBatchNodeCount = 16,
        _initialBatchCharacterCount = 4000;

  /// The configuration that [debugProgressiveByDefault] gives every layout that isn't
  /// configured: a first frame that builds only what's visible, and batches of one node.
  const SingleColumnProgressiveLayout._debugDefault()
      : estimateHeight = null,
        frameBudget = Duration.zero,
        initialScrollOffset = null,
        controller = null,
        safetyTimeout = const Duration(seconds: 3),
        _windowExtentAboveOffset = 0,
        _windowExtentBelowOffset = 0,
        _initialBatchNodeCount = 1,
        _initialBatchCharacterCount = 1;

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

  /// About how long each frame after the first one should spend building, and laying out,
  /// more nodes.
  ///
  /// The size of each batch adapts to the time that the last batch took.
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

  /// How long the layout waits, after its first frame, before it builds every node that
  /// isn't built yet, at once.
  final Duration safetyTimeout;

  /// The extents of the first frame's window, above and below the initial scroll offset,
  /// as fractions of the screen height.
  final double _windowExtentAboveOffset;
  final double _windowExtentBelowOffset;

  /// The number of nodes, and the number of text characters, in the first batch after the
  /// first frame. A batch stops at whichever it reaches first.
  final int _initialBatchNodeCount;
  final int _initialBatchCharacterCount;
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
/// [_ComponentPlaceholder] instead of its component. The nodes are built during the layout
/// of the layout's [_RenderSliverProgressiveAdapter], in a layout callback, so that the
/// frame that builds them lays them out, and paints them.
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
        _batchNodeCount = config._initialBatchNodeCount,
        _batchCharacterCount = config._initialBatchCharacterCount {
    _attachController(config.controller);
    _safetyTimer = Timer(config.safetyTimeout, completeNow);
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

  /// The IDs of the deferred nodes to build in the next layout.
  final Set<String> _pending = {};

  /// Whether [_pending] holds a batch that the scheduler chose, whose time adapts the size
  /// of the next batch.
  bool _isPendingABatch = false;

  /// The IDs of the nodes that were built since their heights were last measured.
  final Set<String> _builtSinceMeasuring;

  int _batchNodeCount;
  int _batchCharacterCount;

  /// The number of batches that were built after the first frame.
  int _batchCount = 0;

  Timer? _safetyTimer;
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
    _pending.addAll(_deferred);
    _isPendingABatch = false;
    _requestLayout();
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

  /// The number of characters that a batch counts for [viewModel].
  static int _characterCount(SingleColumnLayoutComponentViewModel viewModel) {
    return viewModel is TextComponentViewModel ? max(viewModel.text.length, 1) : 100;
  }

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

    _deferred.removeWhere((nodeId) => !componentKeys.containsKey(nodeId));
    _pending.removeWhere((nodeId) => !_deferred.contains(nodeId));
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
  }

  /// Requests a layout of the progressive adapter, which builds the [_pending] nodes, now,
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
  /// Before the layout, it builds the [_pending] nodes, the deferred nodes that the last
  /// layout put in the visible region, the first and last nodes, and the nodes after the
  /// last selectable one. After the layout, it builds the deferred nodes that are still
  /// visible, until there are none, and lays out again. When a child above the visible
  /// content changed its height, it corrects the scroll offset so that the visible
  /// content stays where it was on screen.
  ///
  /// Everything that reads the geometry of the column's children runs in a layout
  /// callback, in which the adapter may read the sizes of its descendants.
  void layoutSliver(_RenderSliverProgressiveAdapter adapter) {
    final constraints = adapter.constraints;
    final stopwatch = Stopwatch()..start();
    final isBatch = _isPendingABatch;
    _isPendingABatch = false;

    final nodesToBuild = <String>{..._pending};
    _pending.clear();

    _ProgressiveAnchor? anchor;
    var didBuild = false;
    adapter.runLayoutCallback(() {
      final column = _layout._componentColumn;
      if (column != null && _canReadLastLayoutOf(column)) {
        final columnTop = _columnTopInSliver(column);
        final visibleTop = constraints.scrollOffset - columnTop;
        final visibleBottom = visibleTop + constraints.remainingPaintExtent;
        anchor = _findAnchor(column, visibleTop, visibleBottom, columnTop);
        nodesToBuild.addAll(_deferredNodesBetween(column, visibleTop, _buildRegionBottom(constraints, columnTop)));
      }

      didBuild = _buildNodes(nodesToBuild);
      didBuild = _buildEnds() || didBuild;
    });
    adapter.layoutChild();

    // Build what's still visible, e.g., because the nodes that were just built are
    // shorter than their estimates.
    for (int pass = 0; pass < _maxBuildPassesPerLayout; pass += 1) {
      var didBuildVisibleNodes = false;
      adapter.runLayoutCallback(() {
        final column = _layout._componentColumn;
        if (column == null || !_canReadLastLayoutOf(column)) {
          return;
        }
        final columnTop = _columnTopInSliver(column);
        final visibleTop = constraints.scrollOffset - columnTop;
        didBuildVisibleNodes =
            _buildNodes(_deferredNodesBetween(column, visibleTop, _buildRegionBottom(constraints, columnTop)));
      });
      if (!didBuildVisibleNodes) {
        break;
      }
      didBuild = true;
      adapter.layoutChild();
    }
    stopwatch.stop();

    if (isBatch) {
      _batchCount += 1;
      _adaptBatchSize(stopwatch.elapsed);
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
          _isAnimationDrivingScrollOffset) {
        return;
      }
      final anchorTop = _columnTopInSliver(column) + column.childRectAt(anchorBeforeLayout.index).top;
      correction = max(anchorTop - anchorBeforeLayout.top, -constraints.scrollOffset);
    });

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
      if (column.childAt(index) is! _RenderComponentPlaceholder) {
        return _ProgressiveAnchor(index, columnTop + rect.top);
      }
    }
    return _ProgressiveAnchor(firstVisibleIndex, columnTop + column.childRectAt(firstVisibleIndex).top);
  }

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
      if (child is _RenderComponentPlaceholder && _deferred.contains(child.nodeId)) {
        nodeIds.add(child.nodeId);
      }
    }
    return nodeIds;
  }

  /// Builds the components of the given deferred nodes, now, and returns whether it built
  /// any.
  ///
  /// Must be called in a layout callback of the layout's progressive adapter, or outside
  /// of a frame.
  bool _buildNodes(Iterable<String> nodeIds) {
    final builders = <_PresenterComponentBuilderState>[];
    for (final nodeId in nodeIds) {
      if (_deferred.remove(nodeId)) {
        _builtSinceMeasuring.add(nodeId);
        builders.addAll(_layout._componentBuilderRegistry.buildersOf(nodeId));
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
      if (column.childAt(index) is _RenderComponentPlaceholder) {
        continue;
      }
      _measuredHeights[nodeId] = column.childRectAt(index).height;
    }
    _builtSinceMeasuring.clear();
  }

  void _adaptBatchSize(Duration elapsed) {
    final budget = _config.frameBudget.inMicroseconds;
    final spent = max(elapsed.inMicroseconds, 1);
    final ratio = (budget / spent).clamp(0.5, 2.0);
    _batchNodeCount = max((_batchNodeCount * ratio).round(), 1);
    _batchCharacterCount = max((_batchCharacterCount * ratio).round(), 1);
  }

  void _onPostFrame(Duration _) {
    _isPostFrameCallbackScheduled = false;
    if (!isActive) {
      return;
    }
    if (!_layout.mounted) {
      return;
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
    _pending.addAll(batch);
    _isPendingABatch = true;
    _markAdapterNeedsLayout();
  }

  void _complete() {
    _isComplete = true;
    _safetyTimer?.cancel();
    _safetyTimer = null;
    _stopWaitingForScrollEnd();
    _pending.clear();
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
  /// are built. While an animation drives the scroll offset, no node above the viewport is
  /// built.
  List<String> _chooseNextBatch() {
    final column = _layout._componentColumn;
    final adapter = _layout._progressiveAdapter;
    if (column == null || adapter == null || !_canReadLastLayoutOf(column) || adapter.geometry == null) {
      // We don't know where the nodes are. Build them in order.
      return _fillBatch(_deferred.toList());
    }

    final position = _scrollPosition;
    final isScrolling = position?.isScrollingNotifier.value ?? false;
    final isAnimating = _isAnimationDrivingScrollOffset;

    final constraints = adapter.constraints;
    final columnTop = _columnTopInSliver(column);
    final viewportExtent = constraints.viewportMainAxisExtent;
    final viewportTop = constraints.scrollOffset - columnTop;
    final windowTop = viewportTop - viewportExtent * 0.5;
    final windowBottom = viewportTop + viewportExtent * 1.5;

    final childCount = column.childCount;
    final firstIndexBelow = _firstChildEndingBelow(column, viewportTop);

    final batch = <String>[];
    var characterCount = 0;
    bool isFull() => batch.length >= _batchNodeCount || characterCount >= _batchCharacterCount;
    void consider(int index) {
      final child = column.childAt(index);
      if (child is _RenderComponentPlaceholder && _deferred.contains(child.nodeId)) {
        batch.add(child.nodeId);
        characterCount += _characterCount(child.viewModel);
      }
    }

    // The window around the viewport, below it first.
    int below = firstIndexBelow;
    while (below < childCount && !isFull() && column.childRectAt(below).top < windowBottom) {
      consider(below);
      below += 1;
    }
    int above = firstIndexBelow - 1;
    if (!isAnimating) {
      while (above >= 0 && !isFull() && column.childRectAt(above).bottom > windowTop) {
        consider(above);
        above -= 1;
      }
    }

    if (!isScrolling) {
      while (below < childCount && !isFull()) {
        consider(below);
        below += 1;
      }
      if (!isAnimating) {
        while (above >= 0 && !isFull()) {
          consider(above);
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
      return _fillBatch(_deferred.toList());
    }
    return batch;
  }

  List<String> _fillBatch(List<String> candidates) {
    final batch = <String>[];
    var characterCount = 0;
    for (final nodeId in candidates) {
      if (batch.length >= _batchNodeCount || characterCount >= _batchCharacterCount) {
        break;
      }
      batch.add(nodeId);
      final viewModel = _layout.widget.presenter.viewModel.getComponentViewModelByNodeId(nodeId);
      characterCount += viewModel != null ? _characterCount(viewModel) : 1;
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

/// A leaf render box that stands in for the component of a node that a progressive
/// [SingleColumnDocumentLayout] hasn't built yet, at the component's estimated size.
class _ComponentPlaceholder extends LeafRenderObjectWidget {
  const _ComponentPlaceholder({
    required this.nodeId,
    required this.viewModel,
    required this.fill,
  });

  final String nodeId;
  final SingleColumnLayoutComponentViewModel viewModel;
  final _ProgressiveFill fill;

  @override
  _RenderComponentPlaceholder createRenderObject(BuildContext context) {
    return _RenderComponentPlaceholder(nodeId: nodeId, viewModel: viewModel, fill: fill);
  }

  @override
  void updateRenderObject(BuildContext context, _RenderComponentPlaceholder renderObject) {
    renderObject
      ..nodeId = nodeId
      ..viewModel = viewModel
      ..fill = fill;
  }
}

class _RenderComponentPlaceholder extends RenderBox {
  _RenderComponentPlaceholder({
    required String nodeId,
    required SingleColumnLayoutComponentViewModel viewModel,
    required _ProgressiveFill fill,
  })  : _nodeId = nodeId,
        _viewModel = viewModel,
        _fill = fill;

  String get nodeId => _nodeId;
  String _nodeId;
  set nodeId(String nodeId) {
    if (nodeId == _nodeId) {
      return;
    }
    _nodeId = nodeId;
    _estimatedHeights.clear();
    markNeedsLayout();
  }

  SingleColumnLayoutComponentViewModel get viewModel => _viewModel;
  SingleColumnLayoutComponentViewModel _viewModel;
  set viewModel(SingleColumnLayoutComponentViewModel viewModel) {
    if (identical(viewModel, _viewModel)) {
      return;
    }
    final isSame = viewModel == _viewModel &&
        (viewModel is! TextComponentViewModel ||
            viewModel.textStyleBuilder(const {}) == (_viewModel as TextComponentViewModel).textStyleBuilder(const {}));
    _viewModel = viewModel;
    if (!isSame) {
      _estimatedHeights.clear();
      markNeedsLayout();
    }
  }

  _ProgressiveFill get fill => _fill;
  _ProgressiveFill _fill;
  set fill(_ProgressiveFill fill) {
    if (identical(fill, _fill)) {
      return;
    }
    _fill = fill;
    _estimatedHeights.clear();
    markNeedsLayout();
  }

  /// The estimated heights, by the width of the column.
  final _estimatedHeights = <double, double>{};

  double _estimateHeight(double columnWidth) {
    return _estimatedHeights[columnWidth] ??= _fill.estimateHeight(_viewModel, columnWidth);
  }

  Size _computeSize(BoxConstraints constraints) {
    final maxWidth = _viewModel.maxWidth ?? double.infinity;
    final width =
        constraints.hasBoundedWidth ? min(maxWidth, constraints.maxWidth) : (maxWidth.isFinite ? maxWidth : 0.0);
    return constraints.constrain(Size(width, _estimateHeight(constraints.maxWidth)));
  }

  @override
  void performLayout() {
    size = _computeSize(constraints);
  }

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) => _computeSize(constraints);

  @override
  double computeMinIntrinsicWidth(double height) => 0;

  @override
  double computeMaxIntrinsicWidth(double height) => 0;

  @override
  double computeMinIntrinsicHeight(double width) => _estimateHeight(width);

  @override
  double computeMaxIntrinsicHeight(double width) => _estimateHeight(width);

  @override
  bool hitTestSelf(Offset position) => false;

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties.add(StringProperty("nodeId", _nodeId));
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
