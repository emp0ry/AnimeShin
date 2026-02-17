import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:animeshin/feature/discover/discover_model.dart';
import 'package:animeshin/feature/discover/discover_title_resolver.dart';
import 'package:animeshin/feature/media/media_route_tile.dart';
import 'package:animeshin/feature/viewer/persistence_provider.dart';
import 'package:animeshin/util/theming.dart';
import 'package:animeshin/widget/cached_image.dart';
import 'package:animeshin/widget/grid/sliver_grid_delegates.dart';
import 'package:animeshin/widget/text_rail.dart';

class DiscoverMediaGrid extends StatelessWidget {
  const DiscoverMediaGrid(this.items);

  final List<DiscoverMediaItem> items;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const SliverFillRemaining(child: Center(child: Text('No Media')));
    }

    return SliverGrid(
      gridDelegate: const SliverGridDelegateWithMinWidthAndFixedHeight(
        minWidth: 290,
        height: 150,
      ),
      delegate: SliverChildBuilderDelegate(
        childCount: items.length,
        (context, index) => _Tile(items[index]),
      ),
    );
  }
}

class _Tile extends ConsumerWidget {
  const _Tile(this.item);

  final DiscoverMediaItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final showRu = ref.watch(
      persistenceProvider.select((s) => s.options.ruTitle),
    );
    final primaryTitle = discoverPrimaryTitle(item);
    final secondaryTitle = discoverSecondaryTitle(
      item,
      showRussianTitle: showRu,
    );

    final textRailItems = <String, bool>{};
    if (item.format != null) textRailItems[item.format!] = false;
    if (item.releaseStatus != null) {
      textRailItems[item.releaseStatus!.label] = false;
    }
    if (item.releaseYear != null) {
      textRailItems[item.releaseYear!.toString()] = false;
    }

    if (item.entryStatus != null) {
      textRailItems[item.entryStatus!.label(item.isAnime)] = true;
    }

    if (item.isAdult) textRailItems['Adult'] = true;

    final detailTextStyle = TextTheme.of(context).labelSmall;

    return Card(
      child: MediaRouteTile(
        id: item.id,
        imageUrl: item.imageUrl,
        child: Row(
          children: [
            Hero(
              tag: item.id,
              child: ClipRRect(
                borderRadius: const BorderRadius.horizontal(
                  left: Theming.radiusSmall,
                ),
                child: Container(
                  width: 150 / Theming.coverHtoWRatio,
                  color: ColorScheme.of(context).surfaceContainerHighest,
                  child: CachedImage(item.imageUrl),
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: Theming.paddingAll,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    Flexible(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Flexible(
                            child: Text(
                              primaryTitle,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (secondaryTitle != null) ...[
                            const SizedBox(height: 2),
                            Text(
                              secondaryTitle,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextTheme.of(context).labelSmall,
                            ),
                          ],
                          const SizedBox(height: 5),
                          TextRail(
                            textRailItems,
                            style: TextTheme.of(context).labelMedium,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 5),
                    Row(
                      children: [
                        Icon(
                          Icons.percent_rounded,
                          size: 15,
                          color: ColorScheme.of(context).onSurfaceVariant,
                        ),
                        const SizedBox(width: 5),
                        Text(
                          item.averageScore.toString(),
                          style: detailTextStyle,
                        ),
                        const SizedBox(width: 15),
                        Icon(
                          Icons.person_outline_rounded,
                          size: 15,
                          color: ColorScheme.of(context).onSurfaceVariant,
                        ),
                        const SizedBox(width: 5),
                        Text(
                          item.popularity.toString(),
                          style: detailTextStyle,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
