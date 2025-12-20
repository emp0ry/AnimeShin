import 'package:flutter/material.dart';
import 'package:animeshin/feature/media/media_item_model.dart';
import 'package:animeshin/feature/media/media_route_tile.dart';
import 'package:animeshin/util/theming.dart';
import 'package:animeshin/widget/cached_image.dart';
import 'package:animeshin/widget/grid/sliver_grid_delegates.dart';

class MediaItemGrid extends StatelessWidget {
  const MediaItemGrid(this.items);

  final List<MediaItem> items;

  @override
  Widget build(BuildContext context) {
    return SliverGrid(
      gridDelegate: const SliverGridDelegateWithMinWidthAndExtraHeight(
        minWidth: 100,
        extraHeight: 40,
        rawHWRatio: Theming.coverHtoWRatio,
      ),
      delegate: SliverChildBuilderDelegate(
        (_, i) => _Tile(items[i]),
        childCount: items.length,
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile(this.item);

  final MediaItem item;

  @override
  Widget build(BuildContext context) {
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
            height: 35,
            child: Text(
              item.name,
              maxLines: 2,
              overflow: TextOverflow.fade,
              style: TextTheme.of(context).bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}
