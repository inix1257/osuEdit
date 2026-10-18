import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';

void main() {
  const rate = 44100.0;

  /// [ms] of audio: quiet noise floor with a 100 Hz tone at 400..800 ms and
  /// an 8 kHz one at 1200..1600 ms.
  Float32List song(double ms) {
    final n = (ms / 1000 * rate).round();
    final s = Float32List(n);
    final rnd = math.Random(1);
    for (var i = 0; i < n; i++) {
      final t = i / rate * 1000;
      var v = (rnd.nextDouble() - 0.5) * 0.02;
      if (t >= 400 && t < 800) v += 0.8 * math.sin(2 * math.pi * 100 * i / rate);
      if (t >= 1200 && t < 1600) v += 0.8 * math.sin(2 * math.pi * 8000 * i / rate);
      s[i] = v;
    }
    return s;
  }

  test('min / max follow the samples at every zoom and stay inside the audio', () {
    final w = DetailedWaveform.fromSamples(song(2000), rate);
    expect(w.duration, closeTo(2000, 0.1));
    expect(w.mins.length, greaterThan(4));
    final col = WaveColumn();

    // Fine: a 0.1 ms column in the quiet part is tiny; in the tone it is a
    // slice of the sine (2.5 ms in: its peak).
    expect(w.column(200, 200.1, col), isTrue);
    expect(col.max - col.min, lessThan(0.2));
    expect(w.column(402.45, 402.55, col), isTrue);
    expect(col.min, greaterThan(0.5));
    expect(w.column(400, 410, col), isTrue); // a whole period
    expect(col.max, greaterThan(0.5));
    expect(col.min, lessThan(-0.5));

    // Coarse: one column over the whole song still sees the bursts.
    expect(w.column(0, 2000, col), isTrue);
    expect(col.max, greaterThan(0.5));
    expect(col.max, lessThanOrEqualTo(1));
    expect(col.min, greaterThanOrEqualTo(-1));

    expect(w.column(-50, 0, col), isFalse);
    expect(w.column(2001, 2100, col), isFalse);
    expect(col.isSilent, isTrue);
  });

  test('bands tell a low attack from a high one', () {
    final w = DetailedWaveform.fromSamples(song(2000), rate);
    final col = WaveColumn();
    w.column(500, 510, col);
    expect(col.low, greaterThan(col.high * 3));
    w.column(1300, 1310, col);
    expect(col.high, greaterThan(col.low * 3));
  });

  test('silence stays silent', () {
    final w = DetailedWaveform.fromSamples(Float32List(44100), rate);
    final col = WaveColumn();
    expect(w.column(0, 1000, col), isTrue);
    expect(col.isSilent, isTrue);
  });

  group('audio header sample rate', () {
    Uint8List bytes(List<int> b) => Uint8List.fromList(b);

    test('MP3 frame headers (MPEG 1 / 2 / 2.5) after an ID3v2 tag', () {
      // ID3v2 tag of 20 bytes + 10 header bytes.
      final id3 = bytes([0x49, 0x44, 0x33, 4, 0, 0, 0, 0, 0, 20, ...List.filled(20, 0)]);
      expect(id3v2Size(id3), 30);
      expect(id3v2Size(bytes([0xFF, 0xFB, 0x90, 0x64])), 0);
      expect(audioSampleRate(bytes([0, 0, 0xFF, 0xFB, 0x90, 0x64])), 44100); // MPEG1 L3
      expect(audioSampleRate(bytes([0xFF, 0xFB, 0x94, 0x64])), 48000);
      expect(audioSampleRate(bytes([0xFF, 0xF3, 0x90, 0x64])), 22050); // MPEG2
      expect(audioSampleRate(bytes([0xFF, 0xE3, 0x90, 0x64])), 11025); // MPEG2.5
      expect(audioSampleRate(bytes([0xFF, 0xFB, 0x9C, 0x64])), isNull); // reserved rate
    });

    test('OGG Vorbis / Opus, WAV, FLAC', () {
      final vorbis = bytes([
        ...'OggS'.codeUnits, ...List.filled(24, 0), //
        1, ...'vorbis'.codeUnits, 0, 0, 0, 0, 2, 0x44, 0xAC, 0, 0,
      ]);
      expect(audioSampleRate(vorbis), 44100);
      expect(audioSampleRate(bytes([...'OggS'.codeUnits, ...List.filled(24, 0), ...'OpusHead'.codeUnits])), 48000);
      final wav = bytes([
        ...'RIFF'.codeUnits, 0, 0, 0, 0, ...'WAVE'.codeUnits, //
        ...'fmt '.codeUnits, 16, 0, 0, 0, 1, 0, 2, 0, 0x80, 0xBB, 0, 0,
      ]);
      expect(audioSampleRate(wav), 48000);
      // fLaC + block header + STREAMINFO: rate 44100 = 0x0AC44 in 20 bits.
      final flac = bytes([...'fLaC'.codeUnits, 0, 0, 0, 34, ...List.filled(10, 0), 0x0A, 0xC4, 0x42]);
      expect(audioSampleRate(flac), 44100);
      expect(audioSampleRate(bytes([1, 2, 3])), isNull);
    });
  });
}
