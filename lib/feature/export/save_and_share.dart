import 'dart:typed_data';
import 'dart:io' show Platform, Process;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:file_selector/file_selector.dart';
import 'package:share_plus/share_plus.dart';

/// iOS: share sheet (user can pick "Save to Files / Open in Folder")
/// Android: SAF "Save to..." dialog (choose folder & name)
/// Desktop/Web: native "Save As..." dialog
/// Returns absolute path when saved (Android/Desktop/Web), or null when shared/cancelled.
Future<String?> saveBytesChooseLocation(
  BuildContext context, {
  required String filename,      // e.g. 'export.json'
  required Uint8List bytes,
  required String mimeType,      // e.g. 'application/json'
  required String fileExtension, // e.g. 'json' (no dot)
  String? shareText,             // used on iOS share
  bool revealAfterSave = false,  // desktop only; default off
}) async {
  // Capture context-derived things BEFORE awaits.
  final messenger = ScaffoldMessenger.maybeOf(context);
  final origin = _computeShareOrigin(context);

  try {
    // --- iOS: share sheet ---
    if (!kIsWeb && Platform.isIOS) {
      await SharePlus.instance.share(
        ShareParams(
          text: shareText ?? 'Export file',
          files: [XFile.fromData(bytes, name: filename, mimeType: mimeType)],
          sharePositionOrigin: origin, // iPad/Mac popover anchor
        ),
      );
      return null; // sharing doesn't return a path
    }

    // --- Android: SAF "Create document" dialog ---
    if (!kIsWeb && Platform.isAndroid) {
      final params = SaveFileDialogParams(
        data: bytes,
        fileName: filename,
        mimeTypesFilter: [mimeType], // optional hint for SAF
      );
      final savedPath = await FlutterFileDialog.saveFile(params: params);
      if (savedPath == null) {
        messenger?.showSnackBar(const SnackBar(content: Text('Save cancelled')));
        return null;
      }
      return savedPath;
    }

    // --- Desktop/Web: native "Save As..." ---
    final location = await getSaveLocation(
      suggestedName: filename,
      acceptedTypeGroups: [
        XTypeGroup(
          label: fileExtension.toUpperCase(),
          extensions: [fileExtension],
          mimeTypes: [mimeType],
        ),
      ],
    );
    if (location == null) {
      messenger?.showSnackBar(const SnackBar(content: Text('Save cancelled')));
      return null;
    }

    final xfile = XFile.fromData(bytes, name: filename, mimeType: mimeType);
    await xfile.saveTo(location.path);

    if (revealAfterSave) {
      await _revealFile(location.path);
    }
    return location.path;
  } catch (e) {
    messenger?.showSnackBar(SnackBar(content: Text('Failed to export: $e')));
    return null;
  }
}

/// Safe origin rect for iPad/Mac popover; harmless elsewhere.
Rect _computeShareOrigin(BuildContext context) {
  try {
    final overlay = Overlay.maybeOf(context)?.context.findRenderObject() as RenderBox?;
    final box = overlay ?? (context.findRenderObject() as RenderBox?);
    if (box != null && box.hasSize) {
      final topLeft = box.localToGlobal(Offset.zero);
      return topLeft & box.size;
    }
  } catch (_) {}
  return const Rect.fromLTWH(0, 0, 1, 1);
}

Future<void> _revealFile(String absPath) async {
  try {
    if (Platform.isWindows) {
      await Process.run('explorer.exe', ['/select,', absPath]);
    } else if (Platform.isMacOS) {
      await Process.run('open', ['-R', absPath]);
    } else if (Platform.isLinux) {
      final dir = absPath.replaceAll(RegExp(r'/[^/\\]+$'), '');
      await Process.run('xdg-open', [dir]);
    }
  } catch (_) {}
}

// Helpers using the new behavior:

Future<String?> saveMalXml(
  BuildContext context,
  String filename,
  Uint8List bytes,
) {
  return saveBytesChooseLocation(
    context,
    filename: filename,
    bytes: bytes,
    mimeType: 'application/xml',
    fileExtension: 'xml',
    shareText: 'MyAnimeList XML export',
    revealAfterSave: false,
  );
}

Future<String?> saveShikiJson(
  BuildContext context,
  String filename,
  Uint8List bytes,
) {
  return saveBytesChooseLocation(
    context,
    filename: filename,
    bytes: bytes,
    mimeType: 'application/json',
    fileExtension: 'json',
    shareText: 'Shikimori JSON export',
    revealAfterSave: false,
  );
}
