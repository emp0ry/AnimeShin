import 'package:animeshin/feature/watch/watch_types.dart';
import 'package:flutter/material.dart';

Future<void> openSupport(AnimeVoice voice, BuildContext context) async {
  // No provider-specific support links in modules-only mode.
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text('Support links not available for modules')),
  );
}
