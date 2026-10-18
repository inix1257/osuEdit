// On-device: with the stable timing compensation, does the real editor
// play a ranked-style map's hitsounds on the music, at every speed and
// across a speed change? Drives a real EditorController with the real SoLoud
// track and hitsound player and captures the mixer output. Map: circles
// every 500 ms from 1 s using the set folder's `normal-hitnormal.wav`
// (sample index 1) = a 150 Hz probe. "Music": 1.25 kHz clicks 20 ms after
// each circle (44 ms for the v4 case), as ranked maps are timed. Prints
// probe − music per case; expected 0 (and −20 ms with the compensation off).
//
// Run without wiping the app's library (`flutter test -d` uninstalls it):
//   flutter build apk --debug -t integration_test/stable_compensation_device_test.dart
//   adb install -r build/app/outputs/flutter-apk/app-debug.apk
//   adb shell am start -n com.osuedit.osu_edit/.MainActivity
//   adb logcat -s flutter | grep COMP
// then reinstall the release build.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_soloud/flutter_soloud.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/audio_clock.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/platform/audio_engine.dart';
import 'package:osu_edit/platform/beatmap_file_service.dart';
import 'package:osu_edit/platform/synth_samples.dart';
import 'package:path_provider/path_provider.dart';

const _sr = 44100;
const _first = 1000.0;
const _beat = 500.0;
const _count = 8;

/// Longer runs: does a speed's small offset grow with playing time?
const _longCount = 40;

double _tone(List<double> x, int from, int n, double hz) {
  var re = 0.0, im = 0.0;
  for (var i = 0; i < n && from + i < x.length; i++) {
    final a = 2 * math.pi * hz * i / _sr;
    re += x[from + i] * math.cos(a);
    im += x[from + i] * math.sin(a);
  }
  return math.sqrt(re * re + im * im) / n;
}

/// Sample index of each burst of [hz] (rising past 30% of the peak).
List<int> _onsets(List<double> x, double hz) {
  const hop = 44, n = 441;
  final e = <double>[];
  for (var i = 0; i + n < x.length; i += hop) {
    e.add(_tone(x, i, n, hz));
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

  testWidgets('hitsounds land on the music with the stable compensation, at every speed', (tester) async {
    await tester.runAsync(() async {
      final dir = Directory('${(await getTemporaryDirectory()).path}/stable_comp')..createSync(recursive: true);
      File('${dir.path}/normal-hitnormal.wav').writeAsBytesSync(SynthSamples.wav(_burst(150, 25, 60)));
      // "Music" timed like a ranked map: its clicks [delay] ms after the notes.
      // [sr]: the file's sample rate (48 kHz files exercise SoLoud's resampler
      // at 1x too; the mixer runs at 44.1 kHz).
      String musicWith(int delay, int count, {int sr = _sr}) {
        final music = Float64List(((_first + count * _beat) / 1000 + 2).ceil() * sr);
        final click = _burst(1250, 20, 80);
        for (var k = 0; k < count; k++) {
          final at = ((_first + k * _beat + delay) / 1000 * sr).round();
          for (var i = 0; i < click.length && at + i < music.length; i++) {
            music[at + i] += click[i];
          }
        }
        final name = 'music${delay}_${count}_$sr.wav';
        final bytes = SynthSamples.wav(music); // 44.1 kHz header: patch the rate
        ByteData.sublistView(bytes)
          ..setUint32(24, sr, Endian.little)
          ..setUint32(28, sr * 2, Endian.little);
        File('${dir.path}/$name').writeAsBytesSync(bytes);
        return name;
      }

      final failures = <String>[];
      // (file version, compensation, music delay, rate, rate switched to mid-play,
      // notes, music sample rate). The long runs catch a slow drift of the music
      // against the reported position (SoLoud resampler, patched: see
      // packages/flutter_soloud/OSUEDIT_PATCH.md).
      for (final (version, comp, delay, rate, switchTo, count, sr) in [
        (14, 20.0, 20, 1.0, null, _count, _sr),
        (14, 20.0, 20, 0.5, null, _count, _sr),
        (14, 20.0, 20, 0.75, null, _count, _sr),
        (14, 20.0, 20, 1.5, null, _count, _sr),
        (14, 20.0, 20, 1.0, 0.75, _count, _sr),
        (14, 0.0, 20, 1.0, null, _count, _sr), // compensation off: hitsounds 20 ms early
        (4, 20.0, 44, 1.0, null, _count, _sr),
        (14, 20.0, 20, 0.75, null, _longCount, _sr),
        (14, 20.0, 20, 1.5, null, _longCount, _sr),
        (14, 20.0, 20, 1.0, null, _longCount, 48000),
        (14, 20.0, 20, 0.75, null, _longCount, 48000),
      ]) {
        final musicName = musicWith(delay, count, sr: sr);
        final track = await AudioEngine.instance.loadTrack(File('${dir.path}/$musicName'));
        final hitsounds = await SoloudHitsoundPlayer.load(setPath: dir.path, musicFile: musicName);
        final b = Beatmap.empty()..formatVersion = version;
        b.insertTimingPoint(const TimingPoint(time: 0, beatLength: _beat, sampleSet: 1, sampleIndex: 1));
        for (var k = 0; k < count; k++) {
          b.insertHitObject(HitCircle(position: const Vec2(256, 192), time: _first + k * _beat));
        }
        b.revision = 0;
        final c = EditorController(
          beatmap: b,
          document: const BeatmapDocument(fileName: 't.osu'),
          clock: AudioClock(track),
          hitsounds: hitsounds,
        );
        c.updateAudioSettings(
            stableCompensationMs: comp, offsetMs: 0, autoLatency: false, musicVolume: 1, hitsoundVolume: 1);
        c.rate = rate;

        final mono = <double>[];
        final sub = SoLoud.instance.startMixerOutputStream(sampleRate: _sr, channels: 2).listen((chunk) {
          final f = Float32List.view(chunk.buffer, chunk.offsetInBytes, chunk.lengthInBytes ~/ 4);
          for (var i = 0; i + 1 < f.length; i += 2) {
            mono.add((f[i] + f[i + 1]) / 2);
          }
        });
        c.seek(_first - 300);
        c.togglePlay();
        var switched = switchTo == null;
        while (c.isPlaying && c.time.value < _first + count * _beat + 300) {
          await Future<void>.delayed(const Duration(milliseconds: 16));
          c.tick();
          // Change speed between notes 2 and 3 (pitch filter on: voice rebuilt).
          if (!switched && c.time.value > _first + 2.5 * _beat) {
            c.rate = switchTo!;
            switched = true;
          }
        }
        if (c.isPlaying) c.togglePlay();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await sub.cancel();
        SoLoud.instance.stopMixerOutputStream();

        final m = _onsets(mono, 1250), p = _onsets(mono, 150);
        final deltas = <double>[];
        for (final x in p) {
          var best = 1 << 30;
          for (final y in m) {
            if ((x - y).abs() < best.abs()) best = x - y;
          }
          if (best.abs() < _sr ~/ 8) deltas.add(best / _sr * 1000);
        }
        final sorted = [...deltas]..sort();
        final med = sorted.isEmpty ? double.nan : sorted[sorted.length ~/ 2];
        // Real time: the content offset (audio-file ms) stretched by the speed.
        final expected = (c.mapAudioOffsetMs - delay) / (switchTo ?? rate);
        final worst = deltas.isEmpty ? double.nan : deltas.map((d) => (d - expected).abs()).reduce(math.max);
        final line = '${sr ~/ 1000} kHz v$version comp ${comp.round()} music +$delay ms, ${rate}x'
            '${switchTo == null ? '' : ' -> ${switchTo}x mid-play'}: probes ${p.length}/$count, '
            'hitsound - music median ${med.toStringAsFixed(1)} ms (expected ${expected.toStringAsFixed(1)}), '
            'worst off ${worst.toStringAsFixed(1)} ms; in order ${deltas.map((d) => d.toStringAsFixed(1)).join(' ')}';
        // ignore: avoid_print
        print('[COMP] $line');
        c.dispose(); // disposes the track and the hitsound player
        if (p.length != count || !(worst <= 4)) failures.add(line);
      }
      // ignore: avoid_print
      print('[COMP] done, ${failures.length} failed');
      expect(failures, isEmpty);
    });
  });
}
