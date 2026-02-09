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
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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

  Map<int, String>? _anilistThumbs;
  Map<int, String>? _anilistEpisodeTitles;
  String? _lastFetchOrigin;
  String? _fallbackSearchTitle;
  int? _anilistMediaId;

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
    _episodesFuture = _exec.extractEpisodes(widget.module.id, widget.href);
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
    } else {
      final searchTitle = _preferredSearchTitle();
      _fetchAniListEpisodeThumbnailsBySearch(searchTitle).then((m) {
        if (!mounted) return;
        if (m.isEmpty) return;
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

    debugPrint(
      '[VoiceoverDebug] init module=${widget.module.id} epHref=${eps.first.href}',
    );

    try {
      // 1) Prefer explicit hook.
      var list = await _exec.getVoiceovers(widget.module.id, eps.first.href);
      debugPrint(
        '[VoiceoverDebug] getVoiceovers raw module=${widget.module.id}: ${list.join(" | ")}',
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
        '[VoiceoverDebug] getVoiceovers normalized module=${widget.module.id}: ${normalized.join(" | ")}',
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

      final inferred = await _inferVoiceoversFromStreams(eps.first);
      if (inferred) {
        _voiceoverInitDone = true;
      }
      return;
    } catch (_) {
      debugPrint(
        '[VoiceoverDebug] getVoiceovers failed module=${widget.module.id}, falling back to stream inference',
      );
      // Allow a retry on next frame; do not mark done.
      final inferred = await _inferVoiceoversFromStreams(eps.first);
      if (inferred) {
        _voiceoverInitDone = true;
      }
    }
  }

  Future<bool> _inferVoiceoversFromStreams(JsModuleEpisode ep) async {
    // If module doesn't expose getVoiceovers:
    // - for voiceover-first modules, treat stream titles as voiceovers directly.
    // - otherwise, infer based on host + provider/quality patterns.
    try {
      final selection = await _exec.extractStreams(widget.module.id, ep.href);
      debugPrint(
        '[VoiceoverDebug] infer selection.count module=${widget.module.id}: ${selection.streams.length}',
      );
      final candidates = _buildVoiceoverCandidates(selection.streams);
      debugPrint(
        '[VoiceoverDebug] infer candidates.count module=${widget.module.id}: ${candidates.length}',
      );
      debugPrint(
        '[VoiceoverDebug] infer candidates module=${widget.module.id}: ${candidates.join(" | ")}',
      );

      if (candidates.length >= 2) {
        candidates.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
        if (!mounted) return false;
        setState(() => _voiceoverTitles = candidates);
        debugPrint(
          '[VoiceoverDebug] infer setVoiceoverTitles module=${widget.module.id}: ${candidates.length}',
        );
        if (_preferredVoiceoverTitle == null) {
          debugPrint(
            '[VoiceoverDebug] infer prompting dialog module=${widget.module.id}',
          );
          await _pickVoiceover(showAuto: true);
        }
        return true;
      }
    } catch (_) {
      // Ignore; allow a retry on next frame.
    }
    return false;
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
        final serverTitles = selection.streams
            .map((s) => s.title.trim())
            .where((t) => t.isNotEmpty)
            .toList(growable: false);
        final uniqueServerTitles = <String>[];
        final seenServers = <String>{};
        for (final t in serverTitles) {
          final k = t.toLowerCase();
          if (seenServers.add(k)) uniqueServerTitles.add(t);
        }
        if (uniqueServerTitles.length >= 2 && _preferredServerTitle == null) {
          debugPrint(
            '[VoiceoverDebug] openEpisode prompting server dialog module=${widget.module.id}',
          );
          await _pickServer(uniqueServerTitles);
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
    final lastFetchOrigin = _lastFetchOrigin;

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

              final watched = ep.number <= continued;
              final isContinue = ep.number == continued + 1;

              return _ModuleEpisodeTile(
                episode: ep,
                overrideImageUrl: anilistThumb,
                fallbackTitle: anilistTitle,
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
    required this.fallbackTitle,
    required this.watched,
    required this.isContinue,
    required this.imageReferer,
    required this.imageBaseOrigin,
    required this.onPlay,
  });

  final JsModuleEpisode episode;
  final String? overrideImageUrl;
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
    final episodeImage = _ModuleWatchPageState._resolveImageUrl(
      episode.image,
      baseOrigin: imageBaseOrigin,
      imageReferer: imageReferer,
    );
    final candidates = <String>[
      if (episodeImage.isNotEmpty) episodeImage,
      if (override.isNotEmpty) override,
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
