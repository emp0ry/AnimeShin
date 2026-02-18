import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:hive/hive.dart';

import 'package:animeshin/extension/snack_bar_extension.dart';
import 'package:animeshin/feature/export/save_and_share.dart';
import 'package:animeshin/util/module_loader/remote_modules_store.dart';
import 'package:animeshin/util/module_loader/sources_module_loader.dart';
import 'package:animeshin/util/module_loader/sources_module.dart';
import 'package:animeshin/util/module_loader/js_sources_runtime.dart';
import 'package:animeshin/util/theming.dart';
import 'package:animeshin/widget/cached_image.dart';
import 'package:animeshin/widget/layout/navigation_tool.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
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
  final _loader = sharedSourcesModuleLoader;

  bool _busy = false;
  static const String _exportFileName = 'animeshin_extensions.json';

  static const String _legalBoxName = 'legal_flags';
  static const String _extensionsDisclaimerKey = 'extensions_disclaimer_shown_v1';

  XTypeGroup _jsonTypeGroup() {
    return const XTypeGroup(
      label: 'JSON',
      extensions: ['json'],
      uniformTypeIdentifiers: ['public.json'],
      mimeTypes: ['application/json'],
    );
  }

  Future<void> _maybeShowExtensionsDisclaimer() async {
    try {
      final box = await Hive.openBox(_legalBoxName);
      final shown = box.get(_extensionsDisclaimerKey, defaultValue: false) as bool;
      if (shown) return;
      if (!mounted) return;

      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
        title: const Text(
          'Extensions & External Services',
          textAlign: TextAlign.center,
          style: TextStyle(fontWeight: FontWeight.bold),
        ),

        content: const Text(
          'AnimeShin does not include any built-in content sources.\n\n'
          'Extensions are optional and user-configured. They may connect to third-party services directly from your device.\n\n'
          'You are responsible for the sources you add and for complying with local laws.',
          textAlign: TextAlign.center,
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
        ),
      );

      await box.put(_extensionsDisclaimerKey, true);
    } catch (_) {
      // Don't block the UI if persistence fails.
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeShowExtensionsDisclaimer();
    });
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    _loader.clearCache();
    _loader.invalidateIndex();
    setState(() {});
  }

  Future<void> _addFromUrl() async {
    if (_busy) return;

    final url = _urlCtrl.text.trim();
    if (url.isEmpty) {
      SnackBarExtension.show(context, 'Paste an extension JSON URL');
      return;
    }

    final uri = Uri.tryParse(url);
    final isHttp = uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
    if (!isHttp) {
      SnackBarExtension.show(context, 'Invalid URL. Use http(s)://');
      return;
    }

    setState(() => _busy = true);
    try {
      // Prevent indefinite hangs on bad hosts / stalled connections
      final desc = await _remote
          .addOrUpdateFromUrl(url, enabled: true)
          .timeout(const Duration(seconds: 12));

      await JsSourcesRuntime.instance.invalidateModule(desc.id);
      _urlCtrl.clear();

      if (!mounted) return;
      SnackBarExtension.show(context, 'Extension added');
      await _refresh();
    } on TimeoutException {
      if (!mounted) return;
      SnackBarExtension.show(context, 'Request timed out. Check the URL and try again.');
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
      await JsSourcesRuntime.instance.invalidateModule(id);
      if (!mounted) return;
      SnackBarExtension.show(context, 'Extension removed');
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
      final desc = await _remote.addOrUpdateFromUrl(url, enabled: true);
      await JsSourcesRuntime.instance.invalidateModule(desc.id);
      if (!mounted) return;
      SnackBarExtension.show(context, 'Extension updated');
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
      final bytes = Uint8List.fromList(utf8.encode(raw));

      // Compute UI objects now (before awaiting) so we don't use `context`
      // across async gaps. The saved helper will not touch BuildContext.
      // Guard with mounted before using context for UI objects
      if (!mounted) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      final origin = computeShareOrigin(context);

      final savedPath = await saveBytesChooseLocationNoContext(
        origin,
        messenger,
        filename: _exportFileName,
        bytes: bytes,
        mimeType: 'application/json',
        fileExtension: 'json',
        shareText: 'AnimeShin extensions export',
      );
      if (!mounted) return;
      final didShare = !kIsWeb && Platform.isIOS;
      if (savedPath == null && !didShare) return;
      final msg = (savedPath != null && savedPath.isNotEmpty)
          ? 'Exported to: $savedPath'
          : 'Export file shared';
      messenger?.showSnackBar(SnackBar(content: Text(msg)));
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
          _jsonTypeGroup(),
        ],
      );
      if (open == null) return;
      final raw = await open.readAsString();
      await _remote.importJson(raw);

      // After importing, download enabled remote entries so they are available offline.
      await _remote.downloadAllEnabledRemote();

      if (!mounted) return;
      SnackBarExtension.show(context, 'Imported extensions');
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      SnackBarExtension.show(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _moduleLeadingIcon(SourcesModuleDescriptor m) {
    final url = (m.meta?['iconUrl'] ?? m.meta?['iconURL'] ?? m.meta?['icon'] ?? '').toString().trim();
    if (url.isEmpty) {
      return CircleAvatar(
          child: Text(m.name.isNotEmpty ? m.name[0].toUpperCase() : '?'));
    }
    return CircleAvatar(
      backgroundColor: Colors.transparent,
      child: ClipOval(
        child: CachedImage(
          url,
          width: 40,
          height: 40,
          fit: BoxFit.cover,
        ),
      ),
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
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: Text(
                        'Paste an extension JSON URL',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                    const SizedBox(height: 7),
                    TextField(
                      controller: _urlCtrl,
                      enabled: !_busy,
                      decoration: const InputDecoration(
                        labelText: 'Extension JSON URL',
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (_) {
                        if (mounted) setState(() {});
                      },
                      onSubmitted: (_) => canAdd ? _addFromUrl() : null,
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      alignment: WrapAlignment.start,
                      children: [
                        FilledButton(
                          onPressed: canAdd ? _addFromUrl : null,
                          child: const Text('Add'),
                        ),
                        OutlinedButton(
                          onPressed: _busy ? null : _exportAll,
                          child: const Text('Export'),
                        ),
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
            if (sortedRemote.isEmpty) const Text('No extensions added yet.'),
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
                    isThreeLine: descriptorById[e.id] != null,
                    title: Text(
                      descriptorById[e.id]?.name ?? e.id,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),

                    subtitle: () {
                      final d = descriptorById[e.id];
                      if (d == null) return null;
                      final s = _subtitleLine(d);

                      return s.isEmpty
                          ? null
                          : Text(
                              s,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            );
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
