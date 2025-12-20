import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// Returns the default controls and provides a [BuildContext] that sits inside
/// the Video controls subtree (required for media_kit fullscreen helpers).
class ControlsCtxBridge extends StatefulWidget {
  const ControlsCtxBridge({
    super.key,
    required this.state,
    required this.onReady,
  });

  final VideoState state;
  final void Function(BuildContext ctx) onReady;

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
        widget.onReady(context);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AdaptiveVideoControls(widget.state);
  }
}
