// On-device: do slider ticks and slider body loops actually sound, at the
// right times, and do the loops stop (slider end, pause)?
//
// Drives a real EditorController with the real SoLoud hitsound player and
// captures the mixer output. The "music" is silent, so the capture holds
// only hitsounds. The built-in samples are pure tones per bank, so they can
// be told apart: normal-sliderwhistle 1750 Hz (looped), normal-slidertick
// 2200 Hz. No network or files needed.
//
// Run: flutter test integration_test/slider_sounds_test.dart -d <device>
// (installs a debug build and removes it afterwards: re-install the release
// APK and re-import the test sets after running).
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

/// Single-bin DFT magnitude (Hann window) over [n] samples from [from].
double _tone(List<double> x, int from, int n, double hz) {
  var re = 0.0, im = 0.0;
  for (var i = 0; i < n && from + i < x.length; i++) {
    final w = 0.5 - 0.5 * math.cos(2 * math.pi * i / (n - 1));
    final a = 2 * math.pi * hz * i / _sr;
    re += w * x[from + i] * math.cos(a);
    im += w * x[from + i] * math.sin(a);
  }
  return math.sqrt(re * re + im * im) / n;
}

/// Band energy every 5 ms (10 ms windows).
List<double> _envelope(List<double> x, double hz) => [
      for (var i = 0; i + 441 < x.length; i += 220) _tone(x, i, 441, hz),
    ];

/// Rising edges (in 5 ms frames) above [ratio] × peak.
List<int> _onsets(List<double> e, {double ratio = 0.35}) {
  final peak = e.reduce(math.max);
  final out = <int>[];
  var armed = true;
  for (var i = 0; i < e.length; i++) {
    if (armed && e[i] > peak * ratio) {
      out.add(i);
      armed = false;
    } else if (!armed && e[i] < peak * 0.1) {
      armed = true;
    }
  }
  return out;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('slider ticks and body loops sound on time and stop', (tester) async {
    await tester.runAsync(() async {
      final dir = Directory('${(await getTemporaryDirectory()).path}/slider_sounds')..createSync(recursive: true);
      final silence = File('${dir.path}/silence.wav')..writeAsBytesSync(SynthSamples.wav(Float64List(_sr * 6)));
      final track = await AudioEngine.instance.loadTrack(silence);
      final hitsounds = await SoloudHitsoundPlayer.load();

      // 180 BPM from 1000; SM 1.4, tick rate 2: a 280 px slider spans 666.7 ms
      // with ticks every 70 px = 166.7 ms. Whistle on the body only.
      final b = Beatmap.empty();
      b.setValue(SectionNames.difficulty, 'SliderTickRate', '2');
      b.insertTimingPoint(TimingPoint.red(time: 1000, bpm: 180));
      b.insertHitObject(const SliderObject(
        position: Vec2(100, 192),
        time: 1333,
        curveType: CurveType.linear,
        controlPoints: [Vec2(380, 192)],
        length: 280,
        hitSound: HitSoundFlags.whistle,
        edgeSounds: [0, 0],
        sample: HitSample(normalSet: SampleSet.normal, additionSet: SampleSet.normal),
      ));
      b.revision = 0;
      final c = EditorController(
        beatmap: b,
        document: const BeatmapDocument(fileName: 't.osu'),
        clock: AudioClock(track),
        hitsounds: hitsounds,
      );
      c.audioSettings
        ..musicVolume = 0
        ..hitsoundVolume = 1;
      track.volume = 0;

      final mono = <double>[];
      final sub = SoLoud.instance.startMixerOutputStream(sampleRate: _sr, channels: 2).listen((chunk) {
        final f = Float32List.view(chunk.buffer, chunk.offsetInBytes, chunk.lengthInBytes ~/ 4);
        for (var i = 0; i + 1 < f.length; i += 2) {
          mono.add((f[i] + f[i + 1]) / 2);
        }
      });

      Future<void> run(int ms) async {
        final sw = Stopwatch()..start();
        while (sw.elapsedMilliseconds < ms) {
          await Future<void>.delayed(const Duration(milliseconds: 16));
          c.tick();
        }
      }

      // Pass 1: play through the slider and 600 ms past its end.
      c.seek(1150);
      c.togglePlay();
      await run(1500);
      c.togglePlay();
      await run(300);
      final pass1 = mono.length;

      // Pass 2: pause in the middle of the body.
      c.seek(1450);
      c.togglePlay();
      await run(250);
      c.togglePlay(); // at ~1700, inside the body
      await run(500);
      await sub.cancel();
      SoLoud.instance.stopMixerOutputStream();

      final p1 = mono.sublist(0, pass1), p2 = mono.sublist(pass1);
      final loop1 = _envelope(p1, 1750);
      final tick1 = _envelope(p1, 2200);
      final loopPeak = loop1.reduce(math.max);
      bool loud(double v) => v > loopPeak * 0.3;
      // The loop: one continuous run of loud frames.
      final first = loop1.indexWhere(loud);
      final last = loop1.lastIndexWhere(loud);
      final loudFrames = loop1.where(loud).length;
      final bodyMs = (last - first) * 5;
      final ticks = _onsets(tick1);
      final tickMs = [for (final t in ticks) (t - first) * 5];
      // ignore: avoid_print
      print('[SLD] loop: frames $first..$last (${bodyMs}ms), loud ${loudFrames * 5}ms, '
          'peak ${loopPeak.toStringAsExponential(2)}; ticks at +$tickMs ms; tail level after end '
          '${loop1.sublist(math.min(loop1.length, last + 40)).fold(0.0, math.max).toStringAsExponential(2)}');

      expect(first, greaterThan(0), reason: 'the body loop sounds');
      expect(bodyMs, inInclusiveRange(600, 740), reason: 'loop lasts the 667 ms body');
      expect(loudFrames * 5, greaterThan(bodyMs * 0.9), reason: 'no gaps in the loop');
      // Silent after the end (40 frames = 200 ms margin).
      expect(loop1.sublist(math.min(loop1.length, last + 40)).every((v) => v < loopPeak * 0.05), isTrue,
          reason: 'loop stops at the slider end');
      expect(tickMs, hasLength(3));
      for (var k = 0; k < 3; k++) {
        expect(tickMs[k], closeTo(166.7 * (k + 1), 30), reason: 'tick ${k + 1}');
      }

      // Pass 2: loud while playing, gone shortly after the pause.
      final loop2 = _envelope(p2, 1750);
      final on = loop2.indexWhere(loud);
      final off = loop2.lastIndexWhere(loud);
      // ignore: avoid_print
      print('[SLD] pause: loop frames $on..$off (${(off - on) * 5} ms of ~250 ms playing)');
      expect(on, greaterThanOrEqualTo(0));
      expect((off - on) * 5, inInclusiveRange(150, 330), reason: 'loop stops on pause');

      c.dispose();
    });
  });
}
