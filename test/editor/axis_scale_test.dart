import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/toast.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/editor/editor_screen.dart';
import 'package:osu_edit/editor/render/playfield_painter.dart';
import 'package:osu_edit/editor/render/playfield_transform.dart';
import 'package:osu_edit/editor/widgets/playfield_view.dart';
import 'package:osu_edit/platform/app_settings.dart';
import 'package:osu_edit/platform/beatmap_file_service.dart';

/// Scaling width and height separately: the Scale panel unlocked and the
/// selection box's side handles.

/// sample_v14: object 2 is a bezier slider at (300,150)@1666, points
/// (350,200), (300,250), length 140.
EditorController _sample() => EditorController(
      beatmap: OsuParser.parse(File('test/fixtures/sample_v14.osu').readAsStringSync()),
      document: const BeatmapDocument(fileName: 'sample.osu'),
    );

EditorController _circles(List<Vec2> at) {
  final b = Beatmap.empty()..insertTimingPoint(TimingPoint.red(time: 0, bpm: 120));
  for (var i = 0; i < at.length; i++) {
    b.insertHitObject(HitCircle(position: at[i], time: 1000.0 + 100 * i));
  }
  b.revision = 0;
  return EditorController(beatmap: b, document: const BeatmapDocument(fileName: 'x.osu'));
}

List<Vec2> _positions(EditorController c) => [for (final h in c.beatmap.hitObjects) h.position];

void main() {
  test('circles scale across and down by different amounts around the pivot', () {
    final c = _circles(const [Vec2(100, 100), Vec2(200, 200)]);
    addTearDown(c.dispose);
    for (final h in c.beatmap.hitObjects) {
      c.select(h, additive: true);
    }
    c.pivot = TransformPivot.selection; // (150, 150)
    expect(c.beginTransform(label: 'Scale'), isTrue);
    expect(c.updateTransform(scale: 1.5, scaleY: 0.5), isTrue);
    expect(_positions(c), const [Vec2(75, 125), Vec2(225, 175)]);
    // Without scaleY both axes follow scale.
    c.updateTransform(scale: 1.5);
    expect(_positions(c), const [Vec2(75, 75), Vec2(225, 225)]);
    c.updateTransform(scale: 1.5, scaleY: 0.5);
    c.endTransform(apply: true);
    expect(c.history.undoLabel, 'Scale');
    c.undo();
    expect(_positions(c), const [Vec2(100, 100), Vec2(200, 200)]);
  });

  test('a slider stretched across: points move across only, length from the stretched path', () {
    final c = _sample();
    addTearDown(c.dispose);
    final s = c.beatmap.hitObjects[2] as SliderObject;
    c.select(s);
    c.pivot = TransformPivot.selection;
    c.beginTransform(label: 'Scale');
    expect(c.updateTransform(scale: 2, scaleY: 1), isTrue);
    final t = c.selection.single as SliderObject;
    // Points (300,150), (350,200), (300,250): centre x 325.
    expect(t.position, const Vec2(275, 150));
    expect(t.controlPoints, const [Vec2(375, 200), Vec2(275, 250)]);
    final v = SliderPath.of(s).vertices;
    var stretched = 0.0;
    for (var i = 1; i < v.length; i++) {
      stretched += (Vec2((v[i].x - v[i - 1].x) * 2, v[i].y - v[i - 1].y)).length;
    }
    expect(stretched, inExclusiveRange(s.length, s.length * 2));
    expect(t.length, c.timing.snapSliderLength(stretched, s.time, c.beatmap.sliderMultiplier, c.divisor));
    c.endTransform(apply: false);
    expect(identical(c.beatmap.hitObjects[2], s), isTrue);
  });

  test('keeping slider nodes: a stretched slider only moves with its head', () {
    final c = _sample();
    addTearDown(c.dispose);
    final objs = [...c.beatmap.hitObjects];
    final s = objs[2] as SliderObject;
    c.select(objs[1]);
    c.select(s, additive: true);
    c.pivot = TransformPivot.playfield;
    c.beginTransform(label: 'Scale');
    expect(c.updateTransform(scale: 1, scaleY: 1.2, keepSliderShape: true), isTrue);
    final t = c.selection.whereType<SliderObject>().single;
    expect(t.position, Vec2(s.position.x, (192 + (s.position.y - 192) * 1.2).roundToDouble()));
    final d = t.position - s.position;
    expect(t.controlPoints, [for (final p in s.controlPoints) p + d]);
    expect(t.length, s.length);
    c.endTransform(apply: false);
  });

  test('free transform reads out width and height', () {
    final c = _circles(const [Vec2(206, 150), Vec2(306, 250)]);
    addTearDown(c.dispose);
    for (final h in c.beatmap.hitObjects) {
      c.select(h, additive: true);
    }
    c.beginTransform(label: 'Scale');
    expect(c.updateFreeTransform(pivot: const Vec2(206, 150), scale: 1.5, scaleY: 1), isTrue);
    expect(_positions(c), const [Vec2(206, 150), Vec2(356, 250)]);
    expect(c.freeTransformShown, (0.0, 1.5, 1.0));
    c.endTransform(apply: true);
    expect(c.freeTransformShown, isNull);
  });

  test('a handle drag past the playfield edge keeps the pivot side fixed', () {
    final c = _circles(const [Vec2(206, 150), Vec2(306, 250)]);
    addTearDown(c.dispose);
    for (final h in c.beatmap.hitObjects) {
      c.select(h, additive: true);
    }
    c.beginTransform(label: 'Scale');
    const pivot = Vec2(206, 150);
    expect(c.updateFreeTransform(pivot: pivot, scale: 1.5, shiftToFit: false), isTrue);
    // x would reach 206 + 100 * 3 = 506 < 512 fits; 4x does not: it is refused, not shifted left.
    expect(c.updateFreeTransform(pivot: pivot, scale: 4, scaleY: 1, shiftToFit: false), isFalse);
    expect(_positions(c).first, pivot);
    // The panel/two-finger path still shifts back in.
    expect(c.updateFreeTransform(pivot: pivot, scale: 4, scaleY: 1), isTrue);
    expect(_positions(c).first, isNot(pivot));
    c.endTransform(apply: false);
  });

  test('side handles: only on long enough sides, only for axes the objects spread along', () {
    const rect = Rect.fromLTWH(0, 0, 200, 60);
    expect(PlayfieldPainter.selectionEdgeHandles(rect).map((e) => e.$1),
        [rect.centerLeft, rect.centerRight, rect.topCenter, rect.bottomCenter]);
    // A row of circles: the box is just padding up and down.
    expect(PlayfieldPainter.selectionEdgeHandles(rect, padding: 30), [(rect.centerLeft, true), (rect.centerRight, true)]);
    // Too short sides have none.
    expect(PlayfieldPainter.selectionEdgeHandles(const Rect.fromLTWH(0, 0, 40, 40)), isEmpty);
  });

  test('the aspect lock is a saved setting, on by default', () {
    expect(EditSettings().scaleLocksAspect, isTrue);
    expect(EditSettings.fromJson(const {}).scaleLocksAspect, isTrue);
    final off = EditSettings(scaleLocksAspect: false);
    expect(EditSettings.fromJson(off.toJson()).scaleLocksAspect, isFalse);
  });

  group('touch', () {
    Future<(EditorController, Rect, PlayfieldTransform)> pump(WidgetTester tester, List<Vec2> at) async {
      tester.view.physicalSize = const Size(891, 411);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = _circles(at);
      await tester.pumpWidget(MaterialApp(builder: (_, child) => ToastHost(child: child), home: EditorScreen(controller: c)));
      c.seek(1000);
      for (final h in c.beatmap.hitObjects) {
        c.select(h, additive: true);
      }
      await tester.pump();
      final area = tester.getRect(find.byType(PlayfieldView));
      final tf = PlayfieldTransform.fit(area.size, c.playfieldZoom.value);
      final (min, max) = c.selectionBounds!;
      final (rect, _) = PlayfieldPainter.selectionBoxGeometry(min, max, tf, area.size);
      return (c, rect.shift(area.topLeft), tf);
    }

    testWidgets('dragging the right side stretches across from the left side', (tester) async {
      final (c, rect, tf) = await pump(tester, const [Vec2(206, 160), Vec2(306, 230)]);
      final g = await tester.startGesture(rect.centerRight);
      await g.moveBy(const Offset(30, 0));
      // Up / down movement is ignored by a side handle.
      await g.moveBy(Offset(rect.width * 0.5 - 30, 40));
      await tester.pump();
      await g.up();
      await tester.pump();
      expect(c.history.undoLabel, 'Scale');
      final p = _positions(c);
      expect(p[0], const Vec2(206, 160), reason: 'the left side stays');
      expect(p[1].y, 230);
      expect(p[1].x, greaterThan(306 + 50));
      final area = tester.getRect(find.byType(PlayfieldView));
      final (_, max) = c.selectionBounds!;
      expect(area.topLeft.dx + tf.toScreen(max).dx, closeTo(rect.right + rect.width * 0.5, 1.5));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('dragging the top side stretches down from the bottom side', (tester) async {
      final (c, rect, _) = await pump(tester, const [Vec2(206, 160), Vec2(306, 230)]);
      final g = await tester.startGesture(rect.topCenter);
      await g.moveBy(const Offset(0, 30));
      await g.moveBy(const Offset(25, 0));
      await tester.pump();
      await g.up();
      await tester.pump();
      expect(c.history.undoLabel, 'Scale');
      final p = _positions(c);
      expect(p[1], const Vec2(306, 230), reason: 'the bottom side stays');
      expect(p[0].x, 206);
      expect(p[0].y, greaterThan(160));
      await tester.pumpWidget(const SizedBox());
    });
    Rect boxNow(WidgetTester tester, EditorController c, PlayfieldTransform tf) {
      final area = tester.getRect(find.byType(PlayfieldView));
      final (min, max) = c.selectionBounds!;
      return Rect.fromPoints(tf.toScreen(min), tf.toScreen(max)).shift(area.topLeft);
    }

    testWidgets('the box lock button toggles the setting the Scale panel uses', (tester) async {
      final (c, _, _) = await pump(tester, const [Vec2(206, 160), Vec2(306, 230)]);
      expect(c.scaleLocksAspect, isTrue);
      await tester.tap(find.byTooltip('Unlock width / height'));
      await tester.pump();
      expect(c.scaleLocksAspect, isFalse);
      expect(find.byTooltip('Lock width / height'), findsOneWidget);
      expect(find.textContaining('Aspect ratio unlocked'), findsOneWidget);

      // The panel opens unlocked; locking there locks the box too.
      await tester.tap(find.byTooltip('Scale… (Ctrl+Shift+S)'));
      await tester.pumpAndSettle();
      expect(find.text('Width'), findsOneWidget);
      expect(find.text('Height'), findsOneWidget);
      await tester.tap(find.byTooltip('Lock width / height').last);
      await tester.pump();
      expect(c.scaleLocksAspect, isTrue);
      expect(find.text('Width'), findsNothing);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Unlock width / height'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('unlocked, a corner follows the finger in both axes', (tester) async {
      final (c, rect, tf) = await pump(tester, const [Vec2(206, 160), Vec2(306, 230)]);
      c.scaleLocksAspect = false;
      await tester.pump();
      final g = await tester.startGesture(rect.bottomRight);
      await g.moveBy(const Offset(30, 0));
      await g.moveBy(const Offset(30, 0)); // only across
      await tester.pump();
      await g.up();
      await tester.pump();
      expect(c.history.undoLabel, 'Scale');
      final p = _positions(c);
      expect(p[0], const Vec2(206, 160));
      expect(p[1].y, 230, reason: 'the height stays');
      final box = boxNow(tester, c, tf);
      expect(box.right, closeTo(rect.right + 60, 1.5));
      expect(box.bottom, closeTo(rect.bottom, 1.5));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('unlocked, two fingers side by side stretch only the width, without turning', (tester) async {
      final (c, rect, tf) = await pump(tester, const [Vec2(206, 160), Vec2(306, 230)]);
      c.scaleLocksAspect = false;
      await tester.pump();
      final a = await tester.startGesture(rect.center - const Offset(30, 0), pointer: 1);
      final b = await tester.startGesture(rect.center + const Offset(30, 0), pointer: 2);
      await tester.pump();
      for (var i = 0; i < 6; i++) {
        await a.moveBy(const Offset(-5, 0));
        await b.moveBy(const Offset(5, 3)); // a slight turn: ignored
        await tester.pump();
      }
      await a.up();
      await b.up();
      await tester.pump();
      expect(c.history.undoLabel, 'Scale');
      // The box moves with the fingers (down a little) but keeps its height
      // and doesn't turn.
      final p = _positions(c);
      expect(p[1].y - p[0].y, 70);
      expect(p[1].x - p[0].x, greaterThan(150));
      final box = boxNow(tester, c, tf);
      // The fingers' spread across doubled (60 → 120): so did the box's width.
      expect(box.width / rect.width, closeTo(2, 0.03));
      expect(box.height, closeTo(rect.height, 1.5));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('unlocked, two fingers apart diagonally stretch each axis with their spread', (tester) async {
      final (c, rect, tf) = await pump(tester, const [Vec2(206, 160), Vec2(306, 230)]);
      c.scaleLocksAspect = false;
      await tester.pump();
      final a = await tester.startGesture(rect.center - const Offset(30, 30), pointer: 1);
      final b = await tester.startGesture(rect.center + const Offset(30, 30), pointer: 2);
      await tester.pump();
      for (var i = 0; i < 6; i++) {
        await a.moveBy(const Offset(0, -5));
        await b.moveBy(const Offset(0, 5)); // only down: 60 → 120
        await tester.pump();
      }
      await a.up();
      await b.up();
      await tester.pump();
      final box = boxNow(tester, c, tf);
      expect(box.height / rect.height, closeTo(2, 0.03));
      expect(box.width, closeTo(rect.width, 1.5));
      expect(box.center, within(distance: 1.5, from: rect.center));
      await tester.pumpWidget(const SizedBox());
    });
  });
}
