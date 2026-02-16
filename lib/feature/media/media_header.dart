import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ionicons/ionicons.dart';

import 'package:animeshin/extension/date_time_extension.dart';
import 'package:animeshin/extension/snack_bar_extension.dart';
import 'package:animeshin/feature/collection/collection_entries_provider.dart';
import 'package:animeshin/feature/collection/module_search_page.dart';
import 'package:animeshin/feature/media/media_models.dart';
import 'package:animeshin/feature/viewer/persistence_provider.dart';
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
    final viewerId = ref.watch(viewerIdProvider);
    final liveEntry = (media != null && viewerId != null && viewerId != 0)
        ? ref.watch(
            collectionEntryProvider(
              (tag: (userId: viewerId, ofAnime: media!.info.isAnime), mediaId: id),
            ),
          )
        : null;

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
        final progress = liveEntry?.progress ?? media!.entryEdit.progress;
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
        if (media != null)
          Container(
            key: menuAnchorKey,
            child: Tooltip(
              message: 'Search',
              child: TextButton.icon(
                style: TextButton.styleFrom(
                  backgroundColor: Colors.black.withValues(alpha: 0.25),
                  foregroundColor: Colors.white,
                ),
                icon: Icon(
                  media!.info.isAnime
                      ? Ionicons.play
                      : Ionicons.book,
                ),
                label: Text('Search'),
                onPressed: () async {
                final m = media;
                if (m == null) return;

                final info = m.info;

                ({String by, String query}) qv(String by, String query) =>
                    (by: by, query: query);

                final queries = <({String by, String query})>[
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

                final entry = liveEntry;

                if (!context.mounted) return;
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ModuleSearchPage(
                      item: entry,
                      isManga: !info.isAnime,
                      searchQueries: queries,
                    ),
                  ),
                );
                },
              ),
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
