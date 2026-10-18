import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/editor/editor_screen.dart';
import 'package:osu_edit/editor/render/hitsound_painter.dart';
import 'package:osu_edit/editor/render/timeline_painter.dart';
import 'package:osu_edit/editor/widgets/editor_mode_button.dart';
import 'package:osu_edit/editor/widgets/hitsound_view.dart';
import 'package:osu_edit/platform/beatmap_file_service.dart';

/// sample_v14: 180 BPM from 1000 (1/4 snap = 83.33 ms), objects 1000–10000.
EditorController _sample() => EditorController(
      beatmap: OsuParser.parse(File('test/fixtures/sample_v14.osu').readAsStringSync()),
      document: const BeatmapDocument(fileName: 'sample.osu'),
    );

void main() {
  Future<(EditorController, Rect, HitsoundGeometry)> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(891, 411);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = _sample();
    await tester.pumpWidget(MaterialApp(home: EditorScreen(controller: c)));
    await tester.tap(find.byType(EditorModeButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hitsound'));
    await tester.pumpAndSettle();
    c.seek(3000);
    await tester.pump();
    final rect = tester.getRect(find.byType(HitsoundTimeline));
    return (c, rect, HitsoundGeometry(rect.height));
  }

  testWidgets('shows the layers; scrubbing, tapping the strip and pinching share the editor time / zoom',
      (tester) async {
    final (c, rect, g) = await pump(tester);
    for (final l in HitsoundLayer.values) {
      expect(find.text(l.label), findsOneWidget);
    }
    final revision = c.beatmap.revision;
    final rowY = rect.top + g.rowTop(HitsoundLayer.whistle) + g.rowHeight / 2;

    // Drag on the layers: the time follows the finger like the top timeline.
    await tester.dragFrom(Offset(rect.center.dx, rowY), const Offset(-100, 0));
    await tester.pumpAndSettle();
    expect(c.time.value, greaterThan(3000 + 60 / c.timelineZoom)); // minus the touch slop

    // A tap on the strip seeks there, snapped.
    c.seek(3000);
    await tester.pump();
    final x = rect.center.dx + 50;
    await tester.tapAt(Offset(x, rect.top + g.rulerHeight / 2));
    await tester.pump(const Duration(milliseconds: 400));
    final target = TimelinePainter.timeAt(x - rect.left, 3000, c.timelineZoom, rect.width);
    expect(c.time.value, c.timing.snap(target, c.divisor));

    // Pinch zooms (the same zoom as the top timeline).
    final zoom = c.timelineZoom;
    final a = await tester.startGesture(Offset(rect.center.dx - 40, rowY), pointer: 1);
    final b = await tester.startGesture(Offset(rect.center.dx + 40, rowY), pointer: 2);
    for (var i = 0; i < 5; i++) {
      await a.moveBy(const Offset(-10, 0));
      await b.moveBy(const Offset(10, 0));
      await tester.pump();
    }
    await a.up();
    await b.up();
    await tester.pumpAndSettle();
    expect(c.timelineZoom, greaterThan(zoom * 1.5));

    // Mouse wheel steps by the snap.
    c.seek(3000);
    await tester.pump();
    final mouse = TestPointer(9, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(Offset(rect.center.dx, rowY)));
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, 20)));
    await tester.pump();
    expect(c.time.value, greaterThan(3000));

    expect(c.beatmap.revision, revision, reason: 'no edits');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('taps on the layers edit the note under them; long press edits index / volume', (tester) async {
    final (c, rect, g) = await pump(tester);
    double rowY(HitsoundLayer l) => rect.top + g.rowTop(l) + g.rowHeight / 2;
    HitObject at(double t) => c.beatmap.hitObjects.firstWhere((o) => o.time == t);
    Future<void> tapRow(HitsoundLayer l, {double dx = 0}) async {
      await tester.tapAt(Offset(rect.center.dx + dx, rowY(l)));
      await tester.pump(const Duration(milliseconds: 400));
    }

    // The circle at 1333 (whistle) under the playhead.
    c.seek(1333);
    await tester.pump();
    await tapRow(HitsoundLayer.whistle);
    expect(at(1333).hitSound & HitSoundFlags.whistle, 0);
    await tapRow(HitsoundLayer.clap, dx: 5); // within the block
    expect(at(1333).hitSound & HitSoundFlags.clap, isNot(0));
    await tapRow(HitsoundLayer.sampleSet);
    expect(at(1333).sample.normalSet, SampleSet.normal);
    await tapRow(HitsoundLayer.additions);
    expect(at(1333).sample.additionSet, SampleSet.normal);
    await tapRow(HitsoundLayer.additions);
    expect(at(1333).sample.additionSet, SampleSet.soft);
    c.undo();
    await tester.pump();
    expect(at(1333).sample.additionSet, SampleSet.normal);
    expect(find.byType(HitsoundView), findsOneWidget, reason: 'undoing a hitsound edit stays in Hitsound');

    // The slider at 1666: its head edge alone, then its body.
    c.seek(1666);
    await tester.pump();
    await tapRow(HitsoundLayer.finish);
    var s = at(1666) as SliderObject;
    expect(s.edgeSounds, [2 | HitSoundFlags.finish, 0]);
    expect(s.hitSound, 0);
    final mid = (1666 + c.endTimeOf(s)) / 2;
    c.seek(mid);
    await tester.pump();
    await tapRow(HitsoundLayer.whistle);
    s = at(1666) as SliderObject;
    expect(s.hitSound, HitSoundFlags.whistle, reason: 'body whistle');
    expect(s.edgeSounds, [2 | HitSoundFlags.finish, 0], reason: 'edges keep their sounds');
    await tapRow(HitsoundLayer.sampleSet);
    expect((at(1666) as SliderObject).sample.normalSet, SampleSet.normal);

    // Timing row: the point in effect there (the red line at 1000, soft).
    c.seek(3000);
    await tester.pump();
    final red = c.beatmap.timingPoints.first;
    await tapRow(HitsoundLayer.timing);
    expect(c.beatmap.timingPoints.first.sampleSet, SampleSet.drum);
    expect(identical(c.beatmap.timingPoints.first, red), isFalse);
    c.undo();
    await tester.pump();
    expect(c.beatmap.timingPoints.first.sampleSet, SampleSet.soft);
    expect(find.byType(HitsoundView), findsOneWidget);
    c.redo();
    await tester.pump();

    // Long press on the circle at 4333: sample index and own volume.
    c.seek(4333);
    await tester.pump();
    await tester.longPressAt(Offset(rect.center.dx, rowY(HitsoundLayer.sampleSet)));
    await tester.pumpAndSettle();
    expect(find.byType(HitsoundSampleDialog), findsOneWidget);
    expect(find.text('Inherit'), findsOneWidget);
    await tester.tap(find.byTooltip('Raise index'));
    await tester.pump();
    expect(at(4333).sample.index, 1);
    await tester.tap(find.text('Own volume'));
    await tester.pump();
    expect(at(4333).sample.volume, 60, reason: "the timing point's volume");
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    // Long press on the Timing row: the point's index.
    await tester.longPressAt(Offset(rect.center.dx, rowY(HitsoundLayer.timing)));
    await tester.pumpAndSettle();
    expect(find.text('Inherited point 00:03:666'), findsOneWidget);
    await tester.tap(find.byTooltip('Raise index'));
    await tester.pump();
    expect(c.beatmap.timingPoints[1].sampleIndex, 1);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });

  test('note blocks follow the zoom', () {
    final c = _sample();
    c.timelineWidth = 640;
    c.timelineZoom = 0.05;
    final narrow = HitsoundPainter.noteWidthAt(c, 2000);
    c.timelineZoom = 0.3;
    final wide = HitsoundPainter.noteWidthAt(c, 2000);
    expect(wide, greaterThan(narrow));
    expect(narrow, greaterThanOrEqualTo(HitsoundPainter.minNoteWidth));
    expect(wide, lessThanOrEqualTo(HitsoundPainter.maxNoteWidth));
  });
}
