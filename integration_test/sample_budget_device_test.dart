// On-device: storyboard samples over the memory budget stream from disk and
// still play. Loads two sample files with a zero budget (both streamed),
// schedules them, and checks the mixer output carries their tones.
//
// Run without wiping the app's library (`flutter test -d` uninstalls it):
//   flutter build apk --debug -t integration_test/sample_budget_device_test.dart
//   adb install -r build/app/outputs/flutter-apk/app-debug.apk
//   adb shell am start -n com.osuedit.osu_edit/.MainActivity
//   adb logcat -s flutter | grep BUDGET
// then reinstall the release build.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_soloud/flutter_soloud.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/platform/audio_engine.dart';
import 'package:osu_edit/platform/synth_samples.dart';
import 'package:path_provider/path_provider.dart';

const _sr = 44100;

double _tone(List<double> x, int from, int n, double hz) {
  var re = 0.0, im = 0.0;
  for (var i = 0; i < n && from + i < x.length; i++) {
    final a = 2 * math.pi * hz * i / _sr;
    re += x[from + i] * math.cos(a);
    im += x[from + i] * math.sin(a);
  }
  return math.sqrt(re * re + im * im) / n;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('streamed storyboard samples play', (tester) async {
    await tester.runAsync(() async {
      final dir = Directory('${(await getTemporaryDirectory()).path}/budget_set')..createSync(recursive: true);
      Float64List tone(double hz) {
        final pcm = Float64List(_sr ~/ 4);
        for (var i = 0; i < pcm.length; i++) {
          pcm[i] = 0.6 * math.sin(2 * math.pi * hz * i / _sr);
        }
        return pcm;
      }

      Directory('${dir.path}/sb').createSync();
      File('${dir.path}/sb/low.wav').writeAsBytesSync(SynthSamples.wav(tone(300)));
      File('${dir.path}/sb/high.wav').writeAsBytesSync(SynthSamples.wav(tone(2000)));
      await AudioEngine.instance.ensureInitialized();
      final player = await SoloudHitsoundPlayer.load(setPath: dir.path);
      player.decodedBudget = 0;
      await player.loadFiles(dir.path, ['sb/low.wav', 'sb/high.wav']);

      final mono = <double>[];
      final sub = SoLoud.instance.startMixerOutputStream(sampleRate: _sr, channels: 2).listen((chunk) {
        final f = Float32List.view(chunk.buffer, chunk.offsetInBytes, chunk.lengthInBytes ~/ 4);
        for (var i = 0; i + 1 < f.length; i += 2) {
          mono.add((f[i] + f[i + 1]) / 2);
        }
      });
      final now = SoLoud.instance.getEngineTime().inMicroseconds / 1000;
      final a = player.playAt(const SamplePlay(time: 0, bank: 'normal', name: 'x', filename: 'sb/low.wav'), 1, now + 200);
      final b = player.playAt(const SamplePlay(time: 0, bank: 'normal', name: 'x', filename: 'sb/high.wav'), 1, now + 600);
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      await sub.cancel();
      SoLoud.instance.stopMixerOutputStream();

      double peak(double hz) {
        var m = 0.0;
        for (var i = 0; i + 441 < mono.length; i += 441) {
          m = math.max(m, _tone(mono, i, 441, hz));
        }
        return m;
      }

      // ignore: avoid_print
      print('[BUDGET] streamed ${player.streamedFiles} of 2, handles ${a != null} ${b != null}, '
          '300 Hz peak ${peak(300).toStringAsFixed(3)}, 2 kHz peak ${peak(2000).toStringAsFixed(3)}, '
          'captured ${(mono.length / _sr).toStringAsFixed(2)} s');
      player.dispose();
      // ignore: avoid_print
      print('[BUDGET] done');
    });
  });
}
