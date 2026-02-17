import 'package:animeshin/util/module_loader/js_module_executor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('probeVoiceovers uses dedicated voiceover path when available', () async {
    final exec = _FakeProbeExecutor(
      directVoiceovers: <String>['Sub', 'Dub'],
      selection: const JsStreamSelection(streams: <JsStreamCandidate>[]),
    );

    final probe = await exec.probeVoiceovers('demo', 'https://example.com/ep1');

    expect(probe.voiceoverTitles, <String>['Sub', 'Dub']);
    expect(probe.prefetchedSelection, isNull);
    expect(exec.extractStreamsCalls, 0);
    expect(exec.allowInferenceFallbackCalls, <bool>[false]);
  });

  test('probeVoiceovers falls back to stream inference and returns prefetch', () async {
    final prefetched = JsStreamSelection(
      streams: <JsStreamCandidate>[
        const JsStreamCandidate(
          title: 'Sub | 1080p',
          streamUrl: 'https://cdn.example/sub.m3u8',
        ),
        const JsStreamCandidate(
          title: 'Dub 720p',
          streamUrl: 'https://cdn.example/dub.m3u8',
        ),
        const JsStreamCandidate(
          title: '1080p',
          streamUrl: 'https://cdn.example/q.m3u8',
        ),
      ],
      subtitleUrl: 'https://cdn.example/subs.vtt',
    );
    final exec = _FakeProbeExecutor(
      directVoiceovers: const <String>[],
      selection: prefetched,
    );

    final probe = await exec.probeVoiceovers('demo', 'https://example.com/ep1');

    expect(exec.extractStreamsCalls, 1);
    expect(exec.allowInferenceFallbackCalls, <bool>[false]);
    expect(probe.voiceoverTitles, <String>['Sub | 1080p', 'Dub 720p']);
    expect(probe.prefetchedSelection, isNotNull);
    expect(identical(probe.prefetchedSelection, prefetched), isTrue);
  });

  test('probeVoiceovers returns empty result when inferred streams are empty', () async {
    final exec = _FakeProbeExecutor(
      directVoiceovers: const <String>[],
      selection: const JsStreamSelection(streams: <JsStreamCandidate>[]),
    );

    final probe = await exec.probeVoiceovers('demo', 'https://example.com/ep1');

    expect(exec.extractStreamsCalls, 1);
    expect(probe.voiceoverTitles, isEmpty);
    expect(probe.prefetchedSelection, isNull);
  });
}

class _FakeProbeExecutor extends JsModuleExecutor {
  _FakeProbeExecutor({
    required this.directVoiceovers,
    required this.selection,
  });

  final List<String> directVoiceovers;
  final JsStreamSelection selection;

  final List<bool> allowInferenceFallbackCalls = <bool>[];
  int extractStreamsCalls = 0;

  @override
  Future<List<String>> getVoiceovers(
    String moduleId,
    String episodeHref, {
    bool allowInferenceFallback = true,
  }) async {
    allowInferenceFallbackCalls.add(allowInferenceFallback);
    return directVoiceovers;
  }

  @override
  Future<JsStreamSelection> extractStreams(
    String moduleId,
    String episodeHref, {
    String? voiceover,
  }) async {
    extractStreamsCalls += 1;
    return selection;
  }
}
