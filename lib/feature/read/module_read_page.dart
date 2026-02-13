import 'package:animeshin/feature/collection/collection_models.dart';
import 'package:animeshin/feature/collection/collection_entries_provider.dart';
import 'package:animeshin/feature/read/manga_reader_page.dart';
import 'package:animeshin/util/module_loader/js_module_executor.dart';
import 'package:animeshin/util/module_loader/js_sources_runtime.dart';
import 'package:animeshin/util/module_loader/sources_module.dart';
import 'package:animeshin/feature/viewer/persistence_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ModuleReadPage extends ConsumerStatefulWidget {
  const ModuleReadPage({
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
  ConsumerState<ModuleReadPage> createState() => _ModuleReadPageState();
}

class _ModuleReadPageState extends ConsumerState<ModuleReadPage> {
  final JsModuleExecutor _exec = JsModuleExecutor();
  late Future<List<JsModuleEpisode>> _chaptersFuture;
  List<JsModuleEpisode>? _chaptersCache;

  Entry? _watchEntry() {
    final base = widget.item;
    if (base == null) return null;
    final viewerId = ref.watch(viewerIdProvider);
    if (viewerId == null || viewerId == 0) return base;
    final tag = (userId: viewerId, ofAnime: false);
    return ref.watch(
          collectionEntryProvider((tag: tag, mediaId: base.mediaId)),
        ) ??
        base;
  }

  static String _normalizeChapterTitle(String raw, int number) {
    final t = raw.trim();
    if (t.isEmpty) return 'Chapter $number';
    return t.replaceFirst(
      RegExp(r'^\s*episode\b', caseSensitive: false),
      'Chapter',
    ).trim();
  }

  int? _findContinueIndex(List<JsModuleEpisode> chapters, int progress) {
    if (chapters.isEmpty) return null;
    final nextNumber = (progress <= 0) ? chapters.first.number : (progress + 1);
    for (var i = 0; i < chapters.length; i++) {
      if (chapters[i].number == nextNumber) return i;
    }
    for (var i = 0; i < chapters.length; i++) {
      if (chapters[i].number > progress) return i;
    }
    return 0;
  }

  @override
  void initState() {
    super.initState();
    // Reuse extractEpisodes() but interpret it as chapters.
    _chaptersFuture = _exec.extractEpisodes(widget.module.id, widget.href);
    _chaptersFuture.then((list) {
      if (!mounted) return;
      setState(() => _chaptersCache = list);
    });
  }

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

    final chapters = _chaptersCache ?? const <JsModuleEpisode>[];
    final preview = chapters.take(6).map((ch) {
      final title = ch.title.trim();
      final href = ch.href.trim();
      final image = ch.image.trim();
      return 'Ch ${ch.number}: title="$title" | href="$href" | image="$image"';
    }).toList(growable: false);

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
                if (lastFetch != null && lastFetch.isNotEmpty)
                  '\nLast fetch:\n$lastFetch',
                if (preview.isNotEmpty)
                  '\nPreview chapters:\n${preview.join('\n')}',
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
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            tooltip: 'Debug module',
            onPressed: _showModuleDebug,
            icon: const Icon(Icons.bug_report_outlined),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: FutureBuilder<List<JsModuleEpisode>>(
        future: _chaptersFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError) {
            final err = snapshot.error;
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'Failed to load chapters.\n\n$err',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            );
          }

          final chapters = snapshot.data ?? const <JsModuleEpisode>[];
          if (chapters.isEmpty) {
            return const Center(child: Text('No chapters found'));
          }

            final entry = _watchEntry();
            final progress = entry?.progress ?? 0;
          final continueIndex = _findContinueIndex(chapters, progress);
          final continueChapter = continueIndex != null
              ? chapters[continueIndex]
              : null;

          return Stack(
            children: [
              ListView.builder(
                itemCount: chapters.length,
                itemBuilder: (context, i) {
                  final ch = chapters[i];
                  final subtitle = _normalizeChapterTitle(ch.title, ch.number);

                  return ListTile(
                    title: Text('Chapter ${ch.number}'),
                    subtitle: Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: const Icon(Icons.chrome_reader_mode_outlined),
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => MangaReaderPage(
                            moduleId: widget.module.id,
                            mangaTitle: widget.title,
                            chapterTitle: subtitle,
                            chapterHref: ch.href,
                            chapterOrdinal: ch.number,
                            entry: entry,
                            chapterList: chapters,
                            chapterIndex: i,
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
              if (continueChapter != null)
                Positioned(
                  right: 16,
                  bottom: 16,
                  child: FloatingActionButton.extended(
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => MangaReaderPage(
                            moduleId: widget.module.id,
                            mangaTitle: widget.title,
                            chapterTitle: _normalizeChapterTitle(
                              continueChapter.title,
                              continueChapter.number,
                            ),
                            chapterHref: continueChapter.href,
                            chapterOrdinal: continueChapter.number,
                            entry: entry,
                            chapterList: chapters,
                            chapterIndex: continueIndex,
                          ),
                        ),
                      );
                    },
                    icon: const Icon(Icons.play_arrow),
                    label: Text(
                      progress > 0
                          ? 'Continue • Chapter ${continueChapter.number}'
                          : 'Read • Chapter ${continueChapter.number}',
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
