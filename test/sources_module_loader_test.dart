import 'package:animeshin/util/module_loader/remote_modules_store.dart';
import 'package:animeshin/util/module_loader/sources_module.dart';
import 'package:animeshin/util/module_loader/sources_module_loader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('loads index and modules via injected AssetStringReader', () async {
    final assets = <String, String>{
      'assets/sources/index.json': r'''
{
  "generatedAt": "x",
  "count": 1,
  "modules": [
    {
      "id": "demo",
      "jsonAsset": "assets/sources/demo/demo.json",
      "jsAsset": "assets/sources/demo/demo.js",
      "name": "Demo",
      "meta": {"name": "Demo"}
    }
  ]
}
''',
      'assets/sources/demo/demo.json': '{"name":"Demo","version":1}',
      'assets/sources/demo/demo.js': 'export const x = 1;',
    };

    final loader = SourcesModuleLoader(
      readAsset: (p) async {
        final v = assets[p];
        if (v == null) throw StateError('missing asset: $p');
        return v;
      },
      maxCacheEntries: 2,
    );

    final list = await loader.listModules();
    expect(list, hasLength(1));
    expect(list.single.id, 'demo');

    final loaded = await loader.loadModule('demo');
    expect(loaded.descriptor.name, 'Demo');
    expect(loaded.metaRaw, contains('"version"'));
    expect(loaded.script, contains('export'));

    // Cached
    final loaded2 = await loader.loadModule('demo');
    expect(identical(loaded, loaded2), isTrue);
  });

  test('throws on unknown module id', () async {
    final loader = SourcesModuleLoader(
      readAsset: (_) async => '{"generatedAt":"x","count":0,"modules":[]}',
    );

    expect(() => loader.loadModule('nope'), throwsStateError);
  });

  test('falls back to AssetManifest when index is empty', () async {
    final assets = <String, String>{
      'assets/sources/index.json': '{"generatedAt":"x","count":0,"modules":[]}',
      'AssetManifest.json': r'''
{
  "assets/sources/alpha/alpha.json": ["assets/sources/alpha/alpha.json"],
  "assets/sources/alpha/alpha.js": ["assets/sources/alpha/alpha.js"]
}
''',
      'assets/sources/alpha/alpha.json': '{"sourceName":"Alpha","version":"1.2"}',
      'assets/sources/alpha/alpha.js': 'export const ok = true;',
    };

    final loader = SourcesModuleLoader(
      readAsset: (p) async {
        final v = assets[p];
        if (v == null) throw StateError('missing asset: $p');
        return v;
      },
    );

    final list = await loader.listModules();
    expect(list, hasLength(1));
    expect(list.single.id, 'alpha');
    expect(list.single.name, 'Alpha');

    final loaded = await loader.loadModule('alpha');
    expect(loaded.descriptor.name, 'Alpha');
    expect(loaded.script, contains('export'));
  });

  test('loadIndex does not trigger blocking remote refresh', () async {
    final assets = <String, String>{
      'assets/sources/index.json': r'''
{
  "generatedAt": "x",
  "count": 1,
  "modules": [
    {
      "id": "demo",
      "jsonAsset": "assets/sources/demo/demo.json",
      "jsAsset": "assets/sources/demo/demo.js",
      "name": "Demo",
      "meta": {"name": "Demo"}
    }
  ]
}
''',
    };

    final remote = _LoaderFakeRemoteStore();
    final loader = SourcesModuleLoader(
      readAsset: (p) async {
        final v = assets[p];
        if (v == null) throw StateError('missing asset: $p');
        return v;
      },
      remoteStore: remote,
    );

    final list = await loader.listModules();
    expect(list, hasLength(1));
    expect(remote.downloadAllEnabledRemoteCalled, isFalse);
    expect(remote.buildDescriptorsCalls, 1);
  });
}

class _LoaderFakeRemoteStore extends RemoteModulesStore {
  bool downloadAllEnabledRemoteCalled = false;
  int buildDescriptorsCalls = 0;

  @override
  Future<void> downloadAllEnabledRemote({
    Duration perModuleTimeout = const Duration(seconds: 20),
    bool skipLoopbackHosts = false,
  }) async {
    downloadAllEnabledRemoteCalled = true;
  }

  @override
  Future<List<SourcesModuleDescriptor>> buildDescriptors({
    bool includeDisabled = false,
  }) async {
    buildDescriptorsCalls += 1;
    return const <SourcesModuleDescriptor>[];
  }

  @override
  Future<Set<String>> disabledModuleIds() async {
    return const <String>{};
  }
}
