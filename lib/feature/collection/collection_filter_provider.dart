import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:animeshin/feature/collection/collection_filter_model.dart';
import 'package:animeshin/feature/collection/collection_provider.dart';
import 'package:animeshin/feature/viewer/persistence_provider.dart';
import 'package:animeshin/feature/collection/collection_models.dart';
import 'package:animeshin/feature/viewer/persistence_model.dart';

const previewCollectionFilterPageKey = 'preview';

String _normalizeCollectionFilterKeyPart(String value) {
  final normalized = value.trim().toLowerCase();
  if (normalized.isEmpty) return 'empty';
  return Uri.encodeComponent(normalized);
}

String collectionFilterPageKeyFromEntryList(EntryList list) {
  final normalizedName = _normalizeCollectionFilterKeyPart(list.name);
  final status = list.status;
  if (status == null) {
    return 'custom:$normalizedName';
  }

  final splitFormat = list.splitCompletedListFormat?.value ?? 'none';
  return 'status:${status.value}:$splitFormat:$normalizedName';
}

String collectionFilterPageKeyFromCollection(Collection collection) =>
    switch (collection) {
      PreviewCollection _ => previewCollectionFilterPageKey,
      FullCollection c => collectionFilterPageKeyFromEntryList(c.list),
    };

final activeCollectionFilterPageKeyProvider =
    Provider.autoDispose.family<String, CollectionTag>(
  (ref, tag) {
    final collection =
        ref.watch(collectionProvider(tag)).unwrapPrevious().asData?.value;

    if (collection == null) {
      return previewCollectionFilterPageKey;
    }
    return collectionFilterPageKeyFromCollection(collection);
  },
);

CollectionMediaFilter collectionMediaFilterDefaultForPage({
  required Persistence persistence,
  required CollectionTag tag,
  required String pageKey,
}) {
  final savedByPage = tag.ofAnime
      ? persistence.animeCollectionMediaFilterByPage
      : persistence.mangaCollectionMediaFilterByPage;
  final globalDefault = tag.ofAnime
      ? persistence.animeCollectionMediaFilter
      : persistence.mangaCollectionMediaFilter;
  return (savedByPage[pageKey] ?? globalDefault).copy();
}

final collectionFilterProvider = NotifierProvider.autoDispose
    .family<CollectionFilterNotifier, CollectionFilter, CollectionTag>(
  (arg) => CollectionFilterNotifier(arg),
);

class CollectionFilterNotifier extends Notifier<CollectionFilter> {
  CollectionFilterNotifier(this.arg);

  final CollectionTag arg;
  final _searchByPageKey = <String, String>{};
  final _mediaFilterByPageKey = <String, CollectionMediaFilter>{};
  String? _lastKnownPageKey;

  @override
  CollectionFilter build() {
    ref.keepAlive();

    final pageKey = ref.watch(activeCollectionFilterPageKeyProvider(arg));
    final defaults = ref.watch(persistenceProvider.select(
      (s) => (
        globalDefault: arg.ofAnime
            ? s.animeCollectionMediaFilter
            : s.mangaCollectionMediaFilter,
        byPage: arg.ofAnime
            ? s.animeCollectionMediaFilterByPage
            : s.mangaCollectionMediaFilterByPage,
      ),
    ));

    _ensurePageInitialized(
      pageKey: pageKey,
      globalDefault: defaults.globalDefault,
      savedByPage: defaults.byPage,
    );

    _lastKnownPageKey = pageKey;
    final mediaFilter = _mediaFilterByPageKey[pageKey]!.copy();
    final search = _searchByPageKey[pageKey] ?? '';
    return CollectionFilter(mediaFilter).copyWith(search: search);
  }

  CollectionFilter update(
    CollectionFilter Function(CollectionFilter) callback,
  ) {
    final pageKey = ref.read(activeCollectionFilterPageKeyProvider(arg));
    if (!_mediaFilterByPageKey.containsKey(pageKey)) {
      final persistence = ref.read(persistenceProvider);
      final globalDefault = arg.ofAnime
          ? persistence.animeCollectionMediaFilter
          : persistence.mangaCollectionMediaFilter;
      final byPage = arg.ofAnime
          ? persistence.animeCollectionMediaFilterByPage
          : persistence.mangaCollectionMediaFilterByPage;
      _ensurePageInitialized(
        pageKey: pageKey,
        globalDefault: globalDefault,
        savedByPage: byPage,
      );
    }
    final current = _currentForPage(pageKey);
    final next = callback(current);

    _mediaFilterByPageKey[pageKey] = next.mediaFilter.copy();
    _searchByPageKey[pageKey] = next.search;
    _lastKnownPageKey = pageKey;

    return state = CollectionFilter(next.mediaFilter.copy()).copyWith(
      search: next.search,
    );
  }

  CollectionMediaFilter defaultMediaFilterForActivePage() {
    final pageKey = ref.read(activeCollectionFilterPageKeyProvider(arg));
    final persistence = ref.read(persistenceProvider);
    return collectionMediaFilterDefaultForPage(
      persistence: persistence,
      tag: arg,
      pageKey: pageKey,
    );
  }

  String activePageKey() =>
      ref.read(activeCollectionFilterPageKeyProvider(arg));

  void saveActivePageDefault(CollectionMediaFilter mediaFilter) {
    final pageKey = activePageKey();
    final notifier = ref.read(persistenceProvider.notifier);

    if (arg.ofAnime) {
      notifier.setAnimeCollectionMediaFilterForPage(pageKey, mediaFilter);
    } else {
      notifier.setMangaCollectionMediaFilterForPage(pageKey, mediaFilter);
    }
  }

  void resetActivePageToDefaults({bool clearSearch = true}) {
    final pageKey = activePageKey();
    final defaults = defaultMediaFilterForActivePage();
    _mediaFilterByPageKey[pageKey] = defaults.copy();
    if (clearSearch) {
      _searchByPageKey[pageKey] = '';
    } else {
      _searchByPageKey.putIfAbsent(pageKey, () => '');
    }

    final search = _searchByPageKey[pageKey] ?? '';
    state = CollectionFilter(defaults.copy()).copyWith(search: search);
  }

  void _ensurePageInitialized({
    required String pageKey,
    required CollectionMediaFilter globalDefault,
    required Map<String, CollectionMediaFilter> savedByPage,
  }) {
    if (_mediaFilterByPageKey.containsKey(pageKey)) {
      _searchByPageKey.putIfAbsent(pageKey, () => '');
      return;
    }

    final hasSavedPageDefault = savedByPage.containsKey(pageKey);
    final canCopyPreviewToFull =
        _lastKnownPageKey == previewCollectionFilterPageKey &&
            pageKey != previewCollectionFilterPageKey &&
            !hasSavedPageDefault &&
            _mediaFilterByPageKey.containsKey(previewCollectionFilterPageKey);

    if (canCopyPreviewToFull) {
      final previewFilter =
          _mediaFilterByPageKey[previewCollectionFilterPageKey]!.copy();
      previewFilter.sort = previewFilter.previewSort;
      _mediaFilterByPageKey[pageKey] = previewFilter;
      _searchByPageKey[pageKey] =
          _searchByPageKey[previewCollectionFilterPageKey] ?? '';
      return;
    }

    _mediaFilterByPageKey[pageKey] =
        (savedByPage[pageKey] ?? globalDefault).copy();
    _searchByPageKey.putIfAbsent(pageKey, () => '');
  }

  CollectionFilter _currentForPage(String pageKey) {
    final mediaFilter = _mediaFilterByPageKey[pageKey];
    if (mediaFilter == null) return state;
    return CollectionFilter(mediaFilter.copy()).copyWith(
      search: _searchByPageKey[pageKey] ?? '',
    );
  }
}
