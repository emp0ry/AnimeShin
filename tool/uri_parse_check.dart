void main() {
  const url = 'https://api.cdnlibs.org/api/anime?fields[]=rate_avg&fields[]=rate&fields[]=releaseDate&q=naruto';
  try {
    final uri = Uri.parse(url);
     // ignore: avoid_print
     print('OK: ${uri.toString()}');
  } catch (e) {
     // ignore: avoid_print
     print('ERR: $e');
  }
}
