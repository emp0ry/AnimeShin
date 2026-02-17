import 'package:animeshin/feature/discover/discover_model.dart';

String discoverPrimaryTitle(DiscoverMediaItem item) => item.name;

String? discoverSecondaryTitle(
  DiscoverMediaItem item, {
  required bool showRussianTitle,
}) {
  if (!showRussianTitle) return null;

  String? pick(String? v) {
    final t = v?.trim();
    return (t == null || t.isEmpty) ? null : t;
  }

  final primary = discoverPrimaryTitle(item).trim().toLowerCase();
  final secondary = pick(item.titleRussian) ?? pick(item.titleShikimoriRomaji);
  if (secondary == null) return null;
  if (secondary.toLowerCase() == primary) return null;

  return secondary;
}
