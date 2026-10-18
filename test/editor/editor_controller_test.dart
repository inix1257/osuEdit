import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/editor/editor_screen.dart';
import 'package:osu_edit/platform/beatmap_file_service.dart';

EditorController _controller() {
  final src = File('test/fixtures/sample_v14.osu').readAsStringSync();
  return EditorController(
    beatmap: OsuParser.parse(src),
    document: const BeatmapDocument(fileName: 'sample.osu'),
  );
}

void main() {
  test('starts at the first timing point with the map divisor', () {
    final c = _controller();
    expect(c.time.value, 1000);
    expect(c.divisor, 4);
  });

  test('place circle snaps time and selects it', () {
    final c = _controller();
    c.seek(1090); // 1/4 grid at 180 BPM is 83.33ms → snaps to 1083.33, stored 1083
    c.placeCircle(const Vec2(10.4, 600));
    final placed = c.selection.single;
    expect(placed.time, 1083);
    expect(placed.position, const Vec2(10, 384)); // rounded + clamped
    expect(c.isDirty, isTrue);
    c.undo();
    expect(c.selection, isEmpty);
    expect(c.isDirty, isFalse);
  });

  test('hit test finds circles and slider bodies', () {
    final c = _controller();
    expect(c.hitTest(const Vec2(102, 98), 1000), same(c.beatmap.hitObjects[0]));
    // Point on the body of the bezier slider at 1666, away from its head.
    final slider = c.beatmap.hitObjects[2] as SliderObject;
    final mid = c.sliderPath(slider).positionAt(0.5);
    expect(c.hitTest(mid, 1666), same(slider));
    expect(c.hitTest(const Vec2(500, 380), 1000), isNull);
  });

  test('hit test covers the middle of a linear slider body', () {
    final c = _controller();
    // Linear slider at 3666 from (400,300) to (260,300): its path has only
    // the two end vertices, the middle is 70 px from both.
    final slider = c.beatmap.hitObjects[4] as SliderObject;
    expect(c.sliderPath(slider).vertices, hasLength(2));
    expect(c.hitTest(const Vec2(330, 310), 3666), same(slider));
    expect(c.hitTest(const Vec2(330, 380), 3666), isNull); // well off the body
  });


  test('drag move is one undo step and clamps to the playfield', () {
    final c = _controller();
    final h = c.beatmap.hitObjects[0]; // at (100,100)
    c.select(h);
    c.beginMoveSelection();
    c.updateMoveSelection(const Vec2(10, 0));
    c.updateMoveSelection(const Vec2(-500, 20));
    c.endMoveSelection();
    final moved = c.selection.single;
    expect(moved.position, const Vec2(0, 120));
    c.undo();
    expect(c.beatmap.hitObjects[0], same(h));
    expect(c.canUndo, isFalse);
  });

  test('no-op drag leaves no history entry', () {
    final c = _controller();
    c.select(c.beatmap.hitObjects[0]);
    c.beginMoveSelection();
    c.updateMoveSelection(const Vec2(3, 0));
    c.updateMoveSelection(Vec2.zero);
    c.endMoveSelection();
    expect(c.canUndo, isFalse);
    expect(c.serialize(), File('test/fixtures/sample_v14.osu').readAsStringSync());
  });

  test('visible objects window', () {
    final c = _controller();
    // AR8 preempt = 1200 - 750*3/5 = 750ms.
    final vis = c.visibleObjectsAt(1000).map((h) => h.time).toList();
    expect(vis, [1000, 1333, 1666]);
    // The spinner (6333-8000) is visible in the middle of its duration.
    expect(c.visibleObjectsAt(7000).whereType<Spinner>(), hasLength(1));
  });

  test('combo colours come from [Colours]', () {
    final c = _controller();
    final objs = c.beatmap.hitObjects;
    // As in stable, the first combo is Combo2; Combo1 comes after Combo3.
    expect(c.comboColourOf(objs[0]), const Color(0xFF40A0FF)); // NC @1000: Combo2
    expect(c.comboColourOf(objs[3]), const Color(0xFF80FF80)); // NC @2333: Combo3
    expect(c.comboColourOf(objs[6]), const Color(0xFFFF8040)); // NC @5000: Combo1
  });

  test('toggle new combo and delete', () {
    final c = _controller();
    final h = c.beatmap.hitObjects[1];
    c.select(h);
    c.toggleNewComboOnSelection();
    expect(c.selection.single.newCombo, isTrue);
    c.deleteSelection();
    expect(c.beatmap.hitObjects, hasLength(10));
    expect(c.selection, isEmpty);
    c.undo();
    c.undo();
    expect(c.beatmap.hitObjects[1], same(h));
  });

  testWidgets('editor screen renders and plays without errors', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final c = _controller();
    await tester.pumpWidget(MaterialApp(home: EditorScreen(controller: c)));
    expect(find.text('00:01:000'), findsOneWidget);

    // Seek into the slider/spinner region and render.
    c.seek(2500);
    await tester.pump();
    c.seek(7000);
    await tester.pump();

    // Tap play; advance frames.
    await tester.tap(find.byTooltip('Play (Space)'));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    expect(c.isPlaying, isTrue);
    await tester.tap(find.byTooltip('Pause (Space)'));
    await tester.pump();
    expect(c.isPlaying, isFalse);

    // Place a circle with the circle tool.
    await tester.tap(find.text('Circle'));
    await tester.pump();
    final before = c.beatmap.hitObjects.length;
    await tester.tapAt(const Offset(640, 300));
    await tester.pump();
    expect(c.beatmap.hitObjects.length, before + 1);
    expect(find.byTooltip('Save (unsaved changes)'), findsOneWidget); // dirty marker

    // Draw a slider: two taps (tapping a point again only turns it red),
    // then Create. (Elsewhere in time: at the circle's time it would
    // replace the circle.)
    c.seek(8000);
    await tester.tap(find.text('Slider'));
    await tester.pump();
    final count = c.beatmap.hitObjects.length;
    await tester.tapAt(const Offset(500, 356));
    await tester.pump();
    await tester.tapAt(const Offset(640, 356));
    await tester.pump();
    expect(find.text('New slider'), findsOneWidget);
    await tester.tapAt(const Offset(640, 356));
    await tester.pump();
    expect(c.isDrafting, isTrue);
    expect(c.draftPoints.last.red, isTrue);
    await tester.tap(find.text('Create'));
    await tester.pump();
    expect(c.beatmap.hitObjects.length, count + 1);
    expect(c.selection.single, isA<SliderObject>());
    c.setSlides(2); // slider settings have no buttons for now
    await tester.pump();
    expect((c.selection.single as SliderObject).slides, 2);
  });
}
