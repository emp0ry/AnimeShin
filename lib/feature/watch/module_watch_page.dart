import 'package:animeshin/feature/player/player_page.dart';
import 'package:animeshin/feature/watch/watch_types.dart';
import 'package:animeshin/util/module_loader/js_module_executor.dart';
import 'package:animeshin/util/module_loader/js_sources_runtime.dart';
import 'package:animeshin/util/module_loader/sources_module.dart';
import 'package:animeshin/util/graphql.dart';
import 'package:animeshin/util/theming.dart';
import 'package:animeshin/feature/settings/settings_provider.dart';
import 'package:animeshin/feature/settings/settings_model.dart';
import 'package:animeshin/widget/cached_image.dart';
import 'package:animeshin/feature/collection/collection_entries_provider.dart';
import 'package:animeshin/feature/viewer/persistence_provider.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:async';
import 'dart:ui';
import 'dart:convert';

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
  JsStreamSelection? _firstEpisodeSelection;
  Future<JsStreamSelection>? _firstEpisodeSelectionFuture;
  String? _firstEpisodeHref;
  String? _firstEpisodeVoiceover;
  String? _firstEpisodeFutureHref;
  String? _firstEpisodeFutureVoiceover;
  JsStreamSelection? _lastOpenedSelection;

  Map<int, String>? _anilistThumbs;
  Map<int, String>? _anilistEpisodeTitles;
  Map<int, String>? _aniZipEpisodeImages;
  Map<int, String>? _aniZipEpisodeTitles;
  String? _lastFetchOrigin;
  String? _fallbackSearchTitle;
  int? _anilistMediaId;

  Entry? _watchEntry() {
    final base = widget.item;
    if (base == null) return null;
    final viewerId = ref.watch(viewerIdProvider);
    if (viewerId == null || viewerId == 0) return base;
    final tag = (userId: viewerId, ofAnime: true);
    return ref.watch(
          collectionEntryProvider((tag: tag, mediaId: base.mediaId)),
        ) ??
        base;
  }

  Entry? _readEntry() {
    final base = widget.item;
    if (base == null) return null;
    final viewerId = ref.read(viewerIdProvider);
    if (viewerId == null || viewerId == 0) return base;
    final tag = (userId: viewerId, ofAnime: true);
    return ref.read(
          collectionEntryProvider((tag: tag, mediaId: base.mediaId)),
        ) ??
        base;
  }

  JsStreamSelection? _tryCachedSelection(
    JsModuleEpisode ep, {
    String? voiceover,
  }) {
    final cached = _firstEpisodeSelection;
    if (cached == null) return null;
    if (_firstEpisodeHref != ep.href) return null;
    final want = (voiceover ?? '').trim();
    final have = (_firstEpisodeVoiceover ?? '').trim();
    if (want != have) return null;
    return cached;
  }

  void _cacheSelection(
    JsModuleEpisode ep,
    JsStreamSelection selection, {
    String? voiceover,
  }) {
    _firstEpisodeSelection = selection;
    _firstEpisodeHref = ep.href;
    _firstEpisodeVoiceover = voiceover?.trim();
  }

  List<String> _serverTitlesFromSelection(JsStreamSelection selection) {
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

    final nonQuality = selection.streams.where((s) => !_isQualityLabel(s.title));
    final uniqueHosts = _uniqueHostsCount(nonQuality);
    if (uniqueHosts <= 1) {
      unique.clear();
    }

    return unique;
  }

  Future<void> _openServerPicker() async {
    if (_serverDialogOpen) return;
    if (_serverTitles.length >= 2) {
      await _pickServer(_serverTitles);
      return;
    }
    final selection = _lastOpenedSelection;
    if (selection == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Open an episode to load servers')),
      );
      return;
    }
    final titles = _serverTitlesFromSelection(selection);
    if (!mounted) return;
    setState(() => _serverTitles = titles);
    if (titles.length >= 2) {
      await _pickServer(titles);
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Servers not available')),
    );
  }

  Future<JsStreamSelection>? _tryCachedSelectionFuture(
    JsModuleEpisode ep, {
    String? voiceover,
  }) {
    final cached = _firstEpisodeSelectionFuture;
    if (cached == null) return null;
    if (_firstEpisodeFutureHref != ep.href) return null;
    final want = (voiceover ?? '').trim();
    final have = (_firstEpisodeFutureVoiceover ?? '').trim();
    if (want != have) return null;
    return cached;
  }

  void _cacheSelectionFuture(
    JsModuleEpisode ep,
    Future<JsStreamSelection> future, {
    String? voiceover,
  }) {
    _firstEpisodeSelectionFuture = future;
    _firstEpisodeFutureHref = ep.href;
    _firstEpisodeFutureVoiceover = voiceover?.trim();
  }

  void _clearSelectionFuture() {
    _firstEpisodeSelectionFuture = null;
    _firstEpisodeFutureHref = null;
    _firstEpisodeFutureVoiceover = null;
  }

  Future<JsStreamSelection> _loadSelection(
    JsModuleEpisode ep, {
    String? voiceover,
  }) async {
    final cached = _tryCachedSelection(ep, voiceover: voiceover);
    if (cached != null) return cached;

    final inFlight = _tryCachedSelectionFuture(ep, voiceover: voiceover);
    if (inFlight != null) return inFlight;

    final future = _exec.extractStreams(
      widget.module.id,
      ep.href,
      voiceover: voiceover,
    );
    _cacheSelectionFuture(ep, future, voiceover: voiceover);
    try {
      final selection = await future;
      _cacheSelection(ep, selection, voiceover: voiceover);
      return selection;
    } finally {
      _clearSelectionFuture();
    }
  }

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
    final titles = <int, String>{};
    for (final raw in eps) {
      if (raw is! Map) continue;
      final title = (raw['title'] ?? '').toString().trim();
      final thumb = (raw['thumbnail'] ?? '').toString().trim();
      final n = _parseEpisodeNumberFromTitle(title);
      if (n == null || n <= 0) continue;
      if (thumb.isNotEmpty) {
        out.putIfAbsent(n, () => thumb);
      }
      if (title.isNotEmpty) {
        titles.putIfAbsent(n, () => title);
      }
    }
    _anilistEpisodeTitles = titles.isEmpty ? null : titles;
    return out;
  }

  Future<Map<int, String>> _fetchAniListEpisodeThumbnailsBySearch(
    String title,
  ) async {
    final variants = _buildAniListSearchVariants(title);
    if (variants.isEmpty) return const <int, String>{};

    for (final q in variants) {
      final data = await ref.read(repositoryProvider).request(
        GqlQuery.mediaPage,
        {
          'page': 1,
          'type': 'ANIME',
          'search': q,
          'sort': 'SEARCH_MATCH',
        },
      );

      final list = data['Page']?['media'];
      if (list is! List || list.isEmpty) continue;

      final first = list.first;
      if (first is! Map || first['id'] is! int) continue;

      final id = first['id'] as int;
      _anilistMediaId = id;
      return _fetchAniListEpisodeThumbnails(id);
    }

    return const <int, String>{};
  }

  Future<_AniZipEpisodeData?> _fetchAniZipEpisodeAssets(int mediaId) async {
    final uri = Uri.parse('https://api.ani.zip/mappings?anilist_id=$mediaId');
    final resp = await http.get(uri);
    if (resp.statusCode != 200) return null;

    final decoded = jsonDecode(resp.body);
    if (decoded is! Map) return null;

    final episodes = decoded['episodes'];
    if (episodes is! Map) return null;

    final images = <int, String>{};
    final titles = <int, String>{};

    for (final entry in episodes.entries) {
      final key = entry.key;
      if (key is! String) continue;
      final epNum = int.tryParse(key);
      if (epNum == null || epNum <= 0) continue;

      final value = entry.value;
      if (value is! Map) continue;

      final image = (value['image'] ?? '').toString().trim();
      if (image.isNotEmpty) {
        images.putIfAbsent(epNum, () => image);
      }

      final title = value['title'];
      if (title is Map) {
        final picked = _pickAniZipEpisodeTitle(title);
        if (picked != null && picked.isNotEmpty) {
          titles.putIfAbsent(epNum, () => picked);
        }
      }
    }

    if (images.isEmpty && titles.isEmpty) return null;
    return _AniZipEpisodeData(images: images, titles: titles);
  }

  String? _pickAniZipEpisodeTitle(Map raw) {
    String? val(String key) {
      final v = raw[key];
      if (v == null) return null;
      final s = v.toString().trim();
      return s.isEmpty ? null : s;
    }

    final settings = ref.read(settingsProvider).asData?.value;
    final pref = settings?.titleLanguage ?? TitleLanguage.romaji;

    String? preferred;
    switch (pref) {
      case TitleLanguage.english:
        preferred = val('en');
        break;
      case TitleLanguage.romaji:
        preferred = val('x-jat');
        break;
      case TitleLanguage.native:
        preferred = val('ja');
        break;
    }

    return preferred ?? val('en') ?? val('x-jat') ?? val('ja') ?? val('x-unk');
  }

  static List<String> _buildAniListSearchVariants(String title) {
    String normalize(String s) => s
        .replaceAll(RegExp(r'[\(\[\{].*?[\)\]\}]'), ' ')
        .replaceAll(RegExp(r'[:\-–—]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    String stripSeasonParts(String s) {
      var out = s;
      out = out.replaceAll(
        RegExp(
          r'\b(season|part|cour|arc|chapter|series)\b\s*\d+\b',
          caseSensitive: false,
        ),
        ' ',
      );
      out = out.replaceAll(
        RegExp(
          r'\b(season|part|cour|arc|chapter|series)\b\s*[ivx]+\b',
          caseSensitive: false,
        ),
        ' ',
      );
      out = out.replaceAll(
        RegExp(r'\b(\d+)(st|nd|rd|th)\b', caseSensitive: false),
        ' ',
      );
      out = out.replaceAll(
        RegExp(r'\b(i|ii|iii|iv|v|vi|vii|viii|ix|x)\b', caseSensitive: false),
        ' ',
      );
      out = out.replaceAll(RegExp(r'\s+'), ' ').trim();
      return out;
    }

    final raw = title.trim();
    if (raw.isEmpty) return const <String>[];

    final normalized = normalize(raw);
    final stripped = stripSeasonParts(normalized);

    final variants = <String>[raw, normalized, stripped]
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();

    final unique = <String>[];
    final seen = <String>{};
    for (final v in variants) {
      final key = v.toLowerCase();
      if (seen.add(key)) unique.add(v);
    }

    return unique;
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

  static String? _originFromReferer(String? referer) {
    final raw = (referer ?? '').trim();
    if (raw.isEmpty) return null;
    final uri = Uri.tryParse(raw);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return null;
    }
    return uri.origin;
  }

  static String _resolveImageUrl(
    String raw, {
    String? baseOrigin,
    String? imageReferer,
  }) {
    final t = raw.trim();
    if (t.isEmpty) return '';
    if (t.startsWith('//')) return 'https:$t';

    final hasScheme = Uri.tryParse(t)?.hasScheme ?? false;
    if (hasScheme) return t;

    final origin = baseOrigin ?? _originFromReferer(imageReferer);
    if (origin == null || origin.isEmpty) return t;

    if (t.startsWith('/')) return '$origin$t';
    return '$origin/$t';
  }

  String _preferredSearchTitle() {
    final entry = widget.item;
    if (entry == null) return widget.title;

    String? pick(TitleLanguage lang) => switch (lang) {
          TitleLanguage.english => entry.titleEnglish,
          TitleLanguage.romaji => entry.titleRomaji,
          TitleLanguage.native => entry.titleNative,
        };

    final settings = ref.read(settingsProvider).asData?.value;
    final preferred = pick(settings?.titleLanguage ?? TitleLanguage.romaji)
      ?.trim();
    if (preferred != null && preferred.isNotEmpty) return preferred;

    final romaji = entry.titleRomaji?.trim();
    if (romaji != null && romaji.isNotEmpty) return romaji;

    final native = entry.titleNative?.trim();
    if (native != null && native.isNotEmpty) return native;

    final english = entry.titleEnglish?.trim();
    if (english != null && english.isNotEmpty) return english;

    final fallback = _fallbackSearchTitle?.trim();
    if (fallback != null && fallback.isNotEmpty) return fallback;

    return widget.title;
  }

  String? _pickTitleFromMedia(Map media) {
    final title = media['title'];
    if (title is! Map) return null;

    final settings = ref.read(settingsProvider).asData?.value;
    final pref = settings?.titleLanguage ?? TitleLanguage.romaji;

    String? val(String key) => (title[key] ?? '').toString().trim();

    String? pick() => switch (pref) {
          TitleLanguage.english => val('english'),
          TitleLanguage.romaji => val('romaji'),
          TitleLanguage.native => val('native'),
        };

    final preferred = pick();
    if (preferred != null && preferred.isNotEmpty) return preferred;

    final romaji = val('romaji');
    if (romaji != null && romaji.isNotEmpty) return romaji;

    final native = val('native');
    if (native != null && native.isNotEmpty) return native;

    final english = val('english');
    if (english != null && english.isNotEmpty) return english;

    return null;
  }

  static bool _isQualityLabel(String? raw) {
    final t = (raw ?? '').trim().toLowerCase();
    if (t.isEmpty) return false;
    return RegExp(r'^\s*(2160|1440|1080|720|480|360)\s*p\s*$').hasMatch(t) ||
      RegExp(r'^\s*(2160|1440|1080|720|480|360)p\s*$').hasMatch(t);
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

  static String _stripVoiceoverTitle(String raw) {
    var out = raw.trim();
    if (out.isEmpty) return out;
    if (out.contains('|')) {
      final parts = out.split('|').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      if (parts.isNotEmpty) {
        out = parts.first;
      }
    }
    out = out.replaceAll(RegExp(r'\s*\([^)]*\)'), ' ');
    out = out.replaceAll(RegExp(r'\s*\[[^\]]*\]'), ' ');
    out = out.replaceAll(RegExp(r'\b(2160|1440|1080|720|480|360)\s*p\b', caseSensitive: false), ' ');
    out = out.replaceAll(RegExp(r'\s+'), ' ').trim();
    return out;
  }

  static List<String> _buildVoiceoverCandidates(
    Iterable<JsStreamCandidate> streams,
  ) {
    final out = <String>[];
    final seen = <String>{};
    for (final s in streams) {
      final raw = s.title.trim();
      if (raw.isEmpty) continue;
      if (_isQualityLabel(raw)) continue;
      final base = _stripVoiceoverTitle(raw).toLowerCase();
      if (base.isEmpty) continue;
      if (seen.add(base)) {
        out.add(raw);
      }
    }
    return out;
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
    String? parsedLastFetchOrigin;
    try {
      lastFetch = await rt.getLastFetchDebugJson(widget.module.id);
    } catch (_) {
      lastFetch = null;
    }
    if (lastFetch != null && lastFetch.isNotEmpty) {
      try {
        final parsed = jsonDecode(lastFetch);
        if (parsed is Map && parsed['url'] is String) {
          final uri = Uri.tryParse(parsed['url'] as String);
          final origin = uri?.origin;
          if (origin != null && origin.isNotEmpty) {
            parsedLastFetchOrigin = origin;
          }
        }
      } catch (_) {
        // Ignore parse errors; debug info is best-effort.
      }
    }
    try {
      logs = await rt.getLogsJson(widget.module.id);
    } catch (_) {
      logs = null;
    }

    final moduleReferer = _moduleImageReferer(widget.module);
    final effectiveLastFetchOrigin =
      parsedLastFetchOrigin ?? _lastFetchOrigin;
    final baseOrigin =
      effectiveLastFetchOrigin ?? _originFromReferer(moduleReferer);

    final eps = _episodesCache ?? const <JsModuleEpisode>[];
    final debugEps = eps.take(6).toList(growable: false);
    final previewLines = <String>[];
    for (final ep in debugEps) {
      final epTitle = ep.title.trim();
      final raw = (ep.image).trim();
      final resolved = _resolveImageUrl(
        raw,
        baseOrigin: baseOrigin,
        imageReferer: moduleReferer,
      );
      final anilist = _anilistThumbs?[ep.number];
      final resolvedAni = (anilist == null || anilist.trim().isEmpty)
          ? ''
          : _resolveImageUrl(
              anilist,
              baseOrigin: baseOrigin,
              imageReferer: moduleReferer,
            );
      final anilistTitle = _anilistEpisodeTitles?[ep.number]?.trim() ?? '';
      previewLines.add(
        'Ep ${ep.number}: title="$epTitle"'
            '${anilistTitle.isNotEmpty ? ' | anilistTitle="$anilistTitle"' : ''}'
            ' | raw="$raw" | resolved="$resolved"'
            '${anilist != null ? ' | anilist="$anilist" | anilistResolved="$resolvedAni"' : ''}',
      );
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
                'AniList id: ${_anilistMediaId ?? '(null)'}',
                'Image referer: ${moduleReferer ?? '(null)'}',
                'Last fetch origin: ${effectiveLastFetchOrigin ?? '(null)'}',
                if (lastFetch != null) '\nLast fetch:\n$lastFetch',
                if (previewLines.isNotEmpty)
                  '\nPreview images:\n${previewLines.join('\n')}',
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
    Stopwatch? episodesSw;
    String? episodesLabel;
    if (kDebugMode) {
      episodesLabel = 'extractEpisodes module=${widget.module.id}';
      debugPrint('[Perf] $episodesLabel start');
      episodesSw = Stopwatch()..start();
    }
    _episodesFuture = _exec.extractEpisodes(widget.module.id, widget.href);
    if (kDebugMode && episodesSw != null) {
      _episodesFuture.whenComplete(() {
        episodesSw!.stop();
        debugPrint('[Perf] $episodesLabel ${episodesSw.elapsedMilliseconds}ms');
      });
    }
    _loadLastFetchOrigin();

    final mediaId = widget.item?.mediaId;
    if (mediaId != null && mediaId > 0) {
      if (widget.title.trim().isEmpty) {
        ref.read(repositoryProvider)
            .request(GqlQuery.media, {'id': mediaId, 'withInfo': true})
            .then((data) {
          if (!mounted) return;
          final media = data['Media'];
          if (media is! Map) return;
          final title = _pickTitleFromMedia(media);
          if (title == null || title.trim().isEmpty) return;
          setState(() => _fallbackSearchTitle = title.trim());
        }).catchError((_) {
          // Ignore; fallback title is optional.
        });
      }

      _fetchAniListEpisodeThumbnails(mediaId).then((m) {
        if (!mounted) return;
        _anilistMediaId = mediaId;
        setState(() => _anilistThumbs = m);
      }).catchError((_) {
        // Ignore; fallback to module episode images.
      });

      _fetchAniZipEpisodeAssets(mediaId).then((data) {
        if (!mounted) return;
        if (data == null) return;
        setState(() {
          _aniZipEpisodeImages = data.images;
          _aniZipEpisodeTitles = data.titles;
        });
      }).catchError((_) {
        // Ignore; fallback to module/AniList episode images.
      });
    } else {
      final searchTitle = _preferredSearchTitle();
      _fetchAniListEpisodeThumbnailsBySearch(searchTitle).then((m) {
        if (!mounted) return;
        setState(() => _anilistThumbs = m);

        final id = _anilistMediaId;
        if (id == null || id <= 0) return;
        _fetchAniZipEpisodeAssets(id).then((data) {
          if (!mounted) return;
          if (data == null) return;
          setState(() {
            _aniZipEpisodeImages = data.images;
            _aniZipEpisodeTitles = data.titles;
          });
        }).catchError((_) {
          // Ignore; fallback to module/AniList episode images.
        });
      }).catchError((_) {
        // Ignore; fallback to module episode images.
      });
    }

    // Kick off voiceover detection once episodes are available.
    _episodesFuture.then((eps) async {
      if (!mounted) return;
      _episodesCache = eps;
      await _maybeInitVoiceovers(eps);
      setState(() {});
    });
  }

  Future<void> _loadLastFetchOrigin() async {
    final rt = JsSourcesRuntime.instance;
    try {
      final lastFetch = await rt.getLastFetchDebugJson(widget.module.id);
      if (lastFetch == null || lastFetch.isEmpty) return;
      final parsed = jsonDecode(lastFetch);
      if (parsed is! Map || parsed['url'] is! String) return;
      final uri = Uri.tryParse(parsed['url'] as String);
      final origin = uri?.origin;
      if (origin == null || origin.isEmpty) return;
      if (!mounted) return;
      setState(() => _lastFetchOrigin = origin);
    } catch (_) {
      // Best-effort; ignore.
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
    final firstEp = eps.first;

    debugPrint(
      '[VoiceoverDebug] init module=${widget.module.id} epHref=${firstEp.href}',
    );

    try {
      Stopwatch? probeSw;
      String? probeLabel;
      if (kDebugMode) {
        probeLabel = 'probeVoiceovers module=${widget.module.id}';
        debugPrint('[Perf] $probeLabel start');
        probeSw = Stopwatch()..start();
      }
      final probe = await _exec.probeVoiceovers(widget.module.id, firstEp.href);
      if (kDebugMode && probeSw != null) {
        probeSw.stop();
        debugPrint('[Perf] $probeLabel ${probeSw.elapsedMilliseconds}ms');
      }

      if (probe.prefetchedSelection != null) {
        _cacheSelection(firstEp, probe.prefetchedSelection!);
      }

      var list = probe.voiceoverTitles;
      debugPrint(
        '[VoiceoverDebug] probeVoiceovers raw module=${widget.module.id}: ${list.join(" | ")}',
      );

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

      debugPrint(
        '[VoiceoverDebug] probeVoiceovers normalized module=${widget.module.id}: ${normalized.join(" | ")}',
      );

      if (normalized.length >= 2 && _preferredVoiceoverTitle == null) {
        await _pickVoiceover(showAuto: true);
        _voiceoverInitDone = true;
        return;
      }

      if (normalized.isNotEmpty) {
        _voiceoverInitDone = true;
        return;
      }

      if (probe.prefetchedSelection != null) {
        _voiceoverInitDone = true;
      }
      return;
    } catch (_) {
      debugPrint(
        '[VoiceoverDebug] probeVoiceovers failed module=${widget.module.id}',
      );
      // Allow a retry on next frame; do not mark done.
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
    final entry = _readEntry();
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Loading stream...')),
    );

    JsStreamSelection selection;
    try {
      Stopwatch? streamsSw;
      String? streamsLabel;
      if (kDebugMode) {
        streamsLabel =
            'extractStreams module=${widget.module.id} stage=open_episode';
        debugPrint('[Perf] $streamsLabel start');
        streamsSw = Stopwatch()..start();
      }
      selection = await _loadSelection(
        ep,
        voiceover: _preferredVoiceoverTitle,
      );
      if (kDebugMode && streamsSw != null) {
        streamsSw.stop();
        debugPrint('[Perf] $streamsLabel ${streamsSw.elapsedMilliseconds}ms');
      }
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

    _lastOpenedSelection = selection;

    debugPrint(
      '[VoiceoverDebug] openEpisode selection.count module=${widget.module.id}: ${selection.streams.length}',
    );

    final rawTitles = selection.streams
        .map((s) => s.title.trim())
        .where((t) => t.isNotEmpty)
        .toSet()
        .toList();
    if (rawTitles.isNotEmpty) {
      debugPrint(
        '[VoiceoverDebug] openEpisode module=${widget.module.id} titles: ${rawTitles.join(" | ")}',
      );
    }

    final allQuality = selection.streams.every((s) => _isQualityLabel(s.title));

    String? url480;
    String? url720;
    String? url1080;
    Map<String, String>? headers;
    String? subtitleUrl = selection.subtitleUrl;
    String? bannerTitle;
    bool preferredIsVoiceover = false;
    String? preferredStreamTitle;

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
      final candidates = _buildVoiceoverCandidates(selection.streams);
      final looksLikeVoiceovers = _voiceoverTitles.length >= 2 ||
          candidates.length >= 2 ||
          (_modulePrefersVoiceoverPicker && candidates.isNotEmpty);
      preferredIsVoiceover = looksLikeVoiceovers;

      debugPrint(
        '[VoiceoverDebug] openEpisode module=${widget.module.id} candidates: ${candidates.join(" | ")}',
      );
      debugPrint(
        '[VoiceoverDebug] openEpisode module=${widget.module.id} looksLikeVoiceovers: $looksLikeVoiceovers',
      );

      if (looksLikeVoiceovers) {
        debugPrint(
          '[VoiceoverDebug] openEpisode voiceoverTitles.count module=${widget.module.id}: ${_voiceoverTitles.length}',
        );
        if (_voiceoverTitles.length < 2 && candidates.length >= 2) {
          setState(() => _voiceoverTitles = candidates);
          debugPrint(
            '[VoiceoverDebug] openEpisode setVoiceoverTitles module=${widget.module.id}: ${candidates.length}',
          );
        }
        if (_preferredVoiceoverTitle == null && candidates.length >= 2) {
          debugPrint(
            '[VoiceoverDebug] openEpisode prompting dialog (uniqueTitles) module=${widget.module.id}',
          );
          await _pickVoiceover(showAuto: true);
        } else if (_preferredVoiceoverTitle == null && _voiceoverTitles.length >= 2) {
          debugPrint(
            '[VoiceoverDebug] openEpisode prompting dialog (cached) module=${widget.module.id}',
          );
          await _pickVoiceover(showAuto: true);
        } else {
          debugPrint(
            '[VoiceoverDebug] openEpisode dialog skipped module=${widget.module.id} preferred=${_preferredVoiceoverTitle ?? "(null)"}',
          );
        }

        // Some modules need the voiceover passed into extractStreamUrl; refetch after pick.
        if (!mounted) return;
        if (_preferredVoiceoverTitle != null) {
          try {
            Stopwatch? refetchSw;
            String? refetchLabel;
            if (kDebugMode) {
              refetchLabel =
                  'extractStreams module=${widget.module.id} stage=open_episode_refetch';
              debugPrint('[Perf] $refetchLabel start');
              refetchSw = Stopwatch()..start();
            }
            selection = await _loadSelection(
              ep,
              voiceover: _preferredVoiceoverTitle,
            );
            if (kDebugMode && refetchSw != null) {
              refetchSw.stop();
              debugPrint('[Perf] $refetchLabel ${refetchSw.elapsedMilliseconds}ms');
            }
          } catch (_) {
            // Keep existing selection.
          }
        }
      } else {
        final uniqueServerTitles = _serverTitlesFromSelection(selection);
        if (mounted) {
          setState(() => _serverTitles = uniqueServerTitles);
        }
        if (uniqueServerTitles.length >= 2 && _preferredServerTitle == null) {
          debugPrint(
            '[VoiceoverDebug] openEpisode prompting server dialog module=${widget.module.id}',
          );
          await _pickServer(uniqueServerTitles);
        }
      }

      if (!mounted) return;

      preferredStreamTitle =
          looksLikeVoiceovers ? _preferredVoiceoverTitle : _preferredServerTitle;

      // Pick a single stream by preferred title.
      _lastOpenedSelection = selection;
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

    final moduleEpisodes = _episodesCache == null
        ? null
        : List<JsModuleEpisode>.unmodifiable(_episodesCache!);

    await Navigator.of(context).push(
      NoSwipeBackMaterialPageRoute(
        settings: const RouteSettings(name: 'player'),
        builder: (_) => PlayerPage(
          args: PlayerArgs(
            id: 0,
            url: widget.href,
            ordinal: ep.number,
            title: '${widget.title} • Ep ${ep.number}',
            moduleId: widget.module.id,
            moduleEpisodes: moduleEpisodes,
            preferredStreamTitle: preferredStreamTitle,
            preferredStreamIsVoiceover: preferredIsVoiceover,
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
          item: entry,
          sync: entry != null,
          animeVoice: AnimeVoice.modules,
          startupBannerText: bannerTitle,
          startWithProxy: true,
        ),
      ),
    );

    // Rebuild to reflect updated progress after returning.
    if (!mounted) return;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final entry = _watchEntry();
    final continued = entry?.progress ?? 0;
    final eps = _episodesCache;
    final moduleReferer = _moduleImageReferer(widget.module);
    final lastFetchOrigin = _lastFetchOrigin;

    int? continueEp;
    if (eps != null && eps.isNotEmpty) {
      final max = eps.map((e) => e.number).reduce((a, b) => a > b ? a : b);
      final next = (continued <= 0) ? 1 : (continued + 1);
      continueEp = next.clamp(1, max);
    }

    final lastSelection = _lastOpenedSelection;
    final canPickServer = lastSelection != null &&
        !_modulePrefersVoiceoverPicker &&
        _serverTitlesFromSelection(lastSelection).length >= 2;

    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.module.name}: ${widget.title}'),
        actions: [
          if (canPickServer)
            IconButton(
              tooltip: 'Server',
              onPressed: _openServerPicker,
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
          const SizedBox(width: 8),
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
              final anilistTitle = _anilistEpisodeTitles?[ep.number];
              final aniZipThumb = _aniZipEpisodeImages?[ep.number];
              final aniZipTitle = _aniZipEpisodeTitles?[ep.number];
              final resolvedFallbackTitle =
                  (anilistTitle != null && anilistTitle.trim().isNotEmpty)
                      ? anilistTitle
                      : aniZipTitle;

              final watched = ep.number <= continued;
              final isContinue = ep.number == continued + 1;

              return _ModuleEpisodeTile(
                episode: ep,
                overrideImageUrl: anilistThumb,
                fallbackImageUrl: aniZipThumb,
                fallbackTitle: resolvedFallbackTitle,
                watched: watched,
                isContinue: isContinue,
                imageReferer: moduleReferer,
                imageBaseOrigin: lastFetchOrigin,
                onPlay: () => _openEpisode(ep),
              );
            },
          );
        },
      ),
      floatingActionButton: continueEp == null
          ? null
          : FloatingActionButton.extended(
              heroTag: null,
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
    required this.fallbackImageUrl,
    required this.fallbackTitle,
    required this.watched,
    required this.isContinue,
    required this.imageReferer,
    required this.imageBaseOrigin,
    required this.onPlay,
  });

  final JsModuleEpisode episode;
  final String? overrideImageUrl;
  final String? fallbackImageUrl;
  final String? fallbackTitle;
  final bool watched;
  final bool isContinue;
  final String? imageReferer;
  final String? imageBaseOrigin;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).colorScheme.surfaceContainerHighest;
    final header = 'Episode ${episode.number}';
    bool isGenericEpisodeTitle(String t) {
      final raw = t.trim();
      if (raw.isEmpty) return true;
      final lower = raw.toLowerCase();
      if (lower == header.toLowerCase()) return true;
      return RegExp(r'^\s*(episode|ep)\s*\d+\s*$', caseSensitive: false)
          .hasMatch(raw);
    }

    String cleanEpisodePrefix(String t) {
      var out = t.trim();
      if (out.isEmpty) return out;
      out = out.replaceFirst(
        RegExp(r'^\s*(episode|ep)\s*\d+\s*[-:–—]?\s*',
            caseSensitive: false),
        '',
      );
      return out.trim();
    }

    final moduleTitle = episode.title.trim();
    final fallback = cleanEpisodePrefix((fallbackTitle ?? '').trim());
    final subtitle = !isGenericEpisodeTitle(moduleTitle)
        ? moduleTitle
        : fallback;
    final showSubtitle =
        subtitle.isNotEmpty && subtitle.toLowerCase() != header.toLowerCase();

    final override = _ModuleWatchPageState._resolveImageUrl(
      overrideImageUrl ?? '',
      baseOrigin: imageBaseOrigin,
      imageReferer: imageReferer,
    );
    final fallbackImage = _ModuleWatchPageState._resolveImageUrl(
      fallbackImageUrl ?? '',
      baseOrigin: imageBaseOrigin,
      imageReferer: imageReferer,
    );
    final episodeImage = _ModuleWatchPageState._resolveImageUrl(
      episode.image,
      baseOrigin: imageBaseOrigin,
      imageReferer: imageReferer,
    );
    final candidates = <String>[
      if (episodeImage.isNotEmpty) episodeImage,
      if (override.isNotEmpty) override,
      if (fallbackImage.isNotEmpty) fallbackImage,
    ];

    final primaryImageUrl = candidates.isNotEmpty ? candidates.first : '';

    Map<String, String>? headersFor(String url) {
      final uri = Uri.tryParse(url);
      if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
        return null;
      }

      final trimmedReferer = imageReferer?.trim();
      final String? referer =
          (trimmedReferer != null && trimmedReferer.isNotEmpty)
              ? trimmedReferer
              : null;

      final String effectiveReferer = (referer != null &&
              Uri.tryParse(referer)?.origin == uri.origin)
          ? referer
          : '${uri.origin}/';

      return <String, String>{
        if (effectiveReferer.isNotEmpty) 'Referer': effectiveReferer,
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36',
      };
    }

    Widget placeholder() {
      final color = Theme.of(context).colorScheme.onSurfaceVariant;
      return Center(
        child: Icon(
          Icons.image_not_supported_outlined,
          color: color,
        ),
      );
    }

    Widget buildImageSequence(List<String> urls, {int index = 0}) {
      if (index >= urls.length) return placeholder();
      final url = urls[index];
      final headers = headersFor(url);
      return CachedImage(
        url,
        fit: BoxFit.cover,
        headers: headers,
        errorWidget: (context, _, __) {
          return buildImageSequence(urls, index: index + 1);
        },
      );
    }

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
                    if (primaryImageUrl.isNotEmpty)
                      buildImageSequence(
                        <String>{
                          ...candidates,
                        }.where((e) => e.trim().isNotEmpty).toList(),
                      )
                    else
                      placeholder(),
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

class _AniZipEpisodeData {
  const _AniZipEpisodeData({required this.images, required this.titles});
  final Map<int, String> images;
  final Map<int, String> titles;
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
