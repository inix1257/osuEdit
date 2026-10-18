import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/editor/editor_screen.dart';
import 'package:osu_edit/editor/widgets/timeline_view.dart';
import 'package:osu_edit/platform/beatmap_file_service.dart';

/// sample_v14: 180 BPM from 1000 (beat 333.33 ms), SM 1.4. Objects 0 and 1
/// are circles at (100,100)@1000 and (200,100)@1333, 2 is a bezier slider
/// (300,150)→(350,200)→(300,250), length 140 @1666, 5 a circle (100,300)
/// @4333, 7 a spinner 6333–8000.
EditorController _sample() => EditorController(
      beatmap: OsuParser.parse(File('test/fixtures/sample_v14.osu').readAsStringSync()),
      document: const BeatmapDocument(fileName: 'sample.osu'),
    );

void main() {
  group('resnap / move all notes', () {
    test('resnap puts every object (and spinner ends) on the beat snap, one undo step', () {
      final c = _sample();
      c.divisor = 4;
      expect(c.moveNotesInTime(10), c.beatmap.hitObjects.length);
      final moved = c.serialize();
      expect(c.beatmap.hitObjects.first.time, 1010);

      final n = c.resnapNotes();
      expect(n, c.beatmap.hitObjects.length);
      for (final h in c.beatmap.hitObjects) {
        expect(h.time, c.timing.snap(h.time, 4), reason: '$h');
        if (h is Spinner) expect(h.endTime, c.timing.snap(h.endTime, 4));
      }
      expect(c.beatmap.hitObjects.first.time, 1000);
      expect(c.resnapNotes(), 0, reason: 'already snapped');

      c.undo();
      expect(c.serialize(), moved);
    });

    test('with a selection only the selection moves / resnaps', () {
      final c = _sample();
      final objs = c.beatmap.hitObjects;
      final second = objs[1], third = objs[2];
      c.select(second);
      expect(c.moveNotesInTime(-20), 1);
      expect(c.beatmap.hitObjects[1].time, 1313);
      expect(c.beatmap.hitObjects[2], same(third));
      expect(c.resnapNotes(), 1);
      expect(c.beatmap.hitObjects[1].time, 1333);
      expect(c.selection.single.time, 1333, reason: 'the selection follows the new objects');
    });

    test('nothing moves before 0', () {
      final c = _sample();
      expect(c.moveNotesInTime(-5000), c.beatmap.hitObjects.length);
      expect(c.beatmap.hitObjects.first.time, 0);
      expect(c.moveNotesInTime(-1), 0);
    });
  });

  group('merge', () {
    test('two circles become a straight slider, length rounded to the snap', () {
      final c = _sample();
      final src = c.serialize();
      final n = c.beatmap.hitObjects.length;
      final a = c.beatmap.hitObjects[0], b = c.beatmap.hitObjects[1];
      c.divisor = 4;
      c.select(a);
      c.select(b, additive: true);
      expect(c.canMergeSelection, isTrue);
      c.mergeSelection();

      final s = c.selection.single as SliderObject;
      expect(c.beatmap.hitObjects, hasLength(n - 1));
      expect(s.time, a.time);
      expect(s.newCombo, a.newCombo);
      expect(s.curveType, CurveType.linear);
      expect(s.allPoints, [a.position, b.position]);
      expect(s.isLazerPath, isFalse);
      // 100 px; one 1/4 beat is 35 px at SM 1.4 → 3 steps.
      expect(s.length, closeTo(105, 1e-9));

      c.undo();
      expect(c.serialize(), src);
    });

    test('a slider and a later circle: the path continues to the circle', () {
      final c = _sample();
      final src = c.serialize();
      final slider = c.beatmap.hitObjects[2] as SliderObject;
      final circle = c.beatmap.hitObjects[5];
      c.select(slider);
      c.select(circle, additive: true);
      c.mergeSelection();

      final s = c.selection.single as SliderObject;
      expect(s.time, slider.time);
      expect(s.position, slider.position);
      expect(s.allPoints.last, circle.position);
      expect(c.beatmap.hitObjects.contains(circle), isFalse);
      expect(OsuParser.parse(c.serialize()).hitObjects, hasLength(c.beatmap.hitObjects.length),
          reason: 'writes and reads back');
      c.undo();
      expect(c.serialize(), src);
    });

    test('circles on one spot, or a single object, cannot be merged', () {
      final c = _sample();
      final a = c.beatmap.hitObjects[0];
      c.select(a);
      expect(c.canMergeSelection, isFalse);
      final stacked = HitCircle(position: a.position, time: 1166);
      expect(PatternOps.canMerge([a, stacked]), isFalse);
      expect(PatternOps.canMerge([a, stacked, c.beatmap.hitObjects[1]]), isTrue);
    });

    test('in lazer slider format the merged path keeps lazer point types', () {
      final b = OsuParser.parse(File('test/fixtures/sample_v14.osu').readAsStringSync());
      final r = PatternOps.merged([b.hitObjects[2], b.hitObjects[5]], lazerFormat: true)!;
      final types = r.$2.pointTypes!;
      expect(types.first!.kind, CurveType.bezier);
      expect(types.contains(PathType.linear), isTrue, reason: 'the join to the circle is a straight segment');
    });
  });

  test('the star rating follows edits (background isolate, debounced)', () async {
    final c = _sample();
    addTearDown(c.dispose);
    c.trackDifficulty();
    Future<void> until(bool Function() ok) async {
      for (var i = 0; i < 100 && !ok(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }

    await until(() => c.difficulty.value != null);
    final first = c.difficulty.value!;
    expect(first.stars, closeTo(StarRating.of(c.beatmap)!, 1e-9));
    expect(first.times, hasLength(c.beatmap.hitObjects.length - 1));

    c.select(c.beatmap.hitObjects[1]);
    c.deleteSelection();
    await until(() => !identical(c.difficulty.value, first));
    expect(c.difficulty.value!.stars, closeTo(StarRating.of(c.beatmap)!, 1e-9));
    expect(c.difficulty.value!.stars, isNot(first.stars));
  });

  testWidgets('scrubbing the Compose timeline snaps the playhead to the beat snap', (tester) async {
    tester.view.physicalSize = const Size(891, 411);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = _sample();
    c.divisor = 4;
    await tester.pumpWidget(MaterialApp(home: EditorScreen(controller: c)));
    c.seek(2000);
    await tester.pump();
    final strip = tester.getRect(find.byType(TimelineView));
    final y = strip.top + 4;

    bool onSnap(double t) => (t - c.timing.snap(t, 4)).abs() < 1e-9;
    final g = await tester.startGesture(Offset(strip.center.dx, y), kind: PointerDeviceKind.touch);
    final seen = <double>{};
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await g.moveBy(const Offset(-7, 0));
      await tester.pump();
      expect(onSnap(c.time.value), isTrue, reason: '${c.time.value}');
      seen.add(c.time.value);
    }
    await g.up();
    await tester.pump(const Duration(milliseconds: 300));
    expect(seen.length, greaterThan(1), reason: 'it moved');
    expect(c.time.value, greaterThan(2000));

    // A fling glides and still ends on the snap.
    await tester.flingFrom(Offset(strip.center.dx, y), const Offset(-200, 0), 3000);
    await tester.pumpAndSettle();
    expect(onSnap(c.time.value), isTrue);
  });
}
