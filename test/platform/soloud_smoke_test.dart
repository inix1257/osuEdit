// Opt-in: exercises the real SoLoud engine (needs an audio output device).
//   OSUEDIT_AUDIO_TEST=1 flutter test test/platform/soloud_smoke_test.dart
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/audio_clock.dart';
import 'package:osu_edit/platform/audio_engine.dart';
import 'package:osu_edit/platform/synth_samples.dart';

void main() {
  final enabled = Platform.environment['OSUEDIT_AUDIO_TEST'] == '1';
  TestWidgetsFlutterBinding.ensureInitialized();
  // SoLoud asks path_provider for a temp dir during init.
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (_) async => Directory.systemTemp.path,
  );

  test('SoLoud track + clock + hitsounds on a real device', () async {
    final temp = await Directory.systemTemp.createTemp('osuedit_audio_');
    try {
      // 3 s, 440 Hz.
      final pcm = Float64List(SynthSamples.sampleRate * 3);
      for (var i = 0; i < pcm.length; i++) {
        pcm[i] = 0.2 * math.sin(2 * math.pi * 440 * i / SynthSamples.sampleRate);
      }
      final music = File('${temp.path}/audio.wav')..writeAsBytesSync(SynthSamples.wav(pcm));
      File('${temp.path}/soft-hitclap.wav').writeAsBytesSync(SynthSamples.all()['drum-hitclap']!);

      final track = await AudioEngine.instance.loadTrack(music);
      expect(track.length, closeTo(3000, 5));

      final clock = AudioClock(track);
      clock.seek(500);
      expect(track.position, closeTo(500, 30));
      clock.play();
      await Future<void>.delayed(const Duration(milliseconds: 600));
      final t = clock.currentTime;
      expect(t, inInclusiveRange(950, 1250), reason: 'clock $t, engine ${track.position}');
      expect((track.position - clock.audioTime).abs(), lessThan(80));

      // Speed change with pitch compensation keeps playing.
      clock.rate = 0.5;
      final before = clock.currentTime;
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(clock.currentTime - before, inInclusiveRange(120, 300));
      expect(track.isPlaying, isTrue);
      clock.rate = 1;

      clock.pause();
      final paused = clock.currentTime;
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(clock.currentTime, paused);

      // Runs to the end and stops by itself.
      clock.seek(2800);
      clock.play();
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(clock.currentTime, closeTo(3000, 1));
      expect(clock.isPlaying, isFalse);
      // Can seek back and play again after the voice ended.
      clock.seek(100);
      clock.play();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(clock.currentTime, greaterThan(200));
      clock.pause();

      final hs = await SoloudHitsoundPlayer.load(setPath: temp.path, musicFile: 'audio.wav');
      hs.play(const SamplePlay(time: 0, bank: 'soft', name: 'hitclap', index: 1), 1); // custom file
      hs.play(const SamplePlay(time: 0, bank: 'normal', name: 'hitwhistle'), 1); // built-in
      hs.play(const SamplePlay(time: 0, bank: 'drum', name: 'hitnormal', filename: 'missing.wav'), 1);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      hs.dispose();
      clock.dispose();
    } finally {
      await temp.delete(recursive: true);
    }
  }, skip: enabled ? false : 'set OSUEDIT_AUDIO_TEST=1 to run');
}
