// On-device: are hitsounds scheduled with AudioClock.engineTimeAt heard
// exactly with the music? Captures the mixer output, finds the music clicks
// (1–1.5 kHz, synthesized in memory, every 333 ms from 1 s) and the 150 Hz
// probes scheduled for the same times, and prints music − probe per rate.
//
// Run without wiping the app's library (`flutter test -d` uninstalls it):
//   flutter build apk --debug -t integration_test/hitsound_schedule_device_test.dart
//   adb install -r build/app/outputs/flutter-apk/app-debug.apk
//   adb shell am start -n com.osuedit.osu_edit/.MainActivity
//   adb logcat -s flutter | grep SCHED
// then reinstall the release build.
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
const _beat = 1000 / 3;
const _first = 1000.0;

double _tone(List<double> x, int from, int n, double hz) {
  var re = 0.0, im = 0.0;
  for (var i = 0; i < n && from + i < x.length; i++) {
    final a = 2 * math.pi * hz * i / _sr;
    re += x[from + i] * math.cos(a);
    im += x[from + i] * math.sin(a);
  }
  return math.sqrt(re * re + im * im) / n;
}

List<int> _onsets(List<double> x, List<double> hzs) {
  const hop = 44, n = 441;
  final e = <double>[];
  for (var i = 0; i + n < x.length; i += hop) {
    var v = 0.0;
    for (final hz in hzs) {
      v = math.max(v, _tone(x, i, n, hz));
    }
    e.add(v);
  }
  if (e.isEmpty) return const [];
  final peak = e.reduce(math.max);
  final out = <int>[];
  var armed = true;
  for (var i = 0; i < e.length; i++) {
    if (armed && e[i] > peak * 0.3) {
      out.add(i * hop);
      armed = false;
    } else if (!armed && e[i] < peak * 0.05) {
      armed = true;
    }
  }
  return out;
}

Float64List _burst(double hz, int ms, double decay) {
  final pcm = Float64List(_sr * ms ~/ 1000);
  for (var i = 0; i < pcm.length; i++) {
    pcm[i] = 0.8 * math.sin(2 * math.pi * hz * i / _sr) * math.exp(-i / _sr * decay);
  }
  return pcm;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('scheduled hitsounds vs music', (tester) async {
    await tester.runAsync(() async {
      // "Music": 1.25 kHz clicks every beat from 1 s, 9 s long.
      final music = Float64List(_sr * 9);
      final click = _burst(1250, 20, 80);
      for (var t = _first; t < 8500; t += _beat) {
        final at = (t / 1000 * _sr).round();
        for (var i = 0; i < click.length && at + i < music.length; i++) {
          music[at + i] += click[i];
        }
      }
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/sched_music.wav')..writeAsBytesSync(SynthSamples.wav(music));
      final track = await AudioEngine.instance.loadTrack(file);
      final probe = await SoLoud.instance.loadMem('sched_probe.wav', SynthSamples.wav(_burst(150, 25, 60)));

      for (final rate in [1.0, 0.5, 0.75, 1.5]) {
        final clock = AudioClock(track);
        clock.rate = rate;
        clock.seek(_first - 300);
        final mono = <double>[];
        final sub = SoLoud.instance.startMixerOutputStream(sampleRate: _sr, channels: 2).listen((chunk) {
          final f = Float32List.view(chunk.buffer, chunk.offsetInBytes, chunk.lengthInBytes ~/ 4);
          for (var i = 0; i + 1 < f.length; i += 2) {
            mono.add((f[i] + f[i + 1]) / 2);
          }
        });
        clock.play();
        // Like the editor: every ~16 ms, schedule beats within 120 ms ahead.
        var next = 0;
        final beats = rate < 0.75 ? 6 : 10;
        final sw = Stopwatch()..start();
        while (next < beats && sw.elapsedMilliseconds < 12000) {
          await Future<void>.delayed(const Duration(milliseconds: 16));
          final now = clock.audioTime;
          final t = _first + next * _beat;
          if (t > now + 120 * rate) continue;
          final e = clock.engineTimeAt(now);
          if (e == null) continue;
          SoLoud.instance.playScheduled(probe, Duration(microseconds: ((e + (t - now) / rate) * 1000).round()));
          next++;
        }
        await Future<void>.delayed(const Duration(milliseconds: 900));
        clock.pause();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await sub.cancel();
        SoLoud.instance.stopMixerOutputStream();

        final m = _onsets(mono, [1250]);
        final p = _onsets(mono, [150]);
        final deltas = <double>[];
        for (final x in p) {
          var best = 1 << 30;
          for (final y in m) {
            if ((y - x).abs() < best.abs()) best = y - x;
          }
          if (best.abs() < _sr ~/ 4) deltas.add(best / _sr * 1000);
        }
        deltas.sort();
        final med = deltas.isEmpty ? double.nan : deltas[deltas.length ~/ 2];
        final spread = deltas.isEmpty ? double.nan : deltas.last - deltas.first;
        // ignore: avoid_print
        print('[SCHED] rate ${rate}x: probes ${p.length}, music ${m.length}, music - hitsound median '
            '${med.toStringAsFixed(1)} ms, spread ${spread.toStringAsFixed(1)} ms; all ${deltas.map((d) => d.toStringAsFixed(1)).join(' ')}');
      }
      track.dispose();
      await SoLoud.instance.disposeSource(probe);
      // ignore: avoid_print
      print('[SCHED] done');
    });
  });
}
