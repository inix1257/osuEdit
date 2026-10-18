import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';

void main() {
  // 30.0 s, 44.1 kHz MPEG-1 Layer III (ffprobe).
  final mp3 = File('tool/test_set/audio.mp3').readAsBytesSync();
  const frameMs = 1152 * 1000 / 44100;

  test('locates the frame a few frames before a time', () {
    final p = Mp3Frames.locate(mp3, 9000)!;
    // Plus the Info frame and the encoder delay / padding (ffprobe drops them).
    expect(p.totalTime, closeTo(30000, 120));
    // Two frames early, so the wanted time is within the third frame.
    expect(9000 - p.frameTime, inInclusiveRange(2 * frameMs, 3 * frameMs));
    expect(mp3[p.offset], 0xFF);
    expect(mp3[p.offset + 1] & 0xE0, 0xE0);
  });

  test('start and past the end', () {
    final first = Mp3Frames.locate(mp3, 0)!;
    expect(first.frameTime, 0);
    final last = Mp3Frames.locate(mp3, 1e9)!;
    expect(last.frameTime, closeTo(last.totalTime - 3 * frameMs, frameMs));
  });

  test('not an MP3', () {
    expect(Mp3Frames.locate(Uint8List.fromList(List.filled(5000, 7)), 1000), isNull);
    final ogg = Uint8List.fromList([...'OggS'.codeUnits, ...List.filled(5000, 0)]);
    expect(Mp3Frames.locate(ogg, 1000), isNull);
  });
}
