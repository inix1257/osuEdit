import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/platform/app_settings.dart';
import 'package:osu_edit/platform/synth_samples.dart';

void main() {
  group('SynthSamples', () {
    final all = SynthSamples.all();

    test('one WAV per bank × sample', () {
      expect(all.length, 23); // + metronome accent / beat
      expect(all.keys, containsAll(['normal-hitnormal', 'soft-hitwhistle', 'drum-hitfinish', 'soft-hitclap', 'drum-slidertick', 'soft-sliderslide', 'normal-sliderwhistle', 'metronome-accent', 'metronome-beat']));
    });

    test('valid 16-bit mono PCM headers, audible, deterministic', () {
      for (final MapEntry(:key, :value) in all.entries) {
        final b = ByteData.sublistView(value);
        expect(String.fromCharCodes(value.sublist(0, 4)), 'RIFF', reason: key);
        expect(String.fromCharCodes(value.sublist(8, 12)), 'WAVE', reason: key);
        expect(b.getUint16(22, Endian.little), 1);
        expect(b.getUint32(24, Endian.little), SynthSamples.sampleRate);
        expect(b.getUint32(40, Endian.little), value.length - 44);
        var peak = 0;
        for (var i = 44; i < value.length; i += 2) {
          peak = peak > b.getInt16(i, Endian.little).abs() ? peak : b.getInt16(i, Endian.little).abs();
        }
        expect(peak, greaterThan(3000), reason: key);
      }
      expect(SynthSamples.all()['drum-hitclap'], all['drum-hitclap']);
    });
  });

  group('SettingsStore', () {
    late Directory temp;
    setUp(() async => temp = await Directory.systemTemp.createTemp('osuedit_settings_'));
    tearDown(() => temp.delete(recursive: true));

    test('defaults when missing or corrupt; round-trips saved values', () async {
      final f = File('${temp.path}/s.json');
      var s = await SettingsStore.load(f);
      expect(s.audio.offsetMs, 0);
      expect(s.audio.hitsoundsEnabled, isTrue);
      expect(s.audio.stableCompensationMs, 20);

      s.audio
        ..offsetMs = -25
        ..musicVolume = 0.5
        ..hitsoundsEnabled = false
        ..stableCompensationMs = 12;
      // Rapid saves coalesce and the last values win.
      final a = s.save();
      s.audio.hitsoundVolume = 0.3;
      final b = s.save();
      await Future.wait([a, b]);

      s = await SettingsStore.load(f);
      expect(s.audio.offsetMs, -25);
      expect(s.audio.musicVolume, 0.5);
      expect(s.audio.hitsoundVolume, 0.3);
      expect(s.audio.hitsoundsEnabled, isFalse);
      expect(s.audio.stableCompensationMs, 20, reason: 'fixed, not saved');

      await f.writeAsString('{not json');
      expect((await SettingsStore.load(f)).audio.offsetMs, 0);
      // A value saved by older versions (when it was a slider) is ignored.
      await f.writeAsString('{"audio":{"offsetMs":9999,"musicVolume":"x","stableCompensationMs":-5}}');
      final clamped = (await SettingsStore.load(f)).audio;
      expect(clamped.offsetMs, 500);
      expect(clamped.musicVolume, 0.8);
      expect(clamped.stableCompensationMs, 20);
    });
  });
}
