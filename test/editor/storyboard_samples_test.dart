import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/audio_clock.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/platform/beatmap_file_service.dart';
import 'package:osu_edit/platform/storyboard_loader.dart';

import '../support/fake_audio.dart';

/// Storyboard `Sample` events play with the hitsounds while it is shown.
void main() {
  late double wall;
  late RecordingHitsounds sounds;
  late EditorController c;

  setUp(() async {
    wall = 0;
    sounds = RecordingHitsounds();
    final sb = Storyboard.parse([
      (['Sample,1100,0,"sb\\boom.wav",60', 'Sample,1200,1,"fail.wav"', 'Sample,1300,3,"Boom2.WAV"'], {}),
    ]);
    c = EditorController(
      beatmap: OsuParser.parse(File('test/fixtures/sample_v14.osu').readAsStringSync()),
      document: const BeatmapDocument(fileName: 'sample.osu', setPath: '/set'),
      clock: AudioClock(FakeTrack(() => wall, quantum: 23, length: 12000), now: () => wall),
      hitsounds: sounds,
      storyboardLoader: (_, _) async => LoadedStoryboard(sb, {}),
    );
    await c.storyboardLoaded;
  });

  tearDown(() => c.dispose());

  void frames(double ms) {
    for (var t = 0.0; t < ms; t += 16.7) {
      wall += 16.7;
      c.tick();
    }
  }

  List<String> storyboardPlays() => [
        for (final p in sounds.played)
          if (p.name == 'storyboard') '${p.time.round()} ${p.filename} ${p.volume}',
      ];

  test('loads the sample files and fires each event once (Fail layer dropped)', () {
    expect(sounds.loadedFiles, ['sb/boom.wav', 'Boom2.WAV']);
    c.seek(1000);
    c.togglePlay();
    frames(500);
    expect(storyboardPlays(), ['1100 sb/boom.wav 60', '1300 Boom2.WAV 100']);
  });

  test('hidden storyboard or hitsounds off: silent', () {
    c.showStoryboard = false;
    c.seek(1000);
    c.togglePlay();
    frames(500);
    expect(storyboardPlays(), isEmpty);

    c.showStoryboard = true;
    c.updateAudioSettings(hitsoundsEnabled: false);
    c.seek(1000);
    frames(500);
    expect(storyboardPlays(), isEmpty);
  });
}
