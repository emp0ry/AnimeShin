import 'dart:convert';
import 'dart:io';

/// Generates `assets/sources/index.json` for fast module listing.
///
/// Convention:
/// - `assets/sources/{id}/{id}.json`
/// - `assets/sources/{id}/{id}.js`
Future<void> main(List<String> args) async {
  final root = Directory.current;
  final sourcesDir = Directory(_join(root.path, 'assets', 'sources'));

  if (!sourcesDir.existsSync()) {
    stderr.writeln('Missing directory: ${sourcesDir.path}');
    exitCode = 2;
    return;
  }

  final modules = <Map<String, Object?>>[];

  for (final ent in sourcesDir.listSync(followLinks: false)) {
    if (ent is! Directory) continue;
    final id = ent.uri.pathSegments.isNotEmpty
        ? ent.uri.pathSegments[ent.uri.pathSegments.length - 2]
        : ent.path.split(Platform.pathSeparator).last;

    final jsonFile = File(_join(ent.path, '$id.json'));
    final jsFile = File(_join(ent.path, '$id.js'));

    if (!jsonFile.existsSync() || !jsFile.existsSync()) {
      // Skip folders that don't follow the convention.
      continue;
    }

    Map<String, Object?> meta;
    try {
      final raw = jsonFile.readAsStringSync();
      final decoded = jsonDecode(raw);
      meta = decoded is Map<String, dynamic>
          ? decoded.map((k, v) => MapEntry(k, v))
          : <String, Object?>{};
    } catch (_) {
      meta = <String, Object?>{};
    }

    modules.add({
      'id': id,
      'jsonAsset': 'assets/sources/$id/$id.json',
      'jsAsset': 'assets/sources/$id/$id.js',
      // Keep a few common fields if present (optional).
      'name': meta['sourceName'] ?? meta['name'] ?? meta['title'] ?? id,
      'version': meta['version'],
      'lang': meta['lang'] ?? meta['language'],
      'meta': meta,
    });
  }

  modules.sort((a, b) => (a['id'] as String)
      .toLowerCase()
      .compareTo((b['id'] as String).toLowerCase()));

  final out = {
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
    'count': modules.length,
    'modules': modules,
  };

  final outFile = File(_join(sourcesDir.path, 'index.json'));
  outFile.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(out));

  stdout.writeln('Wrote ${outFile.path} (${modules.length} modules)');
}

String _join(String a, String b, [String? c, String? d]) {
  final parts = <String>[a, b];
  if (c != null) parts.add(c);
  if (d != null) parts.add(d);
  return parts.join(Platform.pathSeparator);
}
