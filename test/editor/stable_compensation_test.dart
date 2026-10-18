import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/audio_clock.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/platform/beatmap_file_service.dart';

import '../support/fake_audio.dart';

/// Ranked maps are timed ahead of the song (stable's latency is baked in):
/// map time t goes with the music at audio time t + mapAudioOffsetMs, for
/// the hitsounds, the playhead and the waveforms alike.
Beatmap _map({int version = 14}) {
  final b = Beatmap.empty()
    ..formatVersion = version
    ..insertTimingPoint(TimingPoint.red(time: 0, bpm: 120));
  for (var i = 0; i < 4; i++) {
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

  void setUpWith({int version = 14, bool schedule = true}) {
    wall = 0;
    track = FakeTrack(() => wall, quantum: 1, length: 20000, engineClock: schedule);
    sounds = RecordingHitsounds(canSchedule: schedule);
    c = EditorController(
      beatmap: _map(version: version),
      document: const BeatmapDocument(fileName: 'x.osu'),
      clock: AudioClock(track, now: () => wall),
      hitsounds: sounds,
    );
  }

  tearDown(() => c.dispose());

  void frames(double ms, {double frame = 5}) {
    for (var t = 0.0; t < ms; t += frame) {
      wall += frame;
      c.tick();
    }
  }

  test('default: the song plays 20 ms behind map time', () {
    setUpWith();
    expect(c.mapAudioOffsetMs, 20);
    expect(c.storyboardLeadMs, 0);
    c.seek(900);
    expect(track.position, 920, reason: 'the playhead at 900 is the song at 920');
    expect(c.waveformOffsetMs, 20);
  });

  test('a scheduled sample is heard with the song at map time + 20 ms', () {
    setUpWith();
    c.seek(900);
    final start = track.position; // the song starts here at engine (wall) time 0
    c.togglePlay();
    frames(40);
    final engine = sounds.scheduled.values.single.$2;
    expect(start + engine, 1000 + 20, reason: 'audio time the 1000 ms sample plays at');
  });

  test('frame-fired samples wait for the song to reach map time + 20 ms', () {
    setUpWith(schedule: false);
    c.seek(900); // song at 920
    c.togglePlay();
    frames(95); // song ≈ 1015
    expect(sounds.played, isEmpty);
    frames(10); // song ≈ 1025
    expect([for (final p in sounds.played) p.time], [1000]);
  });

  // The compensation is in audio-file time (where the music's attacks are),
  // not real time: at any speed a sample lands on the song at t + 20 ms.
  for (final rate in [0.5, 0.75, 1.5]) {
    test('at ${rate}x the sample still lands on the song at map time + 20 ms', () {
      setUpWith();
      c.rate = rate;
      c.seek(900);
      final start = track.position;
      c.togglePlay();
      frames(100); // the 1000 ms sample enters the window (120 ms × rate)
      final engine = sounds.scheduled.values.first.$2;
      expect(start + engine * rate, closeTo(1000 + 20, 1e-9));
    });
  }

  test('changing speed while playing keeps samples on the song', () {
    setUpWith();
    c.seek(900);
    c.togglePlay();
    frames(20);
    c.rate = 0.5; // reschedules from here
    final w1 = wall, a1 = track.position; // song position when the speed changed
    frames(60);
    final engine = sounds.scheduled.values.single.$2;
    expect(a1 + (engine - w1) * 0.5, closeTo(1000 + 20, 1e-9));
    expect(sounds.played, isEmpty, reason: 'nothing fired early around the change');
  });

  test('v3/v4 files add 24 ms (as osu! reads them)', () {
    setUpWith(version: 4);
    expect(c.mapAudioOffsetMs, 20 + 24);
    // The storyboard isn't shifted by the 24 ms: it stays at file time + 20.
    expect(c.storyboardLeadMs, 24);
    c.seek(900);
    expect(track.position, 944);
    c.togglePlay();
    frames(40);
    expect(944 + sounds.scheduled.values.single.$2, 1000 + 44);
  });

  test('changing the setting keeps the playhead and moves the song', () {
    setUpWith();
    c.seek(900);
    c.updateAudioSettings(stableCompensationMs: 0);
    expect(c.time.value, 900);
    expect(track.position, 900);
    expect(c.waveformOffsetMs, 0);
    c.updateAudioSettings(stableCompensationMs: 35, offsetMs: 10);
    expect(c.time.value, 900);
    expect(track.position, 900 + 35 + 10);
    expect(c.waveformOffsetMs, 45, reason: "the user's offset counts too");
    c.togglePlay();
    final start = track.position;
    frames(40);
    expect(start + sounds.scheduled.values.single.$2, 1000 + 35,
        reason: 'hitsounds follow the compensation, not the latency offset');
  });
}
