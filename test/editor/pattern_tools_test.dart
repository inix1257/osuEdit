import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/editor/editor_screen.dart';
import 'package:osu_edit/editor/render/playfield_transform.dart';
import 'package:osu_edit/editor/widgets/playfield_view.dart';
import 'package:osu_edit/platform/beatmap_file_service.dart';

/// sample_v14: 180 BPM from 1000 (beat 333.33 ms), SM 1.4. Objects 0 and 1
/// are circles at (100,100)@1000 and (200,100)@1333, 2 is a bezier slider
/// (300,150)→(350,200)→(300,250), length 140 (one span = one beat) @1666.
EditorController _sample() => EditorController(
      beatmap: OsuParser.parse(File('test/fixtures/sample_v14.osu').readAsStringSync()),
      document: const BeatmapDocument(fileName: 'sample.osu'),
    );

void main() {
  group('convert to stream', () {
    test('replaces the slider with circles every beat snap, one undo step', () {
      final c = _sample();
      final src = c.serialize();
      final slider = c.beatmap.hitObjects[2] as SliderObject;
      final circle = c.beatmap.hitObjects[0];
      c.divisor = 4;
      c.select(slider);
      c.select(circle, additive: true);
      expect(c.canConvertToStream, isTrue);
      c.convertSelectionToStream();

      expect(c.beatmap.hitObjects.contains(slider), isFalse);
      final stream = [for (final h in c.selection) if (!identical(h, circle)) h];
      expect(stream, hasLength(5));
      expect(stream.every((h) => h is HitCircle), isTrue);
      expect(stream.map((h) => h.time.round()), [1666, 1749, 1833, 1916, 1999]);
      expect(stream.first.position, slider.position);
      expect(stream.last.position, c.sliderPath(slider).tail.roundToInt());
      expect(stream.first.hitSound, 2); // the head's whistle
      expect(c.selection, contains(circle));
      expect(c.canConvertToStream, isFalse);

      c.undo();
      expect(c.serialize(), src);
      expect(c.canUndo, isFalse);
    });
  });

  group('reverse', () {
    test('mirrors the selection in time; undo restores the file', () {
      final c = _sample();
      final src = c.serialize();
      final objs = c.beatmap.hitObjects;
      final a = objs[0], b = objs[1], s = objs[2] as SliderObject;
      c.select(a);
      c.select(b, additive: true);
      c.select(s, additive: true);
      final end = c.endTimeOf(s);
      c.reverseSelection();

      expect(c.selection, hasLength(3));
      final sorted = c.selection.toList()..sort((x, y) => x.time.compareTo(y.time));
      expect(sorted[0], isA<SliderObject>());
      expect(sorted[0].time, closeTo(1000, 1e-6));
      expect(sorted[0].position, c.sliderPath(s).tail.roundToInt());
      expect(sorted[0].newCombo, isTrue); // a started the combo
      expect(sorted[1].position, b.position);
      // Mirrored times are stored as whole ms (the slider's end is fractional).
      expect(sorted[1].time, (end - (1333 - 1000)).roundToDouble());
      expect(sorted[2].position, a.position);
      expect(sorted[2].time, end.roundToDouble());

      c.undo();
      expect(c.serialize(), src);
    });

    test('nothing to reverse is a no-op', () {
      final c = _sample();
      c.select(c.beatmap.hitObjects[0]);
      c.reverseSelection();
      expect(c.canUndo, isFalse);
    });
  });

  group('insert control point at a position', () {
    test('on a line joining two points: inserted on it, selected; elsewhere: nothing', () {
      final c = _sample();
      final s = c.beatmap.hitObjects[2] as SliderObject;
      c.select(s);
      expect(c.insertControlPointAt(const Vec2(100, 300)), isNull);
      // On the curve but away from the lines (the bezier bulges inside them).
      expect(c.canInsertControlPointAt(c.sliderPath(s).positionAtDistance(c.sliderPath(s).distance / 2)), isFalse);
      // Near (6 px off) the second line: the point lands on the line.
      expect(c.controlLegAt(const Vec2(329, 229)), (2, const Vec2(325, 225)));
      const on = Vec2(325, 225);
      expect(c.insertControlPointAt(on), 2);
      final edited = c.editedSlider!;
      expect(SliderShape.decode(edited.allPoints), hasLength(4));
      expect(edited.allPoints[2], on.roundToInt());
      expect(c.selectedPoint, 2);
      c.undo();
      expect(c.beatmap.hitObjects[2], same(s));
    });
  });

  group('curve type when points are added / removed', () {
    test('two points + one → perfect circle; perfect circle + one → bezier; back to two → linear', () {
      final c = _sample();
      final s = c.beatmap.hitObjects[4] as SliderObject; // linear, (400,300)→(250,300)
      c.select(s);
      final off = c.sliderPath(s).positionAtDistance(40);
      expect(c.insertControlPointAt(off), 1);
      expect(c.editedSlider!.curveType, CurveType.perfectCircle);
      expect(c.canDeleteControlPoint, isTrue);
      expect(c.insertControlPointAt(c.sliderPath(c.editedSlider!).positionAtDistance(100)), isNotNull);
      expect(c.editedSlider!.curveType, CurveType.bezier);

      c.undo();
      final p = c.beatmap.hitObjects.whereType<SliderObject>().firstWhere((h) => h.time == s.time);
      expect(p.curveType, CurveType.perfectCircle);
      c.select(p);
      c.deleteControlPoint(1);
      expect(c.editedSlider!.curveType, CurveType.linear);
      expect(c.canDeleteControlPoint, isFalse);
      c.deleteControlPoint(1); // never below two points
      expect(c.editedSlider!.allPoints, hasLength(2));
    });

    test('other types keep their type', () {
      final c = _sample();
      final s = c.beatmap.hitObjects[2] as SliderObject; // bezier, 3 points
      c.select(s);
      c.insertControlPointAt(const Vec2(325, 175));
      expect(c.editedSlider!.curveType, CurveType.bezier);
    });
  });

  group('touch', () {
    Future<(EditorController, Offset Function(Vec2))> pumpEditor(WidgetTester tester) async {
      tester.view.physicalSize = const Size(891, 411);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = _sample();
      await tester.pumpWidget(MaterialApp(home: EditorScreen(controller: c)));
      final area = tester.getRect(find.byType(PlayfieldView));
      return (c, (Vec2 p) => area.topLeft + PlayfieldTransform.fit(area.size, c.playfieldZoom.value).toScreen(p));
    }

    Future<void> longPress(WidgetTester tester, Offset at) async {
      final g = await tester.startGesture(at);
      await tester.pump(const Duration(milliseconds: 700));
      await g.up();
      await tester.pump();
    }

    final preview = find.byWidgetPredicate(
        (w) => w is DecoratedBox && w.decoration is BoxDecoration && (w.decoration as BoxDecoration).color == const Color(0x80FFFFFF));

    testWidgets('long-press on a line between points offers Add point with a preview; only the button adds it (undo / redo)',
        (tester) async {
      final (c, at) = await pumpEditor(tester);
      c.seek(1666);
      final s = c.beatmap.hitObjects[2] as SliderObject;
      c.select(s);
      await tester.pump();
      const on = Vec2(325, 175); // middle of the first line

      await longPress(tester, at(on));
      expect(find.text('Add point'), findsOneWidget);
      expect(preview, findsOneWidget);
      expect(tester.getCenter(preview), offsetMoreOrLessEquals(at(on), epsilon: 1));
      expect(c.canUndo, isFalse); // nothing yet
      await tester.tap(find.text('Add point'));
      await tester.pump();
      expect(find.text('Add point'), findsNothing);
      expect(preview, findsNothing);
      final added = c.editedSlider!;
      expect(SliderShape.decode(added.allPoints), hasLength(4));
      expect(added.allPoints[1], on.roundToInt());
      expect(c.selectedPoint, 1);

      c.undo();
      expect(c.beatmap.hitObjects[2], same(s));
      c.redo();
      expect(SliderShape.decode((c.beatmap.hitObjects[2] as SliderObject).allPoints), hasLength(4));
    });

    testWidgets('long-press on a point offers Remove point (undo / redo)', (tester) async {
      final (c, at) = await pumpEditor(tester);
      c.seek(1666);
      final s = c.beatmap.hitObjects[2] as SliderObject;
      c.select(s);
      await tester.pump();

      await longPress(tester, at(s.allPoints[1]));
      expect(find.text('Remove point'), findsOneWidget);
      expect(preview, findsNothing);
      expect(c.selectedPoint, 1);
      expect(c.canUndo, isFalse);
      await tester.tap(find.text('Remove point'));
      await tester.pump();
      final removed = c.beatmap.hitObjects[2] as SliderObject;
      expect(removed.allPoints, [s.allPoints[0], s.allPoints[2]]);

      c.undo();
      expect(c.beatmap.hitObjects[2], same(s));
      c.redo();
      expect((c.beatmap.hitObjects[2] as SliderObject).allPoints, hasLength(2));
    });

    testWidgets('long-press on the body away from the lines is a move, not Add point', (tester) async {
      final (c, at) = await pumpEditor(tester);
      c.seek(1666);
      final s = c.beatmap.hitObjects[2] as SliderObject;
      c.select(s);
      await tester.pump();
      // The middle of the curve is ~18 osu!px from the lines: zoomed in, that
      // is well outside the 16 dp touch tolerance.
      c.playfieldZoom.value = PlayfieldZoom.clamped(3, const Vec2(325, 200));
      await tester.pump();
      final body = c.sliderPath(s).positionAtDistance(c.sliderPath(s).distance / 2);
      final g = await tester.startGesture(at(body));
      await tester.pump(const Duration(milliseconds: 700));
      expect(find.text('Add point'), findsNothing);
      await g.moveTo(at(body + const Vec2(20, 0)));
      await tester.pump();
      await g.up();
      await tester.pump();
      expect(c.selection.single.position, s.position + const Vec2(20, 0));
    });

    testWidgets('a touch outside the menu closes it without editing', (tester) async {
      final (c, at) = await pumpEditor(tester);
      c.seek(1666);
      final s = c.beatmap.hitObjects[2] as SliderObject;
      c.select(s);
      await tester.pump();
      await longPress(tester, at(const Vec2(325, 175)));
      expect(find.text('Add point'), findsOneWidget);
      await tester.tapAt(at(const Vec2(450, 50)));
      await tester.pump();
      expect(find.text('Add point'), findsNothing);
      expect(c.canUndo, isFalse);
      expect(c.selection.single, same(s)); // the closing tap doesn't deselect
    });

    testWidgets('a two-point slider has no Remove point: long-press drags the point instead', (tester) async {
      final (c, at) = await pumpEditor(tester);
      c.seek(3666);
      final s = c.beatmap.hitObjects[4] as SliderObject; // L|250:300
      c.select(s);
      await tester.pump();
      final g = await tester.startGesture(at(s.allPoints[1]));
      await tester.pump(const Duration(milliseconds: 700));
      expect(find.text('Remove point'), findsNothing);
      await g.moveTo(at(s.allPoints[1] + const Vec2(0, -40)));
      await tester.pump();
      await g.up();
      await tester.pump();
      expect(c.editedSlider!.allPoints[1], isNot(s.allPoints[1]));
    });

    testWidgets('long-press elsewhere still moves what it lands on', (tester) async {
      final (c, at) = await pumpEditor(tester);
      c.seek(1333);
      c.select(c.beatmap.hitObjects[2]); // the slider @1666 is already shown
      await tester.pump();
      final circle = c.beatmap.hitObjects[1]; // (200,100)@1333
      final g = await tester.startGesture(at(circle.position));
      await tester.pump(const Duration(milliseconds: 700));
      await g.moveTo(at(circle.position + const Vec2(20, 0)));
      await tester.pump();
      await g.up();
      await tester.pump();
      expect(c.selection.single.position.x, closeTo(220, 2));
      expect(c.history.canUndo, isTrue);
    });

    testWidgets('Ctrl+click on the selected slider adds a point', (tester) async {
      final (c, at) = await pumpEditor(tester);
      c.seek(1666);
      final s = c.beatmap.hitObjects[2] as SliderObject;
      c.select(s);
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tapAt(at(const Vec2(325, 175)));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(c.selection.single, isA<SliderObject>());
      expect(SliderShape.decode(c.editedSlider!.allPoints), hasLength(4));
    });

    testWidgets('Reverse and Stream buttons in the right strip', (tester) async {
      final (c, _) = await pumpEditor(tester);
      c.divisor = 2;
      c.select(c.beatmap.hitObjects[0]);
      await tester.pump();
      expect(find.text('Reverse'), findsOneWidget);
      expect(find.text('Convert'), findsNothing);

      final s = c.beatmap.hitObjects[2];
      c.select(s);
      await tester.pump();
      await tester.tap(find.text('Reverse'));
      await tester.pump();
      expect(c.selection.single.position, isNot(s.position));

      await tester.ensureVisible(find.text('Convert'));
      await tester.tap(find.text('Convert'));
      await tester.pump();
      expect(c.selection, hasLength(3)); // 1/2 snap over one beat
      expect(find.text('Convert'), findsNothing);
    });
  });
}
