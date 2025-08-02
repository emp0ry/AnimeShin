import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:animeshin/feature/viewer/persistence_provider.dart';
import 'package:animeshin/feature/home/home_model.dart';

final homeProvider = NotifierProvider.autoDispose<HomeNotifier, Home>(
  HomeNotifier.new,
);

class HomeNotifier extends AutoDisposeNotifier<Home> {
  @override
  Home build() {
    final options = ref.watch(persistenceProvider.select((s) => s.options));

    return Home(
      didExpandAnimeCollection: !options.animeCollectionPreview,
      didExpandMangaCollection: !options.mangaCollectionPreview,
    );
  }

  void expandCollection(bool ofAnime) =>
      state = state.withExpandedCollection(ofAnime);
}
