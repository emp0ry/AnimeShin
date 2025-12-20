import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_slidable/flutter_slidable.dart';

/// A safe Slidable tile for progress +/- with haptics + Undo.
/// Not dismissible from the tree — we only trigger actions, then auto-close.
class ProgressSlidableTile extends StatefulWidget {
  const ProgressSlidableTile({
    super.key,
    required this.child,
    required this.onIncrement,
    required this.onDecrement,
    this.onUndoIncrement, // optional: how to revert an increment
    this.onUndoDecrement, // optional: how to revert a decrement
    this.snackBarLabelAdd = 'Progress +1',
    this.snackBarLabelSub = 'Progress -1',
    this.undoLabel = 'Undo',
  });

  final Widget child;

  /// Called when user triggers +1 (tap or full swipe).
  /// Should perform the mutation (e.g., update provider / save).
  final Future<void> Function() onIncrement;

  /// Called when user triggers -1 (tap or full swipe).
  final Future<void> Function() onDecrement;

  /// If provided, used to revert the last +1 action when the user taps Undo.
  final Future<void> Function()? onUndoIncrement;

  /// If provided, used to revert the last -1 action when the user taps Undo.
  final Future<void> Function()? onUndoDecrement;

  final String snackBarLabelAdd;
  final String snackBarLabelSub;
  final String undoLabel;

  @override
  State<ProgressSlidableTile> createState() => _ProgressSlidableTileState();
}

class _ProgressSlidableTileState extends State<ProgressSlidableTile> {
  bool _busy = false;

  Future<void> _runAction({
    required BuildContext context,
    required Future<void> Function() doAction,
    required Future<void> Function()? undoAction,
    required String label,
  }) async {
    if (_busy) return;
    _busy = true;

    // light haptic for action start
    HapticFeedback.lightImpact();

    try {
      await doAction();
      if (!context.mounted) return;
      // medium haptic when the change completes
      HapticFeedback.mediumImpact();

      // close the slidable if open
      Slidable.of(context)?.close();

      // show Undo
      final messenger = ScaffoldMessenger.of(context);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text(label),
          action: undoAction != null
              ? SnackBarAction(
                  label: widget.undoLabel,
                  onPressed: () async {
                    if (!mounted) return;
                    // subtle feedback for undo
                    HapticFeedback.selectionClick();
                    await undoAction();
                  },
                )
              : null,
          duration: const Duration(seconds: 3),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Slidable(
      // IMPORTANT: give your list item a stable key where you use this widget.
      // Here, Slidable itself does not dismiss/remove the child from the tree.
      groupTag: 'progress-tiles',
      startActionPane: ActionPane(
        motion: const StretchMotion(),
        extentRatio: 0.25,
        children: [
          SlidableAction(
            onPressed: (_) => _runAction(
              context: context,
              doAction: widget.onDecrement,
              undoAction: widget.onUndoDecrement,
              label: widget.snackBarLabelSub,
            ),
            icon: Icons.remove,
          ),
        ],
      ),
      endActionPane: ActionPane(
        motion: const StretchMotion(),
        extentRatio: 0.25,
        children: [
          SlidableAction(
            onPressed: (_) => _runAction(
              context: context,
              doAction: widget.onIncrement,
              undoAction: widget.onUndoIncrement,
              label: widget.snackBarLabelAdd,
            ),
            icon: Icons.add,
          ),
        ],
      ),
      child: widget.child,
    );
  }
}
