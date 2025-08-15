import 'package:animeshin/feature/watch/watch_page.dart';
import 'package:animeshin/repository/shikimori/shikimori_rest_repository.dart';
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
  bool get _canIncrement {
    final max = widget.entry.progressMax;
    if (max == null) return true;
    return widget.entry.progress < max;
  }

  bool get _canDecrement => widget.entry.progress > 0;

  void _optimisticInc() => setState(() => widget.entry.progress += 1);
  void _optimisticDec() => setState(() => widget.entry.progress -= 1);

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

              HapticFeedback.mediumImpact();    // start haptic
              _optimisticDec();                 // instant UI update

              return Future.value(false);       // never actually dismiss
            },
            onDismissed: () {},                 // no-op; not called because we return false
            closeOnCancel: true,
          ),
          children: [
            SlidableAction(
              onPressed: (_) {
                if (!_canDecrement) return;
                HapticFeedback.mediumImpact();
                _optimisticDec();
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

              HapticFeedback.mediumImpact();
              _optimisticInc();

              return Future.value(false);
            },
            onDismissed: () {},
            closeOnCancel: true,
          ),
          children: [
            SlidableAction(
              onPressed: (_) {
                if (!_canIncrement) return;
                HapticFeedback.mediumImpact();
                _optimisticInc();
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

    
    if (widget.item.titles.last.isNotEmpty && widget.item.ruTitleState != null && widget.item.ruTitleState!) {
      if (russianRegex.hasMatch(widget.item.titles.last)) {
        textRailItems['${widget.item.titles.last}\n'] = false;
      }
    }

    if (widget.item.format != null) {
      textRailItems[widget.item.format!.label] = false;
    }

    if (widget.item.airingAt != null) {
      final key = 'Ep ${widget.item.nextEpisode} in ${widget.item.airingAt!.timeUntil}';
      textRailItems[key] = false;
    }

    if (widget.item.nextEpisode != null &&
        widget.item.nextEpisode! - 1 > widget.item.progress) {
      String key;

      if (widget.item.anilibriaEpDubState != null && widget.item.anilibriaEpDubState!) {
        if (widget.item.lastAniLibriaEpisode != null && widget.item.lastAniLibriaEpisode! > widget.item.progress) {
          key = '${widget.item.nextEpisode! - 1 - widget.item.progress} ep behind (✔️AL)';
        } else if (widget.item.lastAniLibriaEpisode != null) {
          key = '${widget.item.nextEpisode! - 1 - widget.item.progress} ep behind (✖️AL)';
        }
        else {
          key = '${widget.item.nextEpisode! - 1 - widget.item.progress} ep behind';
        }
      }
      else {
          key = '${widget.item.nextEpisode! - 1 - widget.item.progress} ep behind';
      }
      
      textRailItems[key] = true;
    }

    return Column(
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Row with title and optional Watch button
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                item.titles[0],
                overflow: TextOverflow.fade,
              ),
            ),
            if (item.anilibriaAlias != null &&
                item.anilibriaAlias!.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: FilledButton.icon(
                  icon: const Icon(Ionicons.play),
                  label: const Text('Watch'),
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) =>
                            WatchPage(alias: item.anilibriaAlias!.trim()),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
        const SizedBox(height: 5),
        TextRail(textRailItems),

        // Progress bar
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

        // Score, repeats, notes, progress
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ScoreLabel(item.score, widget.scoreFormat),
                const SizedBox(width: 8),
                if (item.repeat > 0)
                  Tooltip(
                    message: 'Repeats',
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Ionicons.repeat,
                            size: Theming.iconSmall),
                        const SizedBox(width: 3),
                        Text(
                          item.repeat.toString(),
                          style: TextTheme.of(context).labelSmall,
                        ),
                      ],
                    ),
                  )
                else
                  const SizedBox(),
              ],
            ),
            NotesLabel(item.notes),
            Text(
              item.progress == item.progressMax
                  ? item.progress.toString()
                  : '${item.progress}/${item.progressMax ?? "?"}',
              style: TextTheme.of(context).labelSmall?.copyWith(
                    color: (item.nextEpisode != null &&
                            item.progress + 1 < item.nextEpisode!)
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
