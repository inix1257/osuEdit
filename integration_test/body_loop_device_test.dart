// On-device: slider body loops scheduled on the engine clock start / end
// with the music and follow a volume change; long one-shot sounds stop on
// stopLongSounds. Captures the mixer output: music clicks (1.25 kHz) every
// 333 ms from 1 s, a 300 Hz custom `normal-sliderslide` loop scheduled from
// click 2 to click 5 dropping to 30 % at click 4, and a 3 s 2 kHz storyboard
// sound stopped 500 ms after it starts.
//
// Run without wiping the app's library (`flutter test -d` uninstalls it):
//   flutter build apk --debug -t integration_test/body_loop_device_test.dart
//   adb install -r build/app/outputs/flutter-apk/app-debug.apk
//   adb shell am start -n com.osuedit.osu_edit/.MainActivity
//   adb logcat -s flutter | grep LOOP
// then reinstall the release build.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_soloud/flutter_soloud.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:osu_edit/core/core.dart';
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

/// [hz] magnitude every millisecond (10 ms windows).
List<double> _envelope(List<double> x, double hz) => [
      for (var i = 0; i + 441 < x.length; i += 44) _tone(x, i, 441, hz),
    ];

Float64List _sine(double hz, int ms, {double amp = 0.5}) {
  final pcm = Float64List(_sr * ms ~/ 1000);
  for (var i = 0; i < pcm.length; i++) {
    pcm[i] = amp * math.sin(2 * math.pi * hz * i / _sr);
  }
  return pcm;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('scheduled body loops and long sound stop', (tester) async {
    await tester.runAsync(() async {
      final dir = Directory('${(await getTemporaryDirectory()).path}/loop_set')..createSync(recursive: true);
      Directory('${dir.path}/sb').createSync();
      // Exactly 300 cycles per second of loop: seamless.
      File('${dir.path}/normal-sliderslide.wav').writeAsBytesSync(SynthSamples.wav(_sine(300, 1000)));
      File('${dir.path}/sb/long.wav').writeAsBytesSync(SynthSamples.wav(_sine(2000, 3000)));
      final music = Float64List(_sr * 6);
      final click = _sine(1250, 15, amp: 0.8);
      for (var t = _first; t < 5500; t += _beat) {
        final at = (t / 1000 * _sr).round();
        for (var i = 0; i < click.length; i++) {
          music[at + i] += click[i] * math.exp(-i / _sr * 100);
        }
      }
      File('${dir.path}/music.wav').writeAsBytesSync(SynthSamples.wav(music));
      final track = await AudioEngine.instance.loadTrack(File('${dir.path}/music.wav'));
      final player = await SoloudHitsoundPlayer.load(setPath: dir.path);
      await player.loadFiles(dir.path, ['sb/long.wav']);

      final clock = AudioClock(track);
      clock.seek(_first - 300);
      final mono = <double>[];
      final sub = SoLoud.instance.startMixerOutputStream(sampleRate: _sr, channels: 2).listen((chunk) {
        final f = Float32List.view(chunk.buffer, chunk.offsetInBytes, chunk.lengthInBytes ~/ 4);
        for (var i = 0; i + 1 < f.length; i += 2) {
          mono.add((f[i] + f[i + 1]) / 2);
        }
      });
      clock.play();
      final loopStart = _first + 2 * _beat, loopEnd = _first + 5 * _beat, change = _first + 4 * _beat;
      final longAt = _first + 7 * _beat;
      var loopDone = false, longDone = false, stopped = false;
      final sw = Stopwatch()..start();
      double? stopAudioTime;
      while (sw.elapsedMilliseconds < 5000) {
        await Future<void>.delayed(const Duration(milliseconds: 16));
        final now = clock.audioTime;
        final e = clock.engineTimeAt(now);
        if (e == null) continue;
        double at(double t) => e + (t - now);
        if (!loopDone && loopStart <= now + 120) {
          player.startLoopAt(const SamplePlay(time: 0, bank: 'normal', name: 'sliderslide', index: 1), 1,
              at(loopStart), at(loopEnd), [(at(change), 0.3)]);
          loopDone = true;
        }
        if (!longDone && longAt <= now + 120) {
          player.playAt(const SamplePlay(time: 0, bank: 'normal', name: 'x', filename: 'sb/long.wav'), 1, at(longAt));
          longDone = true;
        }
        if (longDone && !stopped && now >= longAt + 500) {
          player.stopLongSounds();
          stopped = true;
          stopAudioTime = now;
        }
        if (stopped && now >= longAt + 1200) break;
      }
      clock.pause();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await sub.cancel();
      SoLoud.instance.stopMixerOutputStream();

      // Music click onsets (ms of capture), the loop's 300 Hz on/off and
      // levels, the long sound's 2 kHz duration.
      final clicks = <double>[];
      final ce = _envelope(mono, 1250);
      final cPeak = ce.reduce(math.max);
      var armed = true;
      for (var i = 0; i < ce.length; i++) {
        if (armed && ce[i] > cPeak * 0.3) {
          clicks.add(i.toDouble());
          armed = false;
        } else if (!armed && ce[i] < cPeak * 0.05) {
          armed = true;
        }
      }
      final le = _envelope(mono, 300);
      final lPeak = le.reduce(math.max);
      final on = le.indexWhere((v) => v > lPeak * 0.5);
      final off = le.lastIndexWhere((v) => v > lPeak * 0.5 * 0.3);
      final ge = _envelope(mono, 2000);
      final gPeak = ge.reduce(math.max);
      final gOn = ge.indexWhere((v) => v > gPeak * 0.5);
      final gOff = ge.lastIndexWhere((v) => v > gPeak * 0.5);
      // Clicks: index 0 is the first beat (1000 ms); the loop spans clicks 2..5.
      double nearestClick(int ms) => clicks.reduce((a, b) => (a - ms).abs() < (b - ms).abs() ? a : b);
      final startErr = on - nearestClick(on);
      final endErr = off - nearestClick(off);
      final changeClick = clicks.length > 4 ? clicks[4] : double.nan;
      double level(double fromMs, double toMs) {
        final xs = [for (var i = fromMs.round(); i < toMs.round() && i < le.length; i++) le[i]];
        return xs.isEmpty ? double.nan : xs.reduce((a, b) => a + b) / xs.length;
      }

      final before = level(changeClick - 150, changeClick - 20), after = level(changeClick + 30, changeClick + 150);
      // ignore: avoid_print
      print('[LOOP] clicks ${clicks.length}; loop on ${on}ms (click ${startErr.toStringAsFixed(0)} ms), '
          'off ${off}ms (click ${endErr.toStringAsFixed(0)} ms), length ${off - on} ms (expect ${(loopEnd - loopStart).round()}); '
          'level after/before change ${(after / before).toStringAsFixed(2)} (expect 0.30)');
      // ignore: avoid_print
      print('[LOOP] long sound heard ${gOff - gOn} ms (stopped ${stopAudioTime == null ? '?' : (stopAudioTime - longAt).round()} ms after its start; file is 3000 ms)');
      player.dispose();
      track.dispose();
      // ignore: avoid_print
      print('[LOOP] done');
    });
  });
}
