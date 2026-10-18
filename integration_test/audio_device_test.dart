// On-device audio measurements (P0-3). Not part of `flutter test`.
//
// The app is reinstalled (and its data wiped) around each run, so the test
// downloads the audio from the host:
// 1. serve a folder containing audio.mp3 (30 s click track):
//    python -m http.server 8765 --bind 127.0.0.1
// 2. adb reverse tcp:8765 tcp:8765
// 3. flutter test integration_test/audio_device_test.dart -d <device>
//
// Prints a report; assertions only guard against gross failures.
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:osu_edit/editor/audio_clock.dart';
import 'package:osu_edit/platform/audio_engine.dart';
import 'package:path_provider/path_provider.dart';

final _sw = Stopwatch()..start();
double _now() => _sw.elapsedMicroseconds / 1000;

/// Least-squares line through (x, y).
(double slope, double intercept) _fit(List<(double, double)> pts) {
  final n = pts.length;
  var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0;
  for (final (x, y) in pts) {
    sx += x;
    sy += y;
    sxx += x * x;
    sxy += x * y;
  }
  final slope = (n * sxy - sx * sy) / (n * sxx - sx * sx);
  return (slope, (sy - slope * sx) / n);
}

String _f(double v) => v.toStringAsFixed(1);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('audio engine timing on device', (tester) async {
    await tester.runAsync(() async {
      final report = StringBuffer('\n===== P0-3 audio report =====\n');
      void log(String s) {
        report.writeln(s);
        // ignore: avoid_print
        print('[P03] $s');
      }

      final dir = Directory('${(await getTemporaryDirectory()).path}/p03')..createSync(recursive: true);
      final file = File('${dir.path}/audio.mp3');
      final client = HttpClient();
      final res = await (await client.getUrl(Uri.parse('http://127.0.0.1:8765/audio.mp3'))).close();
      expect(res.statusCode, 200, reason: 'serve audio.mp3 on host :8765 and adb reverse');
      await res.pipe(file.openWrite());
      client.close();

      var t0 = _now();
      final track = await AudioEngine.instance.loadTrack(file);
      log('load mp3 (incl. engine init): ${_f(_now() - t0)} ms, length ${_f(track.length)} ms');

      // --- start latency + position granularity -----------------------------
      track.seek(1000);
      t0 = _now();
      track.play();
      final changes = <(double, double)>[]; // (wall, pos) at each change
      var last = track.position;
      double? firstMove;
      while (_now() - t0 < 4000) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
        final p = track.position;
        if (p != last) {
          firstMove ??= _now() - t0;
          changes.add((_now(), p));
          last = p;
        }
      }
      log('play() → first position change: ${_f(firstMove ?? -1)} ms');
      final steps = [for (var i = 1; i < changes.length; i++) changes[i].$2 - changes[i - 1].$2];
      steps.sort();
      log('position updates: ${changes.length} in 4 s, step median ${_f(steps[steps.length ~/ 2])} ms, '
          'min ${_f(steps.first)}, max ${_f(steps.last)}');
      final (slope, icpt) = _fit(changes.skip(5).toList());
      log('engine rate vs wall clock (1.0x): ${slope.toStringAsFixed(5)}');
      var maxRes = 0.0;
      for (final (w, p) in changes.skip(5)) {
        maxRes = math.max(maxRes, (p - (slope * w + icpt)).abs());
      }
      log('engine position jitter around fitted line: max ${_f(maxRes)} ms');
      track.pause();

      // --- seek latency (paused and playing) --------------------------------
      final targets = [15000.0, 3000.0, 27000.0, 500.0, 12345.0];
      for (final playing in [false, true]) {
        final lat = <double>[];
        for (final target in targets) {
          if (playing) track.play();
          t0 = _now();
          track.seek(target);
          final readBack = track.position;
          // Time until the engine reports a position near the target.
          while ((track.position - target).abs() > 60 && _now() - t0 < 1000) {
            await Future<void>.delayed(const Duration(microseconds: 200));
          }
          lat.add(_now() - t0);
          if (!playing) {
            expect((readBack - target).abs(), lessThan(5), reason: 'paused seek read-back');
          }
          await Future<void>.delayed(const Duration(milliseconds: 150));
          track.pause();
        }
        log('seek latency (${playing ? 'playing' : 'paused'}): ${lat.map(_f).join(', ')} ms');
        expect(lat.every((l) => l < 100), isTrue);
      }

      // --- AudioClock vs engine over 8 s at 60 fps ---------------------------
      for (final rate in [1.0, 0.75, 0.5]) {
        final clock = AudioClock(track);
        clock.rate = rate;
        clock.seek(2000);
        clock.play();
        final frames = <(double, double, double)>[]; // wall, clock audioTime, engine pos
        t0 = _now();
        var backwards = 0;
        var prev = -double.infinity;
        while (_now() - t0 < (rate == 1.0 ? 8000 : 3000)) {
          await Future<void>.delayed(const Duration(milliseconds: 16));
          final c = clock.audioTime;
          if (c < prev) backwards++;
          prev = c;
          frames.add((_now(), c, track.position));
        }
        clock.pause();
        // Fit the engine's change points as ground truth.
        final pts = <(double, double)>[];
        var lp = double.nan;
        for (final (w, _, p) in frames) {
          if (p != lp) pts.add((w, p));
          lp = p;
        }
        final (s, b) = _fit(pts.skip(3).toList());
        final errs = [for (final (w, c, _) in frames.skip(30)) c - (s * w + b)];
        final mean = errs.reduce((a, b) => a + b) / errs.length;
        final maxAbs = errs.map((e) => e.abs()).reduce(math.max);
        log('AudioClock @${rate}x: engine slope ${s.toStringAsFixed(4)}, '
            'clock − engine mean ${_f(mean)} ms, max |err| ${_f(maxAbs)} ms, backwards steps $backwards');
        expect(maxAbs, lessThan(40));
        expect(backwards, 0);
        expect((s - rate).abs(), lessThan(0.02));
      }

      // --- end of track ---------------------------------------------------------
      {
        final clock = AudioClock(track);
        clock.seek(29700);
        clock.play();
        t0 = _now();
        String? lastLine;
        while (_now() - t0 < 2500) {
          await Future<void>.delayed(const Duration(milliseconds: 16));
          final line = 'playing=${clock.isPlaying} time=${_f(clock.currentTime)} '
              'engine=${_f(track.position)} enginePlaying=${track.isPlaying}';
          if (line != lastLine) log('end @${_f(_now() - t0)}: $line');
          lastLine = line;
        }
        expect(clock.isPlaying, isFalse);
        expect(clock.currentTime, closeTo(track.length, 1));
        // Replay after the voice ended.
        clock.seek(1000);
        clock.play();
        await Future<void>.delayed(const Duration(milliseconds: 300));
        log('replay after end: time=${_f(clock.currentTime)} engine=${_f(track.position)}');
        expect(clock.currentTime, inInclusiveRange(1200, 1450));
        clock.pause();
      }

      // --- hitsounds ---------------------------------------------------------
      t0 = _now();
      final hs = await SoloudHitsoundPlayer.load(setPath: file.parent.path, musicFile: 'audio.mp3');
      log('hitsound player load: ${_f(_now() - t0)} ms');
      hs.dispose();
      track.dispose();
      log(report.isEmpty ? '' : '=============================');
    });
  });
}
