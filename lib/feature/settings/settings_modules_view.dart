import 'dart:convert';
import 'dart:async';

import 'package:animeshin/extension/snack_bar_extension.dart';
import 'package:animeshin/util/module_loader/remote_modules_store.dart';
import 'package:animeshin/util/module_loader/sources_module_loader.dart';
import 'package:animeshin/util/module_loader/sources_module.dart';
import 'package:animeshin/util/theming.dart';
import 'package:animeshin/widget/layout/navigation_tool.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class SettingsModulesSubview extends StatefulWidget {
  const SettingsModulesSubview(this.scrollCtrl, {super.key});

  final ScrollController scrollCtrl;

  @override
  State<SettingsModulesSubview> createState() => _SettingsModulesSubviewState();
}

class _SettingsModulesSubviewState extends State<SettingsModulesSubview> {
  final _urlCtrl = TextEditingController();
  final _remote = RemoteModulesStore();
  final _loader = SourcesModuleLoader();

  bool _busy = false;

  @override
  void dispose() {
    _urlCtrl.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    _loader.invalidateIndex();
    setState(() {});
  }

  Future<void> _addFromUrl() async {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty) {
      SnackBarExtension.show(context, 'Paste a module JSON URL');
      return;
    }

    setState(() => _busy = true);
    try {
      await _remote.addOrUpdateFromUrl(url, enabled: true);
      _urlCtrl.clear();
      if (!mounted) return;
      SnackBarExtension.show(context, 'Module added');
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      SnackBarExtension.show(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleRemote(String id, bool enabled) async {
    setState(() => _busy = true);
    try {
      await _remote.setEnabled(id, enabled);
      if (!mounted) return;
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      SnackBarExtension.show(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _removeRemote(String id) async {
    setState(() => _busy = true);
    try {
      await _remote.remove(id);
      if (!mounted) return;
      SnackBarExtension.show(context, 'Removed');
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      SnackBarExtension.show(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _updateRemote(String url) async {
    setState(() => _busy = true);
    try {
      await _remote.addOrUpdateFromUrl(url, enabled: true);
      if (!mounted) return;
      SnackBarExtension.show(context, 'Updated');
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      SnackBarExtension.show(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _exportAll() async {
    setState(() => _busy = true);
    try {
      final raw = await _remote.exportJson();
      final path = await getSaveLocation(
        suggestedName: 'animeshin_modules.json',
        acceptedTypeGroups: <XTypeGroup>[
          XTypeGroup(label: 'JSON', extensions: ['json'])
        ],
      );
      if (path == null) return;
      final file = XFile.fromData(
        utf8.encode(raw),
        mimeType: 'application/json',
        name: 'animeshin_modules.json',
      );
      await file.saveTo(path.path);
      if (!mounted) return;
      SnackBarExtension.show(context, 'Exported');
    } catch (e) {
      if (!mounted) return;
      SnackBarExtension.show(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _importAll() async {
    setState(() => _busy = true);
    try {
      final open = await openFile(
        acceptedTypeGroups: <XTypeGroup>[
          XTypeGroup(label: 'JSON', extensions: ['json'])
        ],
      );
      if (open == null) return;
      final raw = await open.readAsString();
      await _remote.importJson(raw);

      // Sora-style: after importing, download enabled remotes so they work.
      await _remote.downloadAllEnabledRemote();

      if (!mounted) return;
      SnackBarExtension.show(context, 'Imported');
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      SnackBarExtension.show(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _moduleLeadingIcon(SourcesModuleDescriptor m) {
    final url = (m.meta?['iconUrl'] ?? m.meta?['icon'] ?? '').toString().trim();
    if (url.isEmpty) {
      return CircleAvatar(
          child: Text(m.name.isNotEmpty ? m.name[0].toUpperCase() : '?'));
    }
    return CircleAvatar(
      backgroundColor: Colors.transparent,
      foregroundImage: NetworkImage(url),
    );
  }

  static String _authorLine(SourcesModuleDescriptor m) {
    final meta = m.meta;
    final candidates = <Object?>[
      meta?['author'],
      meta?['authors'],
      meta?['developer'],
      meta?['dev'],
      meta?['creator'],
    ];
    for (final v in candidates) {
      if (v is String) {
        final t = v.trim();
        if (t.isNotEmpty) return t;
      }
      if (v is List) {
        final parts = v
            .map((e) => (e ?? '').toString().trim())
            .where((s) => s.isNotEmpty)
            .toList();
        if (parts.isNotEmpty) return parts.join(', ');
      }
    }
    return '';
  }

  static String _moduleSubtitle(SourcesModuleDescriptor m,
      {required bool isRemote}) {
    final type = (m.meta?['type'] ?? '').toString().trim();
    final lang =
        (m.meta?['language'] ?? m.meta?['lang'] ?? '').toString().trim();
    final version = (m.meta?['version'] ?? m.version ?? '').toString().trim();

    final parts = <String>[];
    if (type.isNotEmpty) parts.add(type);
    if (lang.isNotEmpty) parts.add(lang);
    if (version.isNotEmpty) parts.add('v$version');
    return parts.isEmpty ? '' : parts.join(' • ');
  }

  static String _subtitleLine(SourcesModuleDescriptor m) {
    final author = _authorLine(m);
    final info = _moduleSubtitle(m, isRemote: true);
    if (author.isNotEmpty && info.isNotEmpty) return '$author • $info';
    if (author.isNotEmpty) return author;
    return info;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: Future.wait([
        _remote.list(),
        _remote.buildDescriptors(includeDisabled: true),
      ]),
      builder: (context, snap) {
        final theming = Theming.of(context);
        final remoteList = (snap.data != null && snap.data!.isNotEmpty)
            ? (snap.data![0] as List<RemoteModuleEntry>)
            : const <RemoteModuleEntry>[];
        final remoteDescriptors = (snap.data != null && snap.data!.length > 1)
            ? (snap.data![1] as List<SourcesModuleDescriptor>)
            : const <SourcesModuleDescriptor>[];

        final descriptorById = <String, SourcesModuleDescriptor>{
          for (final d in remoteDescriptors) d.id: d,
        };

        final sortedRemote = [...remoteList]
          ..sort((a, b) => a.id.toLowerCase().compareTo(b.id.toLowerCase()));

        final urlText = _urlCtrl.text.trim();
        final canAdd = !_busy && urlText.isNotEmpty;

        // AdaptiveScaffold draws behind the TopBar; only use the safe inset.
        final topInset = MediaQuery.paddingOf(context).top + 4;

        // AdaptiveScaffold uses extendBody=true, so content can end up behind the
        // bottom navigation bar unless we add extra padding.
        final bottomInset = MediaQuery.paddingOf(context).bottom +
            (theming.formFactor == FormFactor.phone ? BottomBar.height : 0) +
            Theming.offset;

        return ListView(
          controller: widget.scrollCtrl,
          padding: EdgeInsets.only(
            left: Theming.offset,
            right: Theming.offset,
            bottom: bottomInset,
            top: topInset,
          ),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '  Add Sora-style modules by JSON URL',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 7),
                    TextField(
                      controller: _urlCtrl,
                      enabled: !_busy,
                      decoration: const InputDecoration(
                        labelText: 'Module JSON URL',
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (_) {
                        if (mounted) setState(() {});
                      },
                      onSubmitted: (_) => _addFromUrl(),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        FilledButton(
                          onPressed: canAdd ? _addFromUrl : null,
                          child: const Text('Add'),
                        ),
                        const Spacer(),
                        OutlinedButton(
                          onPressed: _busy ? null : _exportAll,
                          child: const Text('Export'),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton(
                          onPressed: _busy ? null : _importAll,
                          child: const Text('Import'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            if (sortedRemote.isEmpty) const Text('No remote modules added.'),
            for (final e in sortedRemote)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Card(
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 6,
                    ),
                    leading: () {
                      final d = descriptorById[e.id];
                      if (d != null) return _moduleLeadingIcon(d);
                      return CircleAvatar(
                          child: Text(
                              e.id.isNotEmpty ? e.id[0].toUpperCase() : '?'));
                    }(),
                    title: Text(descriptorById[e.id]?.name ?? e.id),
                    subtitle: () {
                      final d = descriptorById[e.id];
                      if (d == null) return null;
                      final s = _subtitleLine(d);
                      return s.isEmpty ? null : Text(s);
                    }(),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: 'Copy URL',
                          onPressed: _busy
                              ? null
                              : () async {
                                  await Clipboard.setData(
                                      ClipboardData(text: e.jsonUrl));
                                  if (!context.mounted) return;
                                  SnackBarExtension.show(context, 'Copied URL');
                                },
                          icon: const Icon(Icons.copy_rounded),
                        ),
                        IconButton(
                          tooltip: 'Update',
                          onPressed:
                              _busy ? null : () => _updateRemote(e.jsonUrl),
                          icon: const Icon(Icons.refresh),
                        ),
                        IconButton(
                          tooltip: 'Remove',
                          onPressed: _busy ? null : () => _removeRemote(e.id),
                          icon: const Icon(Icons.delete_outline),
                        ),
                        Switch(
                          value: e.enabled,
                          onChanged:
                              _busy ? null : (v) => _toggleRemote(e.id, v),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
