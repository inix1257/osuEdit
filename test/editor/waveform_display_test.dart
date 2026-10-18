import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/editor/render/timeline_painter.dart';
import 'package:osu_edit/platform/beatmap_file_service.dart';

/// P2: the song's waveform behind the zoomed timeline.
void main() {
  EditorController make(Future<Waveform?>? waveform) {
    final b = Beatmap.empty();
    b.insertTimingPoint(TimingPoint.red(time: 0, bpm: 120));
    b.revision = 0;
    return EditorController(beatmap: b, document: const BeatmapDocument(fileName: 'x.osu'), waveform: waveform);
  }

  Waveform wave() => Waveform(Float32List.fromList(List.filled(2000, 0.3)), 5);

  test('appears once decoded; a failed decode leaves none', () async {
    final done = Completer<Waveform?>();
    final c = make(done.future);
    expect(c.waveform, isNull);
    final w = wave();
    done.complete(w);
    await c.waveformLoaded;
    expect(c.waveform, same(w));
    c.dispose();

    final failed = make(Future.error(StateError('decode')));
    await failed.waveformLoaded;
    expect(failed.waveform, isNull);
    failed.dispose();
  });

  test('the toggle is a view setting', () {
    final c = make(null);
    expect(c.showWaveform, isTrue);
    var notified = 0;
    c.addListener(() => notified++);
    c.showWaveform = false;
    expect(c.showWaveform, isFalse);
    expect(notified, 1);
    c.dispose();
  });

  test('the timeline paints with a waveform, kiai and bookmarks', () async {
    final c = make(Future.value(wave()));
    await c.waveformLoaded;
    c.history.execute(SetValueCommand(SectionNames.editor, 'Bookmarks', '1000,2500'));
    c.history.execute(AddTimingPointCommand(TimingPoint.green(time: 500, sliderVelocity: 1).copyWith(effects: 1)));
    c.seek(1000);
    final rec = ui.PictureRecorder();
    TimelinePainter(c).paint(Canvas(rec), const Size(800, 44));
    rec.endRecording().dispose();
    c.dispose();
  });
}
