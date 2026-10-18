import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/editor/render/timeline_painter.dart';
import 'package:osu_edit/editor/widgets/timeline_view.dart';
import 'package:osu_edit/platform/beatmap_file_service.dart';

/// 120 BPM from 0 (1/4 snap = 125 ms), AR 9 (preempt 600), circles at 1000,
/// 5000 and 5500.
String map(String breakLines) => 'osu file format v14\r\n'
    '\r\n'
    '[Editor]\r\n'
    'BeatDivisor: 4\r\n'
    '\r\n'
    '[Difficulty]\r\n'
    'ApproachRate:9\r\n'
    '\r\n'
    '[Events]\r\n'
    '//Break Periods\r\n'
    '$breakLines'
    '\r\n'
    '[TimingPoints]\r\n'
    '0,500,4,2,0,100,1,0\r\n'
    '\r\n'
    '\r\n'
    '[HitObjects]\r\n'
    '100,100,1000,1,0,0:0:0:0:\r\n'
    '100,100,5000,1,0,0:0:0:0:\r\n'
    '100,100,5500,1,0,0:0:0:0:\r\n';

EditorController controller(String src) => EditorController(
      beatmap: OsuParser.parse(src),
      document: const BeatmapDocument(fileName: 'b.osu'),
    );

void main() {
  test('add / remove are one undo step each', () {
    final src = map('');
    final c = controller(src);
    expect(c.insertableBreaks, [(1200.0, 4550.0)]);
    c.addBreak(c.insertableBreaks.single);
    expect(c.beatmap.breaks, [(1200.0, 4550.0)]);
    expect(c.insertableBreaks, isEmpty);
    // The gap 1000..5000 must keep its break.
    expect(c.canRemoveBreak(c.breaks.single), isFalse);
    expect(c.removeBreak(c.breaks.single), isFalse);
    expect(c.beatmap.breaks, [(1200.0, 4550.0)]);
    c.undo();
    expect(c.serialize(), src);
    expect(c.canUndo, isFalse);
  });

  test('a break outside the objects can be deleted', () {
    final src = map('2,6000,7000\r\n');
    final c = controller(src);
    expect(c.removeBreak(c.breaks.single), isTrue);
    expect(c.beatmap.breaks, isEmpty);
    c.undo();
    expect(c.serialize(), src);
  });

  test('a break in a gap too short for one can be deleted', () {
    // Objects 5000 and 5500: gap 500 < minGap, a break there is invalid anyway.
    final c = controller(map('2,5100,5400\r\n'));
    expect(c.removeBreak(c.breaks.single), isTrue);
    expect(c.beatmap.breaks, isEmpty);
  });

  test('edge drag snaps, stays clear of objects, and undoes in one step', () {
    final src = map('2,2000,3000\r\n');
    final c = controller(src);
    expect(c.beginBreakDrag(c.breaks.single, end: true), isTrue);
    c.updateBreakDrag(3540); // snaps to 3500
    expect(c.beatmap.breaks, [(2000.0, 3500.0)]);
    c.updateBreakDrag(9000); // at most 450 before the object at 5000
    expect(c.beatmap.breaks, [(2000.0, 4550.0)]);
    c.endBreakDrag();
    expect(c.breakDrag, isNull);

    c.beginBreakDrag(c.breaks.single, end: false);
    c.updateBreakDrag(0); // at least 200 after the object at 1000
    c.endBreakDrag();
    expect(c.beatmap.breaks, [(1200.0, 4550.0)]);
    c.undo();
    c.undo();
    expect(c.serialize(), src);
    expect(c.canUndo, isFalse);
  });

  test('an untouched drag leaves no undo step', () {
    final c = controller(map('2,2000,3000\r\n'));
    c.beginBreakDrag(c.breaks.single, end: false);
    c.updateBreakDrag(2010); // snaps back to 2000
    c.endBreakDrag();
    expect(c.canUndo, isFalse);
  });

  group('automatic regeneration (lazer)', () {
    test('opening a map changes nothing, even with gaps and odd breaks', () {
      final src = map('2,2000,3000\r\n');
      final c = controller(src);
      expect(c.serialize(), src);
    });

    test('moving objects redoes the breaks in the same undo step', () {
      final src = map('2,2000,3000\r\n');
      final c = controller(src);
      final last = c.beatmap.hitObjects.last; // 5500
      c.select(last);
      c.deleteSelection();
      // Times changed: the file break is automatic, so it becomes the longest one.
      expect(c.beatmap.breaks, [(1200.0, 4550.0)]);
      c.undo();
      expect(c.serialize(), src);
      c.redo();
      expect(c.beatmap.breaks, [(1200.0, 4550.0)]);
    });

    test('a gap that opens up gets a break; one that closes loses it', () {
      final c = controller(map(''));
      final objs = c.beatmap.hitObjects;
      // Move the object at 5000 to 2000: gap 1000..2000 too short, 2000..5500 gets one.
      c.history.execute(ReplaceHitObjectsCommand([objs[1]], [objs[1].shiftedInTime(-3000)]));
      expect(c.beatmap.breaks, [(2200.0, 5050.0)]);
      c.undo();
      expect(c.beatmap.breaks, isEmpty);
    });

    test('a time drag regenerates once, at the end', () {
      final c = controller(map(''));
      final o = c.beatmap.hitObjects[1]; // 5000
      c.select(o);
      expect(c.beginTimeDrag(o), isTrue);
      c.updateTimeDrag(4000);
      c.updateTimeDrag(3000);
      expect(c.beatmap.breaks, isEmpty); // not during the drag
      c.endTimeDrag();
      expect(c.beatmap.breaks, [(1200.0, 2550.0), (3200.0, 5050.0)]);
      c.undo();
      expect(c.beatmap.breaks, isEmpty);
      expect(c.beatmap.hitObjects[1].time, 5000);
    });

    test('a break the user dragged stays while valid', () {
      final c = controller(map(''));
      c.addBreak(c.insertableBreaks.single); // 1200..4550
      c.beginBreakDrag(c.breaks.single, end: true);
      c.updateBreakDrag(3000);
      c.endBreakDrag();
      expect(c.beatmap.breaks, [(1200.0, 3000.0)]);

      final objs = c.beatmap.hitObjects;
      c.history.execute(ReplaceHitObjectsCommand([objs[2]], [objs[2].shiftedInTime(100)])); // 5500 -> 5600
      expect(c.beatmap.breaks, [(1200.0, 3000.0)]); // kept

      // An object moved into it: dropped, the gaps get automatic ones again.
      final mid = c.beatmap.hitObjects[1];
      c.history.execute(ReplaceHitObjectsCommand([mid], [mid.shiftedInTime(-2500)])); // 5000 -> 2500
      expect(c.beatmap.breaks, [(1200.0, 2050.0), (2700.0, 5150.0)]);
    });

    test('break edits alone do not regenerate', () {
      final c = controller(map(''));
      c.addBreak(c.insertableBreaks.single);
      c.undo();
      expect(c.beatmap.breaks, isEmpty);
    });
  });

  test('the background dim is 0.3 lighter inside a break', () {
    final c = controller(map('2,1200,4550\r\n'));
    c.backgroundDim = 0.7;
    expect(c.backgroundDimAt(1000), 0.7);
    expect(c.backgroundDimAt(3000), closeTo(0.4, 1e-9));
    c.backgroundDim = 0.2;
    expect(c.backgroundDimAt(3000), 0); // never below 0
  });

  test('the background dim is also lighter in the intro and outro', () {
    final c = controller(map('')); // objects 1000..5500, AR 9: intro until -1000
    c.backgroundDim = 0.7;
    expect(c.backgroundDimAt(-2000), closeTo(0.4, 1e-9));
    expect(c.backgroundDimAt(0), 0.7); // 1000 ms after the intro ended
    expect(c.backgroundDimAt(5500), 0.7);
    expect(c.backgroundDimAt(7000), closeTo(0.4, 1e-9));
  });

  test('a break with an object inside is invalid', () {
    final c = controller(map('2,4000,5200\r\n'));
    expect(c.isBreakInvalid(c.breaks.single), isTrue);
  });

  group('timeline', () {
    Future<(EditorController, Rect)> pump(WidgetTester tester, String src, {double at = 2800}) async {
      final c = controller(src);
      c.timelineZoom = 0.2; // 1 s = 200 px
      c.seek(at);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: Center(child: SizedBox(width: 1200, child: TimelineView(controller: c, height: 44)))),
      ));
      return (c, tester.getRect(find.byType(TimelineView)));
    }

    double x(EditorController c, Rect strip, double t) =>
        strip.left + TimelinePainter.xOf(t, c.time.value, c.timelineZoom, strip.width);

    testWidgets('tapping "+ Break" adds the suggested break, "Break x" deletes it', (tester) async {
      final src = map('');
      final (c, strip) = await pump(tester, src);
      Rect pill(double s, double e) =>
          TimelinePainter.breakPillRect(s, e, c.time.value, c.timelineZoom, strip.width, strip.height)!
              .shift(strip.topLeft);

      await tester.tapAt(pill(1200, 4550).center);
      await tester.pump(const Duration(milliseconds: 500));
      expect(c.beatmap.breaks, [(1200.0, 4550.0)]);

      // The gap is long enough for a break, so tapping it again can't delete it.
      await tester.tapAt(pill(1200, 4550).center);
      await tester.pump(const Duration(milliseconds: 500));
      expect(c.beatmap.breaks, [(1200.0, 4550.0)]);
      c.undo();
      expect(c.serialize(), src);
    });

    testWidgets('"Break x" deletes a break the gap does not need', (tester) async {
      final src = map('2,6000,7000\r\n');
      final (c, strip) = await pump(tester, src);
      c.seek(6500);
      await tester.pump();
      final r = TimelinePainter.breakPillRect(6000, 7000, c.time.value, c.timelineZoom, strip.width, strip.height)!
          .shift(strip.topLeft);
      await tester.tapAt(r.center);
      await tester.pump(const Duration(milliseconds: 500));
      expect(c.beatmap.breaks, isEmpty);
      c.undo();
      expect(c.serialize(), src);
    });

    testWidgets('dragging an edge moves it instead of scrubbing', (tester) async {
      final (c, strip) = await pump(tester, map('2,2000,3000\r\n'));
      final y = strip.top + 6;
      final g = await tester.startGesture(Offset(x(c, strip, 3000), y), kind: PointerDeviceKind.touch);
      for (final t in [3200.0, 3500.0, 3750.0]) {
        await g.moveTo(Offset(x(c, strip, t), y));
        await tester.pump();
      }
      expect(c.breakDrag, isNotNull);
      await g.up();
      await tester.pump(const Duration(milliseconds: 500));
      expect(c.time.value, 2800); // no scrubbing
      expect(c.beatmap.breaks, [(2000.0, 3750.0)]);
      expect(c.history.undoLabel, 'Change break');
    });

    testWidgets('Timing mode shows breaks but does not edit them', (tester) async {
      final c = controller(map('2,2000,3000\r\n'));
      c.timelineZoom = 0.2;
      c.seek(2800);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Center(
                child: SizedBox(
                    width: 1200, child: TimelineView(controller: c, height: 44, objectsInBackground: true)))),
      ));
      final strip = tester.getRect(find.byType(TimelineView));
      await tester.dragFrom(Offset(x(c, strip, 3000), strip.top + 6), const Offset(100, 0));
      await tester.pump(const Duration(milliseconds: 500));
      expect(c.beatmap.breaks, [(2000.0, 3000.0)]);
      expect(c.canUndo, isFalse);
    });
  });
}
