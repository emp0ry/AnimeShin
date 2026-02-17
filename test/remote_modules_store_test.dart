import 'package:animeshin/util/module_loader/remote_modules_store.dart';
import 'package:animeshin/util/module_loader/sources_module.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('downloadAllEnabledRemote skips loopback hosts when requested', () async {
    final store = _FakeRemoteModulesStore(
      entries: <RemoteModuleEntry>[
        RemoteModuleEntry(
          id: 'local-a',
          jsonUrl: 'http://localhost/a.json',
          enabled: true,
          updatedAt: DateTime.utc(2025, 1, 1),
        ),
        RemoteModuleEntry(
          id: 'local-b',
          jsonUrl: 'http://127.0.0.1/b.json',
          enabled: true,
          updatedAt: DateTime.utc(2025, 1, 1),
        ),
        RemoteModuleEntry(
          id: 'local-c',
          jsonUrl: 'http://[::1]/c.json',
          enabled: true,
          updatedAt: DateTime.utc(2025, 1, 1),
        ),
        RemoteModuleEntry(
          id: 'remote',
          jsonUrl: 'https://example.com/ok.json',
          enabled: true,
          updatedAt: DateTime.utc(2025, 1, 1),
        ),
        RemoteModuleEntry(
          id: 'disabled',
          jsonUrl: 'https://example.com/disabled.json',
          enabled: false,
          updatedAt: DateTime.utc(2025, 1, 1),
        ),
      ],
    );

    await store.downloadAllEnabledRemote(skipLoopbackHosts: true);

    expect(store.addCalls, <String>['https://example.com/ok.json']);
  });

  test('per-module timeout does not abort whole refresh batch', () async {
    final store = _FakeRemoteModulesStore(
      entries: <RemoteModuleEntry>[
        RemoteModuleEntry(
          id: 'slow',
          jsonUrl: 'https://slow.example/slow.json',
          enabled: true,
          updatedAt: DateTime.utc(2025, 1, 1),
        ),
        RemoteModuleEntry(
          id: 'fast',
          jsonUrl: 'https://fast.example/fast.json',
          enabled: true,
          updatedAt: DateTime.utc(2025, 1, 1),
        ),
      ],
      onAdd: (url) async {
        if (url.contains('slow.example')) {
          await Future<void>.delayed(const Duration(milliseconds: 120));
          return;
        }
      },
    );

    await store.downloadAllEnabledRemote(
      perModuleTimeout: const Duration(milliseconds: 20),
    );

    expect(
      store.addCalls,
      <String>[
        'https://slow.example/slow.json',
        'https://fast.example/fast.json',
      ],
    );
  });
}

class _FakeRemoteModulesStore extends RemoteModulesStore {
  _FakeRemoteModulesStore({
    required this.entries,
    this.onAdd,
  });

  final List<RemoteModuleEntry> entries;
  final Future<void> Function(String url)? onAdd;
  final List<String> addCalls = <String>[];

  @override
  Future<List<RemoteModuleEntry>> list() async {
    return entries;
  }

  @override
  Future<SourcesModuleDescriptor> addOrUpdateFromUrl(
    String jsonUrl, {
    bool enabled = true,
  }) async {
    addCalls.add(jsonUrl);
    if (onAdd != null) {
      await onAdd!(jsonUrl);
    }

    return SourcesModuleDescriptor(
      id: 'fake-${addCalls.length}',
      jsonAsset: '/tmp/fake.json',
      jsAsset: '/tmp/fake.js',
      name: 'Fake',
    );
  }
}
