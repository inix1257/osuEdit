import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/editor/editor_screen.dart';
import 'package:osu_edit/editor/render/playfield_painter.dart';
import 'package:osu_edit/editor/render/playfield_transform.dart';
import 'package:osu_edit/editor/widgets/playfield_view.dart';
import 'package:osu_edit/platform/beatmap_file_service.dart';

/// Two circles 100 px apart at the same moment of the screen.
EditorController _controller() {
  final b = Beatmap.empty()..insertTimingPoint(TimingPoint.red(time: 0, bpm: 120));
  b.insertHitObject(HitCircle(position: const Vec2(206, 192), time: 1000));
  b.insertHitObject(HitCircle(position: const Vec2(306, 192), time: 1100));
  b.revision = 0;
  return EditorController(beatmap: b, document: const BeatmapDocument(fileName: 'x.osu'));
}

void main() {
  test('the box shows for two objects or a slider, with the Select tool', () {
    final c = _controller();
    addTearDown(c.dispose);
    final objs = c.beatmap.hitObjects;
    c.select(objs[0]);
    expect(c.showsSelectionBox, isFalse, reason: 'a lone circle has nothing to rotate');
    c.select(objs[1], additive: true);
    expect(c.showsSelectionBox, isTrue);
    final (min, max) = c.selectionBounds!;
    final r = c.circleRadius;
    expect(min, Vec2(206 - r, 192 - r));
    expect(max, Vec2(306 + r, 192 + r));
    c.tool = EditorTool.circle;
    expect(c.showsSelectionBox, isFalse);
  });

  test('free transform: rotate around a pivot, scale, move; one undo step; out of bounds keeps the last fit', () {
    final c = _controller();
    addTearDown(c.dispose);
    final objs = c.beatmap.hitObjects;
    c.select(objs[0]);
    c.select(objs[1], additive: true);
    expect(c.beginTransform(label: 'Rotate / scale'), isTrue);
    c.updateFreeTransform(pivot: const Vec2(256, 192), radians: math.pi / 2);
    expect(c.selection.map((h) => h.position), containsAll(const [Vec2(256, 142), Vec2(256, 242)]));
    c.updateFreeTransform(pivot: const Vec2(256, 192), scale: 2, offset: const Vec2(10, 0));
    expect(c.selection.map((h) => h.position), containsAll(const [Vec2(166, 192), Vec2(366, 192)]));
    expect(c.updateFreeTransform(pivot: const Vec2(256, 192), scale: 20), isFalse);
    expect(c.selection.map((h) => h.position), containsAll(const [Vec2(166, 192), Vec2(366, 192)]));
    c.endTransform(apply: true);
    expect(c.history.undoLabel, 'Rotate / scale');
    c.undo();
    expect(c.beatmap.hitObjects.map((h) => h.position), [const Vec2(206, 192), const Vec2(306, 192)]);
  });

  test('the rotation handle stays on screen for a box as tall as the view', () {
    final tf = PlayfieldTransform.fit(const Size(800, 400));
    final (_, above) = PlayfieldPainter.selectionBoxGeometry(const Vec2(200, 150), const Vec2(300, 250), tf, const Size(800, 400));
    final (rect, tall) = PlayfieldPainter.selectionBoxGeometry(const Vec2(0, -40), const Vec2(512, 424), tf, const Size(800, 400));
    expect(above.dy, greaterThanOrEqualTo(16));
    expect(rect.top, lessThan(0));
    expect(tall.dy, inInclusiveRange(16, 384));
  });

  test('right angles stick within 6 degrees', () {
    expect(EditorController.snapRightAngle(85), 90);
    expect(EditorController.snapRightAngle(176), 180);
    expect(EditorController.snapRightAngle(-94), -90);
    expect(EditorController.snapRightAngle(266), 270);
    expect(EditorController.snapRightAngle(3), 0);
    expect(EditorController.snapRightAngle(80), 80);
    expect(EditorController.snapRightAngle(45), 45);
  });

  group('touch', () {
    Future<(EditorController, Rect, Offset, PlayfieldTransform)> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(891, 411);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = _controller();
      await tester.pumpWidget(MaterialApp(home: EditorScreen(controller: c)));
      c.seek(1000);
      final objs = c.beatmap.hitObjects;
      c.select(objs[0]);
      c.select(objs[1], additive: true);
      await tester.pump();
      final area = tester.getRect(find.byType(PlayfieldView));
      final tf = PlayfieldTransform.fit(area.size, c.playfieldZoom.value);
      final (min, max) = c.selectionBounds!;
      final (rect, handle) = PlayfieldPainter.selectionBoxGeometry(min, max, tf, area.size);
      return (c, rect.shift(area.topLeft), handle + area.topLeft, tf);
    }

    List<Vec2> positions(EditorController c) => [for (final h in c.beatmap.hitObjects) h.position];

    testWidgets('dragging a corner scales from the opposite corner', (tester) async {
      final (c, rect, _, tf) = await pump(tester);
      final g = await tester.startGesture(rect.bottomRight);
      await g.moveBy(const Offset(30, 0));
      await g.moveBy(Offset(rect.width * 0.5 - 30, rect.height * 0.5));
      await tester.pump();
      await g.up();
      await tester.pump();
      expect(c.history.undoLabel, 'Scale');
      // The box's corner is where the finger let go and the opposite one
      // stayed (the circles in a row: only the width can follow).
      final area = tester.getRect(find.byType(PlayfieldView));
      final (min, max) = c.selectionBounds!;
      final finger = rect.bottomRight + Offset(rect.width * 0.5, rect.height * 0.5);
      expect(area.topLeft.dx + tf.toScreen(max).dx, closeTo(finger.dx, 1.5));
      expect(area.topLeft + tf.toScreen(min), within(distance: 1.5, from: rect.topLeft));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('dragging the round handle rotates around the centre', (tester) async {
      final (c, rect, handle, _) = await pump(tester);
      final g = await tester.startGesture(handle);
      await g.moveBy(const Offset(30, 0));
      // To the right of the centre: a quarter turn clockwise.
      await g.moveTo(Offset(rect.center.dx + 200, rect.center.dy));
      await tester.pump();
      await g.up();
      await tester.pump();
      expect(c.history.undoLabel, 'Rotate');
      expect(positions(c), containsAll(const [Vec2(256, 142), Vec2(256, 242)]));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('turning the handle counter-clockwise reads negative, past -180 too', (tester) async {
      final (c, rect, handle, _) = await pump(tester);
      final o = rect.center;
      final g = await tester.startGesture(handle);
      await g.moveBy(const Offset(-30, 0));
      // Up -> left -> down -> right: three quarters counter-clockwise.
      for (final p in const [Offset(-150, -150), Offset(-200, 0), Offset(-150, 150), Offset(0, 200), Offset(150, 150), Offset(200, 0)]) {
        await g.moveTo(o + p);
        await tester.pump();
      }
      expect(c.freeTransformShown!.$1, closeTo(-270, 0.01), reason: 'snapped, not wrapped to +90');
      await g.up();
      await tester.pump();
      expect(c.freeTransformShown, isNull);
      expect(positions(c), containsAll(const [Vec2(256, 142), Vec2(256, 242)]), reason: 'same as +90');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('two fingers on the box rotate / scale / move it; elsewhere they zoom', (tester) async {
      final (c, rect, _, tf) = await pump(tester);
      final a = await tester.startGesture(rect.centerLeft + const Offset(20, 0), pointer: 1);
      final b = await tester.startGesture(rect.centerRight - const Offset(20, 0), pointer: 2);
      await tester.pump();
      // Spread to about twice the distance.
      final span = rect.width - 40;
      for (var i = 1; i <= 5; i++) {
        await a.moveBy(Offset(-span / 10, 0));
        await b.moveBy(Offset(span / 10, 0));
        await tester.pump();
      }
      await a.up();
      await b.up();
      await tester.pump();
      expect(c.history.undoLabel, 'Rotate / scale');
      // The box spread with the fingers: twice as wide, around the same centre.
      final area0 = tester.getRect(find.byType(PlayfieldView));
      final (min, max) = c.selectionBounds!;
      final box = Rect.fromPoints(tf.toScreen(min), tf.toScreen(max)).shift(area0.topLeft);
      expect(box.width / rect.width, closeTo(2, 0.02));
      expect(box.center, within(distance: 1.5, from: rect.center));
      expect(c.playfieldZoom.value.isZoomed, isFalse, reason: 'no zoom');

      // Far from the box (and clear of the selection strips): a pinch zooms
      // as before.
      final area = tester.getRect(find.byType(PlayfieldView));
      final start = area.topLeft + tf.toScreen(const Vec2(120, 370));
      final x = start.dx, y = start.dy;
      final z1 = await tester.startGesture(Offset(x, y), pointer: 3);
      final z2 = await tester.startGesture(Offset(x + 40, y), pointer: 4);
      for (var i = 0; i < 5; i++) {
        await z2.moveBy(const Offset(20, 0));
        await tester.pump();
      }
      await z1.up();
      await z2.up();
      await tester.pump();
      expect(c.playfieldZoom.value.isZoomed, isTrue);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('two fingers on the box: the box follows them from touch-down', (tester) async {
      final (c, rect, _, tf) = await pump(tester);
      final area = tester.getRect(find.byType(PlayfieldView));
      // One finger still near the left edge, the other moves right and down.
      final still = rect.centerLeft + const Offset(15, 0);
      final moving0 = rect.centerRight - const Offset(15, 0);
      final a = await tester.startGesture(still, pointer: 1);
      final b = await tester.startGesture(moving0, pointer: 2);
      final target = moving0 + const Offset(120, 0);
      for (var i = 1; i <= 8; i++) {
        await b.moveTo(Offset.lerp(moving0, target, i / 8)!);
        await tester.pump();
      }
      await a.up();
      await b.up();
      await tester.pump();
      // Scaled by the fingers' spread around the still finger.
      final k = (target - still).distance / (moving0 - still).distance;
      final (min, max) = c.selectionBounds!;
      final box = Rect.fromPoints(tf.toScreen(min), tf.toScreen(max)).shift(area.topLeft);
      expect(box.left, closeTo(still.dx + (rect.left - still.dx) * k, 1.5));
      expect(box.right, closeTo(still.dx + (rect.right - still.dx) * k, 1.5));
      await tester.pumpWidget(const SizedBox());
    });
  });
}
