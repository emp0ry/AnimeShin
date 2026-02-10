import 'dart:async';
import 'dart:ui';

import 'package:animeshin/util/theming.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ionicons/ionicons.dart';

import '../collection/collection_models.dart';
import '../collection/collection_provider.dart';
import '../viewer/persistence_provider.dart';

import 'watch_types.dart';
import '../player/player_page.dart';

class WatchPage extends ConsumerStatefulWidget {
  const WatchPage(
      {super.key,
      required this.id,
      required this.url,
      required this.item,
      required this.sync,
      required this.animeVoice,
      required this.startWithProxy});
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
    // Legacy site-specific playback removed. Direct users to module-based playback.
    if (!mounted) return;
    setState(() => _release = const AsyncError(
        'Use modules playback (ModuleWatchPage)', StackTrace.empty));
  }

  Entry? _findMatchingEntry(WidgetRef ref) {
    final viewerId = ref.watch(viewerIdProvider);
    if (viewerId == null) return null;

    final tag = (userId: viewerId, ofAnime: true);
    final collectionAsync = ref.watch(collectionProvider(tag));
    final collection = collectionAsync.asData?.value;
    if (collection == null) return null;

    bool aliasMatches(Entry e) {
      final item = widget.item;
      if (item == null) return false;

      final byMal = (item.malId != 0 && e.malId != 0 && item.malId == e.malId);
      return byMal;
    }

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

  Future<void> _openPlayer(
    AniRelease release,
    int ordinal,
    Entry? item,
    bool sync,
    AnimeVoice animeVoice,
    bool startWithProxy,
  ) async {
    final ep = release.episodes.firstWhere((e) => e.ordinal == ordinal);
    await Navigator.of(context).push(
      NoSwipeBackMaterialPageRoute(
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

    // Refresh progress when returning from player.
    if (!mounted) return;
    if (sync) {
      final viewerId = ref.read(viewerIdProvider);
      if (viewerId != null) {
        ref.invalidate(collectionProvider((userId: viewerId, ofAnime: true)));
      }
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final rel = _release;
    final entry = _findMatchingEntry(ref);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Watch'),
        actions: [
          IconButton(
            icon: const Icon(Ionicons.refresh),
            tooltip: 'Reload',
            onPressed: _load,
          ),
          // Support button removed with site-specific sources
          const SizedBox(
              width:
                  8), // Add a small right inset so actions aren't flush to the edge
        ],
      ),
      body: switch (rel) {
        AsyncData(:final value) => _Body(
            release: value,
            entry: entry,
            onPlay: (e) => unawaited(
              _openPlayer(
                value,
                e.ordinal,
                entry,
                widget.sync,
                widget.animeVoice,
                widget.startWithProxy,
              ),
            ),
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
              entry: entry,
              onPressed: () {
                final i = _resolveInitialOrdinal(
                  release: rel.value,
                  entry: entry,
                );
                unawaited(
                  _openPlayer(
                    rel.value,
                    i,
                    entry,
                    widget.sync,
                    widget.animeVoice,
                    widget.startWithProxy,
                  ),
                );
              },
            )
          : null,
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
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
    final next =
        entry == null ? 1 : (entry!.progress <= 0 ? 1 : entry!.progress + 1);
    final max = release.episodes.isEmpty ? next : release.episodes.last.ordinal;
    final clamped = next.clamp(1, max);
    final labelPrefix = (entry?.progress ?? 0) > 0 ? 'Continue' : 'Watch';

    return FloatingActionButton.extended(
      onPressed: onPressed,
      icon: const Icon(Ionicons.play),
      label: Text('$labelPrefix • Ep $clamped'),
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
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w600),
            ),
          ),
        ),
      ),
    );
  }
}
