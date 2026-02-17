import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:animeshin/feature/discover/discover_model.dart';
import 'package:animeshin/feature/discover/discover_title_resolver.dart';
import 'package:animeshin/feature/media/media_route_tile.dart';
import 'package:animeshin/feature/viewer/persistence_provider.dart';
import 'package:animeshin/util/theming.dart';
import 'package:animeshin/widget/cached_image.dart';
import 'package:animeshin/widget/grid/sliver_grid_delegates.dart';

class DiscoverMediaSimpleGrid extends ConsumerWidget {
  const DiscoverMediaSimpleGrid(this.items);

  final List<DiscoverMediaItem> items;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final showRu = ref.watch(
      persistenceProvider.select((s) => s.options.ruTitle),
    );
    final hasAnySecondary = showRu &&
        items.any(
          (item) => discoverSecondaryTitle(
                item,
                showRussianTitle: true,
              ) != null,
        );

    return SliverGrid(
      gridDelegate: SliverGridDelegateWithMinWidthAndExtraHeight(
        minWidth: 100,
        extraHeight: hasAnySecondary ? 58 : 40,
        rawHWRatio: Theming.coverHtoWRatio,
      ),
      delegate: SliverChildBuilderDelegate(
        (_, i) => _Tile(items[i]),
        childCount: items.length,
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
    final titleBlockHeight = secondaryTitle != null ? 52.0 : 35.0;

    return MediaRouteTile(
      id: item.id,
      imageUrl: item.imageUrl,
      child: Column(
        children: [
          Expanded(
            child: Hero(
              tag: item.id,
              child: ClipRRect(
                borderRadius: Theming.borderRadiusSmall,
                child: CachedImage(item.imageUrl),
              ),
            ),
          ),
          const SizedBox(height: 5),
          SizedBox(
            height: titleBlockHeight,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  primaryTitle,
                  maxLines: secondaryTitle == null ? 2 : 1,
                  overflow: TextOverflow.fade,
                  style: TextTheme.of(context).bodyMedium,
                ),
                if (secondaryTitle != null)
                  Text(
                    secondaryTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextTheme.of(context).labelSmall,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
