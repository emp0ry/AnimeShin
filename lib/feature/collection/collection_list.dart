import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:ionicons/ionicons.dart';
import 'package:animeshin/extension/date_time_extension.dart';
import 'package:animeshin/feature/media/media_route_tile.dart';
import 'package:animeshin/util/theming.dart';
import 'package:animeshin/util/debounce.dart';
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

bool isDesktop() {
  if (kIsWeb) return true;
  return Platform.isWindows || Platform.isLinux || Platform.isMacOS;
}

class _Tile extends StatelessWidget {
  const _Tile(this.entry, this.scoreFormat, this.onProgressUpdated);

  final Entry entry;
  final ScoreFormat scoreFormat;
  final Future<String?> Function(Entry, bool)? onProgressUpdated;

  @override
  Widget build(BuildContext context) {
    if (isDesktop()) {
      // Desktop — show + and - buttons
      return Card(
        margin: const EdgeInsets.only(bottom: Theming.offset),
        child: MediaRouteTile(
          key: ValueKey(entry.mediaId),
          id: entry.mediaId,
          imageUrl: entry.imageUrl,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Hero(
                tag: entry.mediaId,
                child: ClipRRect(
                  borderRadius: const BorderRadius.horizontal(
                    left: Theming.radiusSmall,
                  ),
                  child: Container(
                    width: _tileHeight / Theming.coverHtoWRatio,
                    color: ColorScheme.of(context).surfaceContainerHighest,
                    child: CachedImage(entry.imageUrl),
                  ),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: Theming.paddingAll,
                  child: _TileContent(entry, scoreFormat, onProgressUpdated),
                ),
              ),
              // Buttons on the right
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    icon: const Icon(Icons.remove, color: Colors.red),
                    onPressed: entry.progress > 0
                        ? () {
                            entry.progress--;
                            onProgressUpdated?.call(entry, false);
                          }
                        : null,
                  ),
                  IconButton(
                    icon: const Icon(Icons.add, color: Colors.green),
                    onPressed: (entry.progressMax == null || entry.progress < entry.progressMax!)
                        ? () {
                            entry.progress++;
                            onProgressUpdated?.call(entry, false);
                          }
                        : null,
                  ),
                ],
              )
            ],
          ),
        ),
      );
    } else {
      return _TileMobile(entry, scoreFormat, onProgressUpdated);
    }
  }
}

class _TileMobile extends StatefulWidget {
  const _TileMobile(this.entry, this.scoreFormat, this.onProgressUpdated);

  final Entry entry;
  final ScoreFormat scoreFormat;
  final Future<String?> Function(Entry, bool)? onProgressUpdated;

  @override
  State<_TileMobile> createState() => _TileMobileState();
}

class _TileMobileState extends State<_TileMobile> with SingleTickerProviderStateMixin {
  late final SlidableController _slidableController;
  bool _leftActionTriggered = false;
  bool _rightActionTriggered = false;

  @override
  void initState() {
    super.initState();
    _slidableController = SlidableController(this);

    _slidableController.animation.addListener(() {
      final ratio = _slidableController.ratio;
      if (ratio <= -0.25 && !_leftActionTriggered) {
        _leftActionTriggered = true;
        if (widget.onProgressUpdated != null && widget.entry.progress > 0) {
          widget.entry.progress++;
          widget.onProgressUpdated!(widget.entry, false);
          setState(() {});
        }
        _slidableController.close();
        Future.delayed(const Duration(milliseconds: 350), () {
          _leftActionTriggered = false;
        });
      }
      if (ratio >= 0.25 && !_rightActionTriggered) {
        _rightActionTriggered = true;
        if (widget.onProgressUpdated != null &&
            (widget.entry.progressMax == null ||
                widget.entry.progress < widget.entry.progressMax!)) {
          widget.entry.progress--;
          widget.onProgressUpdated!(widget.entry, false);
          setState(() {});
        }
        _slidableController.close();
        Future.delayed(const Duration(milliseconds: 350), () {
          _rightActionTriggered = false;
        });
      }
    });
  }

  @override
  void dispose() {
    _slidableController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Theming.offset),
      child: Slidable(
        key: ValueKey(widget.entry.mediaId),
        controller: _slidableController,
        startActionPane: ActionPane(
          motion: const DrawerMotion(),
          extentRatio: 0.25,
          children: [
            CustomSlidableAction(
              onPressed: (_) {
                if (widget.onProgressUpdated != null && widget.entry.progress > 0) {
                  setState(() => widget.entry.progress--);
                  widget.onProgressUpdated!(widget.entry, false);
                }
              },
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
              borderRadius: Theming.borderRadiusSmall,
              child: const Icon(Icons.remove),
            ),
          ],
        ),
        endActionPane: ActionPane(
          motion: const DrawerMotion(),
          extentRatio: 0.25,
          children: [
            CustomSlidableAction(
              onPressed: (_) {
                if (widget.onProgressUpdated != null &&
                    (widget.entry.progressMax == null ||
                        widget.entry.progress < widget.entry.progressMax!)) {
                  setState(() => widget.entry.progress++);
                  widget.onProgressUpdated!(widget.entry, false);
                }
              },
              backgroundColor: Colors.green,
              foregroundColor: Colors.white,
              borderRadius: Theming.borderRadiusSmall,
              child: const Icon(Icons.add),
            ),
          ],
        ),
        child: SizedBox(
          height: _tileHeight, // <--- высота фиксирована
          child: Card(
            margin: EdgeInsets.zero, // <--- убираем внутренний отступ
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
                          widget.entry, widget.scoreFormat, widget.onProgressUpdated),
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

class _SwipeActionBackground extends StatelessWidget {
  const _SwipeActionBackground({
    required this.color,
    required this.icon,
    required this.alignment,
  });

  final Color color;
  final IconData icon;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: color,
      alignment: alignment,
      child: Padding(
        padding: alignment == Alignment.centerLeft
            ? const EdgeInsets.only(left: 32)
            : const EdgeInsets.only(right: 32),
        child: Icon(icon, color: Colors.white, size: 28),
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
  final _debounce = Debounce();
  int? _lastProgress;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;

    double progressPercent = 0;
    if (item.progressMax != null) {
      progressPercent = item.progress / item.progressMax!;
    } else if (item.nextEpisode != null) {
      progressPercent = item.progress / (item.nextEpisode! - 1);
    } else if (item.progress > 0) {
      progressPercent = 1;
    }

    final textRailItems = <String, bool>{};

    if (widget.item.ruTitle != null) {
      textRailItems['${widget.item.ruTitle}\n'] = false;
    }

    if (widget.item.format != null) {
      textRailItems[widget.item.format!.label] = false;
    }

    if (widget.item.airingAt != null) {
      final key = 'Ep ${widget.item.nextEpisode} in ${widget.item.airingAt!.timeUntil}';
      textRailItems[key] = false;
    }

    if (widget.item.nextEpisode != null && widget.item.nextEpisode! - 1 > widget.item.progress) {
      String key;
      if (widget.item.ruLastEpisode != null && widget.item.ruLastEpisode! > widget.item.progress) {
        key = '${widget.item.nextEpisode! - 1 - widget.item.progress} ep behind (✔️AniLiberty)';
      } else {
        key = '${widget.item.nextEpisode! - 1 - widget.item.progress} ep behind (✖️AniLiberty)';
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
                        widget.item.progress + 1 < widget.item.nextEpisode!)
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
