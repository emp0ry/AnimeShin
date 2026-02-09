import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ionicons/ionicons.dart';

import 'package:animeshin/extension/date_time_extension.dart';
import 'package:animeshin/extension/snack_bar_extension.dart';
import 'package:animeshin/feature/collection/collection_models.dart';
import 'package:animeshin/feature/collection/collection_provider.dart';
import 'package:animeshin/feature/media/media_models.dart';
import 'package:animeshin/feature/viewer/persistence_provider.dart';
import 'package:animeshin/feature/watch/module_watch_page.dart';
import 'package:animeshin/util/module_loader/js_module_executor.dart';
import 'package:animeshin/util/module_loader/sources_module.dart';
import 'package:animeshin/util/module_loader/sources_module_loader.dart';
import 'package:animeshin/util/text_utils.dart';
import 'package:animeshin/util/theming.dart';
import 'package:animeshin/widget/layout/content_header.dart';
import 'package:animeshin/widget/text_rail.dart';

class MediaHeader extends ConsumerWidget {
  const MediaHeader.withTabBar({
    required this.id,
    required this.coverUrl,
    required this.media,
    required TabController this.tabCtrl,
    required void Function() this.scrollToTop,
    required this.toggleFavorite,
    super.key,
  });

  const MediaHeader.withoutTabBar({
    required this.id,
    required this.coverUrl,
    required this.media,
    required this.toggleFavorite,
    super.key,
  })  : tabCtrl = null,
        scrollToTop = null;

  final int id;
  final String? coverUrl;
  final Media? media;
  final TabController? tabCtrl;
  final void Function()? scrollToTop;
  final Future<Object?> Function() toggleFavorite;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textRailItems = <String, bool>{};
    final menuAnchorKey = GlobalKey();

    if (media != null) {
      final info = media!.info;
      final options = ref.watch(persistenceProvider.select((s) => s.options));

      if (options.ruTitle && info.russianTitle != null && info.russianTitle!.trim().isNotEmpty) {
        textRailItems['${info.russianTitle}\n'] = false;
      }

      if (info.isAdult) textRailItems['Adult'] = true;

      if (info.format != null) {
        textRailItems[info.format!.label] = false;
      }

      if (media!.entryEdit.listStatus != null) {
        textRailItems[media!.entryEdit.listStatus!.label(info.isAnime)] = false;
      }

      if (info.airingAt != null) {
        textRailItems['Ep ${info.nextEpisode} in ${info.airingAt!.timeUntil}'] = true;
      }

      if (media!.entryEdit.listStatus != null) {
        final progress = media!.entryEdit.progress;
        if (info.nextEpisode != null && info.nextEpisode! - 1 > progress) {
          textRailItems['${info.nextEpisode! - 1 - progress} ep behind'] = true;
        }
      }
    }

    return ContentHeader(
      bannerUrl: media?.info.banner,
      imageUrl: media?.info.cover ?? coverUrl,
      imageLargeUrl: media?.info.extraLargeCover,
      imageHeightToWidthRatio: Theming.coverHtoWRatio,
      imageHeroTag: id,
      siteUrl: media?.info.siteUrl,
      siteShikimoriUrl: media?.info.siteShikimoriUrl,
      title: media?.info.preferredTitle,
      details: TextRail(
        textRailItems,
        style: TextTheme.of(context).labelMedium,
      ),
      tabBarConfig: tabCtrl != null && scrollToTop != null
          ? (
              tabCtrl: tabCtrl!,
              scrollToTop: scrollToTop!,
              tabs: tabsWithOverview,
            )
          : null,
      trailingTopButtons: [
        if (media != null && media!.info.isAnime)
          Container(
            key: menuAnchorKey,
            child: IconButton(
              tooltip: 'Search modules',
              icon: const Icon(Ionicons.search_outline),
              onPressed: () async {
                final m = media;
                if (m == null) return;

                final info = m.info;
                final js = JsModuleExecutor();
                String? lastError;

                const minGoodMatchScore = 0.10; // 10%

                ({String by, String query}) qv(String by, String query) =>
                    (by: by, query: query);

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
                      RegExp(
                        r'\s*[:\-–—]?\s*(?:season\s*\d+|s\s*\d+)\s*$',
                        caseSensitive: false,
                      ),
                      '',
                    );
                    t = t.replaceAll(
                      RegExp(
                        r'\s*[:\-–—]?\s*\d+(?:st|nd|rd|th)?\s*season\s*$',
                        caseSensitive: false,
                      ),
                      '',
                    );

                    // Russian: "2 сезон", "сезон 2".
                    t = t.replaceAll(
                      RegExp(
                        r'\s*[:\-–—]?\s*(?:сезон\s*\d+|\d+\s*сезон)\s*$',
                        caseSensitive: false,
                      ),
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
                    add(romanizeStandaloneDigits(
                        stripSeasonSuffix(base.substring(0, colon))));
                  }

                  return out;
                }

                Future<List<({JsModuleTile tile, double score, String by, String matchedQuery})>>
                    searchModule(SourcesModuleDescriptor module) async {
                  final base = <({String by, String query})>[
                    if (info.russianTitle?.trim().isNotEmpty == true)
                      qv('RU', info.russianTitle!.trim()),
                    if (info.romajiTitle?.trim().isNotEmpty == true)
                      qv('RO', info.romajiTitle!.trim()),
                    if (info.englishTitle?.trim().isNotEmpty == true)
                      qv('EN', info.englishTitle!.trim()),
                    if (info.nativeTitle?.trim().isNotEmpty == true)
                      qv('NA', info.nativeTitle!.trim()),
                    if (info.preferredTitle?.trim().isNotEmpty == true)
                      qv('PR', info.preferredTitle!.trim()),
                    for (final s in info.synonyms)
                      if (s.trim().isNotEmpty) qv('SY', s.trim()),
                  ];

                  final queries = <({String by, String query})>[];
                  for (final b in base) {
                    for (final v in queryVariants(b.query)) {
                      queries.add(qv(b.by, v));
                    }
                  }

                  final bestByKey =
                      <String, ({JsModuleTile tile, double score, String by, String matchedQuery})>{};

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
                          bestByKey[key] = (
                            tile: it,
                            score: score,
                            by: q.by,
                            matchedQuery: q.query,
                          );
                        }
                      }
                    } catch (e) {
                      // Ignore and try next query.
                      lastError = e.toString();
                    }
                  }

                  var out = bestByKey.values.toList()
                    ..sort((a, b) => b.score.compareTo(a.score));

                  // Filtering behavior:
                  // - If there are any >=10% matches, hide everything below 10% (including 0%).
                  // - Otherwise, keep results (including 0%) so cross-script titles can still be selected.
                  final hasGood = out.any((e) => e.score >= minGoodMatchScore);
                  if (hasGood) {
                    out = out.where((e) => e.score >= minGoodMatchScore).toList();
                  }

                  return out;
                }

                // --- Capture contexts & geometry BEFORE any awaits ---
                final ctx = context;
                final overlay = Overlay.of(ctx);
                final anchorCtx = menuAnchorKey.currentContext;
                if (anchorCtx == null) return;

                final box = anchorCtx.findRenderObject() as RenderBox?;
                final overlayBox = overlay.context.findRenderObject() as RenderBox?;
                if (box == null || overlayBox == null) return;

                final position = RelativeRect.fromRect(
                  Rect.fromPoints(
                    box.localToGlobal(Offset.zero, ancestor: overlayBox),
                    box.localToGlobal(
                      box.size.bottomRight(Offset.zero),
                      ancestor: overlayBox,
                    ),
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
                    const SnackBar(
                      content: Text('No modules found in assets/sources/'),
                    ),
                  );
                  return;
                }

                if (!ctx.mounted) return;

                final topItems = <PopupMenuEntry<String>>[];
                for (final mm in modules) {
                  topItems.add(
                    PopupMenuItem<String>(
                      value: 'module:${mm.id}',
                      child: Row(
                        children: [
                          const Icon(Ionicons.extension_puzzle_outline, size: 16),
                          const SizedBox(width: 8),
                          Text(mm.name),
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

                if (!ctx.mounted || selectedSource == null) return;

                final selectedId = selectedSource.startsWith('module:')
                    ? selectedSource.substring('module:'.length)
                    : '';

                SourcesModuleDescriptor? selectedModule;
                for (final mm in modules) {
                  if (mm.id == selectedId) {
                    selectedModule = mm;
                    break;
                  }
                }
                if (selectedModule == null) return;

                if (!ctx.mounted) return;
                ScaffoldMessenger.of(ctx).showSnackBar(
                  SnackBar(content: Text('Searching: ${selectedModule.name}...')),
                );

                final chosenList = await searchModule(selectedModule);
                if (!ctx.mounted) return;
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
                  final by = chosenList[i].by;
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

                if (!ctx.mounted || selectedItem == null) return;

                final parts = selectedItem.split(':');
                if (parts.length != 2) return;
                final selIndex = int.tryParse(parts[1]) ?? -1;
                if (selIndex < 0 || selIndex >= chosenList.length) return;

                final picked = chosenList[selIndex].tile;

                Entry? entry;
                final viewerId = ref.read(viewerIdProvider);
                if (viewerId != null && viewerId != 0) {
                  final tag = (userId: viewerId, ofAnime: true);
                  final collection = ref.read(collectionProvider(tag)).valueOrNull;
                  if (collection != null) {
                    final all = switch (collection) {
                      FullCollection c => c.lists.expand((l) => l.entries),
                      _ => collection.list.entries,
                    };
                    entry = all.cast<Entry?>().firstWhere(
                          (e) => e?.mediaId == info.id,
                          orElse: () => null,
                        );
                  }
                }

                Navigator.of(ctx).push(
                  MaterialPageRoute(
                    builder: (_) => ModuleWatchPage(
                      module: selectedModule!,
                      title: picked.title,
                      href: picked.href,
                      item: entry,
                    ),
                  ),
                );
              },
            ),
          ),
        if (media != null) _FavoriteButton(media!.info, toggleFavorite),
      ],
    );
  }

  static const tabsWithoutOverview = [
    Tab(text: 'Related'),
    Tab(text: 'Characters'),
    Tab(text: 'Staff'),
    Tab(text: 'Reviews'),
    Tab(text: 'Threads'),
    Tab(text: 'Following'),
    Tab(text: 'Recommendations'),
    Tab(text: 'Statistics'),
  ];

  static const tabsWithOverview = [
    Tab(text: 'Overview'),
    ...tabsWithoutOverview,
  ];
}

class _FavoriteButton extends StatefulWidget {
  const _FavoriteButton(this.info, this.toggleFavorite);

  final MediaInfo info;
  final Future<Object?> Function() toggleFavorite;

  @override
  State<_FavoriteButton> createState() => __FavoriteButtonState();
}

class __FavoriteButtonState extends State<_FavoriteButton> {
  @override
  Widget build(BuildContext context) {
    final info = widget.info;

    return IconButton(
      tooltip: info.isFavorite ? 'Unfavourite' : 'Favourite',
      icon: info.isFavorite
          ? const Icon(Icons.favorite)
          : const Icon(Icons.favorite_border),
      onPressed: () async {
        setState(() => info.isFavorite = !info.isFavorite);

        final err = await widget.toggleFavorite();
        if (err == null) return;

        setState(() => info.isFavorite = !info.isFavorite);
        if (context.mounted) SnackBarExtension.show(context, err.toString());
      },
    );
  }
}
