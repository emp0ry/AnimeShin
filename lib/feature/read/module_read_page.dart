import 'package:animeshin/feature/collection/collection_models.dart';
import 'package:animeshin/feature/read/manga_reader_page.dart';
import 'package:animeshin/util/module_loader/js_module_executor.dart';
import 'package:animeshin/util/module_loader/sources_module.dart';
import 'package:flutter/material.dart';

class ModuleReadPage extends StatefulWidget {
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
  State<ModuleReadPage> createState() => _ModuleReadPageState();
}

class _ModuleReadPageState extends State<ModuleReadPage> {
  final JsModuleExecutor _exec = JsModuleExecutor();
  late Future<List<JsModuleEpisode>> _chaptersFuture;

  @override
  void initState() {
    super.initState();
    // Reuse extractEpisodes() but interpret it as chapters.
    _chaptersFuture = _exec.extractEpisodes(widget.module.id, widget.href);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
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

          return ListView.builder(
            itemCount: chapters.length,
            itemBuilder: (context, i) {
              final ch = chapters[i];
              final subtitle = ch.title.trim().isEmpty
                  ? 'Chapter ${ch.number}'
                  : ch.title.trim();

              return ListTile(
                title: Text('Chapter ${ch.number}'),
                subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
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
                        entry: widget.item,
                      ),
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}
