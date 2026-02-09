import 'package:flutter/material.dart';
import 'package:ionicons/ionicons.dart';

import 'package:animeshin/feature/collection/collection_models.dart';
import 'package:animeshin/feature/read/module_read_page.dart';
import 'package:animeshin/feature/watch/module_watch_page.dart';
import 'package:animeshin/util/module_loader/js_module_executor.dart';
import 'package:animeshin/util/module_loader/js_sources_runtime.dart';
import 'package:animeshin/util/module_loader/sources_module.dart';
import 'package:animeshin/util/module_loader/sources_module_loader.dart';
import 'package:animeshin/util/text_utils.dart';
import 'package:animeshin/util/theming.dart';
import 'package:animeshin/widget/cached_image.dart';

Set<String> _extractModuleTypes(SourcesModuleDescriptor m) {
  final meta = m.meta ?? const <String, dynamic>{};
  final raw = meta['type'] ?? meta['types'] ?? meta['mediaType'] ?? meta['mediaTypes'];

  final out = <String>{};

  void addToken(String token) {
    final t = token.trim().toLowerCase();
    if (t.isEmpty) return;
    if (t.contains('anime')) out.add('anime');
    if (t.contains('manga')) out.add('manga');
  }

  if (raw is String) {
    for (final part in raw.split(RegExp(r'[|,/]'))) {
      addToken(part);
    }
  } else if (raw is List) {
    for (final v in raw) {
      if (v == null) continue;
      addToken(v.toString());
    }
  }

  return out;
}

bool _moduleSupportsType(SourcesModuleDescriptor m, {required bool isManga}) {
  final types = _extractModuleTypes(m);
  if (types.isEmpty) return true;
  return isManga ? types.contains('manga') : types.contains('anime');
}

class ModuleSearchPage extends StatefulWidget {
  const ModuleSearchPage({
    super.key,
    required this.item,
    required this.isManga,
    this.searchQueries,
  });

  final Entry? item;
  final bool isManga;
  final List<({String by, String query})>? searchQueries;

  @override
  State<ModuleSearchPage> createState() => _ModuleSearchPageState();
}

class _ModuleSearchPageState extends State<ModuleSearchPage> {
  late final Future<List<SourcesModuleDescriptor>> _modulesFuture;

  Widget _moduleLeadingIcon(SourcesModuleDescriptor m) {
    final url = (m.meta?['iconUrl'] ?? m.meta?['iconURL'] ?? m.meta?['icon'] ?? '').toString().trim();
    if (url.isEmpty) {
      return CircleAvatar(
        child: Text(m.name.isNotEmpty ? m.name[0].toUpperCase() : '?'),
      );
    }
    return CircleAvatar(
      backgroundColor: Colors.transparent,
      child: ClipOval(
        child: CachedImage(
          url,
          width: 40,
          height: 40,
          fit: BoxFit.cover,
        ),
      ),
    );
  }

  String _moduleSubtitle(SourcesModuleDescriptor m) {
    final type = (m.meta?['type'] ?? '').toString().trim();
    final lang = (m.meta?['language'] ?? m.meta?['lang'] ?? '').toString().trim();

    final parts = <String>[];
    if (type.isNotEmpty) parts.add(type);
    if (lang.isNotEmpty) parts.add(lang);
    return parts.isEmpty ? '' : parts.join(' • ');
  }

  @override
  void initState() {
    super.initState();
    _modulesFuture = _loadModules();
  }

  Future<List<SourcesModuleDescriptor>> _loadModules() async {
    try {
      return await SourcesModuleLoader().listModules();
    } catch (_) {
      return const <SourcesModuleDescriptor>[];
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Search modules'),
      ),
      body: FutureBuilder<List<SourcesModuleDescriptor>>(
        future: _modulesFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final allModules = snapshot.data ?? const <SourcesModuleDescriptor>[];
          final modules = allModules
              .where((m) => _moduleSupportsType(m, isManga: widget.isManga))
              .toList(growable: false);

          if (modules.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text('No matching modules found in assets/sources/'),
              ),
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.all(Theming.offset),
            itemCount: modules.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final module = modules[index];
              return Card(
                child: ListTile(
                  leading: _moduleLeadingIcon(module),
                  title: Text(module.name),
                  subtitle: Text(
                    _moduleSubtitle(module).isEmpty
                        ? module.id
                        : _moduleSubtitle(module),
                  ),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => ModuleSearchResultsPage(
                          item: widget.item,
                          isManga: widget.isManga,
                          module: module,
                          searchQueries: widget.searchQueries,
                        ),
                      ),
                    );
                  },
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class ModuleSearchResultsPage extends StatefulWidget {
  const ModuleSearchResultsPage({
    super.key,
    required this.item,
    required this.isManga,
    required this.module,
    this.searchQueries,
  });

  final Entry? item;
  final bool isManga;
  final SourcesModuleDescriptor module;
  final List<({String by, String query})>? searchQueries;

  @override
  State<ModuleSearchResultsPage> createState() => _ModuleSearchResultsPageState();
}

class _ModuleSearchResultsPageState extends State<ModuleSearchResultsPage> {
  late final Future<_SearchResults> _resultsFuture;

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

    final meta = widget.module.meta ?? const <String, dynamic>{};
    final type = (meta['type'] ?? '').toString().trim();
    final lang = (meta['language'] ?? meta['lang'] ?? '').toString().trim();
    final searchBaseUrl = (meta['searchBaseUrl'] ?? '').toString().trim();
    final asyncJs = (meta['asyncJS'] ?? '').toString().trim();

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
                'Type: ${type.isEmpty ? '(null)' : type}',
                'Language: ${lang.isEmpty ? '(null)' : lang}',
                'searchBaseUrl: ${searchBaseUrl.isEmpty ? '(null)' : searchBaseUrl}',
                'asyncJS: ${asyncJs.isEmpty ? '(null)' : asyncJs}',
                'Last fetch: ${lastFetch == null || lastFetch.isEmpty ? '(null)' : ''}',
                if (lastFetch != null && lastFetch.isNotEmpty)
                  '\n$lastFetch',
                if (logs != null && logs.isNotEmpty) '\nLogs:\n$logs',
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
    _resultsFuture = _search();
  }

  Future<_SearchResults> _search() async {
    final js = JsModuleExecutor();
    String? lastError;

    if (!_moduleSupportsType(widget.module, isManga: widget.isManga)) {
      final wanted = widget.isManga ? 'manga' : 'anime';
      final types = _extractModuleTypes(widget.module).join(', ');
      return (
        items: const <_RankedModuleTile>[],
        error: 'Module type mismatch. Expected $wanted, got ${types.isEmpty ? 'unknown' : types}.',
      );
    }

    ({String by, String query}) qv(String by, String query) =>
        (by: by, query: query);

    List<String> queryVariants(String q) {
      final base = q.trim();
      if (base.isEmpty) return const [];

      String romanizeStandaloneDigits(String s) {
        // Only apply to Latin-script queries to avoid mangling Cyrillic titles.
        if (!RegExp(r'[A-Za-z]').hasMatch(s)) return s;
        const map = <String, String>{
          '2': 'II',
          '3': 'III',
          '4': 'IV',
          '5': 'V',
          '6': 'VI',
          '7': 'VII',
          '8': 'VIII',
          '9': 'IX',
          '10': 'X',
        };

        var out = s;
        // Replace standalone numbers only.
        for (final e in map.entries) {
          out = out.replaceAllMapped(
            RegExp(r'\b' + RegExp.escape(e.key) + r'\b'),
            (_) => e.value,
          );
        }
        return out;
      }

      String stripSeasonSuffix(String s) {
        var t = s.trim();
        // English: "Season 2", "S2", "2nd Season".
        t = t.replaceAll(
          RegExp(
            r'\s*[:\-–—]?\s*(?:season\s*\d+|s\s*\d+)\s*$',
            caseSensitive: false,
          ),
          '',
        );
        t = t.replaceAll(
          RegExp(
            r'\s*[:\-–—]?\s*\d+(?:st|nd|rd|th)?\s*season\s*$',
            caseSensitive: false,
          ),
          '',
        );

        // Russian: "2 сезон", "сезон 2".
        t = t.replaceAll(
          RegExp(
            r'\s*[:\-–—]?\s*(?:сезон\s*\d+|\d+\s*сезон)\s*$',
            caseSensitive: false,
          ),
          '',
        );

        return t.trim();
      }

      final out = <String>[];
      void add(String v) {
        final t = v.trim();
        if (t.isEmpty) return;
        if (!out.contains(t)) out.add(t);
      }

      add(base);
      add(stripSeasonSuffix(base));

      add(romanizeStandaloneDigits(base));
      add(romanizeStandaloneDigits(stripSeasonSuffix(base)));

      // Also try removing any subtitle after ':' for some APIs.
      final colon = base.indexOf(':');
      if (colon > 0) {
        add(base.substring(0, colon));
        add(stripSeasonSuffix(base.substring(0, colon)));
        add(romanizeStandaloneDigits(base.substring(0, colon)));
        add(romanizeStandaloneDigits(stripSeasonSuffix(base.substring(0, colon))));
      }

      return out;
    }

    final base = widget.searchQueries != null && widget.searchQueries!.isNotEmpty
        ? widget.searchQueries!
        : <({String by, String query})>[
            if (widget.item?.titleRussian?.trim().isNotEmpty == true)
              qv('RU', widget.item!.titleRussian!.trim()),
            if (widget.item?.titleRomaji?.trim().isNotEmpty == true)
              qv('RO', widget.item!.titleRomaji!.trim()),
            if (widget.item?.titleShikimoriRomaji?.trim().isNotEmpty == true &&
                widget.item!.titleShikimoriRomaji!.trim() !=
                    widget.item!.titleRomaji?.trim())
              qv('RO', widget.item!.titleShikimoriRomaji!.trim()),
            if (widget.item?.titleEnglish?.trim().isNotEmpty == true)
              qv('EN', widget.item!.titleEnglish!.trim()),
          ];

    final queries = <({String by, String query})>[];
    for (final b in base) {
      for (final v in queryVariants(b.query)) {
        queries.add(qv(b.by, v));
      }
    }

    final bestByKey = <String, _RankedModuleTile>{};

    for (final q in queries) {
      try {
        final items = await js.searchResults(widget.module.id, q.query);
        for (final it in items) {
          final key = it.href.trim().isNotEmpty
              ? it.href.trim()
              : '${it.title.trim()}|${it.image.trim()}';
          final score = fuzzyMatchScore(q.query, it.title);
          final existing = bestByKey[key];
          if (existing == null || score > existing.score) {
            bestByKey[key] = _RankedModuleTile(
              it,
              score,
              matchedBy: q.by,
              matchedQuery: q.query,
            );
          }
        }
      } catch (e) {
        // Ignore and try next query.
        lastError = e.toString();
      }
    }

    final items = bestByKey.values.toList()
      ..sort((a, b) => b.score.compareTo(a.score));

    return (items: items, error: lastError);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.module.name),
        actions: [
          IconButton(
            tooltip: 'Debug module',
            onPressed: _showModuleDebug,
            icon: const Icon(Icons.bug_report_outlined),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: FutureBuilder<_SearchResults>(
        future: _resultsFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final data = snapshot.data;
          final items = data?.items ?? const <_RankedModuleTile>[];
          if (items.isEmpty) {
            final msg = data?.error ?? 'No results in ${widget.module.name}';
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

          return ListView.separated(
            padding: const EdgeInsets.all(Theming.offset),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final item = items[index];
              final name = item.tile.title.trim();
              final pct = (item.score * 100).round();
              final by = item.matchedBy;

              return Card(
                child: ListTile(
                  leading: Icon(
                    widget.isManga ? Ionicons.book_outline : Ionicons.play,
                  ),
                  title: Text(
                    name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text('$pct% match • $by'),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => widget.isManga
                            ? ModuleReadPage(
                                module: widget.module,
                                title: item.tile.title,
                                href: item.tile.href,
                                item: widget.item,
                              )
                            : ModuleWatchPage(
                                module: widget.module,
                                title: item.tile.title,
                                href: item.tile.href,
                                item: widget.item,
                              ),
                      ),
                    );
                  },
                ),
              );
            },
          );
        },
      ),
    );
  }
}

typedef _SearchResults = ({
  List<_RankedModuleTile> items,
  String? error,
});

class _RankedModuleTile {
  const _RankedModuleTile(
    this.tile,
    this.score, {
    required this.matchedBy,
    required this.matchedQuery,
  });

  final JsModuleTile tile;
  final double score; // 0..1
  final String matchedBy; // RU / RO / EN
  final String matchedQuery;
}
