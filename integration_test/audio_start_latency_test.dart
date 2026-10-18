// On-device: how long after Play does the music really start when SoLoud
// had stopped the idle output device (cold) vs. when it was still running
// (warm), and does the playhead jump back meanwhile (AudioClock waits up
// to maxHold = 250 ms for the engine, then snaps back)?
//
// Run without wiping the app's library (`flutter test -d` uninstalls it):
//   flutter build apk --debug -t integration_test/audio_start_latency_test.dart
//   adb install -r build/app/outputs/flutter-apk/app-debug.apk
//   adb shell am start -n com.osuedit.osu_edit/.MainActivity
//   adb logcat -s flutter | grep START
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

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('music start latency, cold vs warm device', (tester) async {
    await tester.runAsync(() async {
      // A constant 1 kHz tone: the first audible output marks the start.
      final music = Float64List(_sr * 20);
      for (var i = 0; i < music.length; i++) {
        music[i] = 0.5 * math.sin(2 * math.pi * 1000 * i / _sr);
      }
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/start_music.wav')..writeAsBytesSync(SynthSamples.wav(music));
      final track = await AudioEngine.instance.loadTrack(file);
      final s = SoLoud.instance;
      final silence = await s.loadMem('start_silence.wav', SynthSamples.wav(Float64List(_sr)));

      Future<void> trial(String label, {required bool cold}) async {
        final clock = AudioClock(track);
        clock.seek(1000);
        if (cold) {
          await Future<void>.delayed(const Duration(milliseconds: 1500));
        } else {
          // Keep the device busy right up to the play.
          final h = s.play(silence, volume: 0, looping: true);
          await Future<void>.delayed(const Duration(milliseconds: 200));
          s.stop(h);
        }
        final stateBefore = s.getAudioDeviceState();
        final sw = Stopwatch()..start();
        clock.play();
        double? deviceOn, posMoves;
        final p0 = track.position;
        var last = clock.currentTime;
        var maxBack = 0.0;
        var lastShown = clock.currentTime;
        while (sw.elapsedMilliseconds < 1500) {
          await Future<void>.delayed(const Duration(milliseconds: 2));
          final now = sw.elapsedMicroseconds / 1000;
          if (deviceOn == null && s.getAudioDeviceState() == AudioDeviceState.started) deviceOn = now;
          if (posMoves == null && track.position != p0) posMoves = now;
          final shown = clock.currentTime;
          maxBack = math.max(maxBack, lastShown - shown);
          lastShown = shown;
          last = shown;
        }
        clock.pause();
        // ignore: avoid_print
        print('[START] $label: device $stateBefore → started after ${deviceOn?.toStringAsFixed(0)} ms, '
            'engine position moves after ${posMoves?.toStringAsFixed(0)} ms, playhead at 1.5 s = '
            '${(last - 1000).toStringAsFixed(0)} ms played, max backward jump ${maxBack.toStringAsFixed(1)} ms');
      }

      for (var i = 0; i < 3; i++) {
        await trial('cold #$i', cold: true);
        await trial('warm #$i', cold: false);
      }
      track.dispose();
      await s.disposeSource(silence);
      // ignore: avoid_print
      print('[START] done');
    });
  });
}
