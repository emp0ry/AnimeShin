import 'dart:ui';

import 'package:animeshin/feature/watch/aniv_mapper.dart';
import 'package:animeshin/feature/watch/sameband_mapper.dart';
import 'package:animeshin/repository/anilibria/anilibria_repository.dart';
import 'package:animeshin/repository/aniv/aniv_repository.dart';
import 'package:animeshin/repository/sameband/sameband_repository.dart';
import 'package:animeshin/util/theming.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ionicons/ionicons.dart';

import '../collection/collection_models.dart';
import '../collection/collection_provider.dart';
import '../viewer/persistence_provider.dart';

import 'watch_types.dart';
import 'anilibria_mapper.dart';
import '../player/player_page.dart';

class WatchPage extends ConsumerStatefulWidget {
  const WatchPage({super.key, required this.id, required this.url, required this.item, required this.sync, required this.animeVoice, required this.startWithProxy});
  final int id;
  final String url;
  final Entry? item;
  final bool sync;
  final AnimeVoice animeVoice;
  final bool startWithProxy;

  @override
  ConsumerState<WatchPage> createState() => _WatchPageState();
}

class _WatchPageState extends ConsumerState<WatchPage> {
  AsyncValue<AniRelease>? _release;

  @override
  void initState() {
    super.initState();
    _release = const AsyncLoading();
    _load();
  }

  Future<void> _load() async {
    switch (widget.animeVoice) {
      case AnimeVoice.aniliberty: {
        try {
          final anilibertyRepo = AnilibriaRepository();
          final json = await anilibertyRepo.fetchById(id: widget.id);
          if (!mounted) return;
          if (json == null) {
            setState(() => _release = const AsyncError('Not found', StackTrace.empty));
            return;
          }
          final mapped = mapAniLibriaRelease(json);
          setState(() => _release = AsyncData(mapped));
        } catch (e, st) {
          if (!mounted) return;
          setState(() => _release = AsyncError(e, st));
        }
        break;
      }
      case AnimeVoice.aniv: {
        try {
          final anivRepo = AniVRepository();
          final items = await anivRepo.fetchPlaylist(widget.id);
          if (!mounted) return;
          if (items.isEmpty) {
            setState(() => _release = const AsyncError('Not found', StackTrace.empty));
            return;
          }
          final mapped = mapAniVRelease(items, widget.id, '');
          setState(() => _release = AsyncData(mapped));
        } catch (e, st) {
          if (!mounted) return;
          setState(() => _release = AsyncError(e, st));
        }
        break;
      }
      case AnimeVoice.sameband: {
        try {
          final samebandRepo = SameBandRepository();
          final items = await samebandRepo.fetchPlaylistByAnimePage(widget.url);
          if (!mounted) return;
          if (items.isEmpty) {
            setState(() => _release = const AsyncError('Not found', StackTrace.empty));
            return;
          }
          final mapped = mapSameBandRelease(items, widget.url, '');
          setState(() => _release = AsyncData(mapped));
        } catch (e, st) {
          if (!mounted) return;
          setState(() => _release = AsyncError(e, st));
        }
        break;
      }
    }
  }

  Entry? _findMatchingEntry(WidgetRef ref) {
    final viewerId = ref.watch(viewerIdProvider);
    if (viewerId == null) return null;

    final tag = (userId: viewerId, ofAnime: true);
    final collectionAsync = ref.watch(collectionProvider(tag));
    final collection = collectionAsync.valueOrNull;
    if (collection == null) return null;

    bool aliasMatches(Entry e) => (e.anilibriaId! != 0 && e.anilibriaId == widget.id)
                                  || (widget.item!.malId != 0 && e.malId != 0 && widget.item!.malId == e.malId);

    for (final e in collection.list.entries) {
      if (aliasMatches(e)) return e;
    }
    return null;
  }

  int _resolveInitialOrdinal({
    required AniRelease release,
    required Entry? entry,
  }) {
    final maxOrdinal =
        release.episodes.isNotEmpty ? release.episodes.last.ordinal : 1;
    if (entry == null) return 1;
    final ep = (entry.progress <= 0) ? 1 : (entry.progress + 1);
    return ep.clamp(1, maxOrdinal);
  }

  void _openPlayer(AniRelease release, int ordinal, Entry? item, bool sync, AnimeVoice animeVoice, bool startWithProxy) {
    final ep = release.episodes.firstWhere((e) => e.ordinal == ordinal);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerPage(
          args: PlayerArgs(
            id: release.id,
            url: release.url,
            ordinal: ordinal,
            title: release.title ?? '',
            url480: ep.hls480,
            url720: ep.hls720,
            url1080: ep.hls1080,
            duration: ep.duration,
            openingStart: ep.openingStart,
            openingEnd: ep.openingEnd,
            endingStart: ep.endingStart,
            endingEnd: ep.endingEnd,
          ),
          item: item,
          sync: sync,
          animeVoice: animeVoice,
          startWithProxy: startWithProxy,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rel = _release;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Watch'),
        actions: [
          IconButton(
            icon: const Icon(Ionicons.refresh),
            tooltip: 'Reload',
            onPressed: _load,
          ),
          // Support button that opens dubs source support page
          if (widget.animeVoice != AnimeVoice.aniv)
            IconButton(
              icon: const Icon(Ionicons.heart),
              tooltip: 'Support voiceover authors',
              onPressed: () async {
                await openSupport(widget.animeVoice, context);
              },
            ),
          const SizedBox(width: 8), // Add a small right inset so actions aren't flush to the edge
        ],
      ),
      body: switch (rel) {
        AsyncData(:final value) => _Body(
            release: value,
            entry: _findMatchingEntry(ref),
            onPlay: (e) => _openPlayer(value, e.ordinal, widget.item, widget.sync, widget.animeVoice, widget.startWithProxy),
          ),
        AsyncError(:final error) => Center(
            child: Text(
              'Failed to load: $error',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        _ => const Center(child: CircularProgressIndicator()),
      },
      floatingActionButton: rel is AsyncData<AniRelease>
          ? _PlayFab(
              release: rel.value,
              entry: _findMatchingEntry(ref),
              onPressed: () {
                final i = _resolveInitialOrdinal(
                  release: rel.value,
                  entry: _findMatchingEntry(ref),
                );
                _openPlayer(rel.value, i, widget.item, widget.sync, widget.animeVoice, widget.startWithProxy);
              },
            )
          : null,
    );
  }
}

class _PlayFab extends StatelessWidget {
  const _PlayFab({
    required this.release,
    required this.entry,
    required this.onPressed,
  });

  final AniRelease release;
  final Entry? entry;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final next = entry == null ? 1 : (entry!.progress <= 0 ? 1 : entry!.progress + 1);
    final max = release.episodes.isEmpty ? next : release.episodes.last.ordinal;
    final clamped = next.clamp(1, max);

    return FloatingActionButton.extended(
      onPressed: onPressed,
      icon: const Icon(Ionicons.play),
      label: Text('Watch • Ep $clamped'),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({
    required this.release,
    required this.entry,
    required this.onPlay,
  });

  final AniRelease release;
  final Entry? entry;
  final void Function(AniEpisode) onPlay;

  @override
  Widget build(BuildContext context) {
    final continued = entry?.progress ?? 0;

    return ListView.separated(
      padding: const EdgeInsets.all(Theming.offset),
      itemCount: release.episodes.length,
      separatorBuilder: (_, __) => const SizedBox(height: Theming.offset),
      itemBuilder: (context, i) {
        final e = release.episodes[i];

        // watched / continue
        final watched = e.ordinal <= continued;
        final isContinue = e.ordinal == continued + 1;

        return _EpisodeTile(
          episode: e,
          watched: watched,
          isContinue: isContinue,
          onPlay: () => onPlay(e),
        );
      },
    );
  }
}

class _EpisodeTile extends StatelessWidget {
  const _EpisodeTile({
    required this.episode,
    required this.watched,
    required this.isContinue,
    required this.onPlay,
  });

  final AniEpisode episode;
  final bool watched;
  final bool isContinue;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).colorScheme.surfaceContainerHighest;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPlay,
        child: SizedBox(
          height: 96,
          child: Row(
            children: [
              AspectRatio(
                aspectRatio: Theming.coverHtoWRatio,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Container(color: surface),
                    if (episode.previewSrc != null)
                      Image.network(episode.previewSrc!, fit: BoxFit.cover),
                    if (watched || isContinue)
                      _WatchedBadge(isContinue: isContinue),
                  ],
                ),
              ),
              // Title + meta + play
              Expanded(
                child: Padding(
                  padding: Theming.paddingAll,
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.max,
                          children: [
                            Text(
                              'Episode ${episode.ordinal}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              // If you have a custom TextTheme.of, keep it; otherwise use Theme.of(context).textTheme
                              style: TextTheme.of(context).titleMedium,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              episode.name ?? '',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextTheme.of(context).bodySmall,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      // IconButton.filledTonal(
                      //   onPressed: onPlay,
                      //   icon: const Icon(Ionicons.play),
                      //   tooltip: 'Play',
                      // ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Frosted/blurred ribbon for "Watched" / "Continue".
class _WatchedBadge extends StatelessWidget {
  const _WatchedBadge({required this.isContinue});
  final bool isContinue;

  @override
  Widget build(BuildContext context) {
    final text = isContinue ? 'Continue' : 'Watched';
    final bg = Colors.black.withValues(alpha: 0.45);

    return Align(
      alignment: Alignment.bottomLeft,
      child: ClipRRect(
        borderRadius: const BorderRadius.only(topRight: Theming.radiusSmall),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            color: bg,
            child: Text(
              text,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
            ),
          ),
        ),
      ),
    );
  }
}
