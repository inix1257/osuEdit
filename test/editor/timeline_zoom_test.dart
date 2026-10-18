import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/audio_clock.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/platform/beatmap_file_service.dart';

import '../support/fake_audio.dart';

EditorController _controller({double trackMs = 120000, String? timelineZoom}) {
  final b = Beatmap.empty()..insertTimingPoint(TimingPoint.red(time: 0, bpm: 120));
  if (timelineZoom != null) b.setValue(SectionNames.editor, 'TimelineZoom', timelineZoom);
  b.revision = 0;
  return EditorController(
    beatmap: b,
    document: const BeatmapDocument(fileName: 'x.osu'),
    clock: AudioClock(FakeTrack(() => 0, length: trackMs)),
  );
}

void main() {
  test('lazer default: 6 s across the timeline, px/ms from its width', () {
    final c = _controller();
    addTearDown(c.dispose);
    c.timelineWidth = 600;
    expect(c.timelineVisibleMs, closeTo(6000, 1e-6));
    expect(c.timelineZoomLevel, closeTo(20, 1e-6)); // 120 s / 6 s
    expect(c.timelineZoom, closeTo(0.1, 1e-9));
    c.timelineWidth = 1200;
    expect(c.timelineZoom, closeTo(0.2, 1e-9), reason: 'same span on a wider timeline');
  });

  test('the map\'s [Editor] TimelineZoom scales the default', () {
    final c = _controller(timelineZoom: '2');
    addTearDown(c.dispose);
    expect(c.timelineVisibleMs, closeTo(3000, 1e-6));
  });

  test('limits: 10 s to 0.5 s visible; pinch and wheel stay inside', () {
    final c = _controller();
    addTearDown(c.dispose);
    c.timelineWidth = 600;
    c.timelineZoom = 100; // far in
    expect(c.timelineVisibleMs, closeTo(500, 1e-6));
    c.timelineZoom = 0.0001; // far out
    expect(c.timelineVisibleMs, closeTo(10000, 1e-6));
    // Wheel: 2% of the zoom range (12 .. 240) per step.
    final z = c.timelineZoomLevel;
    c.stepTimelineZoom(1);
    expect(c.timelineZoomLevel, closeTo(z + (240 - 12) * 0.02, 1e-6));
  });

  test('a track shorter than the default shows all of it', () {
    final c = _controller(trackMs: 4000);
    addTearDown(c.dispose);
    expect(c.timelineVisibleMs, closeTo(4000, 1e-6)); // zoom 1 at least
  });
}
