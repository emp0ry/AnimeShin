import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:ionicons/ionicons.dart';
import 'package:animeshin/extension/date_time_extension.dart';
import 'package:animeshin/feature/media/media_route_tile.dart';
import 'package:animeshin/util/theming.dart';
import 'package:animeshin/feature/collection/collection_models.dart';
import 'package:animeshin/widget/cached_image.dart';
import 'package:animeshin/widget/input/note_label.dart';
import 'package:animeshin/widget/input/score_label.dart';
import 'package:animeshin/widget/text_rail.dart';
import 'package:animeshin/feature/media/media_models.dart';

const _tileHeight = 140.0;

class CollectionList extends StatelessWidget {
  const CollectionList({
    required this.items,
    required this.scoreFormat,
    required this.onProgressUpdated,
  });

  final List<Entry> items;
  final ScoreFormat scoreFormat;
  /// Signature: (entry, setAsCurrent) -> error message or null
  final Future<String?> Function(Entry, bool)? onProgressUpdated;

  @override
  Widget build(BuildContext context) {
    return SliverFixedExtentList(
      delegate: SliverChildBuilderDelegate(
        (_, i) => _Tile(items[i], scoreFormat, onProgressUpdated),
        childCount: items.length,
      ),
      itemExtent: _tileHeight + Theming.offset,
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile(this.entry, this.scoreFormat, this.onProgressUpdated);

  final Entry entry;
  final ScoreFormat scoreFormat;
  final Future<String?> Function(Entry, bool)? onProgressUpdated;

  @override
  Widget build(BuildContext context) {
    return _TileWidget(entry, scoreFormat, onProgressUpdated);
  }
}

class _TileWidget extends StatefulWidget {
  const _TileWidget(this.entry, this.scoreFormat, this.onProgressUpdated);

  final Entry entry;
  final ScoreFormat scoreFormat;
  final Future<String?> Function(Entry, bool)? onProgressUpdated;

  @override
  State<_TileWidget> createState() => _TileState();
}

class _TileState extends State<_TileWidget> {
  bool _busy = false;

  bool get _canIncrement {
    final max = widget.entry.progressMax;
    if (max == null) return true;
    return widget.entry.progress < max;
  }

  bool get _canDecrement => widget.entry.progress > 0;

  void _optimisticInc() => setState(() => widget.entry.progress += 1);
  void _optimisticDec() => setState(() => widget.entry.progress -= 1);

  void _persistWithUndo({
    required BuildContext context,
    required Future<String?> Function() persist,
    required Future<void> Function() undoOptimistic,
    required String snackLabel,
  }) {
    // Run after the current frame so we don't block the animation.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // Close the slidable smoothly
      Slidable.of(context)?.close();
      // Medium haptic after the animation feels nicer
      HapticFeedback.mediumImpact();

      // Fire-and-forget persist; if it fails, revert.
      final err = await persist();
      if (err != null) {
        await undoOptimistic();
        return;
      }

      final messenger = ScaffoldMessenger.of(context);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text(snackLabel),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () async {
              HapticFeedback.selectionClick();
              await undoOptimistic();
            },
          ),
          duration: const Duration(seconds: 3),
        ),
      );
    });
  }

  Future<String?> _saveProgress() async {
    if (widget.onProgressUpdated == null) return null;
    return widget.onProgressUpdated!(widget.entry, false);
  }

  Future<void> _runAction({
    required BuildContext context,
    required Future<void> Function() doAction,
    required Future<void> Function()? undoAction,
    required String label,
  }) async {
    if (_busy) return;
    _busy = true;

    // Start haptic
    HapticFeedback.lightImpact();

    try {
      await doAction();
      // Confirm haptic
      HapticFeedback.mediumImpact();

      // Close slidable if open
      Slidable.of(context)?.close();

      // Show Undo
      final messenger = ScaffoldMessenger.of(context);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text(label),
          action: undoAction != null
              ? SnackBarAction(
                  label: 'Undo',
                  onPressed: () async {
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

  Future<void> _increment(BuildContext context) async {
    if (!_canIncrement || widget.onProgressUpdated == null) return;
    setState(() => widget.entry.progress += 1);
    final err = await widget.onProgressUpdated!(widget.entry, false);
    if (err != null) {
      // revert on error
      setState(() => widget.entry.progress -= 1);
    }
  }

  Future<void> _decrement(BuildContext context) async {
    if (!_canDecrement || widget.onProgressUpdated == null) return;
    setState(() => widget.entry.progress -= 1);
    final err = await widget.onProgressUpdated!(widget.entry, false);
    if (err != null) {
      // revert on error
      setState(() => widget.entry.progress += 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Theming.offset),
      child: Slidable(
        key: ValueKey(widget.entry.mediaId),
        groupTag: 'collection-tiles',

        // Start (swipe right) → decrement
        startActionPane: ActionPane(
          motion: const StretchMotion(),        // smoothest on desktop
          extentRatio: 0.24,                    // a bit smaller feels snappier
          dismissible: DismissiblePane(
            confirmDismiss: () {
              if (!_canDecrement) return Future.value(false);

              HapticFeedback.lightImpact();     // start haptic
              _optimisticDec();                 // instant UI update

              _persistWithUndo(
                context: context,
                persist: _saveProgress,         // async, runs post-frame
                undoOptimistic: () async {      // revert path
                  setState(() => widget.entry.progress += 1);
                  await _saveProgress();
                },
                snackLabel: 'Progress -1',
              );

              return Future.value(false);       // never actually dismiss
            },
            onDismissed: () {},                 // no-op; not called because we return false
            closeOnCancel: true,
          ),
          children: [
            SlidableAction(
              onPressed: (_) {
                if (!_canDecrement) return;
                HapticFeedback.lightImpact();
                _optimisticDec();
                _persistWithUndo(
                  context: context,
                  persist: _saveProgress,
                  undoOptimistic: () async {
                    setState(() => widget.entry.progress += 1);
                    await _saveProgress();
                  },
                  snackLabel: 'Progress -1',
                );
              },
              icon: Ionicons.remove,
              backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
              foregroundColor: Theme.of(context).colorScheme.onSecondaryContainer,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              borderRadius: BorderRadius.circular(8),
              autoClose: true,
            ),
          ],
        ),

        // End (swipe left) → increment
        endActionPane: ActionPane(
          motion: const StretchMotion(),
          extentRatio: 0.24,
          dismissible: DismissiblePane(
            confirmDismiss: () {
              if (!_canIncrement) return Future.value(false);

              HapticFeedback.lightImpact();
              _optimisticInc();

              _persistWithUndo(
                context: context,
                persist: _saveProgress,
                undoOptimistic: () async {
                  setState(() => widget.entry.progress -= 1);
                  await _saveProgress();
                },
                snackLabel: 'Progress +1',
              );

              return Future.value(false);
            },
            onDismissed: () {},
            closeOnCancel: true,
          ),
          children: [
            SlidableAction(
              onPressed: (_) {
                if (!_canIncrement) return;
                HapticFeedback.lightImpact();
                _optimisticInc();
                _persistWithUndo(
                  context: context,
                  persist: _saveProgress,
                  undoOptimistic: () async {
                    setState(() => widget.entry.progress -= 1);
                    await _saveProgress();
                  },
                  snackLabel: 'Progress +1',
                );
              },
              icon: Ionicons.add,
              backgroundColor: Theme.of(context).colorScheme.primaryContainer,
              foregroundColor: Theme.of(context).colorScheme.onPrimaryContainer,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              borderRadius: BorderRadius.circular(8),
              autoClose: true,
            ),
          ],
        ),

        child: SizedBox(
          height: _tileHeight,
          child: Card(
            margin: EdgeInsets.zero,
            child: MediaRouteTile(
              key: ValueKey(widget.entry.mediaId),
              id: widget.entry.mediaId,
              imageUrl: widget.entry.imageUrl,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Hero(
                    tag: widget.entry.mediaId,
                    child: ClipRRect(
                      borderRadius: const BorderRadius.horizontal(
                        left: Theming.radiusSmall,
                      ),
                      child: Container(
                        width: _tileHeight / Theming.coverHtoWRatio,
                        color: ColorScheme.of(context).surfaceContainerHighest,
                        child: CachedImage(widget.entry.imageUrl),
                      ),
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: Theming.paddingAll,
                      child: _TileContent(
                        widget.entry,
                        widget.scoreFormat,
                        widget.onProgressUpdated,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TileContent extends StatefulWidget {
  const _TileContent(this.item, this.scoreFormat, this.onProgressUpdated);

  final Entry item;
  final ScoreFormat scoreFormat;
  final Future<String?> Function(Entry, bool)? onProgressUpdated;

  @override
  State<_TileContent> createState() => __TileContentState();
}

class __TileContentState extends State<_TileContent> {
  @override
  Widget build(BuildContext context) {
    final item = widget.item;

    double progressPercent = 0;
    if (item.progressMax != null && item.progressMax! > 0) {
      progressPercent = item.progress / item.progressMax!;
    } else if (item.nextEpisode != null && item.nextEpisode! > 1) {
      progressPercent = item.progress / (item.nextEpisode! - 1);
    } else if (item.progress > 0) {
      progressPercent = 1;
    }
    progressPercent = progressPercent.clamp(0.0, 1.0);

    final textRailItems = <String, bool>{};

    if (widget.item.ruTitle != null) {
      textRailItems['${widget.item.ruTitle}\n'] = false;
    }

    if (widget.item.format != null) {
      textRailItems[widget.item.format!.label] = false;
    }

    if (widget.item.airingAt != null) {
      final key =
          'Ep ${widget.item.nextEpisode} in ${widget.item.airingAt!.timeUntil}';
      textRailItems[key] = false;
    }

    if (widget.item.nextEpisode != null &&
        widget.item.nextEpisode! - 1 > widget.item.progress) {
      String key;
      if (widget.item.ruLastEpisode != null &&
          widget.item.ruLastEpisode! > widget.item.progress) {
        key =
            '${widget.item.nextEpisode! - 1 - widget.item.progress} ep behind (✔️AL)';
      } else {
        key =
            '${widget.item.nextEpisode! - 1 - widget.item.progress} ep behind (✖️AL)';
      }
      textRailItems[key] = true;
    }

    return Column(
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Flexible(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Flexible(
                child: Text(
                  widget.item.titles[0],
                  overflow: TextOverflow.fade,
                ),
              ),
              const SizedBox(height: 5),
              TextRail(textRailItems),
            ],
          ),
        ),
        Container(
          height: 5,
          margin: const EdgeInsets.symmetric(vertical: 3),
          decoration: BoxDecoration(
            borderRadius: Theming.borderRadiusSmall,
            gradient: LinearGradient(
              colors: [
                ColorScheme.of(context).onSurfaceVariant,
                ColorScheme.of(context).onSurfaceVariant,
                ColorScheme.of(context).surface,
                ColorScheme.of(context).surface,
              ],
              stops: [0.0, progressPercent, progressPercent, 1.0],
            ),
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            ScoreLabel(widget.item.score, widget.scoreFormat),
            if (widget.item.repeat > 0)
              Tooltip(
                message: 'Repeats',
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Ionicons.repeat, size: Theming.iconSmall),
                    const SizedBox(width: 3),
                    Text(
                      widget.item.repeat.toString(),
                      style: TextTheme.of(context).labelSmall,
                    ),
                  ],
                ),
              )
            else
              const SizedBox(),
            NotesLabel(item.notes),
            Text(
              widget.item.progress == widget.item.progressMax
                  ? widget.item.progress.toString()
                  : '${widget.item.progress}/${widget.item.progressMax ?? "?"}',
              style: TextTheme.of(context).labelSmall?.copyWith(
                    color: (widget.item.nextEpisode != null &&
                            widget.item.progress + 1 <
                                widget.item.nextEpisode!)
                        ? ColorScheme.of(context).error
                        : ColorScheme.of(context).onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ],
    );
  }
}
