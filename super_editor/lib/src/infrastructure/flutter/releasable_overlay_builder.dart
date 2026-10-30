import 'package:flutter/widgets.dart';

/// Builds an [OverlayPortal]'s overlay child while its `State` is mounted.
///
/// Flutter 3.44 keeps a disposed portal's state, its widget and so this builder in
/// `SemanticsOwner._traversalChildNodes` while semantics are on (fixed upstream in
/// flutter/flutter#186118); a tear-off of the `State`'s method would keep the `State`,
/// its widget and the whole editor alive.
///
/// The `State` that owns the portal creates one with the method that builds the overlay
/// child, passes [build] as the portal's `overlayChildBuilder`, and calls [release] in
/// its `dispose()`:
///
/// ```dart
/// late final _overlayChild = ReleasableOverlayBuilder(_buildToolbar);
///
/// @override
/// void dispose() {
///   _overlayChild.release();
///   super.dispose();
/// }
///
/// @override
/// Widget build(BuildContext context) {
///   return OverlayPortal(
///     controller: _overlayController,
///     overlayChildBuilder: _overlayChild.build,
///     child: const SizedBox(),
///   );
/// }
/// ```
///
/// The portal keeps its `child` too. When the `child` reaches the `State`, for example
/// through a callback, pass it through [child], which [release] lets go of as well.
final class ReleasableOverlayBuilder {
  ReleasableOverlayBuilder(WidgetBuilder builder) : _builder = builder;

  WidgetBuilder? _builder;
  Widget? _child;

  /// Builds the overlay child, or nothing once [release]d.
  Widget build(BuildContext context) => _builder?.call(context) ?? const SizedBox.shrink();

  /// Returns a widget that shows [child], for an [OverlayPortal]'s `child`, which keeps
  /// [child] only until [release].
  Widget child(Widget child) {
    _child = child;
    return _ReleasableOverlayPortalChild(this);
  }

  /// Lets go of the builder, and of the [child], so that a portal that outlives its
  /// `State` doesn't keep the `State` alive.
  void release() {
    _builder = null;
    _child = null;
  }
}

/// An [OverlayPortal]'s `child`, which shows the latest [ReleasableOverlayBuilder.child].
///
/// A new one is made each time the owning `State` builds, so that it rebuilds with the
/// latest child.
class _ReleasableOverlayPortalChild extends StatelessWidget {
  const _ReleasableOverlayPortalChild(this._holder);

  final ReleasableOverlayBuilder _holder;

  @override
  Widget build(BuildContext context) => _holder._child ?? const SizedBox.shrink();
}
