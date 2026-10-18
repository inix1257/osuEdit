// On-device: how late does the *music* sound relative to a hitsound fired at
// the clock's beat time, per playback rate? This is exactly what a mapper
// hears (hitsounds are not time-stretched; the music is when rate != 1).
//
// Captures the mixer output, separates the music clicks (1–1.5 kHz) from the
// probe hitsound (150 Hz) and prints music − probe per rate. Uploads nothing.
// Setup: host serves audio.mp3 on :8765 (see audio_device_test.dart).
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_soloud/flutter_soloud.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:osu_edit/editor/audio_clock.dart';
import 'package:osu_edit/platform/audio_engine.dart';
import 'package:osu_edit/platform/synth_samples.dart';
import 'package:path_provider/path_provider.dart';

const _sr = 44100;
const _beat = 333.333333333333;
const _offset = 1000.0;

/// Single-bin DFT magnitude over [n] samples starting at [from].
double _tone(List<double> x, int from, int n, double hz) {
  var re = 0.0, im = 0.0;
  for (var i = 0; i < n && from + i < x.length; i++) {
    final a = 2 * math.pi * hz * i / _sr;
    re += x[from + i] * math.cos(a);
    im += x[from + i] * math.sin(a);
  }
  return math.sqrt(re * re + im * im) / n;
}

/// Onsets (sample index) where the [hz] band energy rises.
List<int> _onsets(List<double> x, List<double> hzs, {double thresholdRatio = 0.3}) {
  const hop = 44; // 1 ms
  const n = 441; // 10 ms window
  final e = <double>[];
  for (var i = 0; i + n < x.length; i += hop) {
    var v = 0.0;
    for (final hz in hzs) {
      v = math.max(v, _tone(x, i, n, hz));
    }
    e.add(v);
  }
  final peak = e.reduce(math.max);
  final out = <int>[];
  var armed = true;
  for (var i = 0; i < e.length; i++) {
    if (armed && e[i] > peak * thresholdRatio) {
      out.add(i * hop);
      armed = false;
    } else if (!armed && e[i] < peak * 0.05) {
      armed = true;
    }
  }
  return out;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('music vs hitsound latency per rate', (tester) async {
    await tester.runAsync(() async {
      final dir = Directory('${(await getTemporaryDirectory()).path}/p03')..createSync(recursive: true);
      final file = File('${dir.path}/audio.mp3');
      final client = HttpClient();
      final res = await (await client.getUrl(Uri.parse('http://127.0.0.1:8765/audio.mp3'))).close();
      await res.pipe(file.openWrite());
      client.close();

      final track = await AudioEngine.instance.loadTrack(file);
      // 150 Hz probe, 25 ms, sharp attack.
      final probePcm = Float64List(_sr * 25 ~/ 1000);
      for (var i = 0; i < probePcm.length; i++) {
        probePcm[i] = 0.8 * math.sin(2 * math.pi * 150 * i / _sr) * math.exp(-i / _sr * 60);
      }
      final probe = await SoLoud.instance.loadMem('probe.wav', SynthSamples.wav(probePcm));

      final report = <String>[];
      for (final rate in [1.0, 0.75, 0.5, 0.25, 1.25, 1.5]) {
        final clock = AudioClock(track);
        clock.rate = rate;
        clock.seek(_offset - 100);

        final mono = <double>[];
        final sub = SoLoud.instance.startMixerOutputStream(sampleRate: _sr, channels: 2).listen((chunk) {
          final f = Float32List.view(chunk.buffer, chunk.offsetInBytes, chunk.lengthInBytes ~/ 4);
          for (var i = 0; i + 1 < f.length; i += 2) {
            mono.add((f[i] + f[i + 1]) / 2);
          }
        });

        clock.play();
        var next = 0;
        final sw = Stopwatch()..start();
        final beats = rate < 0.5 ? 6 : 10;
        while (next < beats && sw.elapsedMilliseconds < 8000) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
          if (clock.audioTime >= _offset + next * _beat) {
            SoLoud.instance.play(probe);
            next++;
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 700));
        clock.pause();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await sub.cancel();
        SoLoud.instance.stopMixerOutputStream();

        final music = _onsets(mono, [1000, 1500]);
        final probes = _onsets(mono, [150]);
        // Pair each probe with the nearest music onset.
        final deltas = <double>[];
        for (final p in probes) {
          var best = 1 << 30;
          for (final m in music) {
            if ((m - p).abs() < best.abs()) best = m - p;
          }
          if (best.abs() < _sr) deltas.add(best / _sr * 1000);
        }
        deltas.sort();
        final med = deltas.isEmpty ? double.nan : deltas[deltas.length ~/ 2];
        final line = 'rate ${rate}x: probes ${probes.length}, music ${music.length}, '
            'music − hitsound median ${med.toStringAsFixed(1)} ms (wall), '
            '= ${(med * rate).toStringAsFixed(1)} ms of music; all ${deltas.map((d) => d.toStringAsFixed(0)).join(' ')}';
        report.add(line);
        // ignore: avoid_print
        print('[LAT] $line');
      }
      track.dispose();
      await SoLoud.instance.disposeSource(probe);
      // ignore: avoid_print
      print('[LAT] done ${report.length}');
    });
  });
}
