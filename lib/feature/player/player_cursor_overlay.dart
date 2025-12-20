import 'dart:async';

import 'package:flutter/material.dart';

/// Controller to restart cursor auto-hide countdown from outside.
class CursorAutoHideController {
  final ValueNotifier<int> _tick = ValueNotifier<int>(0);
  final ValueNotifier<int> _hideNowTick = ValueNotifier<int>(0);

  void kick() => _tick.value++;
  void hideNow() => _hideNowTick.value++;
}

/// Transparent overlay that auto-hides the mouse cursor after [idle].
/// Lives inside the video controls overlay while fullscreen is active.
class PlayerCursorAutoHideOverlay extends StatefulWidget {
  const PlayerCursorAutoHideOverlay({
    super.key,
    this.idle = const Duration(seconds: 3),
    this.forceVisible = false,
    this.controller,
  });

  final Duration idle;
  final bool forceVisible;
  final CursorAutoHideController? controller;

  @override
  State<PlayerCursorAutoHideOverlay> createState() =>
      _PlayerCursorAutoHideOverlayState();
}

class _PlayerCursorAutoHideOverlayState
    extends State<PlayerCursorAutoHideOverlay> {
  bool _visible = true;
  Timer? _t;
  VoidCallback? _controllerSub;
  VoidCallback? _hideNowSub;

  void _bump() {
    _t?.cancel();
    if (!_visible) setState(() => _visible = true);
    if (widget.forceVisible) return;
    _t = Timer(widget.idle, () {
      if (!mounted) return;
      setState(() => _visible = false);
    });
  }

  @override
  void initState() {
    super.initState();
    _bump();

    _controllerSub = _bump;
    widget.controller?._tick.addListener(_controllerSub!);

    _hideNowSub = () {
      _t?.cancel();
      if (_visible) setState(() => _visible = false);
    };
    widget.controller?._hideNowTick.addListener(_hideNowSub!);
  }

  @override
  void didUpdateWidget(covariant PlayerCursorAutoHideOverlay old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      if (old.controller != null && _controllerSub != null) {
        old.controller!._tick.removeListener(_controllerSub!);
        old.controller!._hideNowTick.removeListener(_hideNowSub!);
      }
      if (widget.controller != null) {
        widget.controller!._tick.addListener(_controllerSub!);
        widget.controller!._hideNowTick.addListener(_hideNowSub!);
      }
    }

    if (widget.forceVisible && !_visible) {
      setState(() => _visible = true);
    }
  }

  @override
  void dispose() {
    _t?.cancel();
    if (widget.controller != null) {
      if (_controllerSub != null) {
        widget.controller!._tick.removeListener(_controllerSub!);
      }
      if (_hideNowSub != null) {
        widget.controller!._hideNowTick.removeListener(_hideNowSub!);
      }
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerHover: (_) => _bump(),
      onPointerMove: (_) => _bump(),
      onPointerDown: (_) => _bump(),
      onPointerSignal: (_) => _bump(),
      child: MouseRegion(
        opaque: false,
        cursor: (widget.forceVisible || _visible)
            ? SystemMouseCursors.basic
            : SystemMouseCursors.none,
        child: const SizedBox.expand(),
      ),
    );
  }
}
