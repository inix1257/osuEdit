import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/audio_clock.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/platform/beatmap_file_service.dart';

import '../support/fake_audio.dart';

void main() {
  late double wall;
  late FakeTrack track;
  late RecordingHitsounds sounds;
  late EditorController c;

  setUp(() {
    wall = 0;
    track = FakeTrack(() => wall, quantum: 23, length: 12000);
    sounds = RecordingHitsounds();
    c = EditorController(
      beatmap: OsuParser.parse(File('test/fixtures/sample_v14.osu').readAsStringSync()),
      document: const BeatmapDocument(fileName: 'sample.osu'),
      clock: AudioClock(track, now: () => wall),
      hitsounds: sounds,
    );
  });

  tearDown(() => c.dispose());

  void frames(double ms) {
    for (var t = 0.0; t < ms; t += 16.7) {
      wall += 16.7;
      c.tick();
    }
  }

  List<String> playedNames() => [for (final p in sounds.played) '${p.time.round()} ${p.bank}-${p.name}'];

  test('fires each sample once as playback passes it', () {
    c.seek(900);
    c.togglePlay();
    frames(500);
    expect(playedNames(), ['1000 soft-hitnormal', '1333 soft-hitnormal', '1333 soft-hitwhistle']);
    frames(100);
    expect(sounds.played.length, 3);
  });

  test('metronome replaces hitsounds and slider loops with beat clicks', () {
    c.updateAudioSettings(hitsoundsEnabled: false); // the metronome ignores this
    c.metronome = true;
    c.seek(900);
    c.togglePlay();
    frames(1200); // 180 BPM from 1000, 4/4: 1000 1333 1666 2000 (slider 1666–1999)
    expect(playedNames().take(4), ['0 metronome-accent', '0 metronome-beat', '0 metronome-beat', '0 metronome-beat']);
    expect(sounds.loops, isEmpty);
    frames(400); // 2333: next measure
    expect(playedNames()[4], '0 metronome-accent');

    c.updateAudioSettings(hitsoundsEnabled: true);
    c.metronome = false;
    sounds.played.clear();
    c.seek(900);
    frames(500);
    expect(playedNames(), ['1000 soft-hitnormal', '1333 soft-hitnormal', '1333 soft-hitwhistle']);
  });

  test('starting exactly on an object plays it', () {
    c.seek(1000);
    c.togglePlay();
    frames(50);
    expect(playedNames(), ['1000 soft-hitnormal']);
  });

  test('seeking while playing does not replay or burst', () {
    c.seek(900);
    c.togglePlay();
    frames(200); // plays 1000
    c.seek(4500); // nothing between 4500 and 4550
    frames(50);
    c.seek(900);
    frames(150);
    expect(playedNames(), ['1000 soft-hitnormal', '1000 soft-hitnormal']);
  });

  test('disabled hitsounds stay silent; settings apply to the clock', () {
    c.updateAudioSettings(hitsoundsEnabled: false, offsetMs: 30);
    expect((c.clock as AudioClock).offset, 30 + c.mapAudioOffsetMs);
    c.seek(900);
    c.togglePlay();
    frames(500);
    expect(sounds.played, isEmpty);
  });

  test('a long frame gap skips the backlog', () {
    c.seek(900);
    c.togglePlay();
    frames(17);
    wall += 1000; // app stalled
    c.tick();
    expect(sounds.played, isEmpty);
  });

  test('end of track stops playback and notifies once', () {
    var notified = 0;
    c.addListener(() => notified++);
    c.seek(11900);
    c.togglePlay();
    notified = 0;
    frames(400);
    expect(c.isPlaying, isFalse);
    expect(notified, 1);
    expect(c.time.value, closeTo(12000 - c.mapAudioOffsetMs, 0.001)); // map time of the audio end
  });

  test('rate is forwarded to the clock', () {
    c.rate = 0.5;
    expect(c.rate, 0.5);
    c.seek(0);
    c.togglePlay();
    frames(1000);
    expect(c.time.value, closeTo(500, 30));
  });

  test('dispose releases hitsounds', () {
    final local = EditorController(
      beatmap: Beatmap.empty(),
      document: const BeatmapDocument(fileName: 'x.osu'),
      clock: AudioClock(FakeTrack(() => 0)),
      hitsounds: RecordingHitsounds(),
    );
    final hs = local.hitsounds as RecordingHitsounds;
    local.dispose();
    expect(hs.disposed, isTrue);
  });
  test('slider bodies loop while the ball rolls; pausing or seeking stops them', () {
    // The slider at 1666 ends at 1999 (SM 1.4, 180 BPM, length 140).
    c.seek(1600);
    c.togglePlay();
    frames(100);
    expect([for (final p in sounds.loops.values) '${p.bank}-${p.name}'], ['soft-sliderslide']);
    frames(400); // past its end
    expect(sounds.loops, isEmpty);

    c.seek(1700);
    frames(50);
    expect(sounds.loops, hasLength(1));
    c.togglePlay(); // pause
    expect(sounds.loops, isEmpty);
    c.togglePlay();
    frames(50);
    expect(sounds.loops, hasLength(1));
    c.seek(4400); // seeking out of the body stops it at once
    expect(sounds.loops, isEmpty);
    frames(50);
    expect(sounds.loops, isEmpty);
  });

  test('a body loop stops when its slider is deleted mid-play', () {
    c.seek(1700);
    c.togglePlay();
    frames(50);
    expect(sounds.loops, hasLength(1));
    c.select(c.beatmap.hitObjects[2]);
    c.deleteSelection();
    frames(20);
    expect(sounds.loops, isEmpty);
  });
}
