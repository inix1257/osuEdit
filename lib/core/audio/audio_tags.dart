import 'dart:convert';
import 'dart:typed_data';

/// Title / artist from an audio file's tags (ID3v2.2–2.4, else ID3v1), for
/// prefilling a new map's metadata like osu!stable does. Empty when absent.
class AudioTags {
  final String title;
  final String artist;
  const AudioTags({this.title = '', this.artist = ''});

  static AudioTags read(Uint8List bytes) {
    final v2 = _readId3v2(bytes);
    if (v2 != null && (v2.title.isNotEmpty || v2.artist.isNotEmpty)) return v2;
    return _readId3v1(bytes) ?? const AudioTags();
  }

  static AudioTags? _readId3v2(Uint8List b) {
    if (b.length < 10 || b[0] != 0x49 || b[1] != 0x44 || b[2] != 0x33) return null;
    final version = b[3];
    if (version < 2 || version > 4) return null;
    int syncsafe(int i) => (b[i] & 0x7F) << 21 | (b[i + 1] & 0x7F) << 14 | (b[i + 2] & 0x7F) << 7 | (b[i + 3] & 0x7F);
    final end = (10 + syncsafe(6)).clamp(10, b.length);
    var i = 10;
    // Extended header (2.3: plain size without itself, 2.4: syncsafe with itself).
    if (b[5] & 0x40 != 0 && version >= 3 && i + 4 <= end) {
      i += version == 4 ? syncsafe(i) : (b[i] << 24 | b[i + 1] << 16 | b[i + 2] << 8 | b[i + 3]) + 4;
    }
    final idLen = version == 2 ? 3 : 4, headLen = version == 2 ? 6 : 10;
    final titleId = version == 2 ? 'TT2' : 'TIT2', artistId = version == 2 ? 'TP1' : 'TPE1';
    var title = '', artist = '';
    while (i + headLen <= end) {
      if (b[i] == 0) break; // padding
      final id = String.fromCharCodes(b, i, i + idLen);
      final size = switch (version) {
        2 => b[i + 3] << 16 | b[i + 4] << 8 | b[i + 5],
        3 => b[i + 4] << 24 | b[i + 5] << 16 | b[i + 6] << 8 | b[i + 7],
        _ => syncsafe(i + 4),
      };
      final start = i + headLen;
      if (size <= 0 || start + size > end) break;
      if (id == titleId) title = _text(b, start, start + size);
      if (id == artistId) artist = _text(b, start, start + size);
      i = start + size;
    }
    return AudioTags(title: title, artist: artist);
  }

  /// A text frame: encoding byte, then the text (first value only).
  static String _text(Uint8List b, int start, int end) {
    if (start >= end) return '';
    final enc = b[start];
    final data = Uint8List.sublistView(b, start + 1, end);
    String s;
    switch (enc) {
      case 1 || 2:
        var bigEndian = enc == 2, from = 0;
        if (data.length >= 2 && data[0] == 0xFF && data[1] == 0xFE) {
          bigEndian = false;
          from = 2;
        } else if (data.length >= 2 && data[0] == 0xFE && data[1] == 0xFF) {
          bigEndian = true;
          from = 2;
        }
        final units = <int>[];
        for (var k = from; k + 1 < data.length; k += 2) {
          units.add(bigEndian ? data[k] << 8 | data[k + 1] : data[k] | data[k + 1] << 8);
        }
        s = String.fromCharCodes(units);
      case 3:
        s = utf8.decode(data, allowMalformed: true);
      default:
        s = latin1.decode(data);
    }
    final nul = s.indexOf('\u0000');
    return (nul >= 0 ? s.substring(0, nul) : s).trim();
  }

  static AudioTags? _readId3v1(Uint8List b) {
    if (b.length < 128) return null;
    final t = b.length - 128;
    if (b[t] != 0x54 || b[t + 1] != 0x41 || b[t + 2] != 0x47) return null;
    String field(int from, int len) {
      final s = latin1.decode(Uint8List.sublistView(b, t + from, t + from + len));
      final nul = s.indexOf('\u0000');
      return (nul >= 0 ? s.substring(0, nul) : s).trim();
    }

    return AudioTags(title: field(3, 30), artist: field(33, 30));
  }
}
