import 'dart:async';

import 'package:animeshin/feature/player/player_config.dart';
import 'package:animeshin/feature/watch/watch_types.dart';
import 'package:flutter/material.dart';

List<Widget> buildPlayerAppBarActions({
  required BuildContext context,
  required bool isIOS,
  required VoidCallback onOpenIOSPlayer,
  required PlayerQuality currentQuality,
  required double speed,
  required int seekStepSeconds,
  required bool autoSkipOpening,
  required bool autoSkipEnding,
  required bool autoNextEpisode,
  required bool autoProgress,
  required bool subtitlesEnabled,
  required Future<void> Function(PlayerQuality quality) onSelectQuality,
  required Future<void> Function(double speed) onSelectSpeed,
  required VoidCallback onOpenSeekStep,
  required VoidCallback onToggleAutoSkipOpening,
  required VoidCallback onToggleAutoSkipEnding,
  required VoidCallback onToggleAutoNextEpisode,
  required VoidCallback onToggleAutoProgress,
  required VoidCallback onToggleSubtitles,
  required VoidCallback onOpenSubtitleStyle,
  required AnimeVoice animeVoice,
}) {
  return <Widget>[
    if (isIOS)
      IconButton(
        tooltip: 'Open iOS Player',
        icon: const Icon(Icons.play_circle_fill),
        onPressed: onOpenIOSPlayer,
      ),
    PopupMenuButton<PlayerQuality>(
      tooltip: 'Quality',
      onSelected: (q) {
        unawaited(onSelectQuality(q));
      },
      itemBuilder: (_) {
        PopupMenuItem<PlayerQuality> item(PlayerQuality quality) =>
            PopupMenuItem<PlayerQuality>(
              value: quality,
              child: Row(
                children: [
                  if (currentQuality == quality)
                    const Icon(Icons.check, size: 16)
                  else
                    const SizedBox(width: 16),
                  const SizedBox(width: 8),
                  Text(quality.label),
                ],
              ),
            );

        return PlayerQuality.menuOrder.map(item).toList();
      },
      child: Row(
        children: [
          const Icon(Icons.high_quality),
          const SizedBox(width: 6),
          Text(currentQuality.label),
          const SizedBox(width: 12),
        ],
      ),
    ),
    PopupMenuButton<double>(
      tooltip: 'Speed',
      initialValue: speed,
      onSelected: (r) {
        unawaited(onSelectSpeed(r));
      },
      itemBuilder: (_) => PlayerTuning.speedMenu
          .map<PopupMenuEntry<double>>(
            (s) => PopupMenuItem<double>(value: s, child: Text('${s}x')),
          )
          .toList(),
      child: Row(
        children: [
          const Icon(Icons.speed),
          const SizedBox(width: 6),
          Text(
              '${speed.toStringAsFixed(speed == speed.roundToDouble() ? 0 : 2)}x'),
          const SizedBox(width: 12),
        ],
      ),
    ),
    PopupMenuButton<String>(
      tooltip: 'Preferences',
      onSelected: (_) {},
      itemBuilder: (_) => [
        PopupMenuItem<String>(
          value: 'seek_step',
          onTap: onOpenSeekStep,
          child: Text('Seek step… ($seekStepSeconds s)'),
        ),
        CheckedPopupMenuItem<String>(
          value: 'skip_op',
          checked: autoSkipOpening,
          onTap: onToggleAutoSkipOpening,
          child: const Text('Auto-skip Opening'),
        ),
        CheckedPopupMenuItem<String>(
          value: 'skip_ed',
          checked: autoSkipEnding,
          onTap: onToggleAutoSkipEnding,
          child: const Text('Auto-skip Ending'),
        ),
        CheckedPopupMenuItem<String>(
          value: 'auto_next',
          checked: autoNextEpisode,
          onTap: onToggleAutoNextEpisode,
          child: const Text('Auto next episode'),
        ),
        CheckedPopupMenuItem<String>(
          value: 'auto_progress',
          checked: autoProgress,
          onTap: onToggleAutoProgress,
          child: const Text('Auto Progress'),
        ),
        CheckedPopupMenuItem<String>(
          value: 'subs',
          checked: subtitlesEnabled,
          onTap: onToggleSubtitles,
          child: const Text('Subtitles'),
        ),
        PopupMenuItem<String>(
          value: 'sub_style',
          onTap: onOpenSubtitleStyle,
          child: const Text('Subtitle style…'),
        ),
      ],
      child: const Padding(
        padding: EdgeInsets.only(right: 8),
        child: Icon(Icons.settings),
      ),
    ),
    const SizedBox(width: 2),
  ];
}
