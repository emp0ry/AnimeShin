import 'package:animeshin/feature/collection/module_search_page.dart';
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

const _tileHeight = 156.0;

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

  void _persistWithUndo({
    required BuildContext context,
    required Future<String?> Function() persist,
    required Future<void> Function() undoOptimistic,
  }) {
    // Run after the current frame so we don't block the animation.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!context.mounted) return;
      // Close the slidable smoothly
      Slidable.of(context)?.close();
      // Medium haptic after the animation feels nicer
      HapticFeedback.mediumImpact();

      // Fire-and-forget persist; if it fails, revert.
      final err = await persist();
      if (!context.mounted) return;
      if (err != null) {
        await undoOptimistic();
        return;
      }

      final messenger = ScaffoldMessenger.of(context);
      messenger.hideCurrentSnackBar();
    });
  }

  Future<String?> _saveProgress() async {
    if (widget.onProgressUpdated == null) return null;
    return widget.onProgressUpdated!(widget.entry, false);
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
          motion: const StretchMotion(), // smoothest on desktop
          extentRatio: 0.24, // a bit smaller feels snappier
          dismissible: DismissiblePane(
            confirmDismiss: () {
              if (!_canDecrement) return Future.value(false);
              _optimisticDec(); // instant UI update
              _persistWithUndo(
                context: context,
                persist: _saveProgress, // async, runs post-frame
                undoOptimistic: () async {
                  // revert path
                  if (mounted) {
                    setState(() => widget.entry.progress += 1);
                  }
                  await _saveProgress();
                },
              );

              return Future.value(false); // never actually dismiss
            },
            onDismissed: () {}, // no-op; not called because we return false
            closeOnCancel: true,
          ),
          children: [
            SlidableAction(
              onPressed: (_) {
                if (!_canDecrement) return;
                _optimisticDec();
                _persistWithUndo(
                  context: context,
                  persist: _saveProgress,
                  undoOptimistic: () async {
                    setState(() => widget.entry.progress += 1);
                    await _saveProgress();
                  },
                );
              },
              icon: Ionicons.remove,
              backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
              foregroundColor:
                  Theme.of(context).colorScheme.onSecondaryContainer,
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
              _optimisticInc();
              _persistWithUndo(
                context: context,
                persist: _saveProgress,
                undoOptimistic: () async {
                  setState(() => widget.entry.progress -= 1);
                  await _saveProgress();
                },
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
                _optimisticInc();
                _persistWithUndo(
                  context: context,
                  persist: _saveProgress,
                  undoOptimistic: () async {
                    setState(() => widget.entry.progress -= 1);
                    await _saveProgress();
                  },
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
    final isManga =
      widget.item.format?.toString().toLowerCase().contains('manga') ?? false;

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
      final diff = widget.item.nextEpisode! - 1 - widget.item.progress;
      String key;

      if (!isManga && widget.item.anilibriaEpDubState == true) {
        final last = widget.item.lastAniLibriaEpisode ?? 0;
        final id = widget.item.anilibriaId;
        if (last > 0 && id != null && id != 0) {
          if (last > widget.item.progress) {
            key = '$diff ep behind (✔️RU)';
          } else {
            key = '$diff ep behind (✖️RU)';
          }
        } else {
          key = '$diff ep behind';
        }
      } else {
        key = '$diff ep behind';
      }

      textRailItems[key] = true;
    }

    Future<void> openSearchMenu() async {
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ModuleSearchPage(
            mediaId: widget.item.mediaId,
            item: widget.item,
            isManga: isManga,
          ),
        ),
      );
    }

    Widget buildWatchButton() {
      final icon = isManga ? Ionicons.book : Ionicons.play;
      final label = 'Search';
      return FilledButton(
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            minimumSize: const Size(80, 36),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          onPressed: openSearchMenu,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16),
              SizedBox(width: isManga ? 5 : 2),
              Text(
                label,
                style:
                    const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
              ),
            ],
          ),
        );
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
                overflow: TextOverflow.ellipsis,
                maxLines: 2,
              ),
            ),
            buildWatchButton(),
          ],
        ),
        const SizedBox(height: 5),
        if (widget.item.titles.last.isNotEmpty &&
            widget.item.ruTitleState != null &&
            widget.item.ruTitleState! &&
            widget.item.titleRussian != null)
          Text(widget.item.titleRussian!,
              overflow: TextOverflow.ellipsis,
              maxLines: 2,
              style: TextTheme.of(context).labelSmall),
        Expanded(
          child: Align(
            alignment: Alignment.bottomLeft,
            child: TextRail(textRailItems),
          ),
        ),

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
                        const Icon(Ionicons.repeat, size: Theming.iconSmall),
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
