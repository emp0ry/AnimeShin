import 'dart:typed_data';
import 'dart:io' show Platform, Process, File;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:file_selector/file_selector.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

/// iOS: share sheet using a real temp file (keeps the filename, no extra text.txt)
/// Android: SAF "Save to..." dialog
/// Desktop/Web: native "Save As..." dialog
Future<String?> saveBytesChooseLocation(
  BuildContext context, {
  required String filename,      // e.g. 'export.json'
  required Uint8List bytes,
  required String mimeType,      // e.g. 'application/json'
  required String fileExtension, // e.g. 'json'
  String? shareText,             // ignored on iOS to avoid extra text.txt
  bool revealAfterSave = false,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final origin = _computeShareOrigin(context);

  try {
    // --- iOS: Share a real file (NO 'text' param) ---
    if (!kIsWeb && Platform.isIOS) {
      final tmpDir = await getTemporaryDirectory();
      final tmpPath = p.join(tmpDir.path, filename);
      // Overwrite if exists.
      await File(tmpPath).writeAsBytes(bytes, flush: true);

      await SharePlus.instance.share(
        ShareParams(
          // DO NOT set 'text' on iOS to avoid extra text.txt
          files: [XFile(tmpPath, mimeType: mimeType)],
          sharePositionOrigin: origin,
          // subject: shareText, // optional; Files may ignore it
        ),
      );
      return null; // Shared; no path returned by iOS share sheet
    }

    // --- Android: SAF "Create document" (user picks folder & name) ---
    if (!kIsWeb && Platform.isAndroid) {
      final params = SaveFileDialogParams(
        data: bytes,
        fileName: filename,
        mimeTypesFilter: [mimeType],
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

// Helpers unchanged — iOS will share, Android/Desktop will save.
Future<String?> saveMalXml(BuildContext c, String name, Uint8List b) =>
    saveBytesChooseLocation(c,
      filename: name, bytes: b,
      mimeType: 'application/xml', fileExtension: 'xml',
      shareText: 'MyAnimeList XML export',
      revealAfterSave: false);

Future<String?> saveShikiJson(BuildContext c, String name, Uint8List b) =>
    saveBytesChooseLocation(c,
      filename: name, bytes: b,
      mimeType: 'application/json', fileExtension: 'json',
      shareText: 'Shikimori JSON export',
      revealAfterSave: false);
