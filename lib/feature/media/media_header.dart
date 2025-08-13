import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:animeshin/extension/date_time_extension.dart';
import 'package:animeshin/extension/snack_bar_extension.dart';
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
        final progress = media!.entryEdit.progress;
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
      siteAniLibriaUrl: media?.info.siteAniLibriaUrl,
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
