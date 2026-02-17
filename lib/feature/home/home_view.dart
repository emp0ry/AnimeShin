import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:ionicons/ionicons.dart';
import 'package:animeshin/extension/scroll_controller_extension.dart';
import 'package:animeshin/feature/activity/activities_provider.dart';
import 'package:animeshin/feature/activity/activities_view.dart';
import 'package:animeshin/feature/collection/collection_entries_provider.dart';
import 'package:animeshin/feature/collection/collection_floating_action.dart';
import 'package:animeshin/feature/collection/collection_models.dart';
import 'package:animeshin/feature/collection/collection_top_bar.dart';
import 'package:animeshin/feature/discover/discover_filter_provider.dart';
import 'package:animeshin/feature/discover/discover_floating_action.dart';
import 'package:animeshin/feature/discover/discover_provider.dart';
import 'package:animeshin/feature/discover/discover_top_bar.dart';
import 'package:animeshin/feature/discover/discover_search_focus_provider.dart';
import 'package:animeshin/feature/feed/feed_floating_action.dart';
import 'package:animeshin/feature/feed/feed_top_bar.dart';
import 'package:animeshin/feature/home/home_model.dart';
import 'package:animeshin/feature/home/home_tab_order.dart';
import 'package:animeshin/feature/home/home_provider.dart';
import 'package:animeshin/feature/settings/settings_provider.dart';
import 'package:animeshin/feature/tag/tag_provider.dart';
import 'package:animeshin/feature/user/user_providers.dart';
import 'package:animeshin/feature/user/user_view.dart';
import 'package:animeshin/feature/viewer/persistence_provider.dart';
import 'package:animeshin/util/paged_controller.dart';
import 'package:animeshin/feature/discover/discover_view.dart';
import 'package:animeshin/feature/collection/collection_view.dart';
import 'package:animeshin/util/routes.dart';
import 'package:animeshin/util/theming.dart';
import 'package:animeshin/widget/layout/adaptive_scaffold.dart';
import 'package:animeshin/widget/layout/hiding_floating_action_button.dart';
import 'package:animeshin/widget/layout/top_bar.dart';

class HomeView extends ConsumerStatefulWidget {
  const HomeView({super.key, this.tab});

  final HomeTab? tab;

  @override
  ConsumerState<HomeView> createState() => _HomeViewState();
}

class _HomeViewState extends ConsumerState<HomeView>
    with SingleTickerProviderStateMixin {
  final _animeFocusNode = FocusNode();
  final _mangaFocusNode = FocusNode();
  final _discoverFocusNode = FocusNode();

  final _animeScrollCtrl = ScrollController();
  final _mangaScrollCtrl = ScrollController();
  late final _feedScrollCtrl = PagedController(
    loadMore: () => ref.read(activitiesProvider(null).notifier).fetch(),
  );
  late final _discoverScrollCtrl = PagedController(
    loadMore: () => ref.read(discoverProvider.notifier).fetch(),
  );

  late final _tabCtrl = TabController(
    length: homeTabUiOrder.length,
    vsync: this,
  );

  @override
  void initState() {
    super.initState();
    final persistence = ref.read(persistenceProvider);

    _tabCtrl.index = homeUiIndexByTab(persistence.options.homeTab);
    if (widget.tab != null) _tabCtrl.index = homeUiIndexByTab(widget.tab!);

    _tabCtrl.addListener(
      () => WidgetsBinding.instance.addPostFrameCallback(
        (_) {
          final tab = homeTabByUiIndex(_tabCtrl.index);
          if (tab != HomeTab.anime) _animeFocusNode.unfocus();
          if (tab != HomeTab.manga) _mangaFocusNode.unfocus();
          if (tab != HomeTab.discover) _discoverFocusNode.unfocus();
          context.go(Routes.home(tab));
        },
      ),
    );
  }

  @override
  void didUpdateWidget(covariant HomeView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.tab != null) _tabCtrl.index = homeUiIndexByTab(widget.tab!);
  }

  @override
  void deactivate() {
    ref.invalidate(discoverProvider);
    ref.invalidate(discoverFilterProvider);
    ref.invalidate(activitiesProvider(null));
    super.deactivate();
  }

  @override
  void dispose() {
    _animeFocusNode.dispose();
    _mangaFocusNode.dispose();
    _discoverFocusNode.dispose();

    _animeScrollCtrl.dispose();
    _mangaScrollCtrl.dispose();
    _feedScrollCtrl.dispose();
    _discoverScrollCtrl.dispose();

    _tabCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(settingsProvider.select((_) => null));
    ref.watch(tagsProvider.select((_) => null));

    final currentTab = homeTabByUiIndex(_tabCtrl.index);
    final requestDiscoverSearchFocus =
        ref.watch(requestDiscoverSearchFocusProvider);
    if (requestDiscoverSearchFocus && currentTab == HomeTab.discover) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _discoverFocusNode.requestFocus();
        ref.read(requestDiscoverSearchFocusProvider.notifier).set(false);
      });
    }

    if (currentTab == HomeTab.feed) {
      ref.watch(activitiesProvider(null).select((_) => null));
    } else if (currentTab == HomeTab.discover) {
      ref.watch(discoverProvider.select((_) => null));
    }

    UserTag? userTag;
    CollectionTag? animeCollectionTag;
    CollectionTag? mangaCollectionTag;

    final viewerId = ref.watch(viewerIdProvider);
    if (viewerId != null) {
      userTag = idUserTag(viewerId);
      animeCollectionTag = (userId: viewerId, ofAnime: true);
      mangaCollectionTag = (userId: viewerId, ofAnime: false);

      ref.watch(userProvider(userTag).select((_) => null));
      ref.watch(
        collectionEntriesProvider(animeCollectionTag).select((_) => null),
      );
      ref.watch(
        collectionEntriesProvider(mangaCollectionTag).select((_) => null),
      );
    }

    final primaryScrollCtrl = PrimaryScrollController.of(context);
    final home = ref.watch(homeProvider);
    final formFactor = Theming.of(context).formFactor;

    final topBar = TopBarAnimatedSwitcher(
      switch (currentTab) {
        HomeTab.discover => TopBar(
            key: const Key('discoverTobBar'),
            trailing: [
              DiscoverTopBarTrailingContent(_discoverFocusNode),
            ],
          ),
        HomeTab.anime when animeCollectionTag != null => TopBar(
            key: const Key('animeCollectionTopBar'),
            trailing: [
              CollectionTopBarTrailingContent(
                animeCollectionTag,
                _animeFocusNode,
              ),
            ],
          ),
        HomeTab.manga when mangaCollectionTag != null => TopBar(
            key: const Key('mangaCollectionTopBar'),
            trailing: [
              CollectionTopBarTrailingContent(
                mangaCollectionTag,
                _mangaFocusNode,
              ),
            ],
          ),
        HomeTab.feed => const TopBar(
            key: Key('feedTopBar'),
            title: 'Feed',
            trailing: [
              FeedTopBarTrailingContent(),
            ],
          ),
        _ => const EmptyTopBar() as PreferredSizeWidget,
      },
    );

    double? safePixels(ScrollController ctrl) {
      try {
        if (!ctrl.hasClients) return null;
        return ctrl.position.pixels;
      } catch (_) {
        return null;
      }
    }

    final navigationConfig = NavigationConfig(
      items: _homeTabs,
      selected: _tabCtrl.index,
      onChanged: (i) => context.go(Routes.home(homeTabByUiIndex(i))),
      onSame: (i) {
        final tab = homeTabByUiIndex(i);

        switch (tab) {
          case HomeTab.feed:
            _feedScrollCtrl.scrollToTop();
          case HomeTab.anime:
            final animePixels = safePixels(_animeScrollCtrl);
            if (animePixels != null && animePixels > 0) {
              _animeScrollCtrl.scrollToTop();
              return;
            }

            _toggleSearchFocus(_animeFocusNode);
          case HomeTab.manga:
            final mangaPixels = safePixels(_mangaScrollCtrl);
            if (mangaPixels != null && mangaPixels > 0) {
              _mangaScrollCtrl.scrollToTop();
              return;
            }

            _toggleSearchFocus(_mangaFocusNode);
          case HomeTab.discover:
            final discoverPixels = safePixels(_discoverScrollCtrl);
            if (discoverPixels != null && discoverPixels > 0) {
              _discoverScrollCtrl.scrollToTop();
              return;
            }

            _toggleSearchFocus(_discoverFocusNode);
            return;
          case HomeTab.profile:
            final primaryPixels = safePixels(primaryScrollCtrl);
            if (primaryPixels != null && primaryPixels > 0) {
              primaryScrollCtrl.scrollToTop();
              return;
            }

            context.push(Routes.settings);
        }
      },
    );

    final floatingAction = switch (currentTab) {
      HomeTab.discover => formFactor == FormFactor.phone
          ? HidingFloatingActionButton(
              key: const Key('discover'),
              scrollCtrl: _discoverScrollCtrl,
              child: const DiscoverFloatingAction(),
            )
          : null,
      HomeTab.anime => (formFactor == FormFactor.phone || !home.didExpandAnimeCollection) &&
              animeCollectionTag != null
          ? HidingFloatingActionButton(
              key: const Key('anime'),
              scrollCtrl: _animeScrollCtrl,
              child: CollectionFloatingAction(animeCollectionTag),
            )
          : null,
      HomeTab.manga => (formFactor == FormFactor.phone || !home.didExpandMangaCollection) &&
              mangaCollectionTag != null
          ? HidingFloatingActionButton(
              key: const Key('manga'),
              scrollCtrl: _mangaScrollCtrl,
              child: CollectionFloatingAction(mangaCollectionTag),
            )
          : null,
      HomeTab.feed => HidingFloatingActionButton(
          key: const Key('feed'),
          scrollCtrl: _feedScrollCtrl,
          child: FeedFloatingAction(ref),
        ),
      _ => null,
    };

    final child = TabBarView(
      controller: _tabCtrl,
      physics: const ClampingScrollPhysics(),
      children: [
        DiscoverSubview(_discoverScrollCtrl, formFactor),
        CollectionSubview(
          scrollCtrl: _animeScrollCtrl,
          tag: animeCollectionTag,
          formFactor: formFactor,
          key: Key(true.toString()),
        ),
        CollectionSubview(
          scrollCtrl: _mangaScrollCtrl,
          tag: mangaCollectionTag,
          formFactor: formFactor,
          key: Key(false.toString()),
        ),
        ActivitiesSubView(null, _feedScrollCtrl),
        UserHomeView(
          userTag,
          null,
          homeScrollCtrl: primaryScrollCtrl,
          removableTopPadding: topBar.preferredSize.height,
        ),
      ],
    );

    return AdaptiveScaffold(
      topBar: topBar,
      floatingAction: floatingAction,
      navigationConfig: navigationConfig,
      child: child,
    );
  }

  static final _homeTabs = {
    HomeTab.discover.label: Ionicons.compass_outline,
    HomeTab.anime.label: Ionicons.film_outline,
    HomeTab.manga.label: Ionicons.book_outline,
    HomeTab.feed.label: Ionicons.file_tray_outline,
    HomeTab.profile.label: Ionicons.person_outline,
  };

  void _toggleSearchFocus(FocusNode node) =>
      node.hasFocus ? node.unfocus() : node.requestFocus();
}
