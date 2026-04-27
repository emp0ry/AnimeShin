import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// Returns the default controls and provides a [BuildContext] that sits inside
/// the Video controls subtree (required for media_kit fullscreen helpers).
class ControlsCtxBridge extends StatefulWidget {
  const ControlsCtxBridge({
    super.key,
    required this.state,
    required this.onReady,
    this.overlay,
    this.onPointerDown,
    this.onPointerMove,
    this.onPointerHover,
    this.onPointerEnter,
    this.onPointerExit,
  });

  final VideoState state;
  final void Function(BuildContext ctx, VideoState state) onReady;
  final Widget? overlay;
  final void Function(BuildContext ctx, PointerDownEvent event)? onPointerDown;
  final void Function(PointerMoveEvent event)? onPointerMove;
  final void Function(PointerHoverEvent event)? onPointerHover;
  final void Function(PointerEnterEvent event)? onPointerEnter;
  final void Function(PointerExitEvent event)? onPointerExit;

  @override
  State<ControlsCtxBridge> createState() => _ControlsCtxBridgeState();
}

class _ControlsCtxBridgeState extends State<ControlsCtxBridge> {
  bool _notified = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_notified) {
      _notified = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        widget.onReady(context, widget.state);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final controls = AdaptiveVideoControls(widget.state);
    final overlay = widget.overlay;
    final content = overlay == null
        ? controls
        : Stack(
            fit: StackFit.expand,
            children: [
              controls,
              overlay,
            ],
          );

    return MouseRegion(
      opaque: false,
      onEnter: widget.onPointerEnter,
      onExit: widget.onPointerExit,
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: widget.onPointerDown == null
            ? null
            : (event) => widget.onPointerDown!(context, event),
        onPointerMove: widget.onPointerMove,
        onPointerHover: widget.onPointerHover,
        child: content,
      ),
    );
  }
}
