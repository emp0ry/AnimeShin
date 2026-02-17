import 'package:animeshin/feature/discover/discover_enrichment_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('cache hit avoids repeated fetch for same MAL ids', () async {
    final controller = DiscoverTitleEnrichmentController();
    var fetchCalls = 0;

    Future<Map<int, DiscoverRuTitleInfo>> fetchMissing(List<int> missing) async {
      fetchCalls += 1;
      return <int, DiscoverRuTitleInfo>{
        for (final id in missing)
          id: (
            russian: 'RU $id',
            shikimoriRomaji: 'Shiki $id',
          ),
      };
    }

    final first = await controller.resolve(<int>[1, 2], fetchMissing: fetchMissing);
    final second =
        await controller.resolve(<int>[1, 2], fetchMissing: fetchMissing);

    expect(fetchCalls, 1);
    expect(first[1]?.russian, 'RU 1');
    expect(second[2]?.shikimoriRomaji, 'Shiki 2');
  });

  test('epoch guard marks stale async work as outdated', () {
    final controller = DiscoverTitleEnrichmentController();

    final oldEpoch = controller.beginEpoch();
    final newEpoch = controller.beginEpoch();

    expect(controller.isCurrent(oldEpoch), isFalse);
    expect(controller.isCurrent(newEpoch), isTrue);
  });
}
