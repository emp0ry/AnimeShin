import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';

import 'package:animeshin/util/module_loader/js_module_executor.dart';
import 'package:animeshin/util/module_loader/js_sources_runtime.dart';
import 'package:animeshin/util/module_loader/remote_modules_store.dart';

Future<int> _testOne({
  required String jsonUrl,
  required String query,
}) async {
  final store = RemoteModulesStore();
  final exec = JsModuleExecutor();
  final rt = JsSourcesRuntime.instance;

  stdout.writeln('----------------------------------------');
  stdout.writeln('Module JSON: $jsonUrl');

  try {
    final d = await store.addOrUpdateFromUrl(jsonUrl, enabled: true);
    stdout.writeln('Downloaded as id="${d.id}" name="${d.name}"');

    // Inspect exports present after load.
    await rt.ensureModuleLoaded(d.id);
    final exportsJson = await rt.getModuleExportsJson(d.id);
    stdout.writeln('exports: ${exportsJson ?? '<none>'}');

    final raw = await rt.callStringArgs(d.id, 'searchResults', <Object?>[query]);
    if (raw != null) {
      final preview = raw.length > 200 ? raw.substring(0, 200) : raw;
      stdout.writeln('raw searchResults: $preview');
    }

    final res = await exec.searchResults(d.id, query);
    stdout.writeln('searchResults("$query") -> ${res.length} items');
    for (final item in res.take(5)) {
      stdout.writeln('- ${item.title} (${item.href})');
    }

    final lastFetch = await rt.getLastFetchDebugJson(d.id);
    stdout.writeln('lastFetch: ${lastFetch ?? '<none>'}');

    final logs = await rt.getLogsJson(d.id);
    if (logs != null && logs.trim().isNotEmpty) {
      final decoded = jsonDecode(logs);
      if (decoded is List && decoded.isNotEmpty) {
        stdout.writeln('logs (last ${decoded.length.clamp(0, 10)}):');
        for (final row in decoded.take(10)) {
          if (row is Map) {
            stdout.writeln('  ${row['level']}: ${row['msg']}');
          }
        }
      }
    }

    return 0;
  } catch (e, st) {
    stdout.writeln('ERROR: $e');
    stdout.writeln(st);
    return 1;
  }
}

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  String query = 'naruto';
  final urls = <String>[];

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--query' && i + 1 < args.length) {
      query = args[++i];
    } else if (arg.startsWith('--query=')) {
      query = arg.substring('--query='.length);
    } else {
      urls.add(arg);
    }
  }

  if (urls.isEmpty) {
    stdout.writeln('Usage: dart run tool/module_search_smoke.dart [--query <q>] <module_json_url>...');
    stdout.writeln('No module URLs provided; exiting.');
    return;
  }

  var exitCode = 0;
  for (final url in urls) {
    exitCode |= await _testOne(
      jsonUrl: url,
      query: query,
    );
  }

  stdout.writeln('----------------------------------------');
  stdout.writeln(exitCode == 0 ? 'OK' : 'FAILED');

  // Give stdout time to flush in Flutter desktop.
  await Future<void>.delayed(const Duration(milliseconds: 250));
  exit(exitCode);
}
