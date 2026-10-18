import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';

void main() {
  test('peaks over ranges use pooled levels and the same maxima', () {
    // 1000 bins of 5 ms; a loud bin at 3001..3005 ms.
    final rms = Float32List(1000);
    for (var i = 0; i < rms.length; i++) {
      rms[i] = 0.1;
    }
    rms[600] = 0.4;
    final w = Waveform(rms, 5);
    expect(w.duration, 5000);
    expect(w.levels.length, greaterThan(2));
    // Normalised by the 99.5th percentile (0.1), clamped to 1.
    expect(w.peak(0, 100), closeTo(1, 1e-6));
    expect(w.peak(2990, 3010), 1);
    expect(w.peak(0, 5000), 1);
    expect(w.peak(-100, 0), 0);
    expect(w.peak(5000, 6000), 0);
  });

  test('quiet audio stays quiet and pooled levels agree with level 0', () {
    final rms = Float32List.fromList([for (var i = 0; i < 4096; i++) i < 2048 ? 0.0 : 0.5]);
    final w = Waveform(rms, 1);
    expect(w.peak(0, 2000), 0);
    expect(w.peak(0, 3000), 1);
    expect(w.peak(2048, 2049), 1);
    expect(Waveform(Float32List(0), 5).peak(0, 10), 0);
  });
}
