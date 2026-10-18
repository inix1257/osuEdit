import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/audio_clock.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/platform/beatmap_file_service.dart';

import '../support/fake_audio.dart';

/// Circles every 500 ms from 1000 (120 BPM), so each one is one sample.
Beatmap _map() {
  final b = Beatmap.empty()..insertTimingPoint(TimingPoint.red(time: 0, bpm: 120));
  for (var i = 0; i < 8; i++) {
    b.insertHitObject(HitCircle(position: const Vec2(100, 100), time: 1000.0 + 500 * i));
  }
  b.revision = 0;
  return b;
}

void main() {
  late double wall;
  late FakeTrack track;
  late RecordingHitsounds sounds;
  late EditorController c;

  void setUpWith({double latency = 0}) {
    wall = 0;
    track = FakeTrack(() => wall, quantum: 23, length: 20000, latency: latency, engineClock: true);
    sounds = RecordingHitsounds(canSchedule: true);
    c = EditorController(
      beatmap: _map(),
      document: const BeatmapDocument(fileName: 'x.osu'),
      clock: AudioClock(track, now: () => wall),
      hitsounds: sounds,
    );
  }

  tearDown(() => c.dispose());

  void frames(double ms, {double frame = 16.7}) {
    for (var t = 0.0; t < ms; t += frame) {
      wall += frame;
      c.tick();
    }
  }

  /// Wall (= fake engine) time the music reaches file time t, playing from
  /// [from] at wall time [startWall] at [rate].
  double heardAt(double t, {required double from, required double startWall, double rate = 1}) =>
      startWall + (t - from) / rate;

  test('samples are scheduled ahead, at the exact engine time of their music', () {
    setUpWith();
    c.seek(900);
    c.togglePlay(); // music starts at wall 0 from 900
    frames(40);
    // 1000 is within 120 ms: scheduled, not played.
    expect(sounds.played, isEmpty);
    expect(sounds.scheduled.values.map((s) => s.$2), [heardAt(1000, from: 900, startWall: 0)]);
    frames(600);
    expect(sounds.scheduled.values.map((s) => s.$2).toList(), [
      heardAt(1000, from: 900, startWall: 0),
      heardAt(1500, from: 900, startWall: 0),
    ]);
    expect(sounds.played, isEmpty);
  });

  test('exact at other speeds and with the pitch filter latency', () {
    setUpWith(latency: 120);
    c.rate = 0.5;
    c.seek(900);
    c.togglePlay();
    frames(400);
    final at = sounds.scheduled.values.single.$2;
    // Heard 1000 when the latency-corrected position reaches it: (1000 + 120×0.5 − 900) / 0.5.
    expect(at, closeTo((1000 + 120 * 0.5 - 900) / 0.5, 1e-6));
  });

  test('seek and pause cancel pending samples', () {
    setUpWith();
    c.seek(950);
    c.togglePlay();
    frames(20);
    expect(sounds.scheduled, hasLength(1));
    c.togglePlay(); // pause
    expect(sounds.scheduled, isEmpty);
    expect(sounds.cancelled, hasLength(1));
    c.togglePlay();
    frames(20);
    expect(sounds.scheduled, hasLength(1));
    c.seek(3000);
    expect(sounds.scheduled, isEmpty);
  });

  test('an edit reschedules what is not heard yet', () {
    setUpWith();
    c.seek(950);
    c.togglePlay();
    frames(20);
    final before = sounds.scheduled.keys.single;
    // Add a whistle to the circle at 1000 while it is pending.
    c.select(c.beatmap.hitObjects.first);
    c.toggleAddition(HitSoundFlags.whistle);
    frames(17);
    expect(sounds.cancelled, contains(before));
    expect(sounds.scheduled.values.map((s) => s.$1.name).toList()..sort(), ['hitnormal', 'hitwhistle']);
  });

  test('without an engine clock samples still fire per frame', () {
    wall = 0;
    track = FakeTrack(() => wall, quantum: 23, length: 20000);
    sounds = RecordingHitsounds(canSchedule: true);
    c = EditorController(
      beatmap: _map(),
      document: const BeatmapDocument(fileName: 'x.osu'),
      clock: AudioClock(track, now: () => wall),
      hitsounds: sounds,
    );
    c.seek(950);
    c.togglePlay();
    frames(100);
    expect(sounds.scheduled, isEmpty);
    expect(sounds.played.map((p) => p.time), [1000]);
  });

  test('samples queued past the end of the song are cancelled when it ends', () {
    wall = 0;
    track = FakeTrack(() => wall, quantum: 23, length: 1050, engineClock: true);
    sounds = RecordingHitsounds(canSchedule: true);
    final b = Beatmap.empty()..insertTimingPoint(TimingPoint.red(time: 0, bpm: 120));
    b.insertHitObject(HitCircle(position: const Vec2(1, 1), time: 1100)); // after the audio ends
    b.revision = 0;
    c = EditorController(
      beatmap: b,
      document: const BeatmapDocument(fileName: 'x.osu'),
      clock: AudioClock(track, now: () => wall),
      hitsounds: sounds,
    );
    c.seek(1000);
    c.togglePlay();
    frames(20);
    expect(sounds.scheduled, hasLength(1));
    frames(200);
    expect(c.isPlaying, isFalse);
    expect(sounds.scheduled, isEmpty);
  });

  group('slider body loops', () {
    /// A 1000 ms slider body from 2000 (SM 1.4, 120 BPM: 280 px = 1000 ms)
    /// with a green line at 2500 changing the volume to 30.
    Beatmap bodyMap() {
      final b = Beatmap.empty()
        ..setValue(SectionNames.difficulty, 'SliderMultiplier', '1.4')
        ..insertTimingPoint(TimingPoint.red(time: 0, bpm: 120))
        ..insertTimingPoint(OsuParser.parse('osu file format v14\n\n[TimingPoints]\n2500,-100,4,1,0,30,0,0\n').timingPoints.single)
        ..insertHitObject(OsuParser.parseHitObject('100,100,2000,2,0,L|380:100,1,280')!);
      b.revision = 0;
      return b;
    }

    test('the body knows the green line volume inside it', () {
      final b = bodyMap();
      final body = HitsoundResolver.resolveBodies(b, TimingInfo.of(b)).single;
      expect(body.end, 3000);
      expect(body.volumeChanges, [(2500.0, 30)]);
      expect(body.volumeAt(2200), 100);
      expect(body.volumeAt(2700), 30);
      setUpWith(); // for the shared tearDown
    });

    test('scheduled: start, end and the volume change on the engine clock', () {
      wall = 0;
      track = FakeTrack(() => wall, quantum: 23, length: 20000, engineClock: true);
      sounds = RecordingHitsounds(canSchedule: true);
      c = EditorController(
        beatmap: bodyMap(),
        document: const BeatmapDocument(fileName: 'x.osu'),
        clock: AudioClock(track, now: () => wall),
        hitsounds: sounds,
      );
      c.seek(1950);
      c.togglePlay();
      frames(20);
      final loop = sounds.scheduledLoops.values.single;
      expect(loop.$1, closeTo(50, 1e-6)); // 2000 heard 50 ms after starting at 1950
      expect(loop.$2, closeTo(1050, 1e-6));
      expect(loop.$3.single.$1, closeTo(550, 1e-6));
      expect(loop.$3.single.$2, closeTo(0.3 * 0.6, 1e-9)); // × default hitsound volume
      c.togglePlay();
      expect(sounds.loops, isEmpty, reason: 'pausing stops it');
      expect(sounds.longStops, greaterThan(0), reason: 'and long sounds');
    });

    test('frame-driven: the volume follows the green line', () {
      wall = 0;
      track = FakeTrack(() => wall, quantum: 23, length: 20000);
      sounds = RecordingHitsounds();
      c = EditorController(
        beatmap: bodyMap(),
        document: const BeatmapDocument(fileName: 'x.osu'),
        clock: AudioClock(track, now: () => wall),
        hitsounds: sounds,
      );
      c.seek(2100);
      c.togglePlay();
      frames(50);
      final h = sounds.loops.keys.single;
      expect(sounds.loopVolumes[h], closeTo(0.6, 1e-9)); // default hitsound volume
      frames(500);
      expect(sounds.loopVolumes[h], closeTo(0.3 * 0.6, 1e-9));
    });
  });
}
