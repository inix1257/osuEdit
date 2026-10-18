import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/audio_clock.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/platform/audio_session.dart';
import 'package:osu_edit/platform/beatmap_file_service.dart';

import '../support/fake_audio.dart';

void main() {
  tearDown(() => AudioSession.instance.deviceLatency.value = null);

  test('the measured latency beyond the reference phone adds to the offset', () {
    final clock = AudioClock(FakeTrack(() => 0));
    final c = EditorController(
      beatmap: Beatmap.empty()..insertTimingPoint(TimingPoint.red(time: 0, bpm: 120)),
      document: const BeatmapDocument(fileName: 'x.osu'),
      clock: clock,
      hitsounds: RecordingHitsounds(),
    );
    addTearDown(c.dispose);
    final d = c.mapAudioOffsetMs; // stable timing compensation, always added
    expect(clock.offset, d, reason: 'not measured: user offset only');

    AudioSession.instance.deviceLatency.value = AudioSession.referenceLatencyMs + 40;
    expect(c.effectiveOffsetMs, 40);
    expect(clock.offset, d + 40, reason: 'applied when the measurement arrives');

    c.updateAudioSettings(offsetMs: -10);
    expect(clock.offset, d + 30);

    c.updateAudioSettings(autoLatency: false);
    expect(clock.offset, d - 10);

    c.updateAudioSettings(autoLatency: true);
    AudioSession.instance.deviceLatency.value = AudioSession.referenceLatencyMs + 900;
    expect(AudioSession.instance.latencyCorrection, 200, reason: 'limited');
  });

  test('a measurement arriving while playing waits for the pause (no jump)', () {
    var wall = 0.0;
    final clock = AudioClock(FakeTrack(() => wall), now: () => wall);
    final c = EditorController(
      beatmap: Beatmap.empty()..insertTimingPoint(TimingPoint.red(time: 0, bpm: 120)),
      document: const BeatmapDocument(fileName: 'x.osu'),
      clock: clock,
      hitsounds: RecordingHitsounds(),
    );
    addTearDown(c.dispose);
    c.seek(1000);
    c.togglePlay();
    wall += 100;
    c.tick();
    AudioSession.instance.deviceLatency.value = AudioSession.referenceLatencyMs + 30;
    final d = c.mapAudioOffsetMs;
    expect(clock.offset, d, reason: 'not while playing');
    c.togglePlay();
    expect(clock.offset, d + 30, reason: 'applied on pause');
  });
}
