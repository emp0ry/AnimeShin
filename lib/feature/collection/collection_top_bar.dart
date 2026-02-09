import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:ionicons/ionicons.dart';
import 'package:animeshin/feature/collection/collection_entries_provider.dart';
import 'package:animeshin/feature/collection/collection_filter_provider.dart';
import 'package:animeshin/feature/collection/collection_models.dart';
import 'package:animeshin/feature/collection/collection_provider.dart';
import 'package:animeshin/feature/collection/collection_filter_view.dart';
import 'package:animeshin/feature/discover/discover_filter_model.dart';
import 'package:animeshin/feature/discover/discover_filter_provider.dart';
import 'package:animeshin/feature/discover/discover_model.dart';
import 'package:animeshin/feature/home/home_model.dart';
import 'package:animeshin/feature/viewer/persistence_provider.dart';
import 'package:animeshin/util/routes.dart';
import 'package:animeshin/util/debounce.dart';
import 'package:animeshin/widget/input/search_field.dart';
import 'package:animeshin/widget/dialogs.dart';
import 'package:animeshin/widget/sheets.dart';

class CollectionTopBarTrailingContent extends StatelessWidget {
  const CollectionTopBarTrailingContent(this.tag, this.focusNode);

  final CollectionTag tag;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    return Consumer(
      builder: (context, ref, _) {
        final filter = ref.watch(collectionFilterProvider(tag));

        final filterIcon = IconButton(
          tooltip: 'Filter',
          icon: const Icon(Ionicons.funnel_outline),
          onPressed: () => showSheet(
            context,
            CollectionFilterView(
              tag: tag,
              filter: filter.mediaFilter,
              onChanged: (mediaFilter) => ref
                  .read(collectionFilterProvider(tag).notifier)
                  .update((s) => s.copyWith(mediaFilter: mediaFilter)),
            ),
          ),
        );

        return Expanded(
          child: Row(
            children: [
              Expanded(
                child: SearchField(
                  debounce: Debounce(),
                  focusNode: focusNode,
                  hint: ref.watch(collectionProvider(tag).select(
                    (s) => s.asData?.value.list.name ?? '',
                  )),
                  value: filter.search,
                  onChanged: (search) => ref
                      .read(collectionFilterProvider(tag).notifier)
                      .update((s) => s.copyWith(search: search)),
                ),
              ),
              IconButton(
                tooltip: 'Random',
                icon: const Icon(Ionicons.shuffle_outline),
                onPressed: () {
                  final entries = ref.read(collectionEntriesProvider(tag));

                  if (entries.isEmpty) {
                    ConfirmationDialog.show(context, title: 'No entries');
                    return;
                  }

                  final e = entries[Random().nextInt(entries.length)];
                  context.push(Routes.media(e.mediaId, e.imageUrl));
                },
              ),
              if (tag.ofAnime)
                IconButton(
                  tooltip: 'Search',
                  icon: const Icon(Ionicons.search_outline),
                  onPressed: () {
                    final collectionFilter =
                        ref.read(collectionFilterProvider(tag));
                    final sort =
                        ref.read(persistenceProvider).discoverMediaFilter.sort;

                    ref.read(discoverFilterProvider.notifier).update(
                          (f) => f.copyWith(
                            type: DiscoverType.anime,
                            search: collectionFilter.search,
                            mediaFilter: DiscoverMediaFilter.fromCollection(
                              filter: collectionFilter.mediaFilter,
                              sort: sort,
                              ofAnime: true,
                            ),
                          ),
                        );

                    context.go(Routes.home(HomeTab.discover));
                    ref.invalidate(collectionFilterProvider(tag));
                  },
                ),
              if (filter.mediaFilter.isActive)
                Badge(
                  smallSize: 10,
                  alignment: Alignment.topLeft,
                  backgroundColor: ColorScheme.of(context).primary,
                  child: filterIcon,
                )
              else
                filterIcon,
              const SizedBox(width: 8),
            ],
          ),
        );
      },
    );
  }
}
