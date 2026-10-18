import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/editor_audio.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/editor/render/bpm_painter.dart';
import 'package:osu_edit/editor/widgets/bpm_view.dart';
import 'package:osu_edit/platform/beatmap_file_service.dart';

/// The Timing mode's BPM view: detailed waveform (decoded on demand) and
/// the beat rows.
void main() {
  EditorController make({DetailedWaveformLoader? detail}) {
    final b = Beatmap.empty();
    b.insertTimingPoint(TimingPoint.red(time: 1000, bpm: 120)); // 500 ms beats, 4/4
    b.insertTimingPoint(TimingPoint.red(time: 9000, bpm: 150));
    b.revision = 0;
    return EditorController(beatmap: b, document: const BeatmapDocument(fileName: 'x.osu'), detailedWaveform: detail);
  }

  DetailedWaveform wave() {
    final s = Float32List(44100 * 12);
    // A click on every beat of the first section (1000 + k * 500 ms).
    for (var t = 1000; t < 9000; t += 500) {
      final i = t * 44100 ~/ 1000;
      for (var k = 0; k < 200; k++) {
        s[i + k] = k.isEven ? 0.9 : -0.9;
      }
    }
    return DetailedWaveform.fromSamples(s, 44100);
  }

  test('rows are beats (or bars) of the red point at the playhead, centred on them', () {
    final c = make();
    c.seek(2600); // beat 3.2 from the first red point (nearest beat: 2500)
    final rows = BpmRows.at(c.timing, c.time.value, bars: false, count: 8)!;
    expect(rows.length, 500);
    expect(rows.centreOf(rows.current), 2500);
    expect(rows.current, 2);
    expect(rows.centreOf(0), 1500);
    expect(rows.timeAt(rows.current, 0), 2250);
    expect(rows.timeAt(rows.current, 1), 2750);

    final bars = BpmRows.at(c.timing, c.time.value, bars: true, count: 3)!;
    expect(bars.length, 2000);
    expect(bars.centreOf(bars.current), 3000);
    expect(bars.current, 0);

    c.seek(9100); // the second section rules there
    expect(BpmRows.at(c.timing, c.time.value, bars: false, count: 4)!.length, 400);
    c.dispose();
  });

  test('the detailed waveform decodes once, on request', () async {
    var calls = 0;
    final pending = Completer<DetailedWaveform?>();
    final c = make(detail: () {
      calls++;
      return pending.future;
    });
    expect(c.detailedWaveform, isNull);
    expect(calls, 0); // not decoded until a view asks
    final load = c.requestDetailedWaveform();
    c.requestDetailedWaveform();
    expect(calls, 1);
    expect(c.detailedWaveformLoading, isTrue);
    final w = wave();
    pending.complete(w);
    await load;
    expect(c.detailedWaveform, same(w));
    expect(c.detailedWaveformLoading, isFalse);
    await c.requestDetailedWaveform();
    expect(calls, 1);
    c.dispose();
  });

  test('strip and rows paint with and without the waveform', () async {
    final c = make(detail: () async => wave());
    for (final loaded in [false, true]) {
      if (loaded) await c.requestDetailedWaveform();
      c.seek(2600);
      final rec = ui.PictureRecorder();
      final canvas = Canvas(rec);
      BpmStripPainter(c, zoom: 0.5, dpr: 2).paint(canvas, const Size(600, 100));
      BpmRowsPainter(c, bars: false, count: 6, dpr: 2).paint(canvas, const Size(600, 200));
      BpmRowsPainter(c, bars: true, count: 3, dpr: 2).paint(canvas, const Size(600, 200));
      rec.endRecording().dispose();
    }
    c.dispose();
  });

  testWidgets('a tap on a row seeks there, snapped; dragging up moves on by rows', (tester) async {
    final c = make();
    c.seek(2500);
    tester.view.physicalSize = const Size(600, 400); // 8 rows: the playhead's is the third
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ListenableBuilder(listenable: c, builder: (_, _) => BpmView(controller: c))),
    ));
    final rows = find.byKey(const ValueKey('bpm-rows'));
    final box = tester.getRect(rows);
    final count = (box.height / 30).floor();
    final rowH = box.height / count;
    // Row 0 is centred on 1500 (two rows before the playhead's): tap its
    // right edge → 1750, the next beat's 1/4 grid.
    await tester.tapAt(Offset(box.right - 1, box.top + rowH / 2));
    await tester.pump(const Duration(milliseconds: 500));
    expect(c.time.value, 1750);

    c.seek(2500);
    await tester.dragFrom(Offset(box.center.dx, box.bottom - 5), Offset(0, -rowH * 2 - 20));
    await tester.pump();
    expect(c.time.value, greaterThan(3300));
    expect(c.time.value, lessThan(3700));
    c.dispose();
  });
}
