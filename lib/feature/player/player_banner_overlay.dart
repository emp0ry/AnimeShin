import 'package:flutter/material.dart';

class PlayerBannerOverlay extends StatelessWidget {
  const PlayerBannerOverlay({
    super.key,
    required this.visible,
    required this.text,
    required this.showUndo,
    required this.onUndo,
  });

  final bool visible;
  final String text;
  final bool showUndo;
  final VoidCallback onUndo;

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox.shrink();

    return Positioned(
      right: 16,
      top: 16,
      child: Material(
        color: Colors.black.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(text, style: const TextStyle(color: Colors.white)),
              if (showUndo) ...[
                const SizedBox(width: 12),
                TextButton(
                  onPressed: onUndo,
                  child: const Text('UNDO'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
