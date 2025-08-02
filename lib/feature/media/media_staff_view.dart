import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:animeshin/feature/media/media_models.dart';
import 'package:animeshin/util/routes.dart';
import 'package:animeshin/widget/grid/mono_relation_grid.dart';
import 'package:animeshin/widget/paged_view.dart';
import 'package:animeshin/feature/media/media_provider.dart';

class MediaStaffSubview extends StatelessWidget {
  const MediaStaffSubview({required this.id, required this.scrollCtrl});

  final int id;
  final ScrollController scrollCtrl;

  @override
  Widget build(BuildContext context) {
    return PagedView<MediaRelatedItem>(
      scrollCtrl: scrollCtrl,
      onRefresh: (invalidate) => invalidate(mediaConnectionsProvider(id)),
      provider: mediaConnectionsProvider(id).select(
        (s) => s.unwrapPrevious().whenData((data) => data.staff),
      ),
      onData: (data) => MonoRelationGrid(
        items: data.items,
        onTap: (item) => context.push(
          Routes.staff(item.tileId, item.tileImageUrl),
        ),
      ),
    );
  }
}
