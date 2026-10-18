import 'dart:io';
import 'dart:typed_data';

import '../core/core.dart';

/// Compares a local difficulty with the one on the osu! website
/// (`https://osu.ppy.sh/osu/<beatmapId>`, the public .osu download).
class MapUpdateChecker {
  /// Tests replace the download.
  static Future<Uint8List?> Function(int beatmapId)? debugFetch;

  /// Downloads the official .osu of [beatmapId]; null when the website has no
  /// such file (not submitted / deleted).
  static Future<Uint8List?> fetch(int beatmapId) async {
    final hook = debugFetch;
    if (hook != null) return hook(beatmapId);
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.getUrl(Uri.parse('https://osu.ppy.sh/osu/$beatmapId'));
      req.headers.set(HttpHeaders.userAgentHeader, 'osuEdit');
      final res = await req.close().timeout(const Duration(seconds: 15));
      if (res.statusCode == 404) return null;
      if (res.statusCode != 200) throw HttpException('osu! answered ${res.statusCode}');
      final out = BytesBuilder(copy: false);
      await for (final chunk in res.timeout(const Duration(seconds: 20))) {
        out.add(chunk);
      }
      return out.takeBytes();
    } finally {
      client.close(force: true);
    }
  }

  /// Whether [local] and [remote] hold different beatmaps; line endings and
  /// trailing whitespace don't count.
  static bool differs(Uint8List local, Uint8List remote) => _normalize(local) != _normalize(remote);

  static String _normalize(Uint8List bytes) {
    final (text, _) = OsuTextCodec.decode(bytes);
    final lines = text.replaceAll('\r\n', '\n').split('\n').map((l) => l.trimRight()).toList();
    while (lines.isNotEmpty && lines.last.isEmpty) {
      lines.removeLast();
    }
    return lines.join('\n');
  }
}
