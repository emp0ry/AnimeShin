import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:animeshin/feature/collection/collection_floating_action.dart';
import 'package:animeshin/feature/collection/collection_top_bar.dart';
import 'package:animeshin/feature/discover/discover_filter_model.dart';
import 'package:animeshin/feature/discover/discover_filter_provider.dart';
import 'package:animeshin/feature/discover/discover_model.dart';
import 'package:animeshin/feature/home/home_model.dart';
import 'package:animeshin/feature/viewer/persistence_provider.dart';
import 'package:animeshin/util/routes.dart';
import 'package:animeshin/util/theming.dart';
import 'package:animeshin/extension/snack_bar_extension.dart';
import 'package:animeshin/feature/collection/collection_entries_provider.dart';
import 'package:animeshin/feature/collection/collection_filter_provider.dart';
import 'package:animeshin/feature/collection/collection_grid.dart';
import 'package:animeshin/feature/collection/collection_models.dart';
import 'package:animeshin/feature/collection/collection_provider.dart';
import 'package:animeshin/widget/input/pill_selector.dart';
import 'package:animeshin/widget/layout/adaptive_scaffold.dart';
import 'package:animeshin/widget/layout/constrained_view.dart';
import 'package:animeshin/widget/layout/hiding_floating_action_button.dart';
import 'package:animeshin/widget/layout/top_bar.dart';
import 'package:animeshin/widget/loaders.dart';
import 'package:animeshin/feature/collection/collection_list.dart';
import 'package:animeshin/feature/media/media_models.dart';

class CollectionView extends ConsumerStatefulWidget {
  const CollectionView(this.userId, this.ofAnime);

  final int userId;
  final bool ofAnime;

  @override
  ConsumerState<CollectionView> createState() => _CollectionViewState();
}

class _CollectionViewState extends ConsumerState<CollectionView> {
  final _ctrl = ScrollController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tag = (userId: widget.userId, ofAnime: widget.ofAnime);
    final formFactor = Theming.of(context).formFactor;

    return AdaptiveScaffold(
      topBar: TopBar(
        trailing: [CollectionTopBarTrailingContent(tag, null)],
      ),
      floatingAction: formFactor == FormFactor.phone
          ? HidingFloatingActionButton(
              key: const Key('lists'),
              scrollCtrl: _ctrl,
              child: CollectionFloatingAction(tag),
            )
          : null,
      child: CollectionSubview(
        tag: tag,
        scrollCtrl: _ctrl,
        formFactor: formFactor,
      ),
    );
  }
}

class CollectionSubview extends StatelessWidget {
  const CollectionSubview({
    required this.tag,
    required this.scrollCtrl,
    required this.formFactor,
    super.key,
  });

  final CollectionTag? tag;
  final ScrollController scrollCtrl;
  final FormFactor formFactor;

  @override
  Widget build(BuildContext context) {
    if (tag == null) {
      return const Center(
        child: Padding(
          padding: Theming.paddingAll,
          child: Text(
            'Log in from the profile tab to view your collections',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    final listToWidget = (EntryList l) => Row(
          children: [
            Expanded(child: Text(l.name)),
            const SizedBox(width: Theming.offset / 2),
            DefaultTextStyle(
              style: TextTheme.of(context).labelMedium!,
              child: Text(l.entries.length.toString()),
            ),
          ],
        );

    return Consumer(
      builder: (context, ref, _) {
        ref.listen<AsyncValue>(
          collectionProvider(tag!),
          (_, s) => s.whenOrNull(
            error: (error, _) => SnackBarExtension.show(
              context,
              error.toString(),
            ),
          ),
        );

        return ref.watch(collectionProvider(tag!)).unwrapPrevious().when(
              loading: () => const Center(child: Loader()),
              error: (_, __) => CustomScrollView(
                physics: Theming.bouncyPhysics,
                slivers: [
                  SliverRefreshControl(
                    onRefresh: () => ref.invalidate(collectionProvider(tag!)),
                  ),
                  const SliverFillRemaining(
                    child: Center(child: Text('Failed to load')),
                  ),
                ],
              ),
              data: (data) {
                final content = Scrollbar(
                  controller: scrollCtrl,
                  interactive: false,
                  thumbVisibility: false,
                  trackVisibility: false,
                  thickness: 0.0,
                  child: ConstrainedView(
                    child: CustomScrollView(
                      physics: Theming.bouncyPhysics,
                      controller: scrollCtrl,
                      slivers: [
                        SliverRefreshControl(
                          onRefresh: () => ref.invalidate(
                            collectionProvider(tag!),
                          ),
                        ),
                        _Content(tag!, data),
                        const SliverFooter(),
                      ],
                    ),
                  ),
                );

                if (formFactor == FormFactor.phone) return content;

                return switch (data) {
                  PreviewCollection _ => content,
                  FullCollection c => Row(
                      children: [
                        PillSelector(
                          maxWidth: 200,
                          selected: c.index,
                          items: data.lists.map(listToWidget).toList(),
                          onTap: (i) => ref
                              .read(collectionProvider(tag!).notifier)
                              .changeIndex(i),
                        ),
                        Expanded(child: content)
                      ],
                    ),
                };
              },
            );
      },
    );
  }
}

class _Content extends StatelessWidget {
  const _Content(this.tag, this.collection);

  final CollectionTag tag;
  final Collection collection;

  @override
  Widget build(BuildContext context) {
    return Consumer(
      builder: (context, ref, _) {
        final entries = ref.watch(collectionEntriesProvider(tag));

        final options = ref.watch(persistenceProvider.select((s) => s.options));
        final isViewer = ref.watch(viewerIdProvider) == tag.userId;

        if (entries.isEmpty) {
          if (!isViewer) {
            return const SliverFillRemaining(
              child: Center(child: Text('No results')),
            );
          }

          return SliverFillRemaining(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('No results'),
                  TextButton(
                    onPressed: () => _searchGlobally(context, ref),
                    child: const Text('Search Globally'),
                  ),
                ],
              ),
            ),
          );
        }

        final onProgressUpdated = isViewer
            ? ref.read(collectionProvider(tag).notifier).saveEntryProgress
            : null;

        final collectionIsExpanded = switch (collection) {
          PreviewCollection _ => false,
          FullCollection _ => true,
        };

        if (collectionIsExpanded &&
                options.collectionItemView == CollectionItemView.simple ||
            !collectionIsExpanded &&
                options.collectionPreviewItemView ==
                    CollectionItemView.simple) {
          return CollectionGrid(
            items: entries,
            onProgressUpdated: onProgressUpdated,
          );
        }

        return CollectionList(
          items: entries,
          onProgressUpdated: onProgressUpdated,
          scoreFormat: ref.watch(
            collectionProvider(tag).select(
              (s) => s.asData?.value.scoreFormat ?? ScoreFormat.point10Decimal,
            ),
          ),
        );
      },
    );
  }

  void _searchGlobally(BuildContext context, WidgetRef ref) {
    final collectionFilter = ref.read(collectionFilterProvider(tag));
    final sort = ref.read(persistenceProvider).discoverMediaFilter.sort;

    ref.read(discoverFilterProvider.notifier).update((f) => f.copyWith(
          type: tag.ofAnime ? DiscoverType.anime : DiscoverType.manga,
          search: collectionFilter.search,
          mediaFilter: DiscoverMediaFilter.fromCollection(
            filter: collectionFilter.mediaFilter,
            sort: sort,
            ofAnime: tag.ofAnime,
          ),
        ));

    context.go(Routes.home(HomeTab.discover));
    ref
        .read(collectionFilterProvider(tag).notifier)
        .resetActivePageToDefaults();
  }
}
