import 'package:animeshin/util/module_loader/sources_module.dart';
import 'package:animeshin/util/module_loader/sources_module_loader.dart';
import 'package:animeshin/util/module_loader/js_module_executor.dart';
import 'package:animeshin/feature/read/module_read_page.dart';
import 'package:animeshin/feature/watch/module_watch_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:ionicons/ionicons.dart';
import 'package:animeshin/extension/date_time_extension.dart';
import 'package:animeshin/feature/media/media_route_tile.dart';
import 'package:animeshin/util/theming.dart';
import 'package:animeshin/util/text_utils.dart';
import 'package:animeshin/feature/collection/collection_models.dart';
import 'package:animeshin/widget/cached_image.dart';
import 'package:animeshin/widget/input/note_label.dart';
import 'package:animeshin/widget/input/score_label.dart';
import 'package:animeshin/widget/text_rail.dart';
import 'package:animeshin/feature/media/media_models.dart';

const _tileHeight = 150.0;

class _RankedModuleTile {
  const _RankedModuleTile(
    this.tile,
    this.score, {
    required this.matchedBy,
    required this.matchedQuery,
  });
  final JsModuleTile tile;
  final double score; // 0..1
  final String matchedBy; // RU / RO / EN
  final String matchedQuery;
}

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
            key = '$diff ep behind (✔️AniLiberty)';
          } else {
            key = '$diff ep behind (✖️AniLiberty)';
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
      final js = JsModuleExecutor();

      String? lastError;

      ({String by, String query}) qv(String by, String query) => (by: by, query: query);

      List<String> queryVariants(String q) {
        final base = q.trim();
        if (base.isEmpty) return const [];

        String romanizeStandaloneDigits(String s) {
          // Only apply to Latin-script queries to avoid mangling Cyrillic titles.
          if (!RegExp(r'[A-Za-z]').hasMatch(s)) return s;
          const map = <String, String>{
            '2': 'II',
            '3': 'III',
            '4': 'IV',
            '5': 'V',
            '6': 'VI',
            '7': 'VII',
            '8': 'VIII',
            '9': 'IX',
            '10': 'X',
          };

          var out = s;
          // Replace standalone numbers only.
          for (final e in map.entries) {
            out = out.replaceAllMapped(
              RegExp(r'\b' + RegExp.escape(e.key) + r'\b'),
              (_) => e.value,
            );
          }
          return out;
        }

        String stripSeasonSuffix(String s) {
          var t = s.trim();
          // English: "Season 2", "S2", "2nd Season".
          t = t.replaceAll(
            RegExp(r'\s*[:\-–—]?\s*(?:season\s*\d+|s\s*\d+)\s*$', caseSensitive: false),
            '',
          );
          t = t.replaceAll(
            RegExp(r'\s*[:\-–—]?\s*\d+(?:st|nd|rd|th)?\s*season\s*$', caseSensitive: false),
            '',
          );

          // Russian: "2 сезон", "сезон 2".
          t = t.replaceAll(
            RegExp(r'\s*[:\-–—]?\s*(?:сезон\s*\d+|\d+\s*сезон)\s*$', caseSensitive: false),
            '',
          );

          return t.trim();
        }

        final out = <String>[];
        void add(String v) {
          final t = v.trim();
          if (t.isEmpty) return;
          if (!out.contains(t)) out.add(t);
        }

        add(base);
        add(stripSeasonSuffix(base));

        add(romanizeStandaloneDigits(base));
        add(romanizeStandaloneDigits(stripSeasonSuffix(base)));

        // Also try removing any subtitle after ':' for some APIs.
        final colon = base.indexOf(':');
        if (colon > 0) {
          add(base.substring(0, colon));
          add(stripSeasonSuffix(base.substring(0, colon)));
          add(romanizeStandaloneDigits(base.substring(0, colon)));
          add(romanizeStandaloneDigits(stripSeasonSuffix(base.substring(0, colon))));
        }

        return out;
      }

      Future<List<_RankedModuleTile>> searchModule(
        SourcesModuleDescriptor module,
      ) async {
        final base = <({String by, String query})>[
          if (widget.item.titleRussian?.trim().isNotEmpty == true)
            qv('RU', widget.item.titleRussian!.trim()),
          if (widget.item.titleRomaji?.trim().isNotEmpty == true)
            qv('RO', widget.item.titleRomaji!.trim()),
          if (widget.item.titleShikimoriRomaji?.trim().isNotEmpty == true &&
              widget.item.titleShikimoriRomaji!.trim() !=
                  widget.item.titleRomaji?.trim())
            qv('RO', widget.item.titleShikimoriRomaji!.trim()),
          if (widget.item.titleEnglish?.trim().isNotEmpty == true)
            qv('EN', widget.item.titleEnglish!.trim()),
        ];

        final queries = <({String by, String query})>[];
        for (final b in base) {
          for (final v in queryVariants(b.query)) {
            queries.add(qv(b.by, v));
          }
        }

        final bestByKey = <String, _RankedModuleTile>{};

        for (final q in queries) {
          try {
            final items = await js.searchResults(module.id, q.query);
            for (final it in items) {
              final key = it.href.trim().isNotEmpty
                  ? it.href.trim()
                  : '${it.title.trim()}|${it.image.trim()}';
              final score = fuzzyMatchScore(q.query, it.title);
              final existing = bestByKey[key];
              if (existing == null || score > existing.score) {
                bestByKey[key] = _RankedModuleTile(
                  it,
                  score,
                  matchedBy: q.by,
                  matchedQuery: q.query,
                );
              }
            }
          } catch (e) {
            // Ignore and try next query.
            lastError = e.toString();
          }
        }

        return bestByKey.values.toList()
          ..sort((a, b) => b.score.compareTo(a.score));
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
          box.localToGlobal(box.size.bottomRight(Offset.zero),
              ancestor: overlayBox),
        ),
        Offset.zero & overlayBox.size,
      );

      final modules = await (() async {
        try {
          return await SourcesModuleLoader().listModules();
        } catch (_) {
          return const <SourcesModuleDescriptor>[];
        }
      })();

      if (modules.isEmpty) {
        if (!ctx.mounted) return;
        ScaffoldMessenger.of(ctx).showSnackBar(
          const SnackBar(content: Text('No modules found in assets/sources/')),
        );
        return;
      }

      if (!mounted || !ctx.mounted) return;

      final topItems = <PopupMenuEntry<String>>[];
      for (final m in modules) {
        topItems.add(
          PopupMenuItem<String>(
            value: 'module:${m.id}',
            child: Row(
              children: [
                const Icon(Ionicons.extension_puzzle_outline, size: 16),
                const SizedBox(width: 8),
                Text(m.name),
              ],
            ),
          ),
        );
      }

      final selectedSource = await showMenu<String>(
        context: ctx,
        position: position,
        items: topItems,
      );

      if (!mounted || !ctx.mounted || selectedSource == null) return;

      final selectedId = selectedSource.startsWith('module:')
          ? selectedSource.substring('module:'.length)
          : '';

      SourcesModuleDescriptor? selectedModule;
      for (final m in modules) {
        if (m.id == selectedId) {
          selectedModule = m;
          break;
        }
      }
      if (selectedModule == null) return;

      if (!ctx.mounted) return;
      ScaffoldMessenger.of(ctx).showSnackBar(
        SnackBar(content: Text('Searching: ${selectedModule.name}...')),
      );

      final chosenList = await searchModule(selectedModule);
      if (!mounted || !ctx.mounted) return;
      if (chosenList.isEmpty) {
        if (lastError != null) {
          ScaffoldMessenger.of(ctx).showSnackBar(
            SnackBar(content: Text('Module error: $lastError')),
          );
        }
        ScaffoldMessenger.of(ctx).showSnackBar(
          SnackBar(content: Text('No results in ${selectedModule.name}')),
        );
        return;
      }

      final resultItems = <PopupMenuEntry<String>>[];
      for (var i = 0; i < chosenList.length; i++) {
        final name = chosenList[i].tile.title.trim();
        final pct = (chosenList[i].score * 100).round();
        final by = chosenList[i].matchedBy;
        resultItems.add(
          PopupMenuItem<String>(
            value: '${selectedModule.id}:$i',
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Ionicons.play, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '$pct% match • $by',
                        style: TextTheme.of(ctx).labelSmall?.copyWith(
                              color: Theme.of(ctx)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                      ),
                    ],
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

      final parts = selectedItem.split(':');
      if (parts.length != 2) return;
      final selIndex = int.tryParse(parts[1]) ?? -1;
      if (selIndex < 0 || selIndex >= chosenList.length) return;

      final picked = chosenList[selIndex].tile;

      Navigator.of(ctx).push(
        MaterialPageRoute(
          builder: (_) => isManga
              ? ModuleReadPage(
                  module: selectedModule!,
                  title: picked.title,
                  href: picked.href,
                  item: widget.item,
                )
              : ModuleWatchPage(
                  module: selectedModule!,
                  title: picked.title,
                  href: picked.href,
                  item: widget.item,
                ),
        ),
      );
    }

    Widget buildWatchButton() {
      // Modules-only: always open module search.
      final icon = isManga ? Ionicons.book_outline : Ionicons.play;
      final label = isManga ? 'Read' : 'Search';
      return Container(
        key: menuAnchorKey, // anchor to compute menu position
        child: FilledButton(
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
              const SizedBox(width: 2),
              Text(
                label,
                style:
                    const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
              ),
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
