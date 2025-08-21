// sameband_repository.dart
import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:html/parser.dart' as html_parser;

const samebandBase = 'https://sameband.studio';

/// Resolves a possibly relative href against Sameband base.
Uri _abs(String href) {
  final u = Uri.parse(href);
  return u.hasScheme ? u : Uri.parse(samebandBase).resolveUri(u);
}

/// Episode model for Sameband playlist items.
class SamebandEpisode {
  final String title;     // e.g., "Серия 01"
  final Uri? r480;        // 480p HLS (if present)
  final Uri? r720;        // 720p HLS (if present)
  final Uri? r1080;       // 1080p HLS (if present)
  final Uri? poster;      // Absolute poster URL if available
  final Duration? duration; // Parsed from "<div class=playlist_duration>HH:MM:SS</div>" if present

  const SamebandEpisode({
    required this.title,
    this.r480,
    this.r720,
    this.r1080,
    this.poster,
    this.duration,
  });

  Map<String, dynamic> toJson() => {
        'title': title,
        'r480': r480?.toString(),
        'r720': r720?.toString(),
        'r1080': r1080?.toString(),
        'poster': poster?.toString(),
        'duration': duration?.inSeconds,
      };
}

class SameBandRepository {
  SameBandRepository({
    this.defaultHeaders,
    this.timeout = const Duration(seconds: 20),
    this.userAgent =
        'AnimeShin/1.0 (+https://github.com/animeshin) DartHttpClient',
  });

  /// Default headers applied to all requests (e.g. Cookie: PHPSESSID=...).
  final Map<String, String>? defaultHeaders;

  /// Network timeout for all requests.
  final Duration timeout;

  /// User-Agent header to look more like a browser.
  final String userAgent;

  Map<String, String> _buildHeaders([Map<String, String>? headers]) {
    final h = <String, String>{
      // 'User-Agent': userAgent,
      'Accept': 'text/html,application/json;q=0.9,*/*;q=0.8',
    };
    if (defaultHeaders != null) h.addAll(defaultHeaders!);
    if (headers != null) h.addAll(headers);
    return h;
  }

  Future<String> _getText(Uri url, {Map<String, String>? headers}) async {
    final resp = await http.get(url, headers: _buildHeaders(headers)).timeout(timeout);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw http.ClientException('HTTP ${resp.statusCode} ${resp.reasonPhrase ?? ''}', url);
    }
    // Force UTF-8 to avoid mojibake when server omits charset
    return utf8.decode(resp.bodyBytes);
  }

  Future<String> _postMultipartText(
    Uri url, {
    required Map<String, String> fields,
    Map<String, String>? headers,
  }) async {
    final req = http.MultipartRequest('POST', url);
    req.headers.addAll(_buildHeaders(headers));
    fields.forEach((k, v) => req.fields[k] = v);
    final streamed = await req.send().timeout(timeout);
    final bytes = await streamed.stream.toBytes();
    final body = utf8.decode(bytes);
    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      throw http.ClientException(
        'HTTP ${streamed.statusCode} ${streamed.reasonPhrase ?? ''}',
        url,
      );
    }
    return body;
  }

  // ---------------------------------------------------------------------------
  // 1) Search: POST the search form and parse (title, url)
  // ---------------------------------------------------------------------------

  /// Searches Sameband by human title and returns [{title, url}, ...].
  ///
  /// Matches markup:
  ///   <article ...>
  ///     <div class="poster" title="...">
  ///       <a class="image" href="/anime/...html">
  ///         ...
  ///       </a>
  ///     </div>
  ///   </article>
  Future<List<Map<String, String>>> searchByTitle(
    String title, {
    Map<String, String>? headers,
  }) async {
    final url = Uri.parse('$samebandBase/');
    final html = await _postMultipartText(
      url,
      headers: headers,
      fields: {
        'story': title,
        'do': 'search',
        'subaction': 'search',
      },
    );

    final doc = html_parser.parse(html);
    final results = <Map<String, String>>[];

    for (final el in doc.querySelectorAll('article .poster')) {
      final titleAttr = el.attributes['title']?.trim();
      final href = el.querySelector('a.image')?.attributes['href']?.trim();
      if (href == null || href.isEmpty) continue;
      final abs = _abs(href).toString();
      results.add({
        'name': titleAttr ?? '',
        'url': abs,
      });
    }
    return results;
  }

  // ---------------------------------------------------------------------------
  // 2) From anime page → get iframe → convert to list.txt URL(s)
  // ---------------------------------------------------------------------------

  /// Extracts the player iframe src from anime detail page.
  Future<Uri?> _extractPlayerIframeSrc(
    String animePageUrl, {
    Map<String, String>? headers,
  }) async {
    final html = await _getText(Uri.parse(animePageUrl), headers: headers);
    final doc = html_parser.parse(html);
    final src =
        doc.querySelector('.player-block .player-content iframe')?.attributes['src']?.trim();
    if (src == null || src.isEmpty) return null;
    return _abs(src);
  }

  /// Converts "/v/play/NAME.html" → candidates:
  ///  1) https://sameband.studio/v/list/NAME_list.txt
  ///  2) https://sameband.studio/v/list/NAME(with underscores replaced by spaces)_list.txt
  List<Uri> _buildListCandidatesFromPlay(Uri iframeSrc) {
    // Take last segment without ".html"
    final last = iframeSrc.pathSegments.isEmpty
        ? ''
        : iframeSrc.pathSegments.last.replaceAll('.html', '');
    if (last.isEmpty) return const [];

    final withUnderscores =
        Uri.parse('$samebandBase/v/list/${last}_list.txt');

    final withSpaces =
        Uri.parse('$samebandBase/v/list/${last.replaceAll('_', ' ')}_list.txt');

    return [withUnderscores, withSpaces];
  }

  /// Returns the first reachable list.txt URL from the anime page.
  Future<Uri> getListUrlFromAnimePage(
    String animePageUrl, {
    Map<String, String>? headers,
  }) async {
    final iframe = await _extractPlayerIframeSrc(animePageUrl, headers: headers);
    if (iframe == null) {
      throw StateError('Player iframe not found on page: $animePageUrl');
    }
    final candidates = _buildListCandidatesFromPlay(iframe);
    if (candidates.isEmpty) {
      throw StateError('Cannot build list.txt from iframe: $iframe');
    }

    // Try candidates in order: first that returns 200 OK wins.
    for (final c in candidates) {
      try {
        final resp =
            await http.get(c, headers: _buildHeaders(headers)).timeout(timeout);
        if (resp.statusCode >= 200 && resp.statusCode < 300) {
          // We won't parse here; just return working URL.
          return c;
        }
      } catch (_) {
        // Ignore and try next
      }
    }
    throw StateError('No working list.txt URL for: $animePageUrl');
  }

  // ---------------------------------------------------------------------------
  // 3) Parse list.txt JSON → SamebandEpisode[]
  // ---------------------------------------------------------------------------

  /// Parses "HH:MM:SS" or "MM:SS" into Duration.
  Duration? _parseHms(String? text) {
    if (text == null || text.isEmpty) return null;
    final parts = text.split(':').map((e) => int.tryParse(e) ?? 0).toList();
    if (parts.length == 3) {
      return Duration(hours: parts[0], minutes: parts[1], seconds: parts[2]);
    } else if (parts.length == 2) {
      return Duration(minutes: parts[0], seconds: parts[1]);
    }
    return null;
  }

  /// Extracts poster URL and clean "Серия NN" text from the item's "title" HTML.
  (Uri? poster, String cleanTitle, Duration? duration) _parseTitleHtml(String html) {
    final doc = html_parser.parseFragment(html);

    // Poster <img src='...'>
    final imgSrc = doc.querySelector('img')?.attributes['src']?.trim();
    final poster = (imgSrc == null || imgSrc.isEmpty) ? null : _abs(imgSrc);

    // Duration inside <div class=playlist_duration>...</div>
    final durText = doc.querySelector('.playlist_duration')?.text.trim();
    final duration = _parseHms(durText);

    // Remaining text includes "Серия NN"
    // Get full text then remove duration value if present.
    var text = doc.text?.trim() ?? '';
    if (durText != null && durText.isNotEmpty) {
      text = text.replaceFirst(durText, '').trim();
    }
    // Typical result becomes "Серия 01"
    return (poster, text, duration);
  }

  /// Splits the "file" field (comma-separated) and returns map by quality tag.
  Map<String, Uri> _parseFileQualities(String fileField) {
    final out = <String, Uri>{};
    // Format example parts:
    //   [480p]/v/anime/.../Re Zero ... - 01 RUS_r480p.m3u8
    for (final raw in fileField.split(',')) {
      final part = raw.trim();
      final m = RegExp(r'^\[(\d{3,4}p)\](.+)$').firstMatch(part);
      if (m == null) continue;
      final q = m.group(1)!; // "480p" / "720p" / "1080p"
      final path = m.group(2)!.trim(); // "/v/anime/...m3u8"
      final url = _abs(path);
      out[q] = url;
    }
    return out;
  }

  /// Downloads list.txt and converts into SamebandEpisode[].
  Future<List<SamebandEpisode>> fetchPlaylistFromListUrl(
    Uri listUrl, {
    Map<String, String>? headers,
  }) async {
    final text = await _getText(listUrl, headers: headers);

    final body = json.decode(text);
    if (body is! List) {
      throw StateError('Unexpected list payload: ${body.runtimeType}');
    }

    final episodes = <SamebandEpisode>[];
    for (final it in body) {
      if (it is! Map<String, dynamic>) continue;

      final titleHtml = (it['title'] ?? '').toString();
      final fileField = (it['file'] ?? '').toString();

      final (poster, cleanTitle, duration) = _parseTitleHtml(titleHtml);
      Uri? r480, r720, r1080;

      if (fileField.isNotEmpty) {
        final q = _parseFileQualities(fileField);
        r480 = q['480p'];
        r720 = q['720p'];
        r1080 = q['1080p'];
      }

      episodes.add(SamebandEpisode(
        title: cleanTitle.isEmpty ? '' : cleanTitle,
        r480: r480,
        r720: r720,
        r1080: r1080,
        poster: poster,
        duration: duration,
      ));
    }
    return episodes;
  }

  /// Full flow: page → list.txt → episodes.
  Future<List<SamebandEpisode>> fetchPlaylistByAnimePage(
    String animePageUrl, {
    Map<String, String>? headers,
  }) async {
    final listUrl = await getListUrlFromAnimePage(animePageUrl, headers: headers);
    return fetchPlaylistFromListUrl(listUrl, headers: headers);
  }
}
