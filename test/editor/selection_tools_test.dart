import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/editor/editor_screen.dart';
import 'package:osu_edit/editor/render/playfield_transform.dart';
import 'package:osu_edit/editor/widgets/playfield_view.dart';
import 'package:osu_edit/platform/beatmap_file_service.dart';

/// sample_v14: 180 BPM from 1000 (beat 333.33 ms). Objects 0 and 1 are
/// circles at (100,100)@1000 and (200,100)@1333, 2 is a bezier slider
/// at (300,150)@1666, 7 a spinner @6333.
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

void _undoAll(EditorController c) {
  while (c.canUndo) {
    c.undo();
  }
}

void main() {
  test('select all switches to the Select tool and selects every object', () {
    final c = _sample();
    c.tool = EditorTool.circle;
    c.selectAll();
    expect(c.tool, EditorTool.select);
    expect(c.selection, hasLength(c.beatmap.hitObjects.length));
    expect(c.canUndo, isFalse);
  });

  test('box select picks visible heads inside the box; additive keeps the old selection', () {
    final c = _sample();
    c.seek(1000);
    final objs = c.beatmap.hitObjects;
    c.beginBoxSelect(const Vec2(50, 50));
    expect(c.selection, isEmpty);
    c.updateBoxSelect(const Vec2(250, 120));
    expect(c.selectionBox, isNotNull);
    expect(c.selection, unorderedEquals([objs[0], objs[1]]));
    c.updateBoxSelect(const Vec2(150, 120)); // shrinking drops objects again
    expect(c.selection, [objs[0]]);
    c.endBoxSelect();
    expect(c.selectionBox, isNull);
    expect(c.selection, [objs[0]]);

    // Dragging the other way round works too; additive keeps object 0.
    c.beginBoxSelect(const Vec2(320, 170), additive: true);
    c.updateBoxSelect(const Vec2(180, 90));
    c.endBoxSelect();
    expect(c.selection, unorderedEquals([objs[0], objs[1], objs[2]]));
    expect(c.canUndo, isFalse);
  });

  test('a box held while time moves (playback) keeps objects that disappeared', () {
    final c = _sample();
    c.seek(1000);
    final objs = c.beatmap.hitObjects;
    c.beginBoxSelect(const Vec2(0, 0));
    c.updateBoxSelect(const Vec2(512, 384));
    expect(c.selection, isNot(contains(objs[6])));
    var notified = 0;
    c.addListener(() => notified++);
    final seen = <HitObject>{};
    for (var t = 1000.0; t <= 6000; t += 16) {
      c.time.value = t; // no pointer movement: the held box catches new objects
      seen.addAll(c.visibleObjectsAt(t).where((h) => h is! Spinner));
    }
    expect(c.visibleObjectsAt(6000), isNot(contains(objs[0])));
    expect(c.selection, unorderedEquals(seen));
    expect(c.selection, containsAll([objs[0], objs[6]]));
    expect(notified, lessThan(20)); // only when the selection changed
    c.endBoxSelect();
    expect(c.selection, unorderedEquals(seen));

    // Shrinking the box still releases the objects that are shown.
    c.beginBoxSelect(const Vec2(0, 0));
    c.updateBoxSelect(const Vec2(512, 384));
    c.updateBoxSelect(const Vec2(1, 1));
    expect(c.selection.intersection(c.visibleObjectsAt(c.time.value).toSet()), isEmpty);
    c.endBoxSelect();
    c.time.value = 1000; // the listener is gone after the drag
    expect(c.selection, isNot(contains(objs[0])));
  });

  test('copy / paste at the snapped current time keeps spacing; undo restores the file', () {
    final c = _sample();
    final src = c.serialize();
    final objs = c.beatmap.hitObjects;
    final n = objs.length;
    c.select(objs[1]);
    c.select(objs[0], additive: true); // order of selection doesn't matter
    c.copySelection();
    expect(c.clipboardCount, 2);

    c.seek(12010); // snaps to 12000 (1/4 at 180 BPM from 1000 → 83.3 ms grid)
    c.tool = EditorTool.circle;
    c.paste();
    expect(c.tool, EditorTool.select);
    expect(c.beatmap.hitObjects, hasLength(n + 2));
    final pasted = c.selection.toList()..sort((a, b) => a.time.compareTo(b.time));
    expect(pasted, hasLength(2));
    final t0 = c.timing.snap(12010, c.divisor);
    expect(pasted[0].time, closeTo(t0, 1e-6));
    expect(pasted[1].time - pasted[0].time, closeTo(333, 1e-6));
    expect(pasted[0].position, const Vec2(100, 100));
    expect(pasted.any((h) => identical(h, objs[0])), isFalse);

    c.undo();
    expect(c.serialize(), src);
  });

  test('cut removes the selection and paste brings it back elsewhere', () {
    final c = _sample();
    final n = c.beatmap.hitObjects.length;
    final slider = c.beatmap.hitObjects[2] as SliderObject;
    c.select(slider);
    c.cutSelection();
    expect(c.beatmap.hitObjects, hasLength(n - 1));
    expect(c.selection, isEmpty);
    c.seek(20000);
    c.paste();
    final s = c.selection.single as SliderObject;
    expect(s.controlPoints, slider.controlPoints);
    expect(s.length, slider.length);
    expect(s.edgeSounds, slider.edgeSounds);
    expect(c.beatmap.hitObjects, hasLength(n));
  });

  test('move in time steps the first object to the next / previous snap', () {
    final c = _sample();
    final src = c.serialize();
    final objs = c.beatmap.hitObjects;
    c.select(objs[0]);
    c.select(objs[1], additive: true);
    final step = 1000 / 3 / 4; // 1/4 of a 180 BPM beat
    c.moveSelectionInTime(forward: true);
    final moved = c.selection.toList()..sort((a, b) => a.time.compareTo(b.time));
    expect(moved[0].time, (1000 + step).roundToDouble()); // stored as a whole ms
    expect(moved[1].time - moved[0].time, closeTo(333, 1e-6)); // spacing kept
    expect(moved[0].position, const Vec2(100, 100));

    c.moveSelectionInTime(forward: false);
    expect(c.selection.map((h) => h.time).reduce((a, b) => a < b ? a : b), closeTo(1000, 1e-6));

    _undoAll(c);
    expect(c.serialize(), src);
  });

  test('nudge moves the selection by whole pixels and stops at the playfield edge', () {
    final c = _sample();
    final src = c.serialize();
    final objs = c.beatmap.hitObjects;
    c.select(objs[0]);
    c.select(objs[2], additive: true); // slider: its path moves too
    final before = c.selection.toList();
    c.nudgeSelection(1, 0);
    c.nudgeSelection(0, -5);
    final after = c.selection.toList();
    for (var i = 0; i < before.length; i++) {
      expect(after[i].position, before[i].position + const Vec2(1, -5));
      expect(after[i].time, before[i].time);
    }
    final s0 = before.whereType<SliderObject>().single, s1 = after.whereType<SliderObject>().single;
    expect(s1.allPoints, [for (final p in s0.allPoints) p + const Vec2(1, -5)]);

    // Past the edge: nothing changes, no undo step.
    c.clearSelection();
    c.seek(20000);
    c.tool = EditorTool.circle;
    c.placeCircle(const Vec2(512, 384));
    c.tool = EditorTool.select;
    final edge = c.selection.single;
    c.nudgeSelection(1, 0);
    expect(identical(c.selection.single, edge), isTrue);

    _undoAll(c);
    expect(c.serialize(), src);
  });

  test('move in time keeps spinner ends with them and never goes below 0', () {
    final c = _empty();
    c.seek(0);
    c.placeSpinner();
    final s = c.selection.single as Spinner;
    c.moveSelectionInTime(forward: false); // would be negative
    expect(c.canUndo, isTrue); // only the placement
    expect(identical(c.selection.single, s), isTrue);
    c.moveSelectionInTime(forward: true);
    final m = c.selection.single as Spinner;
    expect(m.time, closeTo(125, 1e-6));
    expect(m.endTime - m.time, closeTo(s.endTime - s.time, 1e-6));
  });

  test('flip mirrors heads and slider paths across the playfield centre', () {
    final c = _sample();
    final src = c.serialize();
    final objs = c.beatmap.hitObjects;
    c.select(objs[0]);
    c.select(objs[2], additive: true);
    c.flipSelection(horizontal: true);
    final circle = c.selection.firstWhere((h) => h is HitCircle);
    final slider = c.selection.whereType<SliderObject>().single;
    expect(circle.position, const Vec2(412, 100));
    expect(slider.position, const Vec2(212, 150));
    expect(slider.controlPoints, const [Vec2(162, 200), Vec2(212, 250)]);
    expect(slider.length, 140);

    c.flipSelection(horizontal: false);
    expect(c.selection.firstWhere((h) => h is HitCircle).position, const Vec2(412, 284));

    _undoAll(c);
    expect(c.serialize(), src);
  });

  test('rotate turns around the selection centre; four turns are a full circle', () {
    final c = _empty();
    c.seek(0);
    c.placeCircle(const Vec2(100, 100));
    final a = c.selection.single;
    c.seek(500);
    c.placeCircle(const Vec2(200, 100));
    c.select(a, additive: true);
    c.rotateSelection(clockwise: true);
    var ps = (c.selection.toList()..sort((x, y) => x.time.compareTo(y.time))).map((h) => h.position).toList();
    expect(ps, const [Vec2(150, 50), Vec2(150, 150)]); // y points down: right → down is clockwise

    c.rotateSelection(clockwise: false);
    ps = (c.selection.toList()..sort((x, y) => x.time.compareTo(y.time))).map((h) => h.position).toList();
    expect(ps, const [Vec2(100, 100), Vec2(200, 100)]);

    for (var i = 0; i < 4; i++) {
      c.rotateSelection(clockwise: true);
    }
    ps = (c.selection.toList()..sort((x, y) => x.time.compareTo(y.time))).map((h) => h.position).toList();
    expect(ps, const [Vec2(100, 100), Vec2(200, 100)]);
  });

  test('a single circle rotated around itself is a no-op (no undo step)', () {
    final c = _sample();
    c.select(c.beatmap.hitObjects[0]);
    c.rotateSelection(clockwise: true);
    expect(c.canUndo, isFalse);
  });

  test('transforms keep heads inside the playfield and leave spinners in place', () {
    final c = _empty();
    c.seek(0);
    c.placeCircle(const Vec2(0, 0));
    final a = c.selection.single;
    c.seek(500);
    c.placeCircle(const Vec2(300, 0));
    final b = c.selection.single;
    c.seek(1000);
    c.placeSpinner();
    final s = c.selection.single;
    c.select(a, additive: true);
    c.select(b, additive: true);

    // Around (150, 0): (150, −150) and (150, 150), shifted down by 150.
    c.rotateSelection(clockwise: true);
    final heads = [for (final h in c.selection) if (h is! Spinner) h.position];
    expect(heads, unorderedEquals(const [Vec2(150, 0), Vec2(150, 300)]));
    expect(c.selection, hasLength(3));
    expect(c.selection.any((h) => identical(h, s)), isTrue); // spinner untouched
  });

  test('a transform whose result cannot fit the playfield is refused', () {
    final c = _empty();
    c.seek(0);
    c.placeCircle(const Vec2(0, 0));
    final a = c.selection.single;
    c.seek(500);
    c.placeCircle(const Vec2(500, 0)); // 500 px wide → 500 px tall: too tall
    c.select(a, additive: true);
    final before = c.selection.toList();
    c.rotateSelection(clockwise: true);
    expect(c.selection.toList(), before);
    c.undo(); // only the second placement is undone
    expect(c.beatmap.hitObjects, hasLength(1));
  });

  testWidgets('dragging on empty playfield draws a selection box', (tester) async {
    tester.view.physicalSize = const Size(891, 411);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final c = _sample();
    await tester.pumpWidget(MaterialApp(home: EditorScreen(controller: c)));
    c.seek(1000);
    await tester.pump();

    final area = tester.getRect(find.byType(PlayfieldView));
    final tf = PlayfieldTransform.fit(area.size);
    Offset at(double x, double y) => area.topLeft + tf.toScreen(Vec2(x, y));
    final gesture = await tester.startGesture(at(40, 40));
    await gesture.moveTo(at(150, 80));
    await gesture.moveTo(at(250, 125));
    await tester.pump();
    expect(c.selectionBox, isNotNull);
    await gesture.up();
    await tester.pump();
    expect(c.selectionBox, isNull);
    final objs = c.beatmap.hitObjects;
    expect(c.selection, unorderedEquals([objs[0], objs[1]]));

    // The selection card offers the clipboard / transform actions and fits.
    expect(find.byTooltip('Copy (Ctrl+C)'), findsOneWidget);
    expect(find.byTooltip('Rotate… (Ctrl+Shift+R)'), findsOneWidget);
    expect(find.byTooltip('Scale… (Ctrl+Shift+S)'), findsOneWidget);
    expect(tester.takeException(), isNull);
    // One Flip button; its menu has both directions.
    await tester.tap(find.byTooltip('Flip… · playfield centre'));
    await tester.pumpAndSettle();
    expect(find.text('Flip vertically'), findsOneWidget);
    await tester.tap(find.text('Flip horizontally'));
    await tester.pumpAndSettle();
    expect(find.text('Flip vertically'), findsNothing, reason: 'menu closes');
    expect(c.selection.map((h) => h.position), containsAll(const [Vec2(412, 100), Vec2(312, 100)]));
  });
}
