import 'dart:typed_data';

import 'detailed_waveform.dart' show id3v2Size;

/// Where a time falls in an MP3 (Layer III) file, found by hopping frame
/// headers (no decoding): lets a player start mid-song from a byte offset
/// instead of seeking, which for a streamed MP3 means decoding or scanning
/// every frame before it.
class Mp3Position {
  /// Byte offset of the frame to start decoding at.
  final int offset;

  /// Time (ms) of that frame's start: the wanted time is this plus a
  /// little (at most a few frames).
  final double frameTime;

  /// Length of the whole song (ms).
  final double totalTime;

  const Mp3Position(this.offset, this.frameTime, this.totalTime);
}

class Mp3Frames {
  static const _bitratesV1 = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320];
  static const _bitratesV2 = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160];
  static const _rates = [
    [11025, 12000, 8000], // MPEG 2.5
    <int>[], // reserved
    [22050, 24000, 16000], // MPEG 2
    [44100, 48000, 32000], // MPEG 1
  ];

  /// (frame length in bytes, ms) of a Layer III frame header at [i], or null.
  static (int, double)? _frame(Uint8List b, int i) {
    if (i + 4 > b.length || b[i] != 0xFF || b[i + 1] & 0xE0 != 0xE0) return null;
    final version = b[i + 1] >> 3 & 3, layer = b[i + 1] >> 1 & 3;
    if (version == 1 || layer != 1) return null;
    final bitrateIndex = b[i + 2] >> 4, rateIndex = b[i + 2] >> 2 & 3;
    if (bitrateIndex == 0 || bitrateIndex == 15 || rateIndex == 3) return null;
    final v1 = version == 3;
    final bitrate = (v1 ? _bitratesV1 : _bitratesV2)[bitrateIndex] * 1000;
    final rate = _rates[version][rateIndex];
    final padding = b[i + 2] >> 1 & 1;
    final length = (v1 ? 144 : 72) * bitrate ~/ rate + padding;
    return (length, (v1 ? 1152 : 576) * 1000 / rate);
  }

  /// A frame at [i] followed by another one: a real frame, not data that
  /// happens to look like a header.
  static (int, double)? _confirmed(Uint8List b, int i) {
    final f = _frame(b, i);
    if (f == null) return null;
    final next = i + f.$1;
    if (next + 4 > b.length) return f; // the last frame
    return _frame(b, next) == null ? null : f;
  }

  /// The frame [backFrames] frames before the one playing at [timeMs], or
  /// null if [bytes] is not a Layer III MP3. Starting a few frames early
  /// lets the decoder fill its bit reservoir (a frame can use data from the
  /// ones before it) before the wanted time.
  static Mp3Position? locate(Uint8List bytes, double timeMs, {int backFrames = 2}) {
    var i = id3v2Size(bytes);
    // First frame: search a little (junk / padding after the tag).
    final searchEnd = (i + 64 * 1024).clamp(0, bytes.length);
    while (i < searchEnd && _confirmed(bytes, i) == null) {
      i++;
    }
    if (i >= searchEnd) return null;
    final starts = <int>[], times = <double>[];
    double t = 0;
    var found = false;
    while (i + 4 <= bytes.length) {
      var f = _frame(bytes, i);
      if (f == null) {
        // Lost sync (junk between frames, ID3v1 / APE tag at the end):
        // resync on the next confirmed frame.
        var j = i + 1;
        while (j + 4 <= bytes.length && _confirmed(bytes, j) == null) {
          j++;
        }
        if (j + 4 > bytes.length) break;
        i = j;
        f = _frame(bytes, i)!;
      }
      if (!found) {
        if (starts.length > backFrames) {
          starts.removeAt(0);
          times.removeAt(0);
        }
        starts.add(i);
        times.add(t);
        if (t + f.$2 > timeMs) found = true;
      }
      t += f.$2;
      i += f.$1;
    }
    if (starts.isEmpty) return null;
    // Past the end: the last frames.
    return Mp3Position(starts.first, times.first, t);
  }
}
