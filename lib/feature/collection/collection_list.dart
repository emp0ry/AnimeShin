import 'package:animeshin/feature/watch/watch_page.dart';
import 'package:animeshin/feature/watch/watch_types.dart';
import 'package:animeshin/repository/anilibria/anilibria_repository.dart';
import 'package:animeshin/repository/aniv/aniv_repository.dart';
import 'package:animeshin/repository/sameband/sameband_repository.dart';
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

const _tileHeight = 150.0;

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
          motion: const StretchMotion(),        // smoothest on desktop
          extentRatio: 0.24,                    // a bit smaller feels snappier
          dismissible: DismissiblePane(
            confirmDismiss: () {
              if (!_canDecrement) return Future.value(false);
              _optimisticDec();                 // instant UI update
              _persistWithUndo(
                context: context,
                persist: _saveProgress,         // async, runs post-frame
                undoOptimistic: () async {      // revert path
                  setState(() => widget.entry.progress += 1);
                  await _saveProgress();
                },
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

    if (widget.item.format != null) {
      textRailItems[widget.item.format!.label] = false;
    }

    if (widget.item.airingAt != null) {
      final key = 'Ep ${widget.item.nextEpisode} in ${widget.item.airingAt!.timeUntil}';
      textRailItems[key] = false;
    }

    if (widget.item.nextEpisode != null && widget.item.nextEpisode! - 1 > widget.item.progress) {
      final diff = widget.item.nextEpisode! - 1 - widget.item.progress;
      String key;

      if (widget.item.anilibriaEpDubState == true) {
        if (widget.item.lastAniLibriaEpisode != null && widget.item.anilibriaId != 0) {
          if (widget.item.lastAniLibriaEpisode! > widget.item.progress) {
            key = '$diff ep behind (✔️AL)';
          } else {
            key = '$diff ep behind (✖️AL)';
          }
        } else {
          key = '$diff ep behind';
        }
      } else {
        key = '$diff ep behind';
      }

      textRailItems[key] = true;
    }

    final menuAnchorKey = GlobalKey();

    Future<void> openSearchMenu() async {
      Future<List<Map<String, dynamic>>> searchAniLiberty() async {
        try {
          final aniLibriaRepo = AnilibriaRepository();

          final malId = widget.item.malId;
          if (malId == 0) return const [];

          List<Map<String, dynamic>> items = [];

          if (widget.item.titleRussian != null) {
            items = await aniLibriaRepo.searchByTitle(
              widget.item.titleRussian!,
              ['id', 'name.main'],
              null,
            );
          }

          if (items.isEmpty && widget.item.titleRomaji != null) {
            items = await aniLibriaRepo.searchByTitle(
              widget.item.titleRomaji!,
              ['id', 'name.main'],
              null,
            );
          }
          if (items.isEmpty && widget.item.titleEnglish != null) {
            items = await aniLibriaRepo.searchByTitle(
              widget.item.titleEnglish!,
              ['id', 'name.main'],
              null,
            );
          }
          if (items.isEmpty) return const [];

          final converted = items.map((item) {
            return {
              'id': item['id'],
              'name': item['name']['main'],
            };
          }).toList();

          debugPrint('AniLiberty: ${converted.toString()}');

          return converted;
        } catch (e, st) {
          debugPrint('AniLiberty Search failed: $e\n$st');
          return const [];
        }
      }

      Future<List<Map<String, dynamic>>> searchAniV() async {
        try {
          final aniVRepo = AniVRepository();

          final malId = widget.item.malId;
          if (malId == 0) return const [];

          List<Map<String, dynamic>> items = [];

          if (widget.item.titleRussian != null) {
            items = await aniVRepo.searchByTitle(widget.item.titleRussian!);
          }
          if (items.isEmpty && widget.item.titleRomaji != null) {
            items = await aniVRepo.searchByTitle(widget.item.titleRomaji!);
          }
          if (items.isEmpty && widget.item.titleEnglish != null) {
            items = await aniVRepo.searchByTitle(widget.item.titleEnglish!);
          }
          if (items.isEmpty) return const [];

          debugPrint('AniV: ${items.toString()}');
          return items;
        } catch (e, st) {
          debugPrint('AniV Search failed: $e\n$st');
          return const [];
        }
      }

      Future<List<Map<String, dynamic>>> searchSameBand() async {
        try {
          final sameBandRepo = SameBandRepository();

          List<Map<String, dynamic>> items = [];

          if (widget.item.titleRomaji != null) {
            items = await sameBandRepo.searchByTitle(widget.item.titleRomaji!);
          }
          if (items.isEmpty && widget.item.titleRussian != null) {
            items = await sameBandRepo.searchByTitle(widget.item.titleRussian!);
          }
          if (items.isEmpty && widget.item.titleEnglish != null) {
            items = await sameBandRepo.searchByTitle(widget.item.titleEnglish!);
          }
          if (items.isEmpty) return const [];

          debugPrint('SameBand: ${items.toString()}');
          return items;
        } catch (e, st) {
          debugPrint('SameBand Search failed: $e\n$st');
          return const [];
        }
      }

      // --- Capture contexts & geometry BEFORE any awaits ---
      final ctx = context; // State.context
      final overlay = Overlay.of(ctx);
      final anchorCtx = menuAnchorKey.currentContext;
      if (anchorCtx == null) return;

      final box = anchorCtx.findRenderObject() as RenderBox?;
      final overlayBox = overlay.context.findRenderObject() as RenderBox?;
      if (box == null || overlayBox == null) return;

      final position = RelativeRect.fromRect(
        Rect.fromPoints(
          box.localToGlobal(Offset.zero, ancestor: overlayBox),
          box.localToGlobal(box.size.bottomRight(Offset.zero), ancestor: overlayBox),
        ),
        Offset.zero & overlayBox.size,
      );

      // Do both at once
      final results = await Future.wait([
        searchAniLiberty().catchError((_) => <Map<String, dynamic>>[]),
        searchAniV().catchError((_) => <Map<String, dynamic>>[]),
        searchSameBand().catchError((_) => <Map<String, dynamic>>[]),
      ]);

      // shikimoriRepo.dispose();

      final aniLibertyList = results[0];
      final aniVList = results[1];
      final sameBandList = results[2];

      if (!mounted || !ctx.mounted) return;

      // --- Level 1 menu: sources with counts ---
      final topItems = <PopupMenuEntry<String>>[
        PopupMenuItem<String>(
          value: 'aniliberty',
          child: Row(
            children: [
              const Icon(Ionicons.film_outline, size: 16),
              const SizedBox(width: 8),
              const Text('AniLiberty'),
              const Spacer(),
              Text('(${aniLibertyList.length})'),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'aniv',
          child: Row(
            children: [
              const Icon(Ionicons.film_outline, size: 16),
              const SizedBox(width: 8),
              const Text('AVost'),
              const Spacer(),
              Text('(${aniVList.length})'),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'sameband',
          child: Row(
            children: [
              const Icon(Ionicons.film_outline, size: 16),
              const SizedBox(width: 8),
              const Text('SameBand'),
              const Spacer(),
              Text('(${sameBandList.length})'),
            ],
          ),
        ),
      ];

      final selectedSource = await showMenu<String>(
        context: ctx,
        position: position,
        items: topItems,
      );

      if (!mounted || !ctx.mounted || selectedSource == null) return;

      // --- Level 2 menu: results for the chosen source ---
      List<Map<String, dynamic>> chosenList;
      String sourceKey;
      switch (selectedSource) {
        case 'aniliberty':
          chosenList = aniLibertyList;
          sourceKey = 'aniliberty';
          break;
        case 'aniv':
          chosenList = aniVList;
          sourceKey = 'aniv';
          break;
        case 'sameband':
          chosenList = sameBandList;
          sourceKey = 'sameband';
          break;
        default:
          return;
      }

      if (chosenList.isEmpty) return;

      // Build entries like: Result 1..N with ellipsis for long names
      final resultItems = <PopupMenuEntry<String>>[];
      for (var i = 0; i < chosenList.length; i++) {
        final name = (chosenList[i]['name'] as String?)?.trim() ?? '';
        resultItems.add(
          PopupMenuItem<String>(
            value: '$sourceKey:$i', // encode source + index
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Ionicons.play, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        );
      }

      final selectedItem = await showMenu<String>(
        context: ctx,
        position: position,
        items: resultItems,
      );

      if (!mounted || !ctx.mounted || selectedItem == null) return;

      // --- Handle final selection ---
      final parts = selectedItem.split(':');
      if (parts.length != 2) return;
      final selSource = parts[0];
      final selIndex = int.tryParse(parts[1]) ?? -1;
      if (selIndex < 0 || selIndex >= chosenList.length) return;

      final picked = chosenList[selIndex];

      if (selSource == 'aniliberty') {
        final id = picked['id'] as int? ?? 0;
        if (id == 0) return;
        Navigator.of(ctx).push(
          MaterialPageRoute(
            builder: (_) => WatchPage(
              id: id,
              url: '',
              item: widget.item,
              sync: false,
              animeVoice: AnimeVoice.aniliberty,
              startWithProxy: true,
            ),
          ),
        );
      }
      else if (selSource == 'aniv') {
        final id = picked['id'] as int? ?? 0;
        if (id == 0) return;
        Navigator.of(ctx).push(
          MaterialPageRoute(
            builder: (_) => WatchPage(
              id: id,
              url: '',
              item: widget.item,
              sync: false,
              animeVoice: AnimeVoice.aniv,
              startWithProxy: false,
            ),
          ),
        );
      }
      else if (selSource == 'sameband') {
        String url = picked['url'] as String? ?? '';
        if (url == '') return;
        Navigator.of(ctx).push(
          MaterialPageRoute(
            builder: (_) => WatchPage(
              id: 0,
              url: url,
              item: widget.item,
              sync: false,
              animeVoice: AnimeVoice.sameband,
              startWithProxy: true,
            ),
          ),
        );
      }
    }

    Widget buildWatchButton() {
      final canWatchDirect =
          (widget.item.anilibriaAlias?.trim().isNotEmpty ?? false) &&
          (widget.item.anilibriaWatchState ?? false);

      if (canWatchDirect) {
        return FilledButton(
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            minimumSize: const Size(80, 36),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          onPressed: () {
            Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => WatchPage(
                id: widget.item.anilibriaId!,
                url: '',
                item: widget.item,
                sync: true,
                animeVoice: AnimeVoice.aniliberty,
                startWithProxy: true,
              ),
            ));
          },
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Ionicons.play, size: 16),
              SizedBox(width: 2),
              Text('Watch', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
            ],
          ),
        );
      }

      // Search -> async -> show popup menu
      return Container(
        key: menuAnchorKey, // anchor to compute menu position
        child: FilledButton(
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            minimumSize: const Size(80, 36),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          onPressed: openSearchMenu,
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Ionicons.play, size: 16),
              SizedBox(width: 2),
              Text('Search', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
            ],
          ),
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
            if (!widget.item.format.toString().endsWith('manga') && widget.item.malId != 0)
              buildWatchButton(),
          ],
        ),
        const SizedBox(height: 5),
        if (widget.item.titles.last.isNotEmpty && widget.item.ruTitleState != null && widget.item.ruTitleState! && widget.item.titleRussian != null)
          Text(
            widget.item.titleRussian!,
            overflow: TextOverflow.ellipsis,
            maxLines: 2,
            style: TextTheme.of(context).labelSmall
          ),
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