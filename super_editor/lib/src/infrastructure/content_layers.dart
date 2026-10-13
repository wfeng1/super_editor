import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:super_editor/src/infrastructure/_logging.dart';

/// Widget that displays [content] above a number of [underlays], and beneath a number of
/// [overlays].
///
/// This widget is similar in behavior to a `Stack`, except this widget alters the build
/// and layout order to support use-cases where various layers depend upon the layout of
/// a single [content] layer.
///
/// This widget is useful for use-cases where decorations need to be positioned relative
/// to content within the [content] widget. For example, this [ContentLayers] might be
/// used to display a document as [content] and then display text selection as an
/// underlay, the caret as an overlay, and user comments as another overlay.
///
/// The layers are sized to be exactly the same as the [content], and the layers are
/// positioned at the same (x,y) as [content].
///
/// The layers are built after [content] is laid out, so that the layers can inspect the
/// [content] layout during the layers' build phase. This makes it easy, for example, to
/// position a caret on top of a document, using only the widget tree.
///
/// Some of the implementation details differ between `RenderBox` and `RenderSliver` use-cases,
/// therefore this class is abstract. Use either the box or sliver version of this widget
/// depending on your use-case.
abstract class ContentLayers extends RenderObjectWidget {
  const ContentLayers({
    super.key,
    this.underlays = const [],
    required this.content,
    this.overlays = const [],
  });

  /// Layers displayed beneath the [content].
  ///
  /// These layers are placed at the same (x,y) as [content], and they're forced to layout
  /// at the exact same size as [content].
  ///
  /// {@template layers_as_builders}
  /// Layers are structured as [WidgetBuilder]s so that they can be re-built whenever
  /// the content layout changes, without interference from Flutter's standard build system.
  /// Ideally, layers would be pure [Widget]s, but this is a consequence of how Flutter's
  /// [BuildOwner] works. For more details, see https://github.com/flutter/flutter/issues/123305
  /// and https://github.com/superlistapp/super_editor/pull/1239
  /// {@endtemplate}
  final List<ContentLayerWidgetBuilder> underlays;

  /// The primary content displayed in this widget, which determines the size and location
  /// of all [underlays] and [overlays].
  ///
  /// The content should call `onBuildScheduled` whenever it schedules a build of itself,
  /// e.g., with `setState()`. [ContentLayers] then rebuilds the layers after the content's
  /// next layout, and a layer that's dirty in the meantime waits for that, instead of
  /// building against the content's outdated layout.
  final Widget Function(VoidCallback onBuildScheduled) content;

  /// Layers displayed above the [content].
  ///
  /// These layers are placed at the same (x,y) as [content], and they're forced to layout
  /// at the exact same size as [content].
  ///
  /// {@macro layers_as_builders}
  final List<ContentLayerWidgetBuilder> overlays;

  @override
  RenderObjectElement createElement() {
    return ContentLayersElement(this);
  }

  @override
  RenderObject createRenderObject(BuildContext context);
}

/// `Element` for a [ContentLayers] widget.
///
/// Must have a [renderObject] of type [RenderContentLayers].
class ContentLayersElement extends RenderObjectElement {
  ContentLayersElement(ContentLayers widget) : super(widget);

  List<Element> _underlays = <Element>[];
  Element? _content;
  List<Element> _overlays = <Element>[];

  // We need to track the children for which framework has called `forgetChild`,
  // these need to be excluded from the `visitChildren` method until next `update()`.
  // `forgetChild` is called for elements that will be re-parented to avoid unmounting
  // and remounting them.
  final Set<Element> _forgottenChildren = HashSet<Element>();

  @override
  ContentLayers get widget => super.widget as ContentLayers;

  @override
  RenderContentLayers get renderObject => super.renderObject as RenderContentLayers;

  @override
  void mount(Element? parent, Object? newSlot) {
    contentLayersLog.fine("ContentLayersElement - mounting");
    super.mount(parent, newSlot);

    _content = inflateWidget(widget.content(_onContentBuildScheduled), contentSlot);
  }

  @override
  void activate() {
    contentLayersLog.fine("ContentLayersElement - activating");
    super.activate();
  }

  @override
  void deactivate() {
    contentLayersLog.fine("ContentLayersElement - deactivating");
    // We have to deactivate the underlays and overlays ourselves, because we
    // intentionally don't visit them in visitChildren().
    for (final underlay in _underlays) {
      deactivateChild(underlay);
    }
    _underlays = const [];

    for (final overlay in _overlays) {
      deactivateChild(overlay);
    }
    _overlays = const [];

    super.deactivate();
  }

  @override
  void unmount() {
    contentLayersLog.fine("ContentLayersElement - unmounting");
    super.unmount();
  }

  /// The content scheduled a build of itself.
  ///
  /// The content's layout might change, so mark our render object as needing layout,
  /// which rebuilds the layers after the content's next layout. Until then, a layer
  /// that's dirty keeps what it last built, rather than building against the content's
  /// outdated layout. See [ContentLayerState.build].
  ///
  /// This used to temporarily "forget" the layers, with [forgetChild], which stopped
  /// them from building during the build phase in older versions of Flutter, but
  /// [forgetChild] does nothing outside of debug builds anymore.
  void _onContentBuildScheduled() {
    if (!mounted || !renderObject.attached) {
      return;
    }
    renderObject.markNeedsLayout();
  }

  @override
  void markNeedsBuild() {
    contentLayersLog.finer("ContentLayersElement - marking needs build");
    super.markNeedsBuild();
  }

  /// Builds the underlays and overlays.
  void buildLayers() {
    contentLayersLog.finer("ContentLayersElement - (re)building layers");
    final List<Element> underlays = List<Element>.filled(widget.underlays.length, _NullElement.instance);
    for (int i = 0; i < underlays.length; i += 1) {
      late final Element child;
      if (i > _underlays.length - 1) {
        child = inflateWidget(widget.underlays[i](this), UnderlaySlot(i));
      } else {
        child = super.updateChild(_underlays[i], widget.underlays[i](this), UnderlaySlot(i))!;
      }
      _rebuildIfBuildWasDeferred(child);
      underlays[i] = child;
    }
    _underlays = underlays;

    final List<Element> overlays = List<Element>.filled(widget.overlays.length, _NullElement.instance);
    for (int i = 0; i < overlays.length; i += 1) {
      late final Element child;
      if (i > _overlays.length - 1) {
        child = inflateWidget(widget.overlays[i](this), OverlaySlot(i));
      } else {
        child = super.updateChild(_overlays[i], widget.overlays[i](this), OverlaySlot(i))!;
      }
      _rebuildIfBuildWasDeferred(child);
      overlays[i] = child;
    }
    _overlays = overlays;
  }

  /// Rebuilds the given [layer] if it deferred a build until the layers are built, and
  /// [updateChild] didn't rebuild it, which happens when a layer builder returns the
  /// same widget instance as before.
  void _rebuildIfBuildWasDeferred(Element layer) {
    if (layer is ContentLayerStatefulElement) {
      final state = layer.state;
      if (state is ContentLayerState && state._isBuildDeferredToLayout) {
        layer.rebuild(force: true);
      }
    }
  }

  @override
  Element inflateWidget(Widget newWidget, Object? newSlot) {
    final Element newChild = super.inflateWidget(newWidget, newSlot);

    assert(_debugCheckHasAssociatedRenderObject(newChild));

    return newChild;
  }

  @override
  void update(ContentLayers newWidget) {
    super.update(newWidget);

    final newContent = widget.content(_onContentBuildScheduled);

    assert(widget == newWidget);
    assert(!debugChildrenHaveDuplicateKeys(widget, [newContent]));

    _content = updateChild(_content, newContent, contentSlot);

    if (!renderObject.contentNeedsLayout) {
      // Layout has already run. No layout bounds changed. There might be a
      // non-layout change that needs to be painted, e.g., change to theme brightness.
      // Re-build all layers, which is safe to do because no layout constraints changed.
      buildLayers();
    }
    // Else, dirty content layout will cause this whole widget to re-layout. The
    // layers will be re-built during that layout pass.

    // super.update() and updateChild() is where the framework reparents
    // forgotten children. Therefore, at this point, the framework is
    // done with the concept of forgotten children, so we clear our
    // local cache of them, too.
    _forgottenChildren.clear();
  }

  @override
  Element? updateChild(Element? child, Widget? newWidget, Object? newSlot) {
    if (newSlot != contentSlot) {
      // Never update underlays or overlays because they MUST only build during
      // layout.
      return null;
    }

    return super.updateChild(child, newWidget, newSlot);
  }

  @override
  void insertRenderObjectChild(RenderObject child, Object? slot) {
    assert(slot != null);
    assert(isContentLayersSlot(slot!), "Invalid ContentLayers slot: $slot");

    renderObject.insertChild(child, slot!);
  }

  @override
  void moveRenderObjectChild(RenderObject child, Object? oldSlot, Object? newSlot) {
    assert(child.parent == renderObject);
    assert(oldSlot != null);
    assert(newSlot != null);
    assert(isContentLayersSlot(oldSlot!), "Invalid ContentLayers slot: $oldSlot");
    assert(isContentLayersSlot(newSlot!), "Invalid ContentLayers slot: $newSlot");

    // Can't move renderBox children to and from content slot (which is a sliver)
    if (oldSlot == contentSlot || newSlot == contentSlot) {
      assert(false);
    } else {
      renderObject.moveChildLayer(child as RenderBox, oldSlot!, newSlot!);
    }
  }

  @override
  void removeRenderObjectChild(RenderObject child, Object? slot) {
    assert(child.parent == renderObject);
    assert(slot != null);
    assert(isContentLayersSlot(slot!), "Invalid ContentLayers slot: $slot");

    renderObject.removeChild(child, slot!);
  }

  @override
  void forgetChild(Element child) {
    _forgottenChildren.add(child);
    super.forgetChild(child);
  }

  @override
  void visitChildren(ElementVisitor visitor) {
    // It is the responsibility of `visitChildren` to skip over forgotten children.
    if (_content != null && !_forgottenChildren.contains(_content)) {
      visitor(_content!);
    }

    // WARNING: Do not visit underlays or overlays when "locked". If you do, then the pipeline
    // owner will collect those children for rebuild, e.g., for hot reload, and the
    // pipeline owner will tell them to build before the content is laid out. We only
    // want the underlays and overlays to build during the layout phase, after the
    // content is laid out.

    // FIXME: locked is supposed to be private. We're using it as a proxy indication for when
    //        the build owner wants to build. Find an appropriate way to distinguish this.
    // ignore: invalid_use_of_protected_member
    if (!WidgetsBinding.instance.locked) {
      for (final Element child in _underlays) {
        if (!_forgottenChildren.contains(child)) {
          visitor(child);
        }
      }

      for (final Element child in _overlays) {
        if (!_forgottenChildren.contains(child)) {
          visitor(child);
        }
      }
    }
  }

  bool _debugCheckHasAssociatedRenderObject(Element newChild) {
    assert(() {
      if (newChild.renderObject == null) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: FlutterError.fromParts(<DiagnosticsNode>[
              ErrorSummary('The children of `ContentLayersElement` must each have an associated render object.'),
              ErrorHint(
                'This typically means that the `${newChild.widget}` or its children\n'
                'are not a subtype of `RenderObjectWidget`.',
              ),
              newChild.describeElement('The following element does not have an associated render object'),
              DiagnosticsDebugCreator(DebugCreator(newChild)),
            ]),
          ),
        );
      }
      return true;
    }());
    return true;
  }
}

abstract class RenderContentLayers implements RenderObject {
  /// Whether this render object's layout information or its content
  /// layout information is dirty.
  ///
  /// This is set to `true` when `markNeedsLayout` is called and it's
  /// set to `false` after laying out the content.
  bool get contentNeedsLayout;

  void insertChild(covariant RenderObject child, Object slot);

  void moveChildLayer(covariant RenderObject child, Object oldSlot, Object newSlot);

  void removeChild(covariant RenderObject child, Object slot);
}

bool isContentLayersSlot(Object slot) => slot == contentSlot || slot is UnderlaySlot || slot is OverlaySlot;

const contentSlot = "content";

class UnderlaySlot extends _IndexedSlot {
  const UnderlaySlot(int index) : super(index);

  @override
  String toString() => "[$UnderlaySlot] - underlay index: $index";
}

class OverlaySlot extends _IndexedSlot {
  const OverlaySlot(int index) : super(index);

  @override
  String toString() => "[$OverlaySlot] - overlay index: $index";
}

class _IndexedSlot {
  const _IndexedSlot(this.index);

  final int index;
}

/// Used as a placeholder in [List<Element>] objects when the actual
/// elements are not yet determined.
///
/// Copied from the framework.
class _NullElement extends Element {
  _NullElement() : super(const _NullWidget());

  static _NullElement instance = _NullElement();

  @override
  bool get debugDoingBuild => throw UnimplementedError();
}

class _NullWidget extends Widget {
  const _NullWidget();

  @override
  Element createElement() => throw UnimplementedError();
}

/// A widget builder, which builds a [ContentLayerWidget].
typedef ContentLayerWidgetBuilder = ContentLayerWidget Function(BuildContext context);

/// A widget that can be displayed as a layer in a [ContentLayers] widget.
///
/// [ContentLayers] uses a special type of layer widget to avoid timing issues with
/// Flutter's build order. This timing issue is only a concern when a layer
/// widget inspects content layout within [ContentLayers]. However, to prevent
/// developer confusion and mistakes, all layer widgets are forced to be
/// [ContentLayerWidget]s.
///
/// Extend [ContentLayerStatefulWidget] to create a layer that's based on the
/// content layout within the ancestor [ContentLayers], and requires mutable state.
///
/// Extend [ContentLayerStatelessWidget] to create a layer that's based on the
/// content layout within the ancestor [ContentLayers], but doesn't require mutable
/// state.
///
/// To quickly and easily build a layer from a traditional widget tree, create a
/// [ContentLayerProxyWidget] with the desired subtree. This approach is a
/// quicker and more convenient alternative to [ContentLayerStatelessWidget]
/// for the simplest of layer trees.
abstract class ContentLayerWidget implements Widget {
  // Marker interface.
}

/// A [ContentLayerWidget] that displays nothing.
///
/// Useful when a layer should conditionally display content. An [EmptyContentLayer] can
/// be returned in cases where no visuals are desired.
class EmptyContentLayer extends ContentLayerStatelessWidget {
  const EmptyContentLayer({super.key});

  @override
  Widget doBuild(BuildContext context, Element? contentElement, RenderObject? contentLayout) {
    return const SizedBox();
  }
}

/// Widget that builds a [ContentLayers] layer based on a traditional widget
/// subtree, as represented by the given [child].
///
/// The [child] subtree must NOT access the content layout within [ContentLayers].
///
/// This widget is an escape hatch to easily display traditional widget subtrees
/// as content layers, when those layers don't care about the layout of the content.
class ContentLayerProxyWidget extends ContentLayerStatelessWidget {
  const ContentLayerProxyWidget({
    super.key,
    required this.child,
  });

  final Widget child;

  @override
  Widget doBuild(BuildContext context, Element? contentElement, RenderObject? contentLayout) {
    return child;
  }
}

/// Widget that builds a stateless [ContentLayers] layer, which is given access
/// to the ancestor [ContentLayers] content [Element] and [RenderObject].
abstract class ContentLayerStatelessWidget extends StatelessWidget implements ContentLayerWidget {
  const ContentLayerStatelessWidget({super.key});

  @override
  Widget build(BuildContext context) {
    final contentLayers = (context as Element).findAncestorContentLayers();
    final contentElement = contentLayers?._content;
    final contentLayout = contentElement?.findRenderObject();

    return doBuild(context, contentElement, contentLayout);
  }

  @protected
  Widget doBuild(BuildContext context, Element? contentElement, RenderObject? contentLayout);
}

/// Widget that builds a stateful [ContentLayers] layer, which is given access
/// to the ancestor [ContentLayers] content [Element] and [RenderObject].
///
/// See [ContentLayerState] for information about why a special type of [StatefulWidget]
/// is required for use within [ContentLayers].
abstract class ContentLayerStatefulWidget<LayoutDataType> extends StatefulWidget implements ContentLayerWidget {
  const ContentLayerStatefulWidget({super.key});

  @override
  StatefulElement createElement() => ContentLayerStatefulElement(this);

  @override
  ContentLayerState<ContentLayerStatefulWidget, LayoutDataType> createState();
}

/// A [StatefulElement] that looks for an ancestor [ContentLayersElement] and marks
/// that element as needing to rebuild any time that this [ContentLayerStatefulElement]
/// needs to rebuild.
///
/// In effect, this [Element] connects its dirty state to an ancestor [ContentLayersElement].
class ContentLayerStatefulElement extends StatefulElement {
  ContentLayerStatefulElement(super.widget);

  bool _isActive = false;

  @override
  void activate() {
    super.activate();
    _isActive = true;
  }

  @override
  void deactivate() {
    _isActive = false;
    super.deactivate();
  }

  @override
  void markNeedsBuild() {
    if (_isActive && mounted) {
      // Our Element is attached to the tree. Mark our ancestor ContentLayers as
      // needing to build, too.
      //
      // Flutter blows up if we try to climb the Element tree when this Element
      // isn't active, because when this Element is deactivated, it's technically
      // detached from the tree until its reactivated or disposed.
      findAncestorContentLayers()?.markNeedsBuild();
    }

    super.markNeedsBuild();
  }
}

extension on Element {
  /// Finds and returns a [ContentLayersElement] by walking up the [Element] tree,
  /// beginning with this [Element].
  ContentLayersElement? findAncestorContentLayers() {
    ContentLayersElement? contentLayersElement;

    visitAncestorElements((element) {
      if (element is ContentLayersElement) {
        contentLayersElement = element;
        return false;
      }

      return true;
    });

    return contentLayersElement;
  }
}

/// A state object for a [ContentLayerStatefulWidget].
///
/// A [ContentLayerState] needs to be implemented a little bit differently than
/// a traditional [StatefulWidget]. Calling `setState()` will cause this widget
/// to rebuild, but the ancestor [ContentLayers] has no control over WHEN this
/// widget will rebuild. This widget might rebuild before the content layer can
/// run its layout. If this widget then attempts to query the content layout,
/// Flutter throws an exception.
///
/// To work around the rebuild timing issues, a [ContentLayerState] separates
/// layout inspection from the build process. A [ContentLayerState] should
/// collect all the layout information it needs in [computeLayoutData] and then
/// it should build its subtree in [doBuild].
///
/// A [ContentLayerState] should NOT implement [build] - that implementation is
/// handled on your behalf, and it coordinates between [computeLayoutData] and
/// [doBuild].
abstract class ContentLayerState<WidgetType extends ContentLayerStatefulWidget, LayoutDataType>
    extends State<WidgetType> {
  @protected
  LayoutDataType? get layoutData => _layoutData;
  LayoutDataType? _layoutData;

  /// The subtree that [doBuild] returned last.
  Widget? _builtSubtree;

  /// Whether this layer skipped a build because the ancestor [ContentLayers] is about to
  /// rebuild every layer, after the content's next layout.
  bool _isBuildDeferredToLayout = false;

  /// Traditional build method for this widget - this method should not be overridden
  /// in subclasses.
  @override
  Widget build(BuildContext context) {
    final contentLayers = (context as Element).findAncestorContentLayers();
    final contentElement = contentLayers?._content;
    final contentLayout = contentElement?.findRenderObject();

    final builtSubtree = _builtSubtree;
    if (contentLayers != null && contentLayers.renderObject.contentNeedsLayout && builtSubtree != null) {
      // The content needs layout, and ContentLayers builds every layer again after the
      // content's layout. Build there, against the new content layout, rather than now,
      // against the old one, and keep what this layer built last until then.
      _isBuildDeferredToLayout = true;
      return builtSubtree;
    }
    _isBuildDeferredToLayout = false;

    if (contentLayers != null && !contentLayers.renderObject.contentNeedsLayout) {
      _layoutData = computeLayoutData(contentElement, contentLayout);
    }

    return _builtSubtree = doBuild(context, _layoutData);
  }

  @override
  void reassemble() {
    super.reassemble();

    // Build again after a hot reload.
    _builtSubtree = null;
  }

  /// Computes and returns cached layout data, derived from the content layer's [Element]
  /// and [RenderObject].
  ///
  /// Subclasses can choose what action to take when the [contentElement] or [contentLayout]
  /// are `null`, and therefore unavailable.
  LayoutDataType? computeLayoutData(Element? contentElement, RenderObject? contentLayout);

  /// Composes and returns the subtree for this widget.
  ///
  /// This method should be treated as the replacement for the traditional [build] method.
  ///
  /// [doBuild] is provided with the latest available layout data, which was computed
  /// by [computeLayoutData].
  @protected
  Widget doBuild(BuildContext context, LayoutDataType? layoutData);
}
