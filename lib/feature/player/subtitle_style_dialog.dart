import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:animeshin/feature/player/player_prefs.dart';

Future<void> showSubtitleStyleDialog({
  required BuildContext context,
  required WidgetRef ref,
  required bool isDesktop,
}) async {
  final prefs = ref.read(playerPrefsProvider);

  var size = prefs.subtitleFontSize;
  var color = prefs.subtitleColor;
  var outline = prefs.subtitleOutlineSize;

  const colors = <({String label, String hex})>[
    (label: 'White', hex: 'FFFFFF'),
    (label: 'Yellow', hex: 'FFD54F'),
    (label: 'Cyan', hex: '80DEEA'),
    (label: 'Green', hex: 'A5D6A7'),
  ];

  const outlines = <({String label, int v})>[
    (label: 'None', v: 0),
    (label: 'Thin', v: 2),
    (label: 'Thick', v: 4),
  ];

  await showDialog<void>(
    context: context,
    builder: (ctx) {
      return AlertDialog(
        title: const Text('Subtitle style'),
        content: StatefulBuilder(
          builder: (ctx, setState) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!isDesktop)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 12),
                    child: Text(
                      'Subtitle styling is currently supported on desktop only.',
                    ),
                  ),
                Text('Size: $size'),
                Slider(
                  value: size.toDouble(),
                  min: 20,
                  max: 90,
                  divisions: 70,
                  label: size.toString(),
                  onChanged: (v) {
                    setState(() => size = v.round());
                  },
                ),
                const SizedBox(height: 8),
                const Text('Color'),
                DropdownButton<String>(
                  value:
                      colors.any((c) => c.hex == color) ? color : colors.first.hex,
                  isExpanded: true,
                  items: [
                    for (final c in colors)
                      DropdownMenuItem(value: c.hex, child: Text(c.label)),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() => color = v);
                  },
                ),
                const SizedBox(height: 8),
                const Text('Outline'),
                DropdownButton<int>(
                  value: outlines.any((o) => o.v == outline)
                      ? outline
                      : outlines.first.v,
                  isExpanded: true,
                  items: [
                    for (final o in outlines)
                      DropdownMenuItem(value: o.v, child: Text(o.label)),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() => outline = v);
                  },
                ),
              ],
            );
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              final n = ref.read(playerPrefsProvider.notifier);
              await n.setSubtitleFontSize(size);
              await n.setSubtitleColor(color);
              await n.setSubtitleOutlineSize(outline);
              if (ctx.mounted) Navigator.of(ctx).pop();
            },
            child: const Text('Save'),
          ),
        ],
      );
    },
  );
}
