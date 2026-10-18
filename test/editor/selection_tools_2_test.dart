import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/editor/editor_screen.dart';
import 'package:osu_edit/editor/render/playfield_transform.dart';
import 'package:osu_edit/editor/render/timeline_painter.dart';
import 'package:osu_edit/editor/widgets/playfield_view.dart';
import 'package:osu_edit/editor/widgets/timeline_view.dart';
import 'package:osu_edit/platform/beatmap_file_service.dart';

/// P1-3, second part: rotate / scale preview, flip pivot, timeline time
/// drag and range select, modding timestamps, distance snap while moving,
/// saved snap settings, precision placement and multi-finger taps.
///
/// sample_v14: 180 BPM from 1000 (1/4 snap = 83.33 ms). Objects 0 and 1 are
/// circles at (100,100)@1000 and (200,100)@1333, 2 is a bezier slider at
/// (300,150)@1666 (points (250,200), (300,250), length 140), 7 a spinner @6333.
EditorController _sample() => EditorController(
      beatmap: OsuParser.parse(File('test/fixtures/sample_v14.osu').readAsStringSync()),
      document: const BeatmapDocument(fileName: 'sample.osu'),
    );

/// Empty map, 120 BPM from 0.
EditorController _empty() {
  final b = Beatmap.empty();
  b.insertTimingPoint(TimingPoint.red(time: 0, bpm: 120));
  b.revision = 0;
  return EditorController(beatmap: b, document: const BeatmapDocument(fileName: 'new.osu'));
}

List<Vec2> _positions(EditorController c) =>
    (c.selection.toList()..sort((a, b) => a.time.compareTo(b.time))).map((h) => h.position).toList();

void main() {
  group('flip pivot', () {
    test('flips around the playfield centre by default, the selection centre on request', () {
      final c = _sample();
      final objs = c.beatmap.hitObjects;
      c.select(objs[0]);
      c.select(objs[1], additive: true);
      expect(c.pivot, TransformPivot.playfield);
      c.pivot = TransformPivot.selection;
      c.flipSelection(horizontal: true); // around x = 150: the two swap places
      expect(_positions(c), const [Vec2(200, 100), Vec2(100, 100)]);
      c.pivot = TransformPivot.playfield;
      c.flipSelection(horizontal: true);
      expect(_positions(c), const [Vec2(312, 100), Vec2(412, 100)]);
    });
  });

  group('rotate / scale preview', () {
    test('previews inside one transaction and applies as one undo step', () {
      final c = _sample();
      final src = c.serialize();
      final objs = c.beatmap.hitObjects;
      c.select(objs[0]);
      c.select(objs[1], additive: true);
      c.pivot = TransformPivot.selection;
      expect(c.beginTransform(), isTrue);
      expect(c.isTransforming, isTrue);

      expect(c.updateTransform(degrees: 90), isTrue); // around (150, 100), clockwise
      expect(_positions(c), const [Vec2(150, 50), Vec2(150, 150)]);
      expect(c.updateTransform(degrees: 0, scale: 2), isTrue); // always from the originals
      expect(_positions(c), const [Vec2(50, 100), Vec2(250, 100)]);
      expect(c.canUndo, isFalse); // still previewing

      c.endTransform(apply: true);
      expect(c.isTransforming, isFalse);
      expect(_positions(c), const [Vec2(50, 100), Vec2(250, 100)]);
      expect(c.history.undoLabel, 'Rotate / scale');
      c.undo();
      expect(c.serialize(), src);
    });

    test('cancel restores the original objects and leaves no undo step', () {
      final c = _sample();
      final src = c.serialize();
      final a = c.beatmap.hitObjects[0];
      c.select(a);
      c.select(c.beatmap.hitObjects[1], additive: true);
      c.beginTransform();
      c.updateTransform(degrees: 45, scale: 1.3);
      c.endTransform(apply: false);
      expect(c.serialize(), src);
      expect(c.canUndo, isFalse);
      expect(c.selection.any((h) => identical(h, a)), isTrue);
    });

    test('arbitrary angles round to whole pixels; 360° is a no-op', () {
      final c = _empty();
      c.placeCircle(const Vec2(100, 100));
      final a = c.selection.single;
      c.seek(500);
      c.placeCircle(const Vec2(200, 100));
      c.select(a, additive: true);
      c.pivot = TransformPivot.selection;
      c.beginTransform();
      c.updateTransform(degrees: 30);
      // (±50, 0) around (150, 100) → (±43.3, ±25).
      expect(_positions(c), const [Vec2(107, 75), Vec2(193, 125)]);
      c.updateTransform(degrees: 360);
      expect(_positions(c), const [Vec2(100, 100), Vec2(200, 100)]);
      c.endTransform(apply: true);
      expect(c.history.undoLabel, isNot('Rotate / scale')); // nothing changed
    });

    test('scaling a slider scales its path and its (re-snapped) length', () {
      final c = _sample();
      final s = c.beatmap.hitObjects[2] as SliderObject;
      c.select(s);
      c.pivot = TransformPivot.selection;
      c.beginTransform();
      c.updateTransform(scale: 2);
      final t = c.selection.single as SliderObject;
      // Points (300,150), (350,200), (300,250): centre (325, 200).
      expect(t.position, const Vec2(275, 100));
      expect(t.controlPoints, const [Vec2(375, 200), Vec2(275, 300)]);
      expect(t.length, c.timing.snapSliderLength(280, s.time, c.beatmap.sliderMultiplier, c.divisor));
      c.endTransform(apply: true);
    });

    test('keeping slider nodes: sliders only move with their heads; circles still scale', () {
      final c = _sample();
      final objs = [...c.beatmap.hitObjects];
      final s = objs[2] as SliderObject;
      c.select(objs[1]);
      c.select(s, additive: true);
      c.pivot = TransformPivot.playfield;
      c.beginTransform();
      expect(c.updateTransform(scale: 1.2, keepSliderShape: true), isTrue);
      final t = c.selection.whereType<SliderObject>().single;
      final head = (const Vec2(256, 192) + (s.position - const Vec2(256, 192)) * 1.2).roundToInt();
      expect(t.position, head);
      final d = t.position - s.position;
      expect(t.controlPoints, [for (final p in s.controlPoints) p + d], reason: 'same shape');
      expect(t.length, s.length);
      final circle = c.selection.firstWhere((h) => h is! SliderObject);
      expect(circle.position, (const Vec2(256, 192) + (objs[1].position - const Vec2(256, 192)) * 1.2).roundToInt());
      // Off again: the path scales.
      c.updateTransform(scale: 1.2);
      final u = c.selection.whereType<SliderObject>().single;
      expect(u.position, head);
      expect(u.controlPoints, isNot([for (final p in s.controlPoints) p + d]));
      c.endTransform(apply: false);
      expect(identical(c.beatmap.hitObjects[2], s), isTrue);
    });

    test('a result that cannot fit shows the originals and reports it', () {
      final c = _empty();
      c.placeCircle(const Vec2(10, 10));
      final a = c.selection.single;
      c.seek(500);
      c.placeCircle(const Vec2(500, 370));
      c.select(a, additive: true);
      c.beginTransform();
      expect(c.updateTransform(scale: 1.5), isFalse);
      expect(_positions(c), const [Vec2(10, 10), Vec2(500, 370)]);
      expect(c.updateTransform(scale: 0.5), isTrue);
      c.endTransform(apply: false);
    });

    test('spinners stay selected and unchanged; nothing to transform → false', () {
      final c = _sample();
      final spinner = c.beatmap.hitObjects[7];
      c.select(spinner);
      expect(c.beginTransform(), isFalse);
      c.select(c.beatmap.hitObjects[0], additive: true);
      expect(c.beginTransform(), isTrue);
      c.updateTransform(degrees: 90, scale: 1.5);
      c.endTransform(apply: true);
      expect(c.selection.any((h) => identical(h, spinner)), isTrue);
      expect(c.selection, hasLength(2));
    });
  });

  group('timeline', () {
    test('dragging a selected object moves the selection in time, snapped', () {
      final c = _sample();
      final src = c.serialize();
      final objs = c.beatmap.hitObjects;
      c.select(objs[0]);
      c.select(objs[1], additive: true);
      expect(c.beginTimeDrag(objs[1]), isTrue);
      // The grabbed object (at 1333 in the file) lands on the nearest snap.
      c.updateTimeDrag(1333 + 340);
      c.updateTimeDrag(1333 + 345); // same snap: no extra step
      c.endTimeDrag();
      final times = c.selection.map((h) => h.time).toList()..sort();
      expect(times[1], 1667); // 1666.67 stored as a whole ms
      expect(times[0], 1000 + 334); // spacing kept
      expect(c.history.undoLabel, 'Move in time');
      c.undo();
      expect(c.serialize(), src);
    });

    test('time drag needs a selected object, respects lock and stops at 0', () {
      final c = _sample();
      final objs = c.beatmap.hitObjects;
      c.select(objs[0]);
      expect(c.beginTimeDrag(objs[1]), isFalse); // not selected
      c.lockNotes = true;
      expect(c.beginTimeDrag(objs[0]), isFalse);
      c.lockNotes = false;
      expect(c.beginTimeDrag(objs[0]), isTrue);
      c.updateTimeDrag(-5000); // stops at 0
      c.endTimeDrag();
      expect(c.selection.single.time, 0);
      c.undo();
      expect(identical(c.beatmap.hitObjects.first, objs[0]), isTrue);
    });

    test('range select picks every object starting in the range, spinners too', () {
      final c = _sample();
      final objs = c.beatmap.hitObjects;
      c.beginTimelineBox(1700);
      c.updateTimelineBox(900); // either direction
      expect(c.timelineBox, (900.0, 1700.0));
      expect(c.selection, unorderedEquals([objs[0], objs[1], objs[2]]));
      c.updateTimelineBox(1200);
      expect(c.selection, unorderedEquals([objs[1], objs[2]]));
      c.endTimelineBox();
      expect(c.timelineBox, isNull);

      c.beginTimelineBox(6300, additive: true);
      c.updateTimelineBox(6400);
      c.endTimelineBox();
      expect(c.selection, unorderedEquals([objs[1], objs[2], objs[7]]));
    });
  });

  group('timestamps', () {
    test('the selection copies as a stable timestamp', () {
      final c = _sample();
      final objs = c.beatmap.hitObjects;
      expect(c.selectionTimestamp, isNull);
      c.select(objs[1]);
      c.select(objs[0], additive: true);
      final n0 = c.comboOf(objs[0]).number, n1 = c.comboOf(objs[1]).number;
      expect(c.selectionTimestamp, '00:01:000 ($n0,$n1) - ');
    });

    test('going to a timestamp seeks and selects the named objects', () {
      final c = _sample();
      final objs = c.beatmap.hitObjects;
      c.tool = EditorTool.circle;
      final ts = EditorTimestamp.parse('00:01:000 (${c.comboOf(objs[0]).number},${c.comboOf(objs[1]).number}) - ')!;
      expect(c.goToTimestamp(ts), 2);
      expect(c.time.value, 1000);
      expect(c.tool, EditorTool.select);
      expect(c.selection, [objs[0], objs[1]]);

      expect(c.goToTimestamp(const EditorTimestamp(1333)), 0);
      expect(c.time.value, 1333);
      expect(c.selection, isEmpty);
    });
  });

  group('snapping', () {
    test('distance snap keeps the moved object on the ring around the one before it', () {
      final c = _empty();
      c.placeCircle(const Vec2(100, 100)); // at 0
      c.seek(500);
      c.placeCircle(const Vec2(300, 100)); // 1 beat later; ring radius 140 at DS 1
      c.distanceSnap = true;
      c.beginMoveSelection();
      expect(c.moveSnapGuide!.$1, const Vec2(100, 100));
      expect(c.moveSnapGuide!.$2, closeTo(140, 1e-9));
      c.updateMoveSelection(const Vec2(0, 50)); // towards (300, 150)
      c.endMoveSelection();
      expect(c.moveSnapGuide, isNull);
      final p = c.selection.single.position;
      expect(p.distanceTo(const Vec2(100, 100)), closeTo(140, 1));
      expect(p.y, greaterThan(100));
    });

    test('moving the whole pattern has no previous object: free move', () {
      final c = _empty();
      c.placeCircle(const Vec2(100, 100));
      c.seek(500);
      c.placeCircle(const Vec2(300, 100));
      c.distanceSnap = true;
      c.selectAll();
      c.beginMoveSelection();
      expect(c.moveSnapGuide, isNull);
      c.updateMoveSelection(const Vec2(10, 20));
      c.endMoveSelection();
      expect(_positions(c), const [Vec2(110, 120), Vec2(310, 120)]);
    });

    test('grid size and distance spacing are saved in [Editor] and undoable', () {
      final c = _empty();
      c.setGridSize(8);
      expect(c.gridSize, 8);
      expect(c.beatmap.getValue(SectionNames.editor, 'GridSize'), '8');
      c.setDistanceSpacing(1.234); // to 0.01, like stable's Alt+Shift+scroll
      expect(c.distanceSpacing, 1.23);
      expect(c.serialize(), contains('DistanceSpacing: 1.23'));
      c.setDistanceSpacing(10);
      expect(c.distanceSpacing, 6);
      c.undo();
      c.undo();
      expect(c.distanceSpacing, 1);
      c.undo();
      expect(c.gridSize, 32);
      c.setGridSize(5); // not a grid size
      expect(c.canUndo, isFalse);
    });

    test('the placement preview applies the snapping a tap would', () {
      final c = _empty();
      c.tool = EditorTool.circle;
      c.gridSnap = true;
      c.placementCursor = const Vec2(103, 57);
      expect(c.placementPreview, const Vec2(96, 64));
      c.placementCursor = null;
      expect(c.placementPreview, isNull);
    });
  });

  group('touch', () {
    Future<(EditorController, Offset Function(double, double), PlayfieldTransform)> pumpEditor(
        WidgetTester tester) async {
      tester.view.physicalSize = const Size(891, 411);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = _sample();
      await tester.pumpWidget(MaterialApp(home: EditorScreen(controller: c)));
      final area = tester.getRect(find.byType(PlayfieldView));
      final tf = PlayfieldTransform.fit(area.size);
      return (c, (double x, double y) => area.topLeft + tf.toScreen(Vec2(x, y)), tf);
    }

    testWidgets('a touch drag with the circle tool places under the finger, with no magnifier', (tester) async {
      final (c, at, _) = await pumpEditor(tester);
      c.tool = EditorTool.circle;
      c.seek(12000);
      await tester.pump();
      final n = c.beatmap.hitObjects.length;

      final g = await tester.startGesture(at(250, 300));
      await g.moveTo(at(280, 300)); // past the pan slop
      await g.moveTo(at(300, 310));
      await tester.pump();
      expect(c.placementCursor, isNotNull);
      expect(find.byType(RawMagnifier), findsNothing);
      final cursor = c.placementCursor!;
      await g.up();
      await tester.pump();

      expect(find.byType(RawMagnifier), findsNothing);
      expect(c.placementCursor, isNull);
      expect(c.beatmap.hitObjects, hasLength(n + 1));
      final placed = c.selection.single.position;
      expect(placed, Vec2(cursor.x.roundToDouble(), cursor.y.roundToDouble()));
      expect(placed.x, closeTo(300, 1));
      expect(placed.y, closeTo(310, 1));
    });

    testWidgets('two-finger tap undoes, three-finger tap redoes; neither places', (tester) async {
      final (c, at, _) = await pumpEditor(tester);
      c.seek(12000);
      c.placeCircle(const Vec2(256, 300));
      c.tool = EditorTool.circle;
      await tester.pump();
      final n = c.beatmap.hitObjects.length;

      Future<void> tapWith(int fingers) async {
        final gs = [for (var i = 0; i < fingers; i++) await tester.startGesture(at(150.0 + 60 * i, 250), pointer: 10 + i)];
        await tester.pump(const Duration(milliseconds: 50));
        for (final g in gs) {
          await g.up();
        }
        await tester.pump();
      }

      await tapWith(2);
      expect(c.beatmap.hitObjects, hasLength(n - 1));
      await tapWith(3);
      expect(c.beatmap.hitObjects, hasLength(n));
      // A plain tap still places (at another time: on 12000 it would
      // replace the circle placed there).
      c.seek(12500);
      await tester.pump();
      await tester.tapAt(at(100, 300));
      await tester.pump();
      expect(c.beatmap.hitObjects, hasLength(n + 1));
    });

    testWidgets('long-press drag on the timeline selects a time range', (tester) async {
      final (c, _, _) = await pumpEditor(tester);
      c.seek(1333.33);
      await tester.pump();
      final strip = tester.getRect(find.byType(TimelineView));
      double x(double t) => strip.left + TimelinePainter.xOf(t, c.time.value, c.timelineZoom, strip.width);
      final y = strip.top + 4; // above the object line: never grabs an object

      final g = await tester.startGesture(Offset(x(900), y), kind: PointerDeviceKind.touch);
      await tester.pump(const Duration(milliseconds: 700));
      await g.moveTo(Offset(x(1500), y));
      await tester.pump();
      expect(c.timelineBox, isNotNull);
      await g.up();
      await tester.pump();
      final objs = c.beatmap.hitObjects;
      expect(c.selection, unorderedEquals([objs[0], objs[1]]));
      expect(c.timelineBox, isNull);
    });

    testWidgets('tapping empty timeline space does not seek', (tester) async {
      final (c, _, _) = await pumpEditor(tester);
      c.seek(1333.33);
      await tester.pump();
      final strip = tester.getRect(find.byType(TimelineView));
      await tester.tapAt(Offset(strip.left + strip.width * 0.8, strip.top + 4));
      await tester.pump(const Duration(milliseconds: 500));
      expect(c.time.value, 1333.33);
    });

    testWidgets('a fast timeline scrub keeps gliding and slows down; a touch stops it', (tester) async {
      final (c, _, _) = await pumpEditor(tester);
      c.seek(20000);
      await tester.pump();
      final strip = tester.getRect(find.byType(TimelineView));
      final y = strip.top + 4;

      // Slow drag: stops where the finger stops.
      final g = await tester.startGesture(Offset(strip.center.dx, y), kind: PointerDeviceKind.touch);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        await g.moveBy(const Offset(-10, 0));
      }
      await tester.pump(const Duration(milliseconds: 100));
      await g.up();
      await tester.pump();
      final afterSlow = c.time.value;
      await tester.pump(const Duration(milliseconds: 300));
      expect(c.time.value, afterSlow);

      // Fling left: time keeps advancing after release, each step less.
      await tester.flingFrom(Offset(strip.center.dx, y), const Offset(-200, 0), 3000);
      await tester.pump();
      final t0 = c.time.value;
      await tester.pump(const Duration(milliseconds: 100));
      final t1 = c.time.value;
      await tester.pump(const Duration(milliseconds: 100));
      final t2 = c.time.value;
      expect(t1, greaterThan(t0));
      expect(t2 - t1, lessThan(t1 - t0));
      expect(t2 - t1, greaterThan(0));

      // Touching the timeline stops it.
      final stop = await tester.startGesture(Offset(strip.center.dx, y), kind: PointerDeviceKind.touch);
      await tester.pump();
      final stopped = c.time.value;
      await tester.pump(const Duration(milliseconds: 200));
      expect(c.time.value, stopped);
      await stop.up();
      await tester.pump(const Duration(milliseconds: 500));
      expect(c.time.value, stopped);

      // A seek elsewhere stops it too.
      await tester.flingFrom(Offset(strip.center.dx, y), const Offset(-200, 0), 3000);
      await tester.pump(const Duration(milliseconds: 50));
      c.seek(5000);
      await tester.pump(const Duration(milliseconds: 300));
      expect(c.time.value, 5000);
    });

    testWidgets('double-tap then drag on the timeline selects a time range', (tester) async {
      final (c, _, _) = await pumpEditor(tester);
      c.seek(1333.33);
      await tester.pump();
      final src = c.serialize();
      final strip = tester.getRect(find.byType(TimelineView));
      double x(double t) => strip.left + TimelinePainter.xOf(t, c.time.value, c.timelineZoom, strip.width);
      final objs = c.beatmap.hitObjects;
      // Starts on the object line, over an object: still selects, never moves it.
      final y = strip.top + strip.height / 2;
      c.select(objs[0]);
      await tester.pump();

      await tester.tapAt(Offset(x(900), y));
      await tester.pump(const Duration(milliseconds: 80));
      final g = await tester.startGesture(Offset(x(900), y), kind: PointerDeviceKind.touch);
      await tester.pump(const Duration(milliseconds: 20));
      for (final t in [1000.0, 1200.0, 1500.0]) {
        await g.moveTo(Offset(x(t), y));
        await tester.pump();
      }
      expect(c.timelineBox, isNotNull);
      await g.up();
      await tester.pump(const Duration(milliseconds: 500));
      expect(c.selection, unorderedEquals([objs[0], objs[1]]));
      expect(c.timelineBox, isNull);
      expect(c.time.value, 1333.33); // no scrubbing
      expect(c.serialize(), src); // nothing moved

      // A plain drag (no double tap) still scrubs.
      final g2 = await tester.startGesture(Offset(x(1400), strip.top + 4), kind: PointerDeviceKind.touch);
      await tester.pump();
      await g2.moveBy(const Offset(-80, 0));
      await tester.pump();
      await g2.moveBy(const Offset(-80, 0));
      await tester.pump();
      await g2.up();
      await tester.pump();
      expect(c.time.value, greaterThan(1333.33));
      expect(c.timelineBox, isNull);
    });

    testWidgets('the rotate / scale panel previews live; cancel reverts', (tester) async {
      final (c, _, _) = await pumpEditor(tester);
      final src = c.serialize();
      c.seek(1000);
      c.select(c.beatmap.hitObjects[0]);
      c.select(c.beatmap.hitObjects[1], additive: true);
      await tester.pump();

      await tester.tap(find.byTooltip('Rotate… (Ctrl+Shift+R)'));
      await tester.pumpAndSettle();
      expect(c.isTransforming, isTrue);
      expect(find.byType(Slider), findsOneWidget, reason: 'the Rotate panel: the angle only');
      expect(tester.takeException(), isNull);
      await tester.drag(find.byType(Slider).first, const Offset(60, 0));
      await tester.pump();
      expect(c.serialize(), isNot(src)); // previewed
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(c.isTransforming, isFalse);
      expect(c.serialize(), src);

      // The 90° buttons apply at once (the old Rotate L / R), one undo step
      // each; the panel stays open, and Cancel keeps them.
      await tester.tap(find.byTooltip('Rotate… (Ctrl+Shift+R)'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.rotate_right).last);
      await tester.pump();
      expect(c.isTransforming, isTrue, reason: 'panel still open');
      final turned = c.serialize();
      expect(turned, isNot(src));
      await tester.tap(find.byIcon(Icons.rotate_left).last);
      await tester.pump();
      expect(c.serialize(), src, reason: 'turned back');
      await tester.tap(find.byIcon(Icons.rotate_right).last);
      await tester.pump();
      expect(find.text('Apply').hitTestable(), findsOneWidget); // fits a phone without scrolling
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(c.serialize(), turned, reason: 'already applied');
      expect(c.history.undoLabel, 'Rotate');
      c.undo();
      c.undo();
      expect(c.serialize(), turned);
      c.undo();
      expect(c.serialize(), src);

      await tester.tap(find.byTooltip('Scale… (Ctrl+Shift+S)'));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(Slider), const Offset(40, 0)); // drags from the middle: about 1.5x
      await tester.pump();
      expect(find.text('Apply').hitTestable(), findsOneWidget);
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(c.history.undoLabel, 'Scale');
    });
  });
}
