import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:super_editor/src/core/document.dart';
import 'package:super_editor/src/core/document_layout.dart';
import 'package:super_editor/src/core/document_selection.dart';
import 'package:super_editor/src/default_editor/text.dart';
import 'package:super_editor/src/infrastructure/_logging.dart';

import '_presenter.dart';

/// Displays a document in a single-column layout.
///
/// [SingleColumnDocumentLayout] displays a series of visual "components".
/// The components are positioned vertically in a column with some space
/// in between.
///
/// The given [presenter] produces component view models, and each of those
/// component view models are turned into visual components by the given
/// [componentBuilders].
///
/// [SingleColumnDocumentLayout]'s `State` object implements [DocumentLayout],
/// which establishes a contract for querying many document layout
/// properties. To use the [DocumentLayout] API, assign a `GlobalKey`
/// to a [SingleColumnDocumentLayout], obtain its `State` object, and then
/// cast that `State` object to a [DocumentLayout].
class SingleColumnDocumentLayout extends StatefulWidget {
  const SingleColumnDocumentLayout({
    Key? key,
    required this.presenter,
    required this.componentBuilders,
    this.onBuildScheduled,
    this.wrapWithSliverAdapter = true,
    this.showDebugPaint = false,
  }) : super(key: key);

  /// Presenter that provides a view model for a complete single-column
  /// document layout.
  final SingleColumnLayoutPresenter presenter;

  /// Builders for every type of component that this layout displays.
  ///
  /// Every type of [SingleColumnLayoutComponentViewModel] that might
  /// appear in the displayed `document` should have a
  /// [SingleColumnDocumentComponentBuilder] that knows how to render
  /// that piece of content.
  final List<ComponentBuilder> componentBuilders;

  /// Callback that's invoked whenever this widget schedules a build with
  /// `setState()`.
  ///
  /// This callback was added to facilitate the ContentLayers widget, because
  /// Flutter makes it impossible to monitor the dirty state of a sub-tree.
  ///
  /// TODO: Get rid of this as soon as Flutter makes it possible to monitor
  ///       dirty subtrees.
  final VoidCallback? onBuildScheduled;

  /// Whether to wrap this layout with a [SliverToBoxAdapter] so that this layout
  /// can be displayed within a `Sliver`.
  final bool wrapWithSliverAdapter;

  /// Adds a debugging UI to the document layout, when true.
  final bool showDebugPaint;

  @override
  State createState() => _SingleColumnDocumentLayoutState();
}

class _SingleColumnDocumentLayoutState extends State<SingleColumnDocumentLayout> implements DocumentLayout {
  final Map<String, GlobalKey> _nodeIdsToComponentKeys = {};
  final Map<GlobalKey, String> _componentKeysToNodeIds = {};

  // Keys are cached in top-to-bottom order so that we can visually
  // traverse components without repeatedly querying a `Document`
  // to determine component ordering.
  final List<GlobalKey> _topToBottomComponentKeys = [];

  late SingleColumnLayoutPresenterChangeListener _presenterListener;

  /// The component builders in the tree, by node ID, so that this layout's one
  /// presenter listener can tell only the components that changed to rebuild.
  final _componentBuilderRegistry = _ComponentBuilderRegistry();

  /// The builder widget that was last built for each node, by node ID.
  ///
  /// When this layout rebuilds, a node's builder widget is reused, as the
  /// identical instance, while its inputs don't change, so that Flutter skips
  /// that node's component altogether. A component that changed is rebuilt by
  /// its builder, which [_componentBuilderRegistry] tells to rebuild.
  Map<String, _PresenterComponentBuilder> _builderWidgetsByNodeId = {};

  /// Whether the next build should give every node a new builder widget, so that
  /// every builder checks whether its component needs to rebuild, which is the
  /// case after components were added, moved, or removed.
  bool _checkEveryComponentInNextBuild = false;

  /// The component builders that the builder widgets were given, which stays the
  /// same list while the layout's [SingleColumnDocumentLayout.componentBuilders]
  /// hold the same builders, even when the list itself is a new one.
  List<ComponentBuilder>? _componentBuilders;

  // The key for the renderBox that contains the actual document layout.
  final GlobalKey _boxKey = GlobalKey();
  BuildContext get boxContext => _boxKey.currentContext!;

  @override
  void initState() {
    super.initState();

    _presenterListener = SingleColumnLayoutPresenterChangeListener(
      onPresenterMarkedDirty: _onPresenterMarkedDirty,
      onViewModelChange: _onViewModelChange,
    );
    widget.presenter.addChangeListener(_presenterListener);

    // Build the view model now, so that any further changes to the
    // presenter send us a dirty notification.
    widget.presenter.updateViewModel();
  }

  @override
  void didUpdateWidget(SingleColumnDocumentLayout oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.presenter != oldWidget.presenter) {
      oldWidget.presenter.removeChangeListener(_presenterListener);
      widget.presenter.addChangeListener(_presenterListener);

      widget.presenter.updateViewModel();
    }
  }

  @override
  void dispose() {
    widget.presenter.removeChangeListener(_presenterListener);
    super.dispose();
  }

  @override
  void reassemble() {
    super.reassemble();

    // Build new builder widgets after a hot reload.
    _builderWidgetsByNodeId = {};
  }

  Future<void> _onPresenterMarkedDirty() async {
    editorLayoutLog.fine("Layout presenter is dirty. Instructing it to update the view model.");
    widget.presenter.updateViewModel();
  }

  void _onViewModelChange({
    required List<String> addedComponents,
    required List<String> movedComponents,
    required List<String> changedComponents,
    required List<String> removedComponents,
  }) {
    if (addedComponents.isNotEmpty || movedComponents.isNotEmpty || removedComponents.isNotEmpty) {
      setState(() {
        // Re-flow the whole layout.
        //
        // The presenter reports a node that moved as moved, and a node whose component
        // changed type as removed, even if its view model changed, and a stylesheet rule
        // that depends on a node's neighbors, or on its index, can restyle a node that
        // the presenter doesn't report at all. Give every builder a new widget, as this
        // layout did before it reused builder widgets, so that every builder checks its
        // view model during this layout's build. A builder only rebuilds its component
        // if its view model changed.
        _checkEveryComponentInNextBuild = true;
      });
    }

    // Rebuild the components whose view models changed.
    _componentBuilderRegistry.notifyViewModelChanged(changedComponents);
  }

  @override
  DocumentPosition? getDocumentPositionAtOffset(Offset documentOffset) {
    editorLayoutLog.info('Getting document position at exact offset: $documentOffset');

    final componentKey = _findComponentAtOffset(documentOffset);
    if (componentKey == null || componentKey.currentContext == null) {
      return null;
    }

    return _getDocumentPositionInComponentNearOffset(componentKey, documentOffset);
  }

  @override
  DocumentPosition? getDocumentPositionNearestToOffset(Offset rawDocumentOffset) {
    // Constrain the incoming offset to sit within the width
    // of this document layout.
    final docBox = boxContext.findRenderObject() as RenderBox;
    final documentOffset = Offset(
      // Notice the +1/-1. Experimentally, I determined that if we confine
      // to the exact width, that x-value is considered outside the
      // component RenderBox's. However, 1px less than that is
      // considered to be within the component RenderBox's.
      rawDocumentOffset.dx.clamp(1.0, max(docBox.size.width - 1.0, 1.0)),
      rawDocumentOffset.dy,
    );
    editorLayoutLog.info('Getting document position near offset: $documentOffset');

    if (_isAboveStartOfContent(documentOffset)) {
      // The given offset is above the start of the content.
      // Return the position at the start of the first node.
      final firstPosition = _findFirstPosition();
      if (firstPosition != null) {
        return firstPosition;
      }
    }

    if (_isBeyondDocumentEnd(documentOffset)) {
      // The given offset is beyond the end of the content.
      // Return the position at the end of the last node.
      final lastPosition = _findLastPosition();
      if (lastPosition != null) {
        return lastPosition;
      }
    }

    final componentKey = _findComponentClosestToOffset(documentOffset);
    if (componentKey == null || componentKey.currentContext == null) {
      return null;
    }

    return _getDocumentPositionInComponentNearOffset(componentKey, documentOffset);
  }

  DocumentPosition? _getDocumentPositionInComponentNearOffset(GlobalKey componentKey, Offset documentOffset) {
    final component = componentKey.currentState as DocumentComponent;
    final componentBox = componentKey.currentContext!.findRenderObject() as RenderBox;
    editorLayoutLog.info(' - found node at position: $component');
    final componentOffset = _componentOffset(componentBox, documentOffset);
    final componentPosition = component.getPositionAtOffset(componentOffset);

    if (componentPosition == null) {
      return null;
    }

    final selectionAtOffset = DocumentPosition(
      nodeId: _componentKeysToNodeIds[componentKey]!,
      nodePosition: componentPosition,
    );
    editorLayoutLog.info(' - selection at offset: $selectionAtOffset');
    return selectionAtOffset;
  }

  /// Returns whether or not [documentOffset] is above the start of the document's content.
  bool _isAboveStartOfContent(Offset documentOffset) {
    if (_topToBottomComponentKeys.isEmpty) {
      // There is no component in the document.
      return true;
    }

    final componentKey = _topToBottomComponentKeys.first;
    final componentBox = componentKey.currentContext!.findRenderObject() as RenderBox;
    final offsetAtComponent = _componentOffset(componentBox, documentOffset);

    return offsetAtComponent.dy < 0.0;
  }

  /// Returns whether or not [documentOffset] is beyond the end of the document.
  bool _isBeyondDocumentEnd(Offset documentOffset) {
    if (_topToBottomComponentKeys.isEmpty) {
      // There is no component in the document.
      return true;
    }

    final componentKey = _topToBottomComponentKeys.last;
    final componentBox = componentKey.currentContext!.findRenderObject() as RenderBox;
    final offsetAtComponent = _componentOffset(componentBox, documentOffset);

    return offsetAtComponent.dy > componentBox.size.height;
  }

  @override
  Rect? getEdgeForPosition(DocumentPosition position) {
    final component = getComponentByNodeId(position.nodeId);
    if (component == null) {
      editorLayoutLog.info('Could not find any component for node position: $position');
      return null;
    }

    final componentEdge = component.getEdgeForPosition(position.nodePosition);

    final componentBox = component.context.findRenderObject() as RenderBox;
    final docOffset = componentBox.localToGlobal(Offset.zero, ancestor: boxContext.findRenderObject());

    return componentEdge.translate(docOffset.dx, docOffset.dy);
  }

  @override
  Rect? getRectForPosition(DocumentPosition position) {
    final component = getComponentByNodeId(position.nodeId);
    if (component == null) {
      editorLayoutLog.info('Could not find any component for node position: $position');
      return null;
    }

    final componentRect = component.getRectForPosition(position.nodePosition);

    final componentBox = component.context.findRenderObject() as RenderBox;
    final docOffset = componentBox.localToGlobal(Offset.zero, ancestor: boxContext.findRenderObject());

    return componentRect.translate(docOffset.dx, docOffset.dy);
  }

  @override
  CaretGeometry getCaretForPosition(DocumentPosition position) {
    final component = getComponentByNodeId(position.nodeId);
    if (component == null) {
      throw Exception('Could not find any component for node position: $position');
    }

    final componentCaret = component.getCaretForPosition(position.nodePosition);

    final componentBox = component.context.findRenderObject() as RenderBox;
    final componentOffsetInDocument = componentBox.localToGlobal(Offset.zero, ancestor: boxContext.findRenderObject());

    return componentCaret.translate(componentOffsetInDocument);
  }

  @override
  Rect? getRectForSelection(DocumentPosition base, DocumentPosition extent) {
    final baseComponent = getComponentByNodeId(base.nodeId);
    final extentComponent = getComponentByNodeId(extent.nodeId);
    if (baseComponent == null || extentComponent == null) {
      editorLayoutLog.info(
          'Could not find base and/or extent position to calculate bounding box for selection. Base: $base -> $baseComponent, Extent: $extent -> $extentComponent');
      return null;
    }

    DocumentComponent topComponent;
    final componentBoundingBoxes = <Rect>[];

    // Collect bounding boxes for all selected components.
    final documentLayoutBox = boxContext.findRenderObject() as RenderBox;
    if (base.nodeId == extent.nodeId) {
      // Selection within a single node.
      topComponent = extentComponent;
      final componentOffsetInDocument = (topComponent.context.findRenderObject() as RenderBox)
          .localToGlobal(Offset.zero, ancestor: documentLayoutBox);

      final componentBoundingBox = extentComponent
          .getRectForSelection(
            base.nodePosition,
            extent.nodePosition,
          )
          .translate(
            componentOffsetInDocument.dx,
            componentOffsetInDocument.dy,
          );
      componentBoundingBoxes.add(componentBoundingBox);
    } else {
      // Selection across nodes.
      final selectedNodes = _getNodeIdsBetween(base.nodeId, extent.nodeId);
      topComponent = getComponentByNodeId(selectedNodes.first)!;
      final startPosition = selectedNodes.first == base.nodeId ? base.nodePosition : extent.nodePosition;
      final endPosition = selectedNodes.first == base.nodeId ? extent.nodePosition : base.nodePosition;

      for (int i = 0; i < selectedNodes.length; ++i) {
        final component = getComponentByNodeId(selectedNodes[i])!;
        final componentOffsetInDocument =
            (component.context.findRenderObject() as RenderBox).localToGlobal(Offset.zero, ancestor: documentLayoutBox);

        if (i == 0) {
          // This is the first node. The selection goes from
          // startPosition to the end of the node.
          final firstNodeEndPosition = component.getEndPosition();
          final selectionRectInComponent = component.getRectForSelection(
            startPosition,
            firstNodeEndPosition,
          );
          final componentRectInDocument = selectionRectInComponent.translate(
            componentOffsetInDocument.dx,
            componentOffsetInDocument.dy,
          );
          componentBoundingBoxes.add(componentRectInDocument);
        } else if (i == selectedNodes.length - 1) {
          // This is the last node. The selection goes from
          // the beginning of the node to endPosition.
          final lastNodeStartPosition = component.getBeginningPosition();
          final selectionRectInComponent = component.getRectForSelection(
            lastNodeStartPosition,
            endPosition,
          );
          final componentRectInDocument = selectionRectInComponent.translate(
            componentOffsetInDocument.dx,
            componentOffsetInDocument.dy,
          );
          componentBoundingBoxes.add(componentRectInDocument);
        } else {
          // This node sits between start and end. All content
          // is selected.
          final selectionRectInComponent = component.getRectForSelection(
            component.getBeginningPosition(),
            component.getEndPosition(),
          );
          final componentRectInDocument = selectionRectInComponent.translate(
            componentOffsetInDocument.dx,
            componentOffsetInDocument.dy,
          );
          componentBoundingBoxes.add(componentRectInDocument);
        }
      }
    }

    // Combine all component boxes into one big bounding box.
    Rect boundingBox = componentBoundingBoxes.first;
    for (int i = 1; i < componentBoundingBoxes.length; ++i) {
      boundingBox = boundingBox.expandToInclude(componentBoundingBoxes[i]);
    }

    return boundingBox;
  }

  List<String> _getNodeIdsBetween(String baseNodeId, String extentNodeId) {
    final baseComponentKey = _nodeIdsToComponentKeys[baseNodeId]!;
    final baseComponentIndex = _topToBottomComponentKeys.indexOf(baseComponentKey);
    final extentComponentKey = _nodeIdsToComponentKeys[extentNodeId]!;
    final extentComponentIndex = _topToBottomComponentKeys.indexOf(extentComponentKey);

    final topNodeIndex = baseComponentIndex <= extentComponentIndex ? baseComponentIndex : extentComponentIndex;
    final bottomNodeIndex = topNodeIndex == baseComponentIndex ? extentComponentIndex : baseComponentIndex;
    final componentsInside = _topToBottomComponentKeys.sublist(topNodeIndex, bottomNodeIndex + 1);

    return componentsInside.map((componentKey) => _componentKeysToNodeIds[componentKey]!).toList();
  }

  @override
  DocumentSelection? getDocumentSelectionInRegion(Offset baseOffset, Offset extentOffset) {
    editorLayoutLog.info('getDocumentSelectionInRegion() - from: $baseOffset, to: $extentOffset');
    final region = Rect.fromPoints(baseOffset, extentOffset);

    String? topNodeId;
    dynamic topNodeBasePosition;
    dynamic topNodeExtentPosition;

    String? bottomNodeId;
    dynamic bottomNodeBasePosition;
    dynamic bottomNodeExtentPosition;

    // Find the top and bottom nodes in the selection region. We do this by finding the component
    // at the top of the selection, then we iterate down the document until we find the bottom
    // component in the selection region. We obtain the document nodes from the components.
    final selectionRegionTopOffset = min(baseOffset.dy, extentOffset.dy);
    final componentSearchStartIndex = max(_findComponentIndexAtOffset(selectionRegionTopOffset), 0);
    for (int i = componentSearchStartIndex; i < _topToBottomComponentKeys.length; i++) {
      final componentKey = _topToBottomComponentKeys[i];
      editorLayoutLog.info(' - considering component "$componentKey"');
      if (componentKey.currentState is! DocumentComponent) {
        editorLayoutLog.info(' - found unknown component: ${componentKey.currentState}');
        continue;
      }

      final component = componentKey.currentState as DocumentComponent;

      // Unselectable components should be avoided at base or extent.
      // They should only be selected when the surrounding components are selected.
      if (!component.isVisualSelectionSupported()) {
        editorLayoutLog.fine(' - component does not allow visual selection. Moving on.');
        continue;
      }

      final componentOverlap = _getLocalOverlapWithComponent(region, component);

      if (componentOverlap != null) {
        editorLayoutLog.fine(' - drag intersects: $componentKey}');
        editorLayoutLog.fine(' - intersection: $componentOverlap');
        final componentBaseOffset = _componentOffset(
          componentKey.currentContext!.findRenderObject() as RenderBox,
          baseOffset,
        );
        editorLayoutLog.fine(' - base component offset: $componentBaseOffset');
        final componentExtentOffset = _componentOffset(
          componentKey.currentContext!.findRenderObject() as RenderBox,
          extentOffset,
        );
        editorLayoutLog.fine(' - extent component offset: $componentExtentOffset');

        if (topNodeId == null) {
          // Because we're iterating through components from top to bottom, the
          // first intersecting component that we find must be the top node of
          // the selected area.
          topNodeId = _componentKeysToNodeIds[componentKey];
          topNodeBasePosition = _getNodePositionForComponentOffset(component, componentBaseOffset);
          topNodeExtentPosition = _getNodePositionForComponentOffset(component, componentExtentOffset);
        }
        // We continuously update the bottom node with every additional
        // intersection that we find. This way, when the iteration ends,
        // the last bottom node that we assigned must be the actual bottom
        // node within the selected area.
        bottomNodeId = _componentKeysToNodeIds[componentKey];
        bottomNodeBasePosition = _getNodePositionForComponentOffset(component, componentBaseOffset);
        bottomNodeExtentPosition = _getNodePositionForComponentOffset(component, componentExtentOffset);
      } else if (topNodeId != null) {
        // We already found an overlapping component and the current component doesn't
        // overlap with the region.
        // Because we're iterating through components from top to bottom,
        // it means that there isn't any other component which will overlap,
        // so we can skip the rest of the list.
        break;
      }
    }

    if (topNodeId == null || bottomNodeId == null) {
      // No document content exists in the given region.
      editorLayoutLog
          .finer(' - no document content exists in the region. Node at top: $topNodeId. Node at bottom: $bottomNodeId');
      return null;
    }

    if (topNodeId == bottomNodeId) {
      // Region sits within a single component.
      editorLayoutLog.fine(' - the entire selection sits within a single node: $topNodeId');
      return DocumentSelection(
        base: DocumentPosition(
          nodeId: topNodeId,
          nodePosition: topNodeBasePosition,
        ),
        extent: DocumentPosition(
          nodeId: bottomNodeId,
          nodePosition: topNodeExtentPosition,
        ),
      );
    } else {
      // Region covers multiple components.
      editorLayoutLog.fine(' - the selection spans nodes: $topNodeId -> $bottomNodeId');

      // Drag direction determines whether the extent offset is at the
      // top or bottom of the drag rect.
      final isDraggingDown = baseOffset.dy < extentOffset.dy;

      return DocumentSelection(
        base: DocumentPosition(
          nodeId: isDraggingDown ? topNodeId : bottomNodeId,
          nodePosition: isDraggingDown ? topNodeBasePosition : bottomNodeBasePosition,
        ),
        extent: DocumentPosition(
          nodeId: isDraggingDown ? bottomNodeId : topNodeId,
          nodePosition: isDraggingDown ? bottomNodeExtentPosition : topNodeExtentPosition,
        ),
      );
    }
  }

  /// Returns the overlapping `Rect` between the given `region` and the given
  /// `component`'s bounding box.
  ///
  /// Returns `null` if there is no overlap.
  Rect? _getLocalOverlapWithComponent(Rect region, DocumentComponent component) {
    final componentBox = component.context.findRenderObject() as RenderBox;
    final contentOffset = componentBox.localToGlobal(Offset.zero, ancestor: boxContext.findRenderObject());
    final componentBounds = contentOffset & componentBox.size;
    editorLayoutLog.finest("Component bounds: $componentBounds, versus region of interest: $region");

    if (region.overlaps(componentBounds)) {
      // Report the overlap in our local coordinate space.
      return region.translate(-contentOffset.dx, -contentOffset.dy);
    } else {
      return null;
    }
  }

  /// Returns the [NodePosition] that sits at the given [componentOffset].
  ///
  /// If the [componentOffset] is above the component, then the component's
  /// "beginning" position is returned. If the [componentOffset] is below
  /// the component, then the component's "end" position is returned.
  NodePosition? _getNodePositionForComponentOffset(DocumentComponent component, Offset componentOffset) {
    if (componentOffset.dy < 0) {
      return component.getBeginningPosition();
    }
    if (componentOffset.dy > component.getRectForPosition(component.getEndPosition()).bottom) {
      return component.getEndPosition();
    }

    return component.getPositionAtOffset(componentOffset);
  }

  @override
  MouseCursor? getDesiredCursorAtOffset(Offset documentOffset) {
    final componentKey = _findComponentAtOffset(documentOffset);
    if (componentKey == null ||
        componentKey.currentContext == null ||
        componentKey.currentContext!.findRenderObject() == null) {
      return null;
    }

    final componentBox = componentKey.currentContext!.findRenderObject() as RenderBox;
    final componentOffset = _componentOffset(componentBox, documentOffset);

    final component = componentKey.currentState as DocumentComponent;
    return component.getDesiredCursorAtOffset(componentOffset);
  }

  GlobalKey? _findComponentAtOffset(Offset documentOffset) {
    for (final componentKey in _nodeIdsToComponentKeys.values) {
      if (componentKey.currentState is! DocumentComponent) {
        continue;
      }
      if (componentKey.currentContext == null || componentKey.currentContext!.findRenderObject() == null) {
        continue;
      }

      final textBox = componentKey.currentContext!.findRenderObject() as RenderBox;
      if (_isOffsetInComponent(textBox, documentOffset)) {
        return componentKey;
      }
    }
    return null;
  }

  GlobalKey? _findComponentClosestToOffset(Offset documentOffset) {
    GlobalKey? nearestComponentKey;
    double nearestDistance = double.infinity;
    for (final componentKey in _nodeIdsToComponentKeys.values) {
      if (componentKey.currentState is! DocumentComponent) {
        continue;
      }
      if (componentKey.currentContext == null || componentKey.currentContext!.findRenderObject() == null) {
        continue;
      }

      final componentBox = componentKey.currentContext!.findRenderObject() as RenderBox;
      if (_isOffsetInComponent(componentBox, documentOffset)) {
        return componentKey;
      }

      final distance = _getDistanceToComponent(componentBox, documentOffset);
      if (distance < nearestDistance) {
        nearestDistance = distance;
        nearestComponentKey = componentKey;
      }
    }
    return nearestComponentKey;
  }

  /// Returns the [DocumentPosition] at the beginning of the first node or `null` if the document is empty.
  DocumentPosition? _findFirstPosition() {
    if (_topToBottomComponentKeys.isEmpty) {
      return null;
    }

    final componentKey = _topToBottomComponentKeys.first;
    final component = componentKey.currentState as DocumentComponent;

    return DocumentPosition(
      nodeId: _componentKeysToNodeIds[componentKey]!,
      nodePosition: component.getBeginningPosition(),
    );
  }

  /// Returns the [DocumentPosition] at the end of the last node or `null` if the document is empty.
  DocumentPosition? _findLastPosition() {
    if (_topToBottomComponentKeys.isEmpty) {
      return null;
    }

    final componentKey = _topToBottomComponentKeys.last;
    final component = componentKey.currentState as DocumentComponent;

    return DocumentPosition(
      nodeId: _componentKeysToNodeIds[componentKey]!,
      nodePosition: component.getEndPosition(),
    );
  }

  bool _isOffsetInComponent(RenderBox componentBox, Offset documentOffset) {
    final containerBox = boxContext.findRenderObject() as RenderBox;
    final contentOffset = componentBox.localToGlobal(Offset.zero, ancestor: containerBox);
    final contentRect = contentOffset & componentBox.size;

    return contentRect.contains(documentOffset);
  }

  /// Returns the vertical distance between the given [documentOffset] and the
  /// bounds of the given [componentBox].
  double _getDistanceToComponent(RenderBox componentBox, Offset documentOffset) {
    final documentLayoutBox = boxContext.findRenderObject() as RenderBox;
    final componentOffset = componentBox.localToGlobal(Offset.zero, ancestor: documentLayoutBox);
    final componentRect = componentOffset & componentBox.size;

    if (documentOffset.dy < componentRect.top) {
      // The given offset is above the component's bounds.
      return componentRect.top - documentOffset.dy;
    } else if (documentOffset.dy > componentRect.bottom) {
      // The given offset is below the component's bounds.
      return documentOffset.dy - componentRect.bottom;
    } else {
      // The given offset sits within the component bounds.
      return 0;
    }
  }

  Offset _componentOffset(RenderBox componentBox, Offset documentOffset) {
    final containerBox = boxContext.findRenderObject() as RenderBox;
    final contentOffset = componentBox.localToGlobal(Offset.zero, ancestor: containerBox);
    final contentRect = contentOffset & componentBox.size;

    return documentOffset - contentRect.topLeft;
  }

  @override
  DocumentComponent? getComponentByNodeId(String nodeId) {
    final key = _nodeIdsToComponentKeys[nodeId];
    if (key == null) {
      editorLayoutLog.info('WARNING: could not find component for node ID: $nodeId');
      return null;
    }
    if (key.currentState is! DocumentComponent) {
      editorLayoutLog.info(
          'WARNING: found component but it\'s not a DocumentComponent: $nodeId, layout key: $key, state: ${key.currentState}, widget: ${key.currentWidget}, context: ${key.currentContext}');
      if (kDebugMode) {
        throw Exception(
            'WARNING: found component but it\'s not a DocumentComponent: $nodeId, layout key: $key, state: ${key.currentState}, widget: ${key.currentWidget}, context: ${key.currentContext}');
      }
      return null;
    }
    return key.currentState as DocumentComponent;
  }

  @override
  Offset getDocumentOffsetFromAncestorOffset(Offset ancestorOffset, [RenderObject? ancestor]) {
    return (boxContext.findRenderObject() as RenderBox).globalToLocal(ancestorOffset, ancestor: ancestor);
  }

  @override
  Offset getAncestorOffsetFromDocumentOffset(Offset documentOffset, [RenderObject? ancestor]) {
    return (boxContext.findRenderObject() as RenderBox).localToGlobal(documentOffset, ancestor: ancestor);
  }

  @override
  Offset getGlobalOffsetFromDocumentOffset(Offset documentOffset) {
    return (boxContext.findRenderObject() as RenderBox).localToGlobal(documentOffset);
  }

  @override
  DocumentPosition? findLastSelectablePosition() {
    NodePosition? nodePosition;
    String? nodeId;

    for (int i = _topToBottomComponentKeys.length - 1; i >= 0; i--) {
      final componentKey = _topToBottomComponentKeys[i];
      final component = componentKey.currentState as DocumentComponent;

      if (component.isVisualSelectionSupported()) {
        nodePosition = component.getEndPosition();
        nodeId = _componentKeysToNodeIds[componentKey];
        break;
      }
    }

    if (nodePosition == null) {
      return null;
    }

    return DocumentPosition(
      nodeId: nodeId!,
      nodePosition: nodePosition,
    );
  }

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    widget.onBuildScheduled?.call();
  }

  @override
  Widget build(BuildContext context) {
    editorLayoutLog.fine("Building document layout");
    Widget result = Padding(
      key: _boxKey,
      padding: widget.presenter.viewModel.padding,
      child: _DocumentComponentColumn(
        children: _buildDocComponents(),
      ),
    );

    if (widget.wrapWithSliverAdapter) {
      result = SliverToBoxAdapter(
        child: result,
      );
    }

    editorLayoutLog.fine("Done building document");
    return result;
  }

  List<Widget> _buildDocComponents() {
    editorLayoutLog.fine('Building all document layout components');

    final docComponents = <Widget>[];
    final newComponentKeys = <String, GlobalKey>{};
    final newNodeIds = <GlobalKey, String>{};
    _topToBottomComponentKeys.clear();

    // Keep the same list of component builders while the builders are the same, so
    // that the builder widgets below can be reused.
    if (!listEquals(_componentBuilders, widget.componentBuilders)) {
      _componentBuilders = widget.componentBuilders;
    }
    final componentBuilders = _componentBuilders!;

    final previousBuilderWidgets =
        _checkEveryComponentInNextBuild ? const <String, _PresenterComponentBuilder>{} : _builderWidgetsByNodeId;
    _checkEveryComponentInNextBuild = false;
    final newBuilderWidgets = <String, _PresenterComponentBuilder>{};
    // How many times each node ID appears, only for IDs that appear more than once.
    Map<String, int>? duplicateNodeIdCounts;

    final viewModel = widget.presenter.viewModel;
    editorLayoutLog.fine("Rendering layout view model: ${viewModel.hashCode}");
    for (final componentViewModel in viewModel.componentViewModels) {
      final nodeId = componentViewModel.nodeId;
      final isDuplicateNodeId = newComponentKeys.containsKey(nodeId);
      final componentKey = _obtainComponentKeyForDocumentNode(
        newComponentKeyMap: newComponentKeys,
        nodeId: nodeId,
      );
      newNodeIds[componentKey] = nodeId;
      editorLayoutLog.finer('Node -> Key: $nodeId -> $componentKey');

      _topToBottomComponentKeys.add(componentKey);

      if (isDuplicateNodeId) {
        // A document can briefly hold more than one node with the same ID. Give each
        // extra node a key of its own, so that the keys of the builders stay unique.
        duplicateNodeIdCounts ??= {};
        final occurrence = duplicateNodeIdCounts[nodeId] = (duplicateNodeIdCounts[nodeId] ?? 0) + 1;
        docComponents.add(
          _PresenterComponentBuilder(
            key: ValueKey<(String, int)>((nodeId, occurrence)),
            presenter: widget.presenter,
            registry: _componentBuilderRegistry,
            watchNode: nodeId,
            componentBuilders: componentBuilders,
            componentKey: componentKey,
          ),
        );
        continue;
      }

      // Reuse the identical builder widget from the previous build, when nothing that it
      // holds changed, so that Flutter skips this component altogether. The builder
      // rebuilds its component when the presenter reports that its node changed.
      var builderWidget = previousBuilderWidgets[nodeId];
      if (builderWidget == null ||
          !identical(builderWidget.presenter, widget.presenter) ||
          !identical(builderWidget.componentBuilders, componentBuilders) ||
          !identical(builderWidget.componentKey, componentKey)) {
        builderWidget = _PresenterComponentBuilder(
          // Key each component by its node so that inserting or removing a node keeps
          // every other component, and its Element, State, and GlobalKey, bound to
          // the same node.
          key: ValueKey<String>(nodeId),
          presenter: widget.presenter,
          registry: _componentBuilderRegistry,
          watchNode: nodeId,
          componentBuilders: componentBuilders,
          componentKey: componentKey,
        );
      }
      newBuilderWidgets[nodeId] = builderWidget;
      docComponents.add(builderWidget);
    }

    _builderWidgetsByNodeId = newBuilderWidgets;

    _nodeIdsToComponentKeys
      ..clear()
      ..addAll(newComponentKeys);

    _componentKeysToNodeIds
      ..clear()
      ..addAll(newNodeIds);

    editorLayoutLog.finer(' - keys -> IDs after building all components:');
    _nodeIdsToComponentKeys.forEach((key, value) {
      editorLayoutLog.finer('   - $key: $value');
    });

    return docComponents;
  }

  /// Obtains a `GlobalKey` that should be attached to the component
  /// that represents the given [nodeId].
  ///
  /// If a key was already created for the given [nodeId], that same
  /// key is returned. Otherwise, a new key is created, stored for
  /// later, and returned.
  GlobalKey _obtainComponentKeyForDocumentNode({
    required Map<String, GlobalKey> newComponentKeyMap,
    required String nodeId,
  }) {
    if (_nodeIdsToComponentKeys.containsKey(nodeId)) {
      newComponentKeyMap[nodeId] = _nodeIdsToComponentKeys[nodeId]!;
    } else {
      newComponentKeyMap[nodeId] = GlobalKey();
    }
    return newComponentKeyMap[nodeId]!;
  }

  /// Finds the component whose vertical bounds contains the offset [dy].
  ///
  /// Returns the index of the component, from top to bottom order.
  int _findComponentIndexAtOffset(double dy) {
    if (_topToBottomComponentKeys.isEmpty) {
      return -1;
    }
    return _binarySearchComponentIndexAtOffset(dy, 0, _topToBottomComponentKeys.length - 1);
  }

  /// Performs a binary search starting from [minIndex] to [maxIndex] to find
  /// a component whose bounds contains the offset [dy].
  ///
  /// Returns the index of the component, from top to bottom order.
  int _binarySearchComponentIndexAtOffset(double dy, int minIndex, int maxIndex) {
    if (minIndex > maxIndex) {
      return -1;
    }

    final middleIndex = ((minIndex + maxIndex) / 2).floor();
    final componentBounds = _getComponentBoundsByIndex(middleIndex);

    if (componentBounds.top <= dy && dy <= componentBounds.bottom) {
      // The component in the middle of the search region is the one we're looking for. Return its index.
      return middleIndex;
    }

    if (dy > componentBounds.bottom) {
      if (middleIndex + 1 < _topToBottomComponentKeys.length) {
        // Check the gap between two components.
        final nextComponentBounds = _getComponentBoundsByIndex(middleIndex + 1);
        final gap = nextComponentBounds.top - componentBounds.bottom;
        if (componentBounds.bottom < dy && dy < (componentBounds.bottom + gap / 2)) {
          // The component we're looking for is somewhere in the bottom half of the current search region.
          return middleIndex;
        }
      }
      return _binarySearchComponentIndexAtOffset(dy, middleIndex + 1, maxIndex);
    } else {
      if (middleIndex - 1 >= 0) {
        // Check the gap between two components.
        final previousComponentBounds = _getComponentBoundsByIndex(middleIndex - 1);
        final gap = componentBounds.top - previousComponentBounds.bottom;
        if ((componentBounds.top - gap / 2) < dy && dy < componentBounds.top) {
          // The component we're looking for is somewhere in the top half of the current search region.
          return middleIndex;
        }
      }
      return _binarySearchComponentIndexAtOffset(dy, minIndex, middleIndex - 1);
    }
  }

  /// Gets the component bounds of the component at [componentIndex] from top to bottom order.
  Rect _getComponentBoundsByIndex(int componentIndex) {
    final componentKey = _topToBottomComponentKeys[componentIndex];
    final component = componentKey.currentState as DocumentComponent;

    final componentBox = component.context.findRenderObject() as RenderBox;
    final contentOffset = componentBox.localToGlobal(Offset.zero, ancestor: boxContext.findRenderObject());
    return contentOffset & componentBox.size;
  }
}

/// The component builders of a [SingleColumnDocumentLayout], by the node ID that each
/// one builds, so that the layout, which listens to the presenter, can tell only the
/// builders of the nodes that changed to rebuild.
class _ComponentBuilderRegistry {
  final _buildersByNodeId = <String, _PresenterComponentBuilderState>{};

  /// More builders for node IDs that appear more than once in the document.
  final _duplicateBuildersByNodeId = <String, List<_PresenterComponentBuilderState>>{};

  void register(String nodeId, _PresenterComponentBuilderState builder) {
    final existingBuilder = _buildersByNodeId[nodeId];
    if (existingBuilder == null) {
      _buildersByNodeId[nodeId] = builder;
      return;
    }
    if (identical(existingBuilder, builder)) {
      return;
    }

    final duplicates = _duplicateBuildersByNodeId[nodeId] ??= [];
    if (!duplicates.contains(builder)) {
      duplicates.add(builder);
    }
  }

  void unregister(String nodeId, _PresenterComponentBuilderState builder) {
    final duplicates = _duplicateBuildersByNodeId[nodeId];
    if (identical(_buildersByNodeId[nodeId], builder)) {
      if (duplicates != null && duplicates.isNotEmpty) {
        _buildersByNodeId[nodeId] = duplicates.removeAt(0);
      } else {
        _buildersByNodeId.remove(nodeId);
      }
    } else {
      duplicates?.remove(builder);
    }

    if (duplicates != null && duplicates.isEmpty) {
      _duplicateBuildersByNodeId.remove(nodeId);
    }
  }

  /// Tells the builders of the given [nodeIds] that their component view models might
  /// have changed.
  void notifyViewModelChanged(List<String> nodeIds) {
    for (final nodeId in nodeIds) {
      _buildersByNodeId[nodeId]?._onViewModelChange();

      final duplicates = _duplicateBuildersByNodeId[nodeId];
      if (duplicates != null) {
        for (final builder in duplicates) {
          builder._onViewModelChange();
        }
      }
    }
  }
}

/// Builds the component for the node with the ID [watchNode], from that node's view
/// model in the [presenter], and rebuilds it when the layout's presenter listener,
/// through the [registry], reports that the view model changed.
class _PresenterComponentBuilder extends StatefulWidget {
  const _PresenterComponentBuilder({
    super.key,
    required this.presenter,
    required this.registry,
    required this.watchNode,
    required this.componentBuilders,
    required this.componentKey,
  });

  final SingleColumnLayoutPresenter presenter;
  final _ComponentBuilderRegistry registry;
  final String watchNode;
  final List<ComponentBuilder> componentBuilders;
  final GlobalKey componentKey;

  @override
  _PresenterComponentBuilderState createState() => _PresenterComponentBuilderState();
}

class _PresenterComponentBuilderState extends State<_PresenterComponentBuilder> {
  /// The component that this builder built last, and what it was built from.
  Widget? _component;
  SingleColumnLayoutComponentViewModel? _componentViewModel;
  SingleColumnLayoutPresenter? _componentPresenter;
  List<ComponentBuilder>? _componentBuilders;
  GlobalKey? _componentKey;

  @override
  void initState() {
    super.initState();
    widget.registry.register(widget.watchNode, this);
  }

  @override
  void didUpdateWidget(_PresenterComponentBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (!identical(widget.registry, oldWidget.registry) || widget.watchNode != oldWidget.watchNode) {
      oldWidget.registry.unregister(oldWidget.watchNode, this);
      widget.registry.register(widget.watchNode, this);
    }
  }

  @override
  void reassemble() {
    super.reassemble();

    // Rebuild the component after a hot reload.
    _component = null;
  }

  @override
  void dispose() {
    widget.registry.unregister(widget.watchNode, this);
    super.dispose();
  }

  void _onViewModelChange() {
    setState(() {
      // Re-build.
    });
  }

  /// Whether a component built from [previous] looks the same as one built from [next].
  static bool _isSameViewModel(
    SingleColumnLayoutComponentViewModel previous,
    SingleColumnLayoutComponentViewModel next,
  ) {
    if (identical(previous, next)) {
      return true;
    }
    if (previous != next) {
      return false;
    }

    // View model equality doesn't include a text component's style builder, which a
    // stylesheet rule that depends on the node's neighbors, or on its index, changes
    // when other nodes are added, removed, or moved. Compare the base styles that the
    // style builders build.
    if (previous is TextComponentViewModel && next is TextComponentViewModel) {
      return previous.textStyleBuilder(const {}) == next.textStyleBuilder(const {});
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    editorLayoutLog.finest("Building component: ${widget.watchNode}");

    final viewModel = widget
        .presenter //
        .viewModel //
        .getComponentViewModelByNodeId(widget.watchNode);
    if (viewModel == null) {
      // The node was removed, and the layout will remove this builder in a moment.
      return _component ?? const SizedBox();
    }

    // Return the identical component widget when nothing that it's built from changed,
    // so that Flutter skips the component's subtree. That's the case for most of the
    // components that the presenter reports as moved, e.g., all the components after a
    // node that was inserted.
    //
    // A new presenter always rebuilds the component, because view model equality
    // doesn't cover everything that a new presenter, e.g., one with a new stylesheet,
    // might change.
    final component = _component;
    if (component != null &&
        identical(_componentPresenter, widget.presenter) &&
        identical(_componentKey, widget.componentKey) &&
        (identical(_componentBuilders, widget.componentBuilders) ||
            listEquals(_componentBuilders, widget.componentBuilders)) &&
        _isSameViewModel(_componentViewModel!, viewModel)) {
      return component;
    }

    _componentViewModel = viewModel;
    _componentPresenter = widget.presenter;
    _componentBuilders = widget.componentBuilders;
    _componentKey = widget.componentKey;
    return _component = _Component(
      componentBuilders: widget.componentBuilders,
      componentKey: widget.componentKey,
      componentViewModel: viewModel,
    );
  }
}

/// Builds a component widget for the given [componentViewModel] and
/// binds it to the given [componentKey].
///
/// The specific widget that's build is determined by the given
/// [componentBuilders]. The component widget is rebuilt whenever the
/// given [presenter] reports that the
class _Component extends StatelessWidget {
  const _Component({
    Key? key,
    required this.componentBuilders,
    required this.componentViewModel,
    required this.componentKey,
    // TODO(srawlins): `unused_element`, when reporting a parameter, is being
    // renamed to `unused_element_parameter`. For now, ignore each; when the SDK
    // constraint is >= 3.6.0, just ignore `unused_element_parameter`.
    // ignore: unused_element, unused_element_parameter
    this.showDebugPaint = false,
  }) : super(key: key);

  /// Builders for every type of component that this layout displays.
  ///
  /// Every type of `DocumentNode` that might appear in the displayed
  /// `document` should have a `ComponentBuilder` that knows how to
  /// render that piece of content.
  final List<ComponentBuilder> componentBuilders;

  /// Global key that will be attached to the root of the component
  /// widget sub-tree.
  final GlobalKey componentKey;

  /// The visual configuration for the component that needs to be built.
  final SingleColumnLayoutComponentViewModel componentViewModel;

  /// Whether to add debug paint to the component.
  final bool showDebugPaint;

  @override
  Widget build(BuildContext context) {
    final componentContext = SingleColumnDocumentComponentContext(
      context: context,
      componentKey: componentKey,
    );
    for (final componentBuilder in componentBuilders) {
      var component = componentBuilder.createComponent(componentContext, componentViewModel);
      if (component != null) {
        // TODO: we might need a SizeChangedNotifier here for the case where two components
        //       change size exactly inversely
        component = ConstrainedBox(
          constraints: BoxConstraints(maxWidth: componentViewModel.maxWidth ?? double.infinity),
          child: SizedBox(
            width: double.infinity,
            child: Padding(
              padding: componentViewModel.padding,
              child: component,
            ),
          ),
        );

        return showDebugPaint ? _wrapWithDebugWidget(component) : component;
      }
    }
    return const SizedBox();
  }

  Widget _wrapWithDebugWidget(Widget component) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xFFFF0000), width: 1),
      ),
      child: component,
    );
  }
}

/// The column of components in a [SingleColumnDocumentLayout], which lays out exactly like
/// a [Column] with [MainAxisSize.min] and [CrossAxisAlignment.center], and which paints and
/// hit-tests only the components around what's visible, or around the hit.
class _DocumentComponentColumn extends Flex {
  const _DocumentComponentColumn({
    required super.children,
  }) : super(
          direction: Axis.vertical,
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
        );

  @override
  RenderDocumentComponentColumn createRenderObject(BuildContext context) {
    return RenderDocumentComponentColumn(
      textDirection: getEffectiveTextDirection(context),
    );
  }
}

/// The render box of the column of components in a [SingleColumnDocumentLayout].
///
/// This box lays out its children exactly like a [RenderFlex] for a [Column] with
/// [MainAxisSize.min] and [CrossAxisAlignment.center]: one below another, from top to
/// bottom, centered horizontally. Its intrinsic sizes, dry layout, and semantics are
/// those of that [RenderFlex], too.
///
/// Unlike a [Column], this box only paints the children that can be seen, and only
/// hit-tests the children around the hit position, so that painting and hit-testing
/// don't get slower as a document gets longer.
///
/// ## Painting
///
/// This box paints a child when the child's paint rect intersects the visible rect,
/// which is the canvas clip, intersected with the bounds of the nearest
/// [RenderAbstractViewport] ancestor, and inflated by [paintCullingMargin].
///
/// A child's paint rect is the child's layout rect, expanded to include the child's
/// [RenderBox.paintBounds]. [SingleColumnDocumentLayout] wraps every component in a
/// `ConstrainedBox`, a `SizedBox`, and a `Padding`, so a child's paint rect also
/// includes the [RenderBox.paintBounds] of the render box at the root of the component,
/// which is the root of the widget that a [ComponentBuilder] returns. A component that
/// paints outside of its layout rect, e.g., because it moves its content with a paint
/// transform, must override [RenderBox.paintBounds] on its root render box to report
/// where it paints.
///
/// The paint rects are read once after each layout of this box, so a change to a
/// component's paint bounds must come with a layout of the component.
///
/// When a repaint boundary sits between this box and the nearest viewport, the
/// viewport can scroll without repainting this box, so this box paints every child.
///
/// ## Hit-testing
///
/// This box only hit-tests the child whose vertical span contains the hit position,
/// which it finds with a binary search, plus any child above it whose bottom edge is
/// within a pixel of the hit position. A child is assumed to be hit only within its
/// own bounds, as [RenderBox.hitTest] does.
class RenderDocumentComponentColumn extends RenderFlex {
  RenderDocumentComponentColumn({
    super.textDirection,
  }) : super(
          direction: Axis.vertical,
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
        );

  /// How far beyond the visible rect this box still paints children, to cover content
  /// that paints a bit outside of its paint bounds, like a shadow, or a glyph's overhang.
  static const paintCullingMargin = 100.0;

  /// The number of times this box ran layout, which tells a cache of its children's
  /// geometry when that cache is out of date.
  int get layoutCount => _layoutCount;
  int _layoutCount = 0;

  /// The children, from top to bottom, for random access, or `null` if the children
  /// changed since this list was last created.
  List<RenderBox>? _childList;
  List<RenderBox> get _children => _childList ??= getChildrenAsList();

  /// The paint rects of the children whose paint rects aren't their layout rects, by
  /// child index, or `null` if they haven't been read since the last layout.
  Map<int, Rect>? _paintRectsOutsideOfLayout;

  /// The farthest that any child paints above the top of its layout rect.
  double _maxPaintExtentAboveLayout = 0;

  /// The farthest that any child paints below the bottom of its layout rect.
  double _maxPaintExtentBelowLayout = 0;

  /// The child at [index], counting from the top.
  ///
  /// Every child is reported, including a child that isn't a document component.
  RenderBox childAt(int index) => _children[index];

  /// The layout rect of the child at [index], counting from the top, in this box's
  /// coordinates.
  ///
  /// Every child is reported, including a child that isn't a document component.
  Rect childRectAt(int index) {
    final child = _children[index];
    return (child.parentData! as FlexParentData).offset & child.size;
  }

  /// The rect that this box considers the child at [index] to paint in, counting from
  /// the top, in this box's coordinates.
  ///
  /// See the class documentation for how a child's paint rect is found.
  Rect childPaintRectAt(int index) {
    _readPaintRects();
    return _paintRectsOutsideOfLayout![index] ?? childRectAt(index);
  }

  @override
  void insert(RenderBox child, {RenderBox? after}) {
    super.insert(child, after: after);
    _onChildrenChanged();
  }

  @override
  void remove(RenderBox child) {
    super.remove(child);
    _onChildrenChanged();
  }

  @override
  void removeAll() {
    super.removeAll();
    _onChildrenChanged();
  }

  @override
  void move(RenderBox child, {RenderBox? after}) {
    super.move(child, after: after);
    _onChildrenChanged();
  }

  void _onChildrenChanged() {
    _childList = null;
    _paintRectsOutsideOfLayout = null;
  }

  @override
  void performLayout() {
    super.performLayout();

    _layoutCount += 1;
    _paintRectsOutsideOfLayout = null;
  }

  /// Whether the children are stacked from top to bottom, which the binary searches in
  /// this box rely on, as they are with the configuration of a [_DocumentComponentColumn].
  bool get _areChildrenStackedTopToBottom =>
      direction == Axis.vertical && verticalDirection == VerticalDirection.down && spacing >= 0;

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    if (!_areChildrenStackedTopToBottom) {
      return super.hitTestChildren(result, position: position);
    }

    // Only a child whose vertical span contains the position can be hit, and that's the
    // last child that starts at, or above, the position. Check a child above it, too,
    // when its bottom edge is within a pixel of the position, which can only matter
    // when floating point rounding makes two children share a hairline, so that the
    // children that are hit-tested, and their order, match those of a Column.
    final children = _children;
    for (int i = _lastChildStartingAtOrAbove(position.dy); i >= 0; i -= 1) {
      final child = children[i];
      final childParentData = child.parentData! as FlexParentData;
      if (position.dy - (childParentData.offset.dy + child.size.height) > 1.0) {
        // This child, and every child above it, ends above the position.
        break;
      }

      final isHit = result.addWithPaintOffset(
        offset: childParentData.offset,
        position: position,
        hitTest: (BoxHitTestResult result, Offset transformed) {
          assert(transformed == position - childParentData.offset);
          return child.hitTest(result, position: transformed);
        },
      );
      if (isHit) {
        return true;
      }
    }
    return false;
  }

  @override
  void defaultPaint(PaintingContext context, Offset offset) {
    if (!_areChildrenStackedTopToBottom || firstChild == null) {
      super.defaultPaint(context, offset);
      return;
    }

    final visibleRect = _findVisibleRect(context, offset);
    if (visibleRect == null) {
      // We can't tell what's visible. Paint everything.
      super.defaultPaint(context, offset);
      return;
    }
    if (visibleRect.width < 0 || visibleRect.height < 0) {
      // Nothing is visible.
      return;
    }

    _readPaintRects();
    final paintRectsOutsideOfLayout = _paintRectsOutsideOfLayout!;
    final children = _children;

    // A child whose layout rect ends above `searchTop`, or starts below `searchBottom`,
    // can't paint in the visible rect.
    final searchTop = visibleRect.top - _maxPaintExtentBelowLayout;
    final searchBottom = visibleRect.bottom + _maxPaintExtentAboveLayout;
    for (int i = _firstChildEndingAtOrBelow(searchTop); i < children.length; i += 1) {
      final child = children[i];
      final childOffset = (child.parentData! as FlexParentData).offset;
      if (childOffset.dy > searchBottom) {
        break;
      }

      final paintRect = paintRectsOutsideOfLayout[i] ?? childOffset & child.size;
      if (paintRect.left <= visibleRect.right &&
          paintRect.right >= visibleRect.left &&
          paintRect.top <= visibleRect.bottom &&
          paintRect.bottom >= visibleRect.top) {
        context.paintChild(child, childOffset + offset);
      }
    }
  }

  /// Returns the rect, in this box's coordinates, in which painted children might be
  /// seen, or `null` if this box can't tell, and should paint every child.
  Rect? _findVisibleRect(PaintingContext context, Offset offset) {
    if (isRepaintBoundary) {
      // Our picture can be reused at another scroll offset without painting us again.
      return null;
    }

    // Children can only be seen within the canvas clip.
    Rect visibleRect = context.canvas.getLocalClipBounds().shift(-offset);

    // ...and within the nearest viewport. We use the viewport's bounds, rather than the
    // painting context's estimated bounds, because the estimated bounds aren't shifted
    // by layers that move their children, like an OpacityLayer.
    RenderObject? ancestor = parent;
    while (ancestor != null && ancestor is! RenderAbstractViewport) {
      if (ancestor.isRepaintBoundary) {
        // This repaint boundary caches our picture, and the viewport can show that
        // picture at another scroll offset, without painting us again. Paint everything.
        return null;
      }
      ancestor = ancestor.parent;
    }
    if (ancestor is RenderBox && ancestor.hasSize) {
      final viewportToLocal = Matrix4.tryInvert(getTransformTo(ancestor));
      if (viewportToLocal == null) {
        return null;
      }
      visibleRect = visibleRect.intersect(MatrixUtils.transformRect(viewportToLocal, Offset.zero & ancestor.size));
    }

    return visibleRect.inflate(paintCullingMargin);
  }

  /// Reads the paint rect of every child, and the farthest that any child paints outside
  /// of its layout rect, if they haven't been read since the last layout.
  void _readPaintRects() {
    if (_paintRectsOutsideOfLayout != null) {
      return;
    }

    final paintRectsOutsideOfLayout = <int, Rect>{};
    double maxPaintExtentAboveLayout = 0;
    double maxPaintExtentBelowLayout = 0;
    final children = _children;
    for (int i = 0; i < children.length; i += 1) {
      final child = children[i];
      final childOffset = (child.parentData! as FlexParentData).offset;
      final layoutRect = childOffset & child.size;
      final paintRect = _findPaintBounds(child).shift(childOffset);
      if (paintRect != layoutRect) {
        paintRectsOutsideOfLayout[i] = paintRect;
        maxPaintExtentAboveLayout = max(maxPaintExtentAboveLayout, layoutRect.top - paintRect.top);
        maxPaintExtentBelowLayout = max(maxPaintExtentBelowLayout, paintRect.bottom - layoutRect.bottom);
      }
    }

    _paintRectsOutsideOfLayout = paintRectsOutsideOfLayout;
    _maxPaintExtentAboveLayout = maxPaintExtentAboveLayout;
    _maxPaintExtentBelowLayout = maxPaintExtentBelowLayout;
  }

  /// Returns the rect that [child] paints in, in the child's coordinates: its bounds,
  /// expanded by its paint bounds, and by the paint bounds of the component inside the
  /// boxes that [SingleColumnDocumentLayout] wraps around every component.
  static Rect _findPaintBounds(RenderBox child) {
    Rect paintBounds = (Offset.zero & child.size).expandToInclude(child.paintBounds);

    // Walk through the ConstrainedBox, SizedBox, and Padding that wrap the component.
    // Each of them paints its child where it laid the child out.
    RenderBox box = child;
    Offset boxOffset = Offset.zero;
    while (true) {
      final RenderBox? innerBox;
      Offset innerBoxOffset = boxOffset;
      if (box.runtimeType == RenderConstrainedBox) {
        innerBox = (box as RenderConstrainedBox).child;
      } else if (box.runtimeType == RenderPadding) {
        innerBox = (box as RenderPadding).child;
        if (innerBox != null) {
          innerBoxOffset += (innerBox.parentData! as BoxParentData).offset;
        }
      } else {
        break;
      }
      if (innerBox == null || !innerBox.hasSize) {
        break;
      }

      paintBounds = paintBounds.expandToInclude(innerBox.paintBounds.shift(innerBoxOffset));
      box = innerBox;
      boxOffset = innerBoxOffset;
    }

    return paintBounds;
  }

  /// Returns the index of the last child whose top edge is at, or above, [dy], or `-1`.
  int _lastChildStartingAtOrAbove(double dy) {
    final children = _children;
    int low = 0;
    int high = children.length;
    while (low < high) {
      final middle = (low + high) >> 1;
      if ((children[middle].parentData! as FlexParentData).offset.dy > dy) {
        high = middle;
      } else {
        low = middle + 1;
      }
    }
    return low - 1;
  }

  /// Returns the index of the first child whose bottom edge is at, or below, [dy], or the
  /// number of children if there's none.
  int _firstChildEndingAtOrBelow(double dy) {
    final children = _children;
    int low = 0;
    int high = children.length;
    while (low < high) {
      final middle = (low + high) >> 1;
      final child = children[middle];
      if ((child.parentData! as FlexParentData).offset.dy + child.size.height >= dy) {
        high = middle;
      } else {
        low = middle + 1;
      }
    }
    return low;
  }
}
