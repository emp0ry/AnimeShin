import 'dart:async';

import 'package:animeshin/extension/snack_bar_extension.dart';
import 'package:animeshin/feature/collection/collection_models.dart';
import 'package:animeshin/feature/collection/collection_provider.dart';
import 'package:animeshin/feature/read/manga_reader_prefs.dart';
import 'package:animeshin/feature/viewer/persistence_provider.dart';
import 'package:animeshin/util/module_loader/js_module_executor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/scheduler.dart';

class MangaReaderPage extends ConsumerStatefulWidget {
  const MangaReaderPage({
    super.key,
    required this.moduleId,
    required this.mangaTitle,
    required this.chapterTitle,
    required this.chapterHref,
    required this.chapterOrdinal,
    required this.entry,
    this.chapterList,
    this.chapterIndex,
  });

  final String moduleId;
  final String mangaTitle;
  final String chapterTitle;
  final String chapterHref;

  /// 1-based chapter index as returned by the module list.
  final int chapterOrdinal;

  /// AniList entry (nullable when user not logged in / not on list).
  final Entry? entry;

  /// Optional full chapter list (for Next button navigation).
  final List<JsModuleEpisode>? chapterList;

  /// Index within [chapterList].
  final int? chapterIndex;

  @override
  ConsumerState<MangaReaderPage> createState() => _MangaReaderPageState();
}

class _MangaReaderPageState extends ConsumerState<MangaReaderPage> {
  final JsModuleExecutor _exec = JsModuleExecutor();

  static const int _pageChunkSize = 5;
  final List<String> _pages = <String>[];
  final List<String> _pendingPages = <String>[];
  bool _hasMorePages = true;
  bool _loadingMore = false;
  Object? _loadError;

  final ScrollController _scroll = ScrollController();
  PageController? _pageCtrl;

  final ValueNotifier<bool> _uiVisible = ValueNotifier<bool>(true);
  final ValueNotifier<bool> _atEnd = ValueNotifier<bool>(false);

  bool _autoProgressDone = false;
  bool _navigatingNext = false;

  @override
  void initState() {
    super.initState();
    // Load incrementally so big chapters don't block the UI.
    unawaited(_loadMorePages(initial: true));
  }

  @override
  void dispose() {
    _uiVisible.dispose();
    _atEnd.dispose();
    _scroll.dispose();
    _pageCtrl?.dispose();
    super.dispose();
  }

  String _displayChapterTitle() {
    final raw = widget.chapterTitle.trim();
    if (raw.isEmpty) return widget.mangaTitle;
    return raw
        .replaceFirst(RegExp(r'^\s*episode\b', caseSensitive: false), 'Chapter')
        .trim();
  }

  JsModuleEpisode? _nextChapter() {
    final list = widget.chapterList;
    final idx = widget.chapterIndex;
    if (list == null || idx == null) return null;
    final nextIdx = idx + 1;
    if (nextIdx < 0 || nextIdx >= list.length) return null;
    return list[nextIdx];
  }

  void _resetControllers() {
    _pageCtrl?.dispose();
    _pageCtrl = PageController();
  }

  Future<void> _loadMorePages({required bool initial}) async {
    if (_loadingMore) return;
    if (!_hasMorePages && !initial) return;

    if (_pendingPages.isNotEmpty) {
      final take = _pageChunkSize.clamp(1, _pendingPages.length);
      final chunk = _pendingPages.sublist(0, take);
      _pendingPages.removeRange(0, take);
      setState(() {
        _pages.addAll(chunk);
        _hasMorePages = _pendingPages.isNotEmpty;
      });
      return;
    }

    setState(() {
      _loadingMore = true;
      _loadError = null;
    });

    try {
      final offset = _pages.length;
      final chunk = await _exec.extractPagesChunk(
        widget.moduleId,
        widget.chapterHref,
        offset: offset,
        limit: _pageChunkSize,
      );

      if (!mounted) return;

      setState(() {
        if (chunk.length > _pageChunkSize) {
          final start = offset.clamp(0, chunk.length);
          final end = (start + _pageChunkSize).clamp(0, chunk.length);
          _pages.addAll(chunk.sublist(start, end));
          if (end < chunk.length) {
            _pendingPages.addAll(chunk.sublist(end));
          }
          _hasMorePages = _pendingPages.isNotEmpty;
        } else {
          _pages.addAll(chunk);
          _hasMorePages = chunk.length == _pageChunkSize;
        }
        _loadingMore = false;
      });

      if (initial) {
        _resetControllers();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e;
        _loadingMore = false;
        // Keep _hasMorePages as-is; user may retry by scrolling.
      });
    }
  }

  Future<void> _updateProgressIfEnabled() async {
    if (_autoProgressDone) return;

    final prefs = ref.read(mangaReaderPrefsProvider);
    if (!prefs.autoProgress) return;

    final entry = widget.entry;
    if (entry == null) return;

    final viewerId = ref.read(viewerIdProvider);
    if (viewerId == null || viewerId == 0) return;

    // For manga, AniList progress is "chapters read" (Int).
    if (widget.chapterOrdinal <= entry.progress) {
      _autoProgressDone = true;
      return;
    }

    entry.progress = widget.chapterOrdinal;

    final tag = (userId: viewerId, ofAnime: false);
    final notifier = ref.read(collectionProvider(tag).notifier);
    final err = await notifier.saveEntryProgress(entry, false);
    if (!mounted) return;

    if (err != null) {
      SnackBarExtension.show(context, 'Failed to update progress: $err');
      return;
    }

    _autoProgressDone = true;
    SnackBarExtension.show(context, 'Progress updated to ${entry.progress}');
  }

  Future<void> _openNextChapter() async {
    if (_navigatingNext) return;
    final next = _nextChapter();
    if (next == null) return;

    _navigatingNext = true;
    await _updateProgressIfEnabled();
    if (!mounted) return;

    final nextIdx = (widget.chapterIndex ?? 0) + 1;
    await Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => MangaReaderPage(
          moduleId: widget.moduleId,
          mangaTitle: widget.mangaTitle,
          chapterTitle: next.title.trim().isEmpty
              ? 'Chapter ${next.number}'
              : next.title.trim().replaceFirst(
                    RegExp(r'^\s*episode\b', caseSensitive: false),
                    'Chapter',
                  ),
          chapterHref: next.href,
          chapterOrdinal: next.number,
          entry: widget.entry,
          chapterList: widget.chapterList,
          chapterIndex: nextIdx,
        ),
      ),
    );
  }

  Future<void> _pickMode() async {
    final current = ref.read(mangaReaderPrefsProvider).mode;

    final picked = await showDialog<MangaReaderMode>(
      context: context,
      builder: (ctx) {
        return SimpleDialog(
          title: const Text('Reader mode'),
          children: [
            SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop(MangaReaderMode.webScroll),
              child: Row(
                children: [
                  Icon(
                    current == MangaReaderMode.webScroll
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  const Text('Web scroll'),
                ],
              ),
            ),
            SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop(MangaReaderMode.tapScroll),
              child: Row(
                children: [
                  Icon(
                    current == MangaReaderMode.tapScroll
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  const Text('Tap to scroll'),
                ],
              ),
            ),
            SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop(MangaReaderMode.book),
              child: Row(
                children: [
                  Icon(
                    current == MangaReaderMode.book
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  const Text('Book (tap left/right)'),
                ],
              ),
            ),
          ],
        );
      },
    );

    if (picked == null) return;
    await ref.read(mangaReaderPrefsProvider.notifier).setMode(picked);

    if (!mounted) return;
    setState(() {});
  }

  Widget _buildPageImage(BuildContext context, String url) {
    final headers = _imageHeadersFor(url);
    final mq = MediaQuery.of(context);
    final dpr = mq.devicePixelRatio;
    final cacheWidth = (mq.size.width * dpr).round();

    return Center(
      child: Image.network(
        url,
        headers: headers,
        cacheWidth: cacheWidth,
        fit: BoxFit.contain,
        loadingBuilder: (context, child, progress) {
          if (progress == null) return child;
          return const Center(child: CircularProgressIndicator());
        },
        errorBuilder: (context, error, stack) {
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Failed to load page.\n${error.toString()}\n\n$url',
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          );
        },
      ),
    );
  }

  Map<String, String>? _imageHeadersFor(String url) {
    final uri = Uri.tryParse(url);
    final origin =
        (uri != null && (uri.scheme == 'http' || uri.scheme == 'https'))
            ? uri.origin
            : null;
    if (origin == null) return null;

    final referer = widget.chapterHref.trim().isNotEmpty
        ? widget.chapterHref.trim()
        : '$origin/';

    return <String, String>{
      'Referer': referer,
      'Accept': 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36',
    };
  }

  void _setAtEnd(bool v) {
    if (_atEnd.value == v) return;

    final phase = SchedulerBinding.instance.schedulerPhase;
    final inFrame = phase == SchedulerPhase.persistentCallbacks ||
        phase == SchedulerPhase.midFrameMicrotasks;

    if (inFrame) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_atEnd.value != v) _atEnd.value = v;
      });
    } else {
      _atEnd.value = v;
    }
  }

  bool _isReallyAtListEnd(ScrollMetrics m) {
    const epsilon = 24.0;
    return m.pixels >= (m.maxScrollExtent - epsilon);
  }

  Widget _buildWebScroll(List<String> pages, {required bool tapToScroll}) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: tapToScroll ? null : () => _uiVisible.value = !_uiVisible.value,
      onTapDown: tapToScroll
          ? (TapDownDetails d) {
              final box = context.findRenderObject() as RenderBox?;
              final size = box?.size;
              if (size == null || !_scroll.hasClients) return;

              final y = d.localPosition.dy;
              final h = size.height;
              final delta = h * 0.90;

              if (y < h * 0.33) {
                final next = (_scroll.offset - delta).clamp(
                  _scroll.position.minScrollExtent,
                  _scroll.position.maxScrollExtent,
                );
                _scroll.animateTo(
                  next,
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOut,
                );
              } else if (y > h * 0.66) {
                final next = (_scroll.offset + delta).clamp(
                  _scroll.position.minScrollExtent,
                  _scroll.position.maxScrollExtent,
                );
                _scroll.animateTo(
                  next,
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOut,
                );
              } else {
                _uiVisible.value = !_uiVisible.value;
              }
            }
          : null,
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n.metrics.axis != Axis.vertical) return false;

          final nearEndForPrefetch = _scroll.hasClients &&
              (n.metrics.pixels >=
                  n.metrics.maxScrollExtent - n.metrics.viewportDimension * 2);

          if (nearEndForPrefetch && _hasMorePages) {
            unawaited(_loadMorePages(initial: false));
          }

          final reallyAtEnd = _isReallyAtListEnd(n.metrics);
          _setAtEnd(reallyAtEnd && !_hasMorePages && !_loadingMore);

          return false;
        },
        child: ListView.builder(
          controller: _scroll,
          cacheExtent: MediaQuery.of(context).size.height * 2,
          addAutomaticKeepAlives: false,
          addRepaintBoundaries: true,
          addSemanticIndexes: false,
          itemCount: pages.length + (_loadingMore ? 1 : 0),
          itemBuilder: (context, i) {
            if (i >= pages.length) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: _buildPageImage(context, pages[i]),
            );
          },
        ),
      ),
    );
  }

  Widget _buildBook(List<String> pages) {
    final ctrl = _pageCtrl ??= PageController();

    void goNext() {
      if (!ctrl.hasClients) return;
      final nextPage = ctrl.page == null ? 1 : (ctrl.page!.round() + 1);
      if (nextPage >= pages.length) return;
      ctrl.animateToPage(
        nextPage,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }

    void goPrev() {
      if (!ctrl.hasClients) return;
      final prevPage = ctrl.page == null ? 0 : (ctrl.page!.round() - 1);
      if (prevPage < 0) return;
      ctrl.animateToPage(
        prevPage,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (TapDownDetails d) {
        final box = context.findRenderObject() as RenderBox?;
        final size = box?.size;
        if (size == null) return;

        final x = d.localPosition.dx;
        final w = size.width;

        // Left side -> previous, right side -> next, middle -> toggle UI
        if (x < w * 0.33) {
          goPrev();
        } else if (x > w * 0.66) {
          goNext();
        } else {
          _uiVisible.value = !_uiVisible.value;
        }
      },
      child: PageView.builder(
        controller: ctrl,
        // Keep swipe enabled too; tap just adds an easier control.
        itemCount: pages.length + (_loadingMore ? 1 : 0),
        onPageChanged: (i) {
          final nearEnd = i >= pages.length - 2;
          if (nearEnd && _hasMorePages) {
            unawaited(_loadMorePages(initial: false));
          }
          final atEnd = i >= pages.length - 1;
          _atEnd.value = atEnd && !_hasMorePages && !_loadingMore;
        },
        itemBuilder: (context, i) {
          if (i >= pages.length) {
            return const Center(child: CircularProgressIndicator());
          }
          return _buildPageImage(context, pages[i]);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(mangaReaderPrefsProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(_displayChapterTitle()),
        actions: [
          IconButton(
            tooltip: 'Reader mode',
            icon: const Icon(Icons.menu_book_outlined),
            onPressed: _pickMode,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ValueListenableBuilder<bool>(
        valueListenable: _uiVisible,
        builder: (context, visible, child) {
          return Column(
            children: [
              if (!visible) const SizedBox(height: 0) else const SizedBox(height: 0),
              Expanded(
                child: Builder(
                  builder: (context) {
                    final err = _loadError;
                    if (err != null && _pages.isEmpty) {
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(
                            'Failed to load pages.\n\n$err',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      );
                    }

                    if (_pages.isEmpty && _loadingMore) {
                      return const Center(child: CircularProgressIndicator());
                    }

                    if (_pages.isEmpty) {
                      return const Center(child: Text('No pages found'));
                    }

                    final content = switch (prefs.mode) {
                      MangaReaderMode.book => _buildBook(_pages),
                      MangaReaderMode.tapScroll =>
                        _buildWebScroll(_pages, tapToScroll: true),
                      MangaReaderMode.webScroll =>
                        _buildWebScroll(_pages, tapToScroll: false),
                    };

                    return content;
                  },
                ),
              ),
            ],
          );
        },
      ),
      bottomNavigationBar: ValueListenableBuilder<bool>(
        valueListenable: _atEnd,
        builder: (context, atEnd, _) {
          final next = _nextChapter();
          if (!atEnd || next == null) return const SizedBox.shrink();

          final prefs = ref.watch(mangaReaderPrefsProvider);
          final title = next.title.trim().isEmpty
              ? 'Chapter ${next.number}'
              : next.title.trim().replaceFirst(
                    RegExp(r'^\s*episode\b', caseSensitive: false),
                    'Chapter',
                  );

          final hintStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              );

          return SafeArea(
            top: false,
            child: Material(
              elevation: 4,
              color: Theme.of(context).colorScheme.surface,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: _openNextChapter,
                            icon: const Icon(Icons.arrow_forward),
                            label: Text('Next • $title'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              prefs.autoProgress
                                  ? 'Auto Progress: On'
                                  : 'Auto Progress: Off',
                              style: Theme.of(context).textTheme.labelSmall,
                            ),
                            Switch(
                              value: prefs.autoProgress,
                              onChanged: (v) async {
                                await ref
                                    .read(mangaReaderPrefsProvider.notifier)
                                    .setAutoProgress(v);
                              },
                            ),
                          ],
                        ),
                      ],
                    ),
                    Text(
                      '    To update AniList progress, tap Next.',
                      style: hintStyle,
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
