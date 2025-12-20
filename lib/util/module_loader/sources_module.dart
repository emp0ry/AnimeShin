import 'dart:convert';

class SourcesModuleDescriptor {
  const SourcesModuleDescriptor({
    required this.id,
    required this.jsonAsset,
    required this.jsAsset,
    required this.name,
    this.version,
    this.lang,
    this.meta,
  });

  final String id;
  final String jsonAsset;
  final String jsAsset;

  final String name;
  final Object? version;
  final Object? lang;

  /// Entire metadata JSON (schema-agnostic).
  final Map<String, dynamic>? meta;

  factory SourcesModuleDescriptor.fromJson(Map<String, dynamic> json) {
    return SourcesModuleDescriptor(
      id: (json['id'] as String?) ?? '',
      jsonAsset: (json['jsonAsset'] as String?) ?? '',
      jsAsset: (json['jsAsset'] as String?) ?? '',
      name: (json['name'] as String?) ?? (json['id'] as String? ?? ''),
      version: json['version'],
      lang: json['lang'],
      meta: (json['meta'] is Map)
          ? (json['meta'] as Map).cast<String, dynamic>()
          : null,
    );
  }
}

class SourcesIndex {
  const SourcesIndex({
    required this.generatedAt,
    required this.count,
    required this.modules,
  });

  final String generatedAt;
  final int count;
  final List<SourcesModuleDescriptor> modules;

  factory SourcesIndex.fromJsonString(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      return const SourcesIndex(generatedAt: '', count: 0, modules: []);
    }

    final modulesRaw = decoded['modules'];
    final modules = <SourcesModuleDescriptor>[];
    if (modulesRaw is List) {
      for (final item in modulesRaw) {
        if (item is Map) {
          modules.add(
            SourcesModuleDescriptor.fromJson(item.cast<String, dynamic>()),
          );
        }
      }
    }

    return SourcesIndex(
      generatedAt: (decoded['generatedAt'] as String?) ?? '',
      count: (decoded['count'] as int?) ?? modules.length,
      modules: modules,
    );
  }
}
