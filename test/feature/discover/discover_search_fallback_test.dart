import 'package:animeshin/feature/discover/discover_search_fallback.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AniList non-empty: Shikimori fallback not called', () async {
    var shikiCalls = 0;
    var retryCalls = 0;

    final result = await runDiscoverSearchFallback<List<String>>(
      page: 1,
      originalQuery: 'jujutsu',
      initialResult: <String>['hit'],
      isEmpty: (v) => v.isEmpty,
      retry: (query) async {
        retryCalls += 1;
        return <String>[query];
      },
      localVariants: const <String>['variant'],
      shikimoriCandidates: (query) async {
        shikiCalls += 1;
        return <String>['shiki'];
      },
    );

    expect(result.result, <String>['hit']);
    expect(result.chosenCandidate, isNull);
    expect(result.usedShikimoriCandidate, isFalse);
    expect(retryCalls, 0);
    expect(shikiCalls, 0);
  });

  test('first page empty: requests Shikimori candidates and retries', () async {
    var shikiCalls = 0;
    final tried = <String>[];

    final result = await runDiscoverSearchFallback<List<String>>(
      page: 1,
      originalQuery: 'jujutsu',
      initialResult: const <String>[],
      isEmpty: (v) => v.isEmpty,
      retry: (query) async {
        tried.add(query);
        return query == 'Jujutsu Kaisen'
            ? <String>['found']
            : const <String>[];
      },
      localVariants: const <String>['jujutsu season 3'],
      shikimoriCandidates: (query) async {
        shikiCalls += 1;
        return <String>['Jujutsu Kaisen', 'Sorcery Fight'];
      },
    );

    expect(shikiCalls, 1);
    expect(tried, contains('jujutsu season 3'));
    expect(tried, contains('Jujutsu Kaisen'));
    expect(result.result, <String>['found']);
    expect(result.chosenCandidate, 'Jujutsu Kaisen');
    expect(result.usedShikimoriCandidate, isTrue);
  });

  test('non-first page: fallback not triggered', () async {
    var shikiCalls = 0;
    var retryCalls = 0;

    final result = await runDiscoverSearchFallback<List<String>>(
      page: 2,
      originalQuery: 'jujutsu',
      initialResult: const <String>[],
      isEmpty: (v) => v.isEmpty,
      retry: (query) async {
        retryCalls += 1;
        return const <String>[];
      },
      localVariants: const <String>['variant'],
      shikimoriCandidates: (query) async {
        shikiCalls += 1;
        return <String>['shiki'];
      },
    );

    expect(result.result, isEmpty);
    expect(result.chosenCandidate, isNull);
    expect(retryCalls, 0);
    expect(shikiCalls, 0);
  });
}
