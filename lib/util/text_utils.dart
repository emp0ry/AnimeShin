
// lib/util/text_utils.dart
/// Text normalization utilities for robust matching between AniList and Anilibria/AniLiberty.
String stripDiacritics(String input) {
  if (input.isEmpty) return input;
  const Map<String, String> map = {
    // Latin-1
    'à':'a','á':'a','â':'a','ä':'a','ã':'a','å':'a','ā':'a','ă':'a','ą':'a','ǎ':'a','æ':'ae',
    'ç':'c','ć':'c','č':'c','ĉ':'c','ċ':'c',
    'ď':'d','đ':'d',
    'è':'e','é':'e','ê':'e','ë':'e','ē':'e','ĕ':'e','ė':'e','ę':'e','ě':'e',
    'ƒ':'f',
    'ĝ':'g','ğ':'g','ġ':'g','ģ':'g',
    'ĥ':'h','ħ':'h',
    'ì':'i','í':'i','î':'i','ï':'i','ĩ':'i','ī':'i','ĭ':'i','į':'i','ı':'i','ǐ':'i',
    'ñ':'n','ń':'n','ň':'n','ņ':'n','ŋ':'n',
    'ò':'o','ó':'o','ô':'o','ö':'o','õ':'o','ō':'o','ŏ':'o','ő':'o','œ':'oe','ǒ':'o',
    'ŕ':'r','ř':'r','ŗ':'r',
    'ś':'s','š':'s','ş':'s','ŝ':'s','ș':'s',
    'ť':'t','ţ':'t','ŧ':'t','ț':'t',
    'ù':'u','ú':'u','û':'u','ü':'u','ũ':'u','ū':'u','ŭ':'u','ů':'u','ű':'u','ų':'u','ǔ':'u',
    'ŵ':'w',
    'ý':'y','ÿ':'y','ŷ':'y',
    'ź':'z','ž':'z','ż':'z',
    // Uppercase (just in case)
    'À':'A','Á':'A','Â':'A','Ä':'A','Ã':'A','Å':'A','Ā':'A','Ă':'A','Ą':'A','Ǎ':'A','Æ':'AE',
    'Ç':'C','Ć':'C','Č':'C','Ĉ':'C','Ċ':'C',
    'Ď':'D','Đ':'D',
    'È':'E','É':'E','Ê':'E','Ë':'E','Ē':'E','Ĕ':'E','Ė':'E','Ę':'E','Ě':'E',
    'Ĝ':'G','Ğ':'G','Ġ':'G','Ģ':'G',
    'Ĥ':'H','Ħ':'H',
    'Ì':'I','Í':'I','Î':'I','Ï':'I','Ĩ':'I','Ī':'I','Ĭ':'I','Į':'I','İ':'I','Ǐ':'I',
    'Ñ':'N','Ń':'N','Ň':'N','Ņ':'N','Ŋ':'N',
    'Ò':'O','Ó':'O','Ô':'O','Ö':'O','Õ':'O','Ō':'O','Ŏ':'O','Ő':'O','Œ':'OE','Ǒ':'O',
    'Ŕ':'R','Ř':'R','Ŗ':'R',
    'Ś':'S','Š':'S','Ş':'S','Ŝ':'S','Ș':'S',
    'Ť':'T','Ţ':'T','Ŧ':'T','Ț':'T',
    'Ù':'U','Ú':'U','Û':'U','Ü':'U','Ũ':'U','Ū':'U','Ŭ':'U','Ů':'U','Ű':'U','Ų':'U','Ǔ':'U',
    'Ŵ':'W',
    'Ý':'Y','Ÿ':'Y','Ŷ':'Y',
    'Ź':'Z','Ž':'Z','Ż':'Z',
    'ß':'ss'
  };
  final StringBuffer sb = StringBuffer();
  for (final ch in input.runes) {
    final s = String.fromCharCode(ch);
    sb.write(map[s] ?? s);
  }
  return sb.toString();
}

/// Returns a string suitable for equality/contains comparisons.
String normalizeForCompare(String input) {
  final d = stripDiacritics(input).toLowerCase();
  return d.replaceAll(RegExp(r'[^a-z0-9]+'), '');
}

/// Kebab-case alias used by Anilibria (lowercase ASCII; non-alnum -> '-'; trim dashes).
String toKebabAlias(String input) {
  final d = stripDiacritics(input).toLowerCase();
  final k = d.replaceAll(RegExp(r'[^a-z0-9]+'), '-');
  return k.replaceAll(RegExp(r'^-+|-+$'), '');
}

/// Tokenizes into a..z0..9 words for fuzzy comparison.
List<String> tokenize(String input) {
  final d = stripDiacritics(input).toLowerCase();
  return RegExp(r'[a-z0-9]+').allMatches(d).map((m) => m.group(0)!).toList();
}

/// Simple Jaccard similarity between token sets [0..1].
double tokenOverlapScore(String a, String b) {
  final sa = tokenize(a).toSet();
  final sb = tokenize(b).toSet();
  if (sa.isEmpty || sb.isEmpty) return 0.0;
  final inter = sa.intersection(sb).length;
  final uni = sa.union(sb).length;
  return inter / uni;
}

int? extractNumberAfter(String text, List<String> keys) {
  final t = stripDiacritics(text).toLowerCase();
  for (final k in keys) {
    final re = RegExp(r'\b' + RegExp.escape(k) + r'\s*(\d+)\b');
    final m = re.firstMatch(t);
    if (m != null) return int.tryParse(m.group(1)!);
  }
  return null;
}

int? extractYear(String text) {
  final m = RegExp(r'\b(19|20)\d{2}\b').firstMatch(text);
  return m != null ? int.tryParse(m.group(0)!) : null;
}

enum TitleKind { tv, movie, ova, ona, special, unknown }

TitleKind classifyKind(String text) {
  final t = stripDiacritics(text).toLowerCase();
  if (RegExp(r'\b(movie|film)\b').hasMatch(t)) return TitleKind.movie;
  if (RegExp(r'\b(ova)\b').hasMatch(t)) return TitleKind.ova;
  if (RegExp(r'\b(ona)\b').hasMatch(t)) return TitleKind.ona;
  if (RegExp(r'\b(special)\b').hasMatch(t)) return TitleKind.special;
  return TitleKind.tv;
}