import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/editor/editor_screen.dart';
import 'package:osu_edit/editor/render/playfield_transform.dart';
import 'package:osu_edit/editor/widgets/editor_toolbars.dart';
import 'package:osu_edit/editor/widgets/mini_timeline.dart';
import 'package:osu_edit/editor/widgets/playfield_view.dart';
import 'package:osu_edit/editor/widgets/timeline_view.dart';
import 'package:osu_edit/platform/beatmap_file_service.dart';

/// 120 BPM from 0, SV 1, SliderMultiplier 1.4: one beat = 500 ms = 140 px.
EditorController _empty() {
  final b = Beatmap.empty();
  b.setValue(SectionNames.difficulty, 'SliderMultiplier', '1.4');
  b.insertTimingPoint(TimingPoint.red(time: 0, bpm: 120));
  b.revision = 0;
  return EditorController(beatmap: b, document: const BeatmapDocument(fileName: 'new.osu'));
}

EditorController _sample() => EditorController(
      beatmap: OsuParser.parse(File('test/fixtures/sample_v14.osu').readAsStringSync()),
      document: const BeatmapDocument(fileName: 'sample.osu'),
    );

void main() {
  group('hitsound toggles', () {
    test('with nothing selected they apply to the next placed object; NC is one-shot', () {
      final c = _empty();
      c.toggleAddition(HitSoundFlags.whistle);
      c.toggleAddition(HitSoundFlags.clap);
      c.toggleNewCombo();
      c.setNormalSet(SampleSet.soft);
      c.setAdditionSet(SampleSet.drum);
      expect(c.beatmap.hitObjects, isEmpty); // state only, no edits
      expect(c.canUndo, isFalse);

      c.seek(500);
      c.placeCircle(const Vec2(100, 100));
      final h = c.beatmap.hitObjects.single;
      expect(h.hitSound, HitSoundFlags.whistle | HitSoundFlags.clap);
      expect(h.newCombo, isTrue);
      expect(h.sample.normalSet, SampleSet.soft);
      expect(h.sample.additionSet, SampleSet.drum);

      c.clearSelection();
      expect(c.newComboState, isFalse); // cleared after placing
      expect(c.additionState(HitSoundFlags.whistle), isTrue); // additions stay
    });

    test('with a selection they edit it (undoable), sliders including their edges', () {
      final c = _sample();
      final src = c.serialize();
      final slider = c.beatmap.hitObjects[2] as SliderObject; // edgeSounds 2|0
      final circle = c.beatmap.hitObjects[1]; // hitSound 2 (whistle)
      c.select(slider);
      c.select(circle, additive: true);
      expect(c.additionState(HitSoundFlags.whistle), isFalse); // mixed → off

      c.toggleAddition(HitSoundFlags.whistle); // on for all
      final s2 = c.beatmap.hitObjects[2] as SliderObject;
      expect(s2.hitSound & HitSoundFlags.whistle, isNonZero);
      expect(s2.edgeSounds, [2, 2]);
      expect(c.additionState(HitSoundFlags.whistle), isTrue);

      c.toggleAddition(HitSoundFlags.whistle); // off for all
      expect((c.beatmap.hitObjects[2] as SliderObject).edgeSounds, [0, 0]);
      expect(c.beatmap.hitObjects[1].hitSound, 0);

      c.setNormalSet(SampleSet.drum);
      final s3 = c.beatmap.hitObjects[2] as SliderObject;
      expect(s3.sample.normalSet, SampleSet.drum);
      expect(s3.edgeSets!.every((e) => e.normalSet == SampleSet.drum), isTrue);
      expect(c.normalSetState, SampleSet.drum);

      c.undo();
      c.undo();
      c.undo();
      expect(c.serialize(), src);
    });

    test('setting an unchanged sample set is a no-op', () {
      final c = _sample();
      c.select(c.beatmap.hitObjects[0]);
      c.setNormalSet(SampleSet.auto);
      expect(c.canUndo, isFalse);
    });

    test('with a placement tool they set up the next object even if one is selected', () {
      final c = _empty();
      c.tool = EditorTool.circle;
      c.placeCircle(const Vec2(100, 100)); // stays selected
      final first = c.selection.single;
      c.toggleAddition(HitSoundFlags.finish);
      expect(c.beatmap.hitObjects.single, same(first)); // not edited
      expect(c.additionState(HitSoundFlags.finish), isTrue);
      c.seek(500);
      c.placeCircle(const Vec2(200, 100));
      expect(c.selection.single.hitSound, HitSoundFlags.finish);

      c.tool = EditorTool.select; // now the toggle edits the selection
      expect(c.additionState(HitSoundFlags.finish), isTrue);
      c.toggleAddition(HitSoundFlags.finish);
      expect(c.selection.single.hitSound, 0);
    });

    test('colour skip on the selection turns NC on and shifts the colour (undoable)', () {
      final c = _sample();
      final src = c.serialize();
      final h = c.beatmap.hitObjects[3]; // NC @2333: colour 2 (Combo3)
      c.select(h);
      expect(c.comboSkipState, 0);
      expect(c.comboSkipBaseColour, 2);

      c.setComboSkip(1);
      final h2 = c.selection.single;
      expect((h2.newCombo, h2.comboSkip), (true, 1));
      expect(c.comboOf(h2).colourIndex, 3);
      expect(c.comboColourOf(h2), c.comboColourAt(3)); // wraps to Combo1
      expect(c.comboSkipState, 1);
      expect(c.serialize(), contains('256,192,2333,22,0,')); // 6 | 1 << 4

      c.setComboSkip(1); // unchanged: no extra undo step
      c.undo();
      expect(c.serialize(), src);

      // On a non-NC object it turns NC on; toggling NC off drops the skip.
      c.select(c.beatmap.hitObjects[1]);
      expect(c.comboSkipState, isNull);
      c.setComboSkip(5);
      expect((c.selection.single.newCombo, c.selection.single.comboSkip), (true, 5));
      c.toggleNewCombo();
      expect((c.selection.single.newCombo, c.selection.single.comboSkip), (false, 0));
    });

    test('colour skip with nothing selected applies once to the next placed object', () {
      final c = _empty();
      c.setComboSkip(2);
      expect(c.newComboState, isTrue);
      expect(c.comboSkipState, 2);
      expect(c.comboSkipBaseColour, 1);
      expect(c.canUndo, isFalse);

      c.placeCircle(const Vec2(100, 100));
      final h = c.beatmap.hitObjects.single;
      expect((h.newCombo, h.comboSkip), (true, 2));
      c.clearSelection();
      expect(c.newComboState, isFalse);
      expect(c.comboSkipState, 0);

      c.setComboSkip(3);
      c.toggleNewCombo(); // NC off cancels the pending skip too
      c.seek(500);
      c.placeCircle(const Vec2(200, 100));
      expect(c.beatmap.hitObjects.last.comboSkip, 0);
    });
  });

  group('snapping and lock', () {
    test('grid snap rounds placement and moves to the grid size', () {
      final c = _empty();
      expect(c.gridSize, 32); // new maps write GridSize: 32
      c.gridSnap = true;
      c.placeCircle(const Vec2(103, 57));
      expect(c.selection.single.position, const Vec2(96, 64));
      for (final size in [4, 8, 16]) {
        c.cycleGridSize();
        expect(c.gridSize, size);
      }
      c.beginMoveSelection();
      c.updateMoveSelection(const Vec2(20, 5)); // 116,69 → 112,64
      c.endMoveSelection();
      expect(c.selection.single.position, const Vec2(112, 64));
    });

    test('grid size comes from the map', () {
      expect(_sample().gridSize, 32);
    });

    test('distance snap places on the ring around the previous object', () {
      final c = _empty();
      c.placeCircle(const Vec2(100, 100)); // at 0
      c.distanceSnap = true;
      c.seek(500); // 1 beat later → 140 px at DS 1.0
      final (centre, radius) = c.distanceSnapGuide(500)!;
      expect(centre, const Vec2(100, 100));
      expect(radius, closeTo(140, 1e-9));
      c.placeCircle(const Vec2(400, 100));
      expect(c.selection.single.position, const Vec2(240, 100));
    });

    test('distance snap measures from the slider end', () {
      final c = _empty();
      c.tool = EditorTool.slider;
      c.sliderToolTap(const Vec2(100, 100));
      c.sliderToolTap(const Vec2(240, 100)); // 140 px = 1 beat
      c.finishSlider(); // 0 → 500
      c.distanceSnap = true;
      final (centre, radius) = c.distanceSnapGuide(1000)!;
      expect(centre.x, closeTo(240, 1e-6));
      expect(radius, closeTo(140, 1e-6));
      // A slider ending right at the placement time still counts (gap 0).
      final (atEnd, zero) = c.distanceSnapGuide(500)!;
      expect(atEnd.x, closeTo(240, 1e-6));
      expect(zero, closeTo(0, 1e-6));
    });

    test('locked notes cannot be dragged', () {
      final c = _sample();
      final h = c.beatmap.hitObjects[0];
      c.select(h);
      c.lockNotes = true;
      c.beginMoveSelection();
      c.updateMoveSelection(const Vec2(50, 50));
      c.endMoveSelection();
      expect(c.beatmap.hitObjects[0], same(h));
      expect(c.canUndo, isFalse);
    });
  });

  test('breaks are read from [Events]', () {
    final b = Beatmap.empty();
    final c = EditorController(beatmap: b, document: const BeatmapDocument(fileName: 'x.osu'));
    expect(b.breaks, isEmpty);
    final m = OsuParser.parse(
      File('test/fixtures/sample_v14.osu').readAsStringSync().replaceFirst('//Break Periods', '//Break Periods\r\n2,11000,15000'),
    );
    expect(m.breaks, [(11000.0, 15000.0)]);
    c.dispose();
  });

  test('mini timeline data spans the map with bookmarks, kiai and breaks', () {
    final c = _sample();
    final d = MiniTimelineData.of(c);
    expect(d.start, 0);
    expect(d.end, greaterThan(c.endTimeOf(c.beatmap.hitObjects.last)));
    expect(d.bookmarks, [1000, 6333]);
    expect(d.kiai, [(5000.0, 9000.0)]);
    expect(d.timingPoints, hasLength(4));
  });

  testWidgets('layout: toolboxes, top timeline and bottom bar around a dominant playfield', (tester) async {
    tester.view.physicalSize = const Size(891, 411); // landscape phone (dp)
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final c = _sample();
    await tester.pumpWidget(MaterialApp(home: EditorScreen(controller: c)));
    for (final label in ['Sample', 'Addition', 'Select', 'Circle', 'Slider', 'Spinner']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    for (final tip in ['New combo (Q) · long-press: colour skip', 'Whistle (W)', 'Finish (E)', 'Clap (R)', 'Distance snap (Y) · long-press: distance spacing', 'Lock notes (L)']) {
      expect(find.byTooltip(tip), findsOneWidget, reason: tip);
    }
    // The overview starts hidden; the playfield then runs to the bottom
    // edge while time and play / rate stay in the corners.
    expect(find.byType(MiniTimeline), findsNothing);
    expect(find.byTooltip('Play (Space)'), findsOneWidget);
    expect(tester.takeException(), isNull); // no overflow
    final full = tester.getSize(find.byType(PlayfieldView)).height;
    expect(tester.getRect(find.byType(PlayfieldView)).bottom, 411);

    await tester.tap(find.byTooltip('Show map overview'));
    await tester.pump();
    expect(c.showMiniTimeline, isTrue);
    expect(find.byType(MiniTimeline), findsOneWidget);
    expect(tester.getSize(find.byType(PlayfieldView)).height, full - EditorLayout.phone.bottomBarHeight);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('Whistle (W)'));
    await tester.pump();
    expect(c.additionState(HitSoundFlags.whistle), isTrue);

    // Selecting a slider shows the action buttons beside the playfield; they
    // fit the screen and stay clear of the playfield's object area.
    c.select(c.beatmap.hitObjects[2]);
    await tester.pump();
    expect(find.byTooltip('Delete (Del)'), findsOneWidget);
    expect(find.byTooltip('Rotate… (Ctrl+Shift+R)'), findsOneWidget);
    expect(find.byTooltip('More repeats'), findsNothing); // slider settings are not in the strips
    final field = tester.getRect(find.byType(PlayfieldView));
    final tf = PlayfieldTransform.fit(field.size);
    final objectLeft = field.left + tf.origin.dx - PlayfieldTransform.marginX * tf.scale;
    final objectRight = field.left + tf.origin.dx + (512 + PlayfieldTransform.marginX) * tf.scale;
    expect(tester.getRect(find.byTooltip('Delete (Del)')).right, lessThanOrEqualTo(objectLeft));
    expect(tester.getRect(find.byTooltip('Rotate… (Ctrl+Shift+R)')).left, greaterThanOrEqualTo(objectRight));
    expect(tester.takeException(), isNull);

    // Nudge opens a panel with earlier / later and pixel arrows; it stays
    // open for repeated taps.
    const earlier = 'Earlier by one snap (Ctrl+←)';
    expect(find.byTooltip(earlier), findsNothing);
    final start = c.selection.single;
    await tester.tap(find.byTooltip('Nudge in time / position…'));
    await tester.pumpAndSettle();
    expect(find.byTooltip(earlier), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('Right 1 px'));
    await tester.pump();
    await tester.tap(find.byTooltip('Up 1 px'));
    await tester.pump();
    expect(c.selection.single.position, start.position + const Vec2(1, -1));
    // The middle of the D-pad cycles the step 1 → 2 → 4 → 1.
    await tester.tap(find.text('1px'));
    await tester.pump();
    await tester.tap(find.text('2px'));
    await tester.pump();
    await tester.tap(find.byTooltip('Left 4 px'));
    await tester.pump();
    expect(c.selection.single.position, start.position + const Vec2(-3, -1));
    await tester.tap(find.text('4px'));
    await tester.pump();
    expect(find.text('1px'), findsOneWidget);
    await tester.tap(find.byTooltip('Later by one snap (Ctrl+→)'));
    await tester.pump();
    expect(c.selection.single.time, greaterThan(start.time));
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.byTooltip(earlier), findsNothing);

    // Cut leaves nothing selected, but Paste stays reachable.
    expect(find.byTooltip(RegExp('^Paste')), findsNothing);
    await tester.tap(find.byTooltip('Cut (Ctrl+X)'));
    await tester.pump();
    expect(c.selection, isEmpty);
    expect(find.byTooltip('Delete (Del)'), findsNothing);
    expect(find.byTooltip(RegExp('^Paste')), findsOneWidget);
    final before = c.beatmap.hitObjects.length;
    await tester.tap(find.byTooltip(RegExp('^Paste')));
    await tester.pump();
    expect(c.beatmap.hitObjects.length, before + 1);

    // Tapping the overview seeks.
    final bar = tester.getRect(find.byType(MiniTimeline));
    await tester.tapAt(Offset(bar.left + bar.width * 0.5, bar.center.dy));
    await tester.pump();
    expect(c.time.value, greaterThan(1000));
  });
  testWidgets('long-pressing NC picks the colour skip', (tester) async {
    tester.view.physicalSize = const Size(891, 411);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final c = _sample();
    await tester.pumpWidget(MaterialApp(home: EditorScreen(controller: c)));
    c.select(c.beatmap.hitObjects[3]);
    await tester.pump();

    await tester.longPress(find.text('NC'));
    await tester.pumpAndSettle();
    final panel = find.ancestor(of: find.text('Combo colour skip'), matching: find.byType(Column)).first;
    for (var n = 0; n <= EditorController.maxComboSkip; n++) {
      expect(find.descendant(of: panel, matching: find.text('$n')), findsOneWidget);
    }
    expect(tester.takeException(), isNull);

    await tester.tap(find.descendant(of: panel, matching: find.text('3')));
    await tester.pumpAndSettle();
    expect(find.text('Combo colour skip'), findsNothing);
    expect(c.selection.single.comboSkip, 3);
    expect(find.text('NC +3'), findsOneWidget);
  });

  testWidgets('tablet layout: wider toolboxes and taller bars, nothing overflows', (tester) async {
    expect(EditorLayout.forSize(const Size(891, 411)), same(EditorLayout.phone));
    for (final size in const [Size(1180, 820), Size(1280, 800)]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      expect(EditorLayout.forSize(size), same(EditorLayout.tablet));

      final c = _sample();
      await tester.pumpWidget(MaterialApp(home: EditorScreen(controller: c)));
      expect(tester.takeException(), isNull, reason: '$size');
      expect(tester.getSize(find.byType(ComposeToolbox)).width, EditorLayout.tablet.toolboxWidth);
      expect(tester.getSize(find.byType(HitsoundToolbox)).width, EditorLayout.tablet.toolboxWidth);
      expect(tester.getSize(find.byType(TimelineView)).height, EditorLayout.tablet.topBarHeight - EditorLayout.topDeadZone);
      c.select(c.beatmap.hitObjects[2]);
      await tester.pump();
      expect(tester.takeException(), isNull, reason: '$size with the context card');
      await tester.pumpWidget(const SizedBox());
    }
    tester.view.reset();
  });
}
