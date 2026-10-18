import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/editor/editor_screen.dart';
import 'package:osu_edit/editor/render/playfield_transform.dart';
import 'package:osu_edit/editor/widgets/playfield_view.dart';
import 'package:osu_edit/platform/beatmap_file_service.dart';

/// Pinch zoom of the playfield view.
///
/// sample_v14: circles at (100,100)@1000 and (200,100)@1333.
EditorController _sample() => EditorController(
      beatmap: OsuParser.parse(File('test/fixtures/sample_v14.osu').readAsStringSync()),
      document: const BeatmapDocument(fileName: 'sample.osu'),
    );

void main() {
  group('transform', () {
    const size = Size(800, 400);

    test('no zoom is the plain fit', () {
      final a = PlayfieldTransform.fit(size), b = PlayfieldTransform.fit(size, PlayfieldZoom.none);
      expect(b.scale, a.scale);
      expect(b.origin, a.origin);
    });

    test('zoomKeeping keeps the anchor under the focal point', () {
      final z = PlayfieldTransform.zoomKeeping(size, const Vec2(200, 150), const Offset(300, 180), 3);
      expect(z.factor, 3);
      final tf = PlayfieldTransform.fit(size, z);
      expect(tf.scale, closeTo(PlayfieldTransform.fit(size).scale * 3, 1e-9));
      final p = tf.toScreen(const Vec2(200, 150));
      expect(p.dx, closeTo(300, 1e-6));
      expect(p.dy, closeTo(180, 1e-6));
    });

    test('clamps the factor and keeps the centre on the playfield', () {
      expect(PlayfieldZoom.clamped(0.5, const Vec2(10, 10)), same(PlayfieldZoom.none));
      expect(PlayfieldZoom.clamped(1.01, const Vec2(10, 10)), same(PlayfieldZoom.none));
      final z = PlayfieldZoom.clamped(50, const Vec2(-100, 900));
      expect(z.factor, PlayfieldZoom.maxFactor);
      expect(z.centre, const Vec2(0, 384));
    });
  });

  group('touch', () {
    Future<(EditorController, Offset Function(double, double))> pumpEditor(WidgetTester tester) async {
      tester.view.physicalSize = const Size(891, 411);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = _sample();
      await tester.pumpWidget(MaterialApp(home: EditorScreen(controller: c)));
      final area = tester.getRect(find.byType(PlayfieldView));
      return (
        c,
        (double x, double y) => area.topLeft + PlayfieldTransform.fit(area.size, c.playfieldZoom.value).toScreen(Vec2(x, y)),
      );
    }

    testWidgets('pinching out zooms around the fingers; the pill shows it and resets', (tester) async {
      final (c, at) = await pumpEditor(tester);
      final mid = at(256, 192);
      final a = await tester.startGesture(mid - const Offset(40, 0), pointer: 1);
      final b = await tester.startGesture(mid + const Offset(40, 0), pointer: 2);
      for (var i = 1; i <= 5; i++) {
        await a.moveTo(mid - Offset(40.0 + 16 * i, 0));
        await b.moveTo(mid + Offset(40.0 + 16 * i, 0));
        await tester.pump();
      }
      await a.up();
      await b.up();
      await tester.pump();

      final zoom = c.playfieldZoom.value;
      expect(zoom.isZoomed, isTrue);
      expect(zoom.factor, closeTo(3, 0.15)); // 80 → 240 apart
      // The fingers move one at a time, so the focal point wobbles a little.
      expect(zoom.centre.x, closeTo(256, 15));
      expect(zoom.centre.y, closeTo(192, 2));
      // No undo / placement / selection from the pinch.
      expect(c.history.canUndo, isFalse);
      expect(c.selection, isEmpty);
      expect(find.text('${zoom.factor.toStringAsFixed(1)}×'), findsOneWidget);

      await tester.tap(find.byTooltip('Reset zoom'));
      await tester.pump();
      expect(c.playfieldZoom.value, same(PlayfieldZoom.none));
      expect(find.byTooltip('Reset zoom'), findsNothing);
    });

    testWidgets('the playfield stays under the fingers (one finger still, from touch-down)', (tester) async {
      final (c, at) = await pumpEditor(tester);
      final area = tester.getRect(find.byType(PlayfieldView));
      Vec2 under(Offset global) =>
          PlayfieldTransform.fit(area.size, c.playfieldZoom.value).toOsu(global - area.topLeft);
      final still = at(200, 150), moving0 = at(280, 190);
      final pStill = under(still), pMoving = under(moving0);
      final a = await tester.startGesture(still, pointer: 1);
      final b = await tester.startGesture(moving0, pointer: 2);
      var moving = moving0;
      for (var i = 1; i <= 10; i++) {
        moving = moving0 + Offset(12.0 * i, 6.0 * i);
        await b.moveTo(moving);
        await tester.pump();
      }
      // Both points of the map the fingers went down on are under them.
      expect(c.playfieldZoom.value.isZoomed, isTrue);
      expect(under(still).distanceTo(pStill), lessThan(0.5));
      expect(under(moving).distanceTo(pMoving), lessThan(0.5));
      await a.up();
      await b.up();
      await tester.pump();
    });

    testWidgets('zoomed in, a 1x overview shows in the corner; tapping it moves the view', (tester) async {
      final (c, _) = await pumpEditor(tester);
      expect(find.byType(PlayfieldOverview), findsOneWidget);
      final preview = find.descendant(of: find.byType(PlayfieldOverview), matching: find.byType(CustomPaint));
      expect(preview, findsNothing); // not at 1x

      c.playfieldZoom.value = PlayfieldZoom.clamped(3, const Vec2(150, 100));
      await tester.pump();
      final view = tester.getRect(find.byType(PlayfieldView));
      final mini = tester.getRect(preview);
      expect(mini.width, lessThan(view.width / 3));
      expect(mini.right, lessThan(view.right));
      expect(mini.bottom, lessThan(view.bottom));

      // The overview is at 1x: its point (400, 300) is where the tap lands.
      await tester.tapAt(mini.topLeft + PlayfieldTransform.fit(mini.size).toScreen(const Vec2(400, 300)));
      await tester.pump();
      expect(c.playfieldZoom.value.factor, 3);
      expect(c.playfieldZoom.value.centre.x, closeTo(400, 1e-6));
      expect(c.playfieldZoom.value.centre.y, closeTo(300, 1e-6));
      expect(c.history.canUndo, isFalse);

      c.resetPlayfieldZoom();
      await tester.pump();
      expect(preview, findsNothing);
    });

    testWidgets('taps hit the zoomed position', (tester) async {
      final (c, at) = await pumpEditor(tester);
      c.playfieldZoom.value = PlayfieldZoom.clamped(3, const Vec2(150, 100));
      c.seek(1000);
      await tester.pump();
      await tester.tapAt(at(100, 100));
      await tester.pump();
      expect(c.selection.single.position, const Vec2(100, 100));
    });

    testWidgets('a second finger cancels a move drag', (tester) async {
      final (c, at) = await pumpEditor(tester);
      c.seek(1000);
      await tester.pump();
      final a = await tester.startGesture(at(100, 100), pointer: 1);
      await a.moveTo(at(150, 100));
      await a.moveTo(at(160, 120));
      await tester.pump();
      expect(c.selection.single.position, isNot(const Vec2(100, 100)));

      final b = await tester.startGesture(at(300, 300), pointer: 2);
      await tester.pump();
      await a.moveTo(at(140, 120));
      await b.moveTo(at(340, 330));
      await tester.pump();
      await a.up();
      await b.up();
      await tester.pump();

      expect(c.history.canUndo, isFalse);
      expect(c.history.isDirty, isFalse);
      expect(c.beatmap.hitObjects.first.position, const Vec2(100, 100));
      expect(c.selection.single, same(c.beatmap.hitObjects.first));
    });
  });
}
