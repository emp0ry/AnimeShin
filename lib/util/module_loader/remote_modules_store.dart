import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'sources_module.dart';

class RemoteModuleEntry {
	const RemoteModuleEntry({
		required this.id,
		required this.jsonUrl,
		required this.enabled,
		required this.updatedAt,
	});

	final String id;
	final String jsonUrl;
	final bool enabled;
	final DateTime updatedAt;

	Map<String, Object?> toJson() => <String, Object?>{
				'id': id,
				'jsonUrl': jsonUrl,
				'enabled': enabled,
				'updatedAt': updatedAt.toUtc().toIso8601String(),
			};

	static RemoteModuleEntry? fromJson(Object? v) {
		if (v is! Map) return null;
		final id = (v['id'] ?? '').toString().trim();
		final jsonUrl = (v['jsonUrl'] ?? '').toString().trim();
		if (id.isEmpty || jsonUrl.isEmpty) return null;

		final enabledRaw = v['enabled'];
		final enabled = enabledRaw is bool
				? enabledRaw
				: (enabledRaw is String
						? enabledRaw.toLowerCase() == 'true'
						: true);

		DateTime updatedAt;
		try {
			updatedAt = DateTime.parse((v['updatedAt'] ?? '').toString()).toUtc();
		} catch (_) {
			updatedAt = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
		}

		return RemoteModuleEntry(
			id: id,
			jsonUrl: jsonUrl,
			enabled: enabled,
			updatedAt: updatedAt,
		);
	}
}

/// Manages downloaded JS modules (Sora-style) stored on disk.
///
/// Notes:
/// - Uses Application Support directory when available.
/// - In unit tests (no plugin registration) this gracefully no-ops.
class RemoteModulesStore {
	RemoteModulesStore();

	static const String _registryFileName = 'remote_modules.json';

	static const int _registryVersion = 1;

	static String _slugifyId(String raw) {
		final t = raw.trim().toLowerCase();
		final buf = StringBuffer();
		var prevDash = false;
		for (final code in t.codeUnits) {
			final c = String.fromCharCode(code);
			final isAz = code >= 97 && code <= 122;
			final is09 = code >= 48 && code <= 57;
			if (isAz || is09) {
				buf.write(c);
				prevDash = false;
			} else if (!prevDash) {
				buf.write('-');
				prevDash = true;
			}
		}
		var out = buf.toString();
		out = out.replaceAll(RegExp(r'-+'), '-');
		out = out.replaceAll(RegExp(r'^-+'), '');
		out = out.replaceAll(RegExp(r'-+$'), '');
		return out;
	}

	static String _idFromJsonUrl(String url) {
		try {
			final uri = Uri.parse(url);
			final seg = uri.pathSegments.isNotEmpty ? uri.pathSegments.last : '';
			final base = seg.endsWith('.json') ? seg.substring(0, seg.length - 5) : seg;
			final id = _slugifyId(base.isEmpty ? uri.host : base);
			return id.isEmpty ? 'remote' : id;
		} catch (_) {
			return 'remote';
		}
	}

	static String _normalizeId(String id) {
		final out = _slugifyId(id);
		return out.isEmpty ? 'remote' : out;
	}

	Future<Directory?> _supportDir() async {
		try {
			final d = await getApplicationSupportDirectory();
			return d;
		} catch (_) {
			// Continue to fallback paths.
		}

		try {
			final d = await getApplicationDocumentsDirectory();
			return d;
		} catch (_) {
			// Continue to fallback paths.
		}

		final home = Platform.environment['HOME'];
		if (home != null && home.trim().isNotEmpty) {
			final d = Directory(p.join(home, '.local', 'share', 'animeshin'));
			if (!await d.exists()) {
				await d.create(recursive: true);
			}
			return d;
		}

		return null;
	}

	Future<File?> _registryFile() async {
		final base = await _supportDir();
		if (base == null) return null;
		final dir = Directory(p.join(base.path, 'modules'));
		if (!await dir.exists()) {
			await dir.create(recursive: true);
		}
		return File(p.join(dir.path, _registryFileName));
	}

	Future<_Registry> _readRegistry() async {
		final f = await _registryFile();
		if (f == null || !await f.exists()) {
			return const _Registry(
				version: _registryVersion,
				remoteModules: <RemoteModuleEntry>[],
				disabledModuleIds: <String>[],
			);
		}

		try {
			final raw = await f.readAsString();
			final decoded = jsonDecode(raw);

			// Migration: older format stored a JSON array of RemoteModuleEntry.
			if (decoded is List) {
				final remotes = <RemoteModuleEntry>[];
				for (final item in decoded) {
					final e = RemoteModuleEntry.fromJson(item);
					if (e != null) remotes.add(e);
				}
				return _Registry(
					version: _registryVersion,
					remoteModules: remotes,
					disabledModuleIds: const <String>[],
				);
			}

			if (decoded is Map) {
				final remoteRaw = decoded['remoteModules'];
				final disabledRaw = decoded['disabledModuleIds'] ?? decoded['disabledModules'];

				final remotes = <RemoteModuleEntry>[];
				if (remoteRaw is List) {
					for (final item in remoteRaw) {
						final e = RemoteModuleEntry.fromJson(item);
						if (e != null) remotes.add(e);
					}
				}

				final disabled = <String>[];
				if (disabledRaw is List) {
					for (final v in disabledRaw) {
						final t = (v ?? '').toString().trim();
						if (t.isNotEmpty) disabled.add(_normalizeId(t));
					}
				}

				return _Registry(
					version: (decoded['version'] is int)
							? (decoded['version'] as int)
							: _registryVersion,
					remoteModules: remotes,
					disabledModuleIds: disabled,
				);
			}

			return const _Registry(
				version: _registryVersion,
				remoteModules: <RemoteModuleEntry>[],
				disabledModuleIds: <String>[],
			);
		} catch (_) {
			return const _Registry(
				version: _registryVersion,
				remoteModules: <RemoteModuleEntry>[],
				disabledModuleIds: <String>[],
			);
		}
	}

	Future<void> _writeRegistry(_Registry reg) async {
		final f = await _registryFile();
		if (f == null) return;
		final raw = jsonEncode(<String, Object?>{
			'version': _registryVersion,
			'remoteModules': reg.remoteModules.map((e) => e.toJson()).toList(),
			'disabledModuleIds': reg.disabledModuleIds,
		});
		await f.writeAsString(raw);
	}

	Future<List<RemoteModuleEntry>> list() async {
		final reg = await _readRegistry();
		return reg.remoteModules;
	}

	Future<Set<String>> disabledModuleIds() async {
		final reg = await _readRegistry();
		return reg.disabledModuleIds.toSet();
	}

	Future<Directory?> _moduleDir(String id) async {
		final base = await _supportDir();
		if (base == null) return null;
		final dir = Directory(p.join(base.path, 'modules', id));
		if (!await dir.exists()) {
			await dir.create(recursive: true);
		}
		return dir;
	}

	Future<String?> _downloadText(String url) async {
		final uri = Uri.tryParse(url);
		if (uri == null) return null;

		final resp = await http.get(
			uri,
			headers: <String, String>{
				'User-Agent':
						'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36',
				'Accept': 'application/json,text/plain;q=0.9,*/*;q=0.8',
			},
		);

		if (resp.statusCode < 200 || resp.statusCode >= 300) {
			throw StateError('Failed to download (HTTP ${resp.statusCode})\n$url');
		}

		return resp.body;
	}

	/// Download a module JSON and its JS (via `scriptUrl`/`script_url`), store it
	/// locally, and return a descriptor pointing at local files.
	Future<SourcesModuleDescriptor> addOrUpdateFromUrl(
		String jsonUrl, {
		bool enabled = true,
	}) async {
		final rawJson = await _downloadText(jsonUrl);
		if (rawJson == null || rawJson.trim().isEmpty) {
			throw StateError('Empty module JSON');
		}

		final decoded = jsonDecode(rawJson);
		if (decoded is! Map) {
			throw StateError('Invalid module JSON');
		}
		final meta = decoded.cast<String, dynamic>();

		final idFromJson = (meta['id'] ?? meta['sourceId'] ?? meta['moduleId'])
				?.toString()
				.trim();
		final id = _normalizeId(
			(idFromJson == null || idFromJson.isEmpty) ? _idFromJsonUrl(jsonUrl) : idFromJson,
		);

		String? scriptUrl = (meta['scriptUrl'] ??
					meta['script_url'] ??
					meta['scriptURL'] ??
					meta['jsUrl'] ??
					meta['js_url'] ??
					meta['jsURL'] ??
					meta['script'] ??
					meta['scriptSrc'] ??
					meta['script_src'] ??
					meta['scriptLink'] ??
					meta['scriptHref'])
				?.toString()
				.trim();

		if (scriptUrl == null || scriptUrl.isEmpty) {
			// Fallback: derive script URL from the JSON URL if possible.
			try {
				final uri = Uri.parse(jsonUrl);
				final path = uri.path;
				if (path.endsWith('.json')) {
					final jsPath = '${path.substring(0, path.length - 5)}.js';
					scriptUrl = uri.replace(path: jsPath).toString();
				} else {
					scriptUrl = uri.replace(path: '$path.js').toString();
				}
			} catch (_) {
				scriptUrl = null;
			}
		}

		if (scriptUrl == null || scriptUrl.isEmpty) {
			throw StateError('Module JSON missing scriptUrl');
		}

		final rawJs = await _downloadText(scriptUrl);
		if (rawJs == null || rawJs.trim().isEmpty) {
			throw StateError('Empty module JS');
		}

		final dir = await _moduleDir(id);
		if (dir == null) {
			throw StateError('Storage unavailable');
		}

		final jsonFile = File(p.join(dir.path, '$id.json'));
		final jsFile = File(p.join(dir.path, '$id.js'));

		await jsonFile.writeAsString(rawJson);
		await jsFile.writeAsString(rawJs);

		// Update registry.
		final now = DateTime.now().toUtc();
		final reg = await _readRegistry();
		final existing = reg.remoteModules;
		final updated = <RemoteModuleEntry>[];
		var found = false;
		for (final e in existing) {
			if (e.id == id) {
				updated.add(RemoteModuleEntry(
					id: id,
					jsonUrl: jsonUrl,
					enabled: enabled,
					updatedAt: now,
				));
				found = true;
			} else {
				updated.add(e);
			}
		}
		if (!found) {
			updated.add(RemoteModuleEntry(
				id: id,
				jsonUrl: jsonUrl,
				enabled: enabled,
				updatedAt: now,
			));
		}

		// If module is enabled, ensure it isn't in the disabled list.
		final disabled = reg.disabledModuleIds.toSet();
		if (enabled) {
			disabled.remove(id);
		} else {
			disabled.add(id);
		}

		await _writeRegistry(
			_Registry(
				version: _registryVersion,
				remoteModules: updated,
				disabledModuleIds: disabled.toList(),
			),
		);

		final name = (meta['sourceName'] ?? meta['name'] ?? meta['title'] ?? id)
				.toString();

		return SourcesModuleDescriptor(
			id: id,
			jsonAsset: jsonFile.path,
			jsAsset: jsFile.path,
			name: name,
			version: meta['version'],
			lang: meta['language'] ?? meta['lang'],
			meta: meta,
		);
	}

	Future<void> setEnabled(String id, bool enabled) async {
		final normId = _normalizeId(id);
		final reg = await _readRegistry();
		final items = reg.remoteModules;
		final out = <RemoteModuleEntry>[];
		for (final e in items) {
			if (e.id == normId) {
				out.add(RemoteModuleEntry(
					id: e.id,
					jsonUrl: e.jsonUrl,
					enabled: enabled,
					updatedAt: e.updatedAt,
				));
			} else {
				out.add(e);
			}
		}

		final disabled = reg.disabledModuleIds.toSet();
		if (enabled) {
			disabled.remove(normId);
		} else {
			disabled.add(normId);
		}

		await _writeRegistry(
			_Registry(
				version: _registryVersion,
				remoteModules: out,
				disabledModuleIds: disabled.toList(),
			),
		);
	}

	/// Enable/disable a bundled (asset) module.
	Future<void> setBundledEnabled(String id, bool enabled) async {
		final normId = _normalizeId(id);
		final reg = await _readRegistry();
		final disabled = reg.disabledModuleIds.toSet();
		if (enabled) {
			disabled.remove(normId);
		} else {
			disabled.add(normId);
		}
		await _writeRegistry(
			_Registry(
				version: _registryVersion,
				remoteModules: reg.remoteModules,
				disabledModuleIds: disabled.toList(),
			),
		);
	}

	Future<void> remove(String id) async {
		final normId = _normalizeId(id);
		final reg = await _readRegistry();
		final items = reg.remoteModules;
		final out = items.where((e) => e.id != normId).toList(growable: false);

		final disabled = reg.disabledModuleIds.toSet();
		disabled.remove(normId);

		await _writeRegistry(
			_Registry(
				version: _registryVersion,
				remoteModules: out,
				disabledModuleIds: disabled.toList(),
			),
		);

		final dir = await _moduleDir(normId);
		if (dir != null && await dir.exists()) {
			try {
				await dir.delete(recursive: true);
			} catch (_) {
				// ignore
			}
		}
	}

	/// Build module descriptors for all downloaded modules.
	Future<List<SourcesModuleDescriptor>> buildDescriptors({bool includeDisabled = false}) async {
		final entries = await list();
		if (entries.isEmpty) return const <SourcesModuleDescriptor>[];

		final out = <SourcesModuleDescriptor>[];
		for (final e in entries) {
			if (!includeDisabled && !e.enabled) continue;
			final dir = await _moduleDir(e.id);
			if (dir == null) continue;

			final jsonPath = p.join(dir.path, '${e.id}.json');
			final jsPath = p.join(dir.path, '${e.id}.js');
			final jsonFile = File(jsonPath);
			final jsFile = File(jsPath);
			if (!await jsonFile.exists() || !await jsFile.exists()) continue;

			Map<String, dynamic>? meta;
			try {
				meta = (jsonDecode(await jsonFile.readAsString()) as Map)
						.cast<String, dynamic>();
			} catch (_) {
				meta = null;
			}

			final name = (meta?['sourceName'] ?? meta?['name'] ?? meta?['title'] ?? e.id)
					.toString();

			out.add(
				SourcesModuleDescriptor(
					id: e.id,
					jsonAsset: jsonPath,
					jsAsset: jsPath,
					name: name,
					version: meta?['version'],
					lang: meta?['language'] ?? meta?['lang'],
					meta: meta,
				),
			);
		}

		out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
		return out;
	}

	/// Export current registry (remote modules only).
	Future<String> exportJson() async {
		final reg = await _readRegistry();
		final items = reg.remoteModules;
		return jsonEncode(<String, Object?>{
			'version': _registryVersion,
			'remoteModules': items.map((e) => e.toJson()).toList(),
			'disabledModuleIds': reg.disabledModuleIds,
		});
	}

	/// Import registry (remote modules only). Does not auto-download; it only
	/// restores the URL list + enabled flags.
	Future<void> importJson(String raw) async {
		final decoded = jsonDecode(raw);
		if (decoded is! Map) throw StateError('Invalid import file');

		final listRaw = decoded['remoteModules'];
		if (listRaw is! List) throw StateError('Invalid import file');

		final disabledRaw = decoded['disabledModuleIds'] ?? decoded['disabledModules'];

		final out = <RemoteModuleEntry>[];
		for (final item in listRaw) {
			final e = RemoteModuleEntry.fromJson(item);
			if (e != null) out.add(e);
		}

		final disabled = <String>[];
		if (disabledRaw is List) {
			for (final v in disabledRaw) {
				final t = (v ?? '').toString().trim();
				if (t.isNotEmpty) disabled.add(_normalizeId(t));
			}
		}

		// De-dup by id.
		final byId = <String, RemoteModuleEntry>{};
		for (final e in out) {
			byId[e.id] = e;
		}

		await _writeRegistry(
			_Registry(
				version: _registryVersion,
				remoteModules: byId.values.toList(),
				disabledModuleIds: disabled,
			),
		);
	}

	/// Download/update all enabled remote modules in the registry.
	Future<void> downloadAllEnabledRemote() async {
		final entries = await list();
		for (final e in entries) {
			if (!e.enabled) continue;
			await addOrUpdateFromUrl(e.jsonUrl, enabled: true);
		}
	}
}

class _Registry {
	const _Registry({
		required this.version,
		required this.remoteModules,
		required this.disabledModuleIds,
	});

	final int version;
	final List<RemoteModuleEntry> remoteModules;
	final List<String> disabledModuleIds;
}
