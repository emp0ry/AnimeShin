import 'package:animeshin/feature/player/player_page.dart';
import 'package:animeshin/feature/watch/watch_types.dart';
import 'package:animeshin/util/module_loader/js_module_executor.dart';
import 'package:animeshin/util/module_loader/js_sources_runtime.dart';
import 'package:animeshin/util/module_loader/sources_module.dart';
import 'package:animeshin/util/graphql.dart';
import 'package:animeshin/util/theming.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:ui';

import '../collection/collection_models.dart';
import '../viewer/repository_provider.dart';

class ModuleWatchPage extends ConsumerStatefulWidget {
  const ModuleWatchPage({
    super.key,
    required this.module,
    required this.title,
    required this.href,
    required this.item,
  });

  final SourcesModuleDescriptor module;
  final String title;
  final String href;
  final Entry? item;

  @override
  ConsumerState<ModuleWatchPage> createState() => _ModuleWatchPageState();
}

class _ModuleWatchPageState extends ConsumerState<ModuleWatchPage> {
  final JsModuleExecutor _exec = JsModuleExecutor();
  late Future<List<JsModuleEpisode>> _episodesFuture;
  List<JsModuleEpisode>? _episodesCache;

  Map<int, String>? _anilistThumbs;

  static int? _parseEpisodeNumberFromTitle(String title) {
    final t = title.trim();
    if (t.isEmpty) return null;

    final epMatch =
        RegExp(r'\b(?:episode|ep)\s*(\d{1,4})\b', caseSensitive: false)
            .firstMatch(t);
    if (epMatch != null) {
      return int.tryParse(epMatch.group(1) ?? '');
    }

    // Fallback: first number anywhere (best-effort).
    final any = RegExp(r'(\d{1,4})').firstMatch(t);
    if (any != null) {
      return int.tryParse(any.group(1) ?? '');
    }
    return null;
  }

  Future<Map<int, String>> _fetchAniListEpisodeThumbnails(int mediaId) async {
    final data = await ref.read(repositoryProvider).request(
      GqlQuery.mediaStreamingEpisodes,
      {'id': mediaId},
    );

    final eps = data['Media']?['streamingEpisodes'];
    if (eps is! List) return const <int, String>{};

    final out = <int, String>{};
    for (final raw in eps) {
      if (raw is! Map) continue;
      final title = (raw['title'] ?? '').toString().trim();
      final thumb = (raw['thumbnail'] ?? '').toString().trim();
      if (thumb.isEmpty) continue;
      final n = _parseEpisodeNumberFromTitle(title);
      if (n == null || n <= 0) continue;
      out.putIfAbsent(n, () => thumb);
    }
    return out;
  }

  static String? _moduleImageReferer(SourcesModuleDescriptor module) {
    // Universal referer: use module baseUrl origin when available.
    final raw = (module.meta?['baseUrl'] ?? '').toString().trim();
    if (raw.isEmpty) return null;
    final uri = Uri.tryParse(raw);
    if (uri == null) return null;
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    return '${uri.origin}/';
  }

  static bool _isQualityLabel(String? raw) {
    final t = (raw ?? '').trim().toLowerCase();
    if (t.isEmpty) return false;
    if (RegExp(r'^\d{3,4}p$').hasMatch(t)) return true;
    return RegExp(r'\b(2160|1440|1080|720|480|360)\s*p\b').hasMatch(t) ||
        RegExp(r'\b(2160|1440|1080|720|480|360)p\b').hasMatch(t);
  }

  static int _uniqueHostsCount(Iterable<JsStreamCandidate> streams) {
    final hosts = <String>{};
    for (final s in streams) {
      final raw = s.streamUrl.trim();
      if (raw.isEmpty) continue;
      final norm = raw.startsWith('//') ? 'https:$raw' : raw;
      final uri = Uri.tryParse(norm);
      final host = uri?.host.trim().toLowerCase();
      if (host != null && host.isNotEmpty) hosts.add(host);
    }
    return hosts.length;
  }

  bool get _modulePrefersVoiceoverPicker {
    final meta = widget.module.meta;
    if (meta == null) return false;

    bool asBool(Object? v) {
      if (v is bool) return v;
      final s = (v ?? '').toString().trim().toLowerCase();
      return s == 'true' || s == '1' || s == 'yes';
    }

    // Sora convention: softsub sources typically expose SUB/DUB or similar "voiceover"
    // choices in extractStreamUrl output.
    if (asBool(meta['softsub'])) return true;

    final lang = (meta['language'] ?? '').toString().toLowerCase();
    // Light hint only; not tied to any provider name.
    if (lang.contains('dub') || lang.contains('sub')) return true;

    return false;
  }

  static int? _qualityFromTitleOrUrl(String title, String url) {
    final t = title.toLowerCase();
    final u = url.toLowerCase();
    for (final q in <int>[2160, 1440, 1080, 720, 480, 360]) {
      if (RegExp(r'\b' + q.toString() + r'\s*p\b').hasMatch(t) ||
          RegExp(r'\b' + q.toString() + r'p\b').hasMatch(t) ||
          RegExp(r'\b' + q.toString() + r'\s*p\b').hasMatch(u) ||
          RegExp(r'\b' + q.toString() + r'p\b').hasMatch(u)) {
        return q;
      }
    }
    return null;
  }

  int _voiceoverInitAttempts = 0;
  bool _voiceoverInitDone = false;
  bool _voiceoverDialogOpen = false;
  List<String> _voiceoverTitles = const <String>[];
  String? _preferredVoiceoverTitle;

  bool _serverDialogOpen = false;
  String? _preferredServerTitle;
  List<String> _serverTitles = const <String>[];

  Future<void> _showModuleDebug() async {
    final rt = JsSourcesRuntime.instance;
    String? lastFetch;
    String? logs;
    try {
      lastFetch = await rt.getLastFetchDebugJson(widget.module.id);
    } catch (_) {
      lastFetch = null;
    }
    try {
      logs = await rt.getLogsJson(widget.module.id);
    } catch (_) {
      logs = null;
    }

    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Module debug'),
          content: SingleChildScrollView(
            child: SelectableText(
              [
                'Module: ${widget.module.id}',
                if (lastFetch != null) '\nLast fetch:\n$lastFetch',
                if (logs != null) '\nLogs:\n$logs',
              ].join('\n'),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  @override
  void initState() {
    super.initState();
    _episodesFuture = _exec.extractEpisodes(widget.module.id, widget.href);

    final mediaId = widget.item?.mediaId;
    if (mediaId != null && mediaId > 0) {
      _fetchAniListEpisodeThumbnails(mediaId).then((m) {
        if (!mounted) return;
        setState(() => _anilistThumbs = m);
      }).catchError((_) {
        // Ignore; fallback to module episode images.
      });
    }

    // Kick off voiceover detection once episodes are available.
    _episodesFuture.then((eps) async {
      if (!mounted) return;
      _episodesCache = eps;
      await _maybeInitVoiceovers(eps);
      await _maybeInitServers(eps);
      setState(() {});
    });
  }

  Future<void> _maybeInitServers(List<JsModuleEpisode> eps) async {
    if (!mounted) return;
    if (eps.isEmpty) return;

    // If this source is voiceover-first, don't pre-fill server list from stream titles.
    if (_modulePrefersVoiceoverPicker) return;

    try {
      final selection = await _exec.extractStreams(
        widget.module.id,
        eps.first.href,
        voiceover: _preferredVoiceoverTitle,
      );
      final titles = selection.streams
          .map((s) => s.title.trim())
          .where((t) => t.isNotEmpty)
          .where((t) => !_isQualityLabel(t))
          .toList(growable: false);

      final unique = <String>[];
      final seen = <String>{};
      for (final t in titles) {
        final k = t.toLowerCase();
        if (seen.add(k)) unique.add(t);
      }

      // Generic heuristic: if all URLs are from the same host, treat it as voiceovers/options,
      // not servers.
      final nonQuality = selection.streams.where((s) => !_isQualityLabel(s.title));
      final uniqueHosts = _uniqueHostsCount(nonQuality);
      if (uniqueHosts <= 1) {
        unique.clear();
      }

      if (!mounted) return;
      setState(() => _serverTitles = unique);
    } catch (_) {
      // Ignore; server picker is optional.
    }
  }

  Future<void> _maybeInitVoiceovers(List<JsModuleEpisode> eps) async {
    if (_voiceoverInitDone) return;
    if (_voiceoverInitAttempts >= 2) {
      _voiceoverInitDone = true;
      return;
    }
    _voiceoverInitAttempts += 1;

    if (eps.isEmpty) return;

    try {
      // 1) Prefer explicit hook.
      var list = await _exec.getVoiceovers(widget.module.id, eps.first.href);

      // Never treat qualities as voiceovers.
      list = list.where((t) => !_isQualityLabel(t)).toList(growable: false);

      final normalized = list
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toSet()
          .toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

      if (!mounted) return;
      setState(() => _voiceoverTitles = normalized);

      if (normalized.length >= 2 && _preferredVoiceoverTitle == null) {
        await _pickVoiceover(showAuto: true);
      }

      _voiceoverInitDone = true;
    } catch (_) {
      // Allow a retry on next frame; do not mark done.

      // 2) If module doesn't expose getVoiceovers:
      // - for voiceover-first modules, treat stream titles as voiceovers directly.
      // - otherwise, try a conservative host-based inference.
      try {
        final selection = await _exec.extractStreams(widget.module.id, eps.first.href);
        final nonQuality = selection.streams
            .where((s) => !_isQualityLabel(s.title))
            .toList(growable: false);
        final titles = nonQuality
            .map((s) => s.title.trim())
            .where((t) => t.isNotEmpty)
            .toList(growable: false);

        final unique = <String>[];
        final seen = <String>{};
        for (final t in titles) {
          final k = t.toLowerCase();
          if (seen.add(k)) unique.add(t);
        }

        final inferred = _modulePrefersVoiceoverPicker ||
            (unique.length >= 2 && _uniqueHostsCount(nonQuality) <= 1);
        if (inferred) {
          unique.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
          if (!mounted) return;
          setState(() => _voiceoverTitles = unique);
          if (unique.length >= 2 && _preferredVoiceoverTitle == null) {
            await _pickVoiceover(showAuto: true);
          }
          _voiceoverInitDone = true;
          return;
        }
      } catch (_) {
        // Ignore; allow a retry on next frame.
      }
    }
  }

  Future<void> _pickVoiceover({required bool showAuto}) async {
    if (!mounted) return;
    if (_voiceoverTitles.length < 2) return;
    if (_voiceoverDialogOpen) return;
    _voiceoverDialogOpen = true;

    final picked = await showDialog<String?>(
      context: context,
      builder: (ctx) {
        return SimpleDialog(
          title: const Text('Choose voiceover'),
          children: [
            if (showAuto)
              SimpleDialogOption(
                onPressed: () => Navigator.of(ctx).pop(null),
                child: const Text('Auto'),
              ),
            for (final t in _voiceoverTitles)
              SimpleDialogOption(
                onPressed: () => Navigator.of(ctx).pop(t),
                child: Text(t),
              ),
          ],
        );
      },
    );

    _voiceoverDialogOpen = false;

    if (!mounted) return;
    setState(() {
      _preferredVoiceoverTitle = picked;
      // Voiceover choice can change available servers.
      _preferredServerTitle = null;
      _serverTitles = const <String>[];
    });

    final eps = _episodesCache;
    if (eps != null && eps.isNotEmpty) {
      await _maybeInitServers(eps);
    }
  }

  Future<void> _pickServer(List<String> serverTitles) async {
    if (!mounted) return;
    if (serverTitles.length < 2) return;
    if (_serverDialogOpen) return;
    _serverDialogOpen = true;

    final picked = await showDialog<String?>(
      context: context,
      builder: (ctx) {
        return SimpleDialog(
          title: const Text('Choose server'),
          children: [
            SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop(null),
              child: const Text('Auto'),
            ),
            for (final t in serverTitles)
              SimpleDialogOption(
                onPressed: () => Navigator.of(ctx).pop(t),
                child: Text(t),
              ),
          ],
        );
      },
    );

    _serverDialogOpen = false;
    if (!mounted) return;
    setState(() => _preferredServerTitle = picked);
  }

  Future<void> _openEpisode(JsModuleEpisode ep) async {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Loading stream...')),
    );

    JsStreamSelection selection;
    try {
      selection = await _exec.extractStreams(
        widget.module.id,
        ep.href,
        voiceover: _preferredVoiceoverTitle,
      );
    } catch (_) {
      selection = const JsStreamSelection(streams: <JsStreamCandidate>[]);
    }

    if (!mounted) return;

    if (selection.streams.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not resolve stream URL')),
      );
      return;
    }

    final allQuality = selection.streams.every((s) => _isQualityLabel(s.title));

    String? url480;
    String? url720;
    String? url1080;
    Map<String, String>? headers;
    String? subtitleUrl = selection.subtitleUrl;
    String? bannerTitle;

    if (allQuality) {
      for (final s in selection.streams) {
        final rawUrl = s.streamUrl.trim();
        if (rawUrl.isEmpty) continue;
        final normUrl = rawUrl.startsWith('//') ? 'https:$rawUrl' : rawUrl;
        final q = _qualityFromTitleOrUrl(s.title, normUrl);
        if (q == 480) url480 = normUrl;
        if (q == 720) url720 = normUrl;
        if (q == 1080) url1080 = normUrl;
        headers ??= s.headers;
        subtitleUrl ??= s.subtitleUrl;
      }

      // Fallback: pick first available if titles weren't parseable.
      if (url1080 == null && url720 == null && url480 == null) {
        final first = selection.streams.first;
        final rawUrl = first.streamUrl.trim();
        url1080 = rawUrl.startsWith('//') ? 'https:$rawUrl' : rawUrl;
        headers ??= first.headers;
        subtitleUrl ??= first.subtitleUrl;
      }
    } else {
      // Non-quality mode: either voiceover choices or server choices.
      final titles = selection.streams
          .map((s) => s.title.trim())
          .where((t) => t.isNotEmpty)
          .toList(growable: false);

      final uniqueTitles = <String>[];
      final seen = <String>{};
      for (final t in titles) {
        final k = t.toLowerCase();
        if (seen.add(k)) uniqueTitles.add(t);
      }

      final nonQuality = selection.streams.where((s) => !_isQualityLabel(s.title));

        // Prefer explicit voiceover list when available; otherwise:
        // - if module meta indicates voiceover-first, treat titles as voiceovers
        // - else, infer based on host.
        final looksLikeVoiceovers = _voiceoverTitles.length >= 2 ||
          (_modulePrefersVoiceoverPicker && uniqueTitles.length >= 2) ||
          (uniqueTitles.length >= 2 && _uniqueHostsCount(nonQuality) <= 1);

      if (looksLikeVoiceovers) {
        if (_voiceoverTitles.length < 2 && uniqueTitles.length >= 2) {
          setState(() => _voiceoverTitles = uniqueTitles);
        }
        if (_preferredVoiceoverTitle == null && uniqueTitles.length >= 2) {
          await _pickVoiceover(showAuto: true);
        }

        // Some modules need the voiceover passed into extractStreamUrl; refetch after pick.
        if (!mounted) return;
        if (_preferredVoiceoverTitle != null) {
          try {
            selection = await _exec.extractStreams(
              widget.module.id,
              ep.href,
              voiceover: _preferredVoiceoverTitle,
            );
          } catch (_) {
            // Keep existing selection.
          }
        }
      } else {
        if (uniqueTitles.length >= 2 && _preferredServerTitle == null) {
          await _pickServer(uniqueTitles);
        }
      }

      if (!mounted) return;

      // Pick a single stream by preferred title.
      JsStreamCandidate picked = selection.streams.first;
      final want = looksLikeVoiceovers
          ? _preferredVoiceoverTitle?.trim()
          : _preferredServerTitle?.trim();
      if (want != null && want.isNotEmpty) {
        final w = want.toLowerCase();
        for (final s in selection.streams) {
          final t = s.title.trim().toLowerCase();
          if (t == w || t.contains(w) || w.contains(t)) {
            picked = s;
            break;
          }
        }
      }

      final rawUrl = picked.streamUrl.trim();
      url1080 = rawUrl.startsWith('//') ? 'https:$rawUrl' : rawUrl;

      // If module provided per-quality URLs for this voiceover, pass them through.
      String? norm(String? u) {
        final s = u?.trim();
        if (s == null || s.isEmpty) return null;
        return s.startsWith('//') ? 'https:$s' : s;
      }

      url480 = norm(picked.url480) ?? url480;
      url720 = norm(picked.url720) ?? url720;
      url1080 = norm(picked.url1080) ?? url1080;

      headers = picked.headers;
      subtitleUrl ??= picked.subtitleUrl;
      bannerTitle = picked.title;
    }

    if (!mounted) return;

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerPage(
          args: PlayerArgs(
            id: 0,
            url: widget.href,
            ordinal: ep.number,
            title: '${widget.title} • Ep ${ep.number}',
            moduleId: widget.module.id,
            preferredStreamTitle: _preferredServerTitle,
            subtitleUrl: subtitleUrl,
            url480: url480,
            url720: url720,
            url1080: url1080,
            duration: ep.durationSeconds,
            openingStart: ep.openingStart,
            openingEnd: ep.openingEnd,
            endingStart: ep.endingStart,
            endingEnd: ep.endingEnd,
            httpHeaders: headers,
          ),
          item: widget.item,
          sync: widget.item != null,
          animeVoice: AnimeVoice.modules,
          startupBannerText: bannerTitle,
          startWithProxy: false,
        ),
      ),
    );

    // Rebuild to reflect updated progress after returning.
    if (!mounted) return;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final continued = widget.item?.progress ?? 0;
    final eps = _episodesCache;
    final moduleReferer = _moduleImageReferer(widget.module);

    int? continueEp;
    if (eps != null && eps.isNotEmpty) {
      final max = eps.map((e) => e.number).reduce((a, b) => a > b ? a : b);
      final next = (continued <= 0) ? 1 : (continued + 1);
      continueEp = next.clamp(1, max);
    }

    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.module.name}: ${widget.title}'),
        actions: [
          if (_serverTitles.length >= 2)
            IconButton(
              tooltip: 'Server',
              onPressed: () => _pickServer(_serverTitles),
              icon: const Icon(Icons.cloud_outlined),
            ),
          if (_voiceoverTitles.length >= 2)
            IconButton(
              tooltip: 'Voiceover',
              onPressed: () => _pickVoiceover(showAuto: true),
              icon: const Icon(Icons.record_voice_over_outlined),
            ),
          IconButton(
            tooltip: 'Debug module',
            onPressed: _showModuleDebug,
            icon: const Icon(Icons.bug_report_outlined),
          ),
        ],
      ),
      body: FutureBuilder<List<JsModuleEpisode>>(
        future: _episodesFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError) {
            final msg = snapshot.error.toString();
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  msg,
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          final eps = snapshot.data ?? const <JsModuleEpisode>[];
          if (eps.isEmpty) {
            return const Center(child: Text('No episodes found'));
          }

          return ListView.separated(
            padding: const EdgeInsets.all(Theming.offset),
            itemCount: eps.length,
            separatorBuilder: (_, __) => const SizedBox(height: Theming.offset),
            itemBuilder: (context, i) {
              final ep = eps[i];

              final anilistThumb = _anilistThumbs?[ep.number];

              final watched = ep.number <= continued;
              final isContinue = ep.number == continued + 1;

              return _ModuleEpisodeTile(
                episode: ep,
                overrideImageUrl: anilistThumb,
                watched: watched,
                isContinue: isContinue,
                imageReferer: moduleReferer,
                onPlay: () => _openEpisode(ep),
              );
            },
          );
        },
      ),
      floatingActionButton: continueEp == null
          ? null
          : FloatingActionButton.extended(
              onPressed: () {
                final list = _episodesCache;
                if (list == null) return;
                final target = continueEp!;
                final ep = list.firstWhere(
                  (e) => e.number == target,
                  orElse: () => list.first,
                );
                _openEpisode(ep);
              },
              icon: const Icon(Icons.play_arrow),
              label: Text(
                (continued > 0)
                    ? 'Continue • Ep $continueEp'
                    : 'Watch • Ep $continueEp',
              ),
            ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
    );
  }
}

class _ModuleEpisodeTile extends StatelessWidget {
  const _ModuleEpisodeTile({
    required this.episode,
    required this.overrideImageUrl,
    required this.watched,
    required this.isContinue,
    required this.imageReferer,
    required this.onPlay,
  });

  final JsModuleEpisode episode;
  final String? overrideImageUrl;
  final bool watched;
  final bool isContinue;
  final String? imageReferer;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).colorScheme.surfaceContainerHighest;
    final header = 'Episode ${episode.number}';
    final subtitle = episode.title.trim();
    final showSubtitle =
        subtitle.isNotEmpty && subtitle.toLowerCase() != header.toLowerCase();

    final imageUrl = (overrideImageUrl ?? episode.image).trim();
    final uri = imageUrl.isEmpty ? null : Uri.tryParse(imageUrl);
    final String? referer =
        (imageReferer != null && imageReferer!.trim().isNotEmpty)
            ? imageReferer!.trim()
            : (uri != null && (uri.scheme == 'http' || uri.scheme == 'https'))
                ? '${uri.origin}/'
                : null;

    final String? effectiveReferer = (referer != null && uri != null)
        ? (Uri.tryParse(referer)?.origin == uri.origin
            ? referer
            : '${uri.origin}/')
        : referer;

    final imageHeaders =
        (uri != null && (uri.scheme == 'http' || uri.scheme == 'https'))
            ? <String, String>{
                if (effectiveReferer != null) 'Referer': effectiveReferer,
                'User-Agent':
                    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36',
              }
            : null;

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
                    if (imageUrl.isNotEmpty)
                      Image.network(
                        imageUrl,
                        fit: BoxFit.cover,
                        headers: imageHeaders,
                      ),
                    if (watched || isContinue)
                      _WatchedBadge(isContinue: isContinue),
                  ],
                ),
              ),
              Expanded(
                child: Padding(
                  padding: Theming.paddingAll,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.max,
                    children: [
                      Text(
                        header,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextTheme.of(context).titleMedium,
                      ),
                      if (showSubtitle) ...[
                        const SizedBox(height: 4),
                        Text(
                          subtitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextTheme.of(context).bodySmall,
                        ),
                      ],
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
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
