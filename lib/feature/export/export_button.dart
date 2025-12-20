import 'dart:async';

import 'package:animeshin/feature/export/myanimelist/mal_builder.dart';
import 'package:animeshin/feature/export/save_and_share.dart';
import 'package:animeshin/feature/viewer/persistence_provider.dart';
import 'package:animeshin/feature/export/export_collection_provider.dart';
import 'package:animeshin/feature/export/shikimori/shiki_builder.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ExportButton extends ConsumerWidget {
  const ExportButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return IconButton(
      tooltip: 'Export',
      icon: const Icon(Icons.ios_share),
      onPressed: () async {
        // Compute the popup anchor rect from the button position.
        final button = context.findRenderObject() as RenderBox?;
        final overlay =
            Overlay.of(context).context.findRenderObject() as RenderBox?;
        if (button == null || overlay == null) return;
        final position = RelativeRect.fromRect(
          Rect.fromPoints(
            button.localToGlobal(Offset.zero, ancestor: overlay),
            button.localToGlobal(button.size.bottomRight(Offset.zero),
                ancestor: overlay),
          ),
          Offset.zero & overlay.size,
        );

        // --- Level 1: export targets ---
        final top = await showMenu<String>(
          context: context,
          position: position,
          items: const [
            PopupMenuItem<String>(
              value: 'mal',
              child: Row(
                children: [
                  Icon(Icons.cloud_upload_outlined, size: 18),
                  SizedBox(width: 8),
                  Text('MyAnimeList'),
                ],
              ),
            ),
            PopupMenuItem<String>(
              value: 'shiki',
              child: Row(
                children: [
                  Icon(Icons.cloud_upload_outlined, size: 18),
                  SizedBox(width: 8),
                  Text('Shikimori'),
                ],
              ),
            ),
          ],
        );

        if (!context.mounted || top == null) return;

        // --- Level 2: Anime / Manga ---
        final pick = await showMenu<String>(
          context: context,
          position: position,
          items: const [
            PopupMenuItem<String>(
              value: 'anime',
              child: Row(
                children: [
                  Icon(Icons.movie_outlined, size: 18),
                  SizedBox(width: 8),
                  Text('Anime'),
                ],
              ),
            ),
            PopupMenuItem<String>(
              value: 'manga',
              child: Row(
                children: [
                  Icon(Icons.menu_book_outlined, size: 18),
                  SizedBox(width: 8),
                  Text('Manga'),
                ],
              ),
            ),
          ],
        );
        if (!context.mounted || pick == null) return;

        final ofAnime = (pick == 'anime');

        if (top == 'mal') {
          await _exportMal(context, ref, ofAnime: ofAnime);
        } else if (top == 'shiki') {
          await _exportShiki(context, ref, ofAnime: ofAnime);
        }
      },
    );
  }

  /// Full export to MyAnimeList (Anime or Manga).
  Future<void> _exportMal(BuildContext context, WidgetRef ref,
      {required bool ofAnime}) async {
    final viewerId = ref.read(viewerIdProvider);
    final username = ref.read(
      persistenceProvider.select((s) => s.accountGroup.account?.name),
    );

    if (viewerId == null || username == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please sign in to export')),
      );
      return;
    }

    // Show progress UI
    unawaited(
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const _ProgressDialog(title: 'Exporting...'),
      ),
    );

    void closeDialogIfOpen() {
      if (!context.mounted) return;
      final nav = Navigator.of(context, rootNavigator: true);
      if (nav.canPop()) nav.pop();
    }

    try {
      // Add a hard timeout to avoid infinite spinner.
      final full = await ref
          .read(
            exportFullCollectionProvider((
              userId: viewerId,
              ofAnime: ofAnime,
              listIndex: 0,
              isShikimori: false
            )).future,
          )
          .timeout(const Duration(seconds: 35));

      final payload = buildMalFromCollection(
        collection: full,
        username: username,
        ofAnime: ofAnime,
      );

      closeDialogIfOpen();

      if (payload == null) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Nothing to export')),
        );
        return;
      }

      if (!context.mounted) return;
      final savedPath =
          await saveMalXml(context, payload.filename, payload.bytes);
      if (!context.mounted) return;

      final msg = (savedPath != null && savedPath.isNotEmpty)
          ? 'Exported to: $savedPath'
          : 'Export file shared';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    } on TimeoutException {
      closeDialogIfOpen();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Export timeout. Check connection and try again.')),
        );
      }
    } catch (e) {
      closeDialogIfOpen();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export failed: $e')),
        );
      }
    }
  }

  /// Full export to Shikimori JSON (Anime or Manga).
  Future<void> _exportShiki(BuildContext context, WidgetRef ref,
      {required bool ofAnime}) async {
    final viewerId = ref.read(viewerIdProvider);
    if (viewerId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please sign in to export')),
      );
      return;
    }

    // Show progress UI
    unawaited(
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const _ProgressDialog(title: 'Exporting...'),
      ),
    );

    void closeDialogIfOpen() {
      if (!context.mounted) return;
      final nav = Navigator.of(context, rootNavigator: true);
      if (nav.canPop()) nav.pop();
    }

    try {
      final full = await ref
          .read(
            exportFullCollectionProvider((
              userId: viewerId,
              ofAnime: ofAnime,
              listIndex: 0,
              isShikimori: true
            )).future,
          )
          .timeout(const Duration(seconds: 35));

      final payload = buildShikiFromCollection(
        collection: full,
        ofAnime: ofAnime,
      );

      closeDialogIfOpen();

      if (payload == null) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Nothing to export')),
        );
        return;
      }

      if (!context.mounted) return;
      final savedPath =
          await saveShikiJson(context, payload.filename, payload.bytes);
      if (!context.mounted) return;

      final msg = (savedPath != null && savedPath.isNotEmpty)
          ? 'Exported to: $savedPath'
          : 'Export file shared';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    } on TimeoutException {
      closeDialogIfOpen();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Export timeout. Check connection and try again.')),
        );
      }
    } catch (e) {
      closeDialogIfOpen();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export failed: $e')),
        );
      }
    }
  }
}

class _ProgressDialog extends StatelessWidget {
  const _ProgressDialog({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      content: Row(
        children: [
          const SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 16),
          Text(title),
        ],
      ),
    );
  }
}
