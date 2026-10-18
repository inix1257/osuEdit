import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/editor/editor_screen.dart';
import 'package:osu_edit/editor/render/timeline_painter.dart';
import 'package:osu_edit/editor/song_setup_screen.dart';
import 'package:osu_edit/editor/timing_mode_panel.dart';
import 'package:osu_edit/editor/timing_screen.dart';
import 'package:osu_edit/editor/widgets/editor_mode_button.dart';
import 'package:osu_edit/editor/widgets/hitsound_view.dart';
import 'package:osu_edit/editor/widgets/playfield_view.dart';
import 'package:osu_edit/editor/widgets/timeline_view.dart';
import 'package:osu_edit/platform/beatmap_file_service.dart';

final _src = File('test/fixtures/sample_v14.osu').readAsStringSync();

EditorController _controller() => EditorController(
      beatmap: OsuParser.parse(_src),
      document: const BeatmapDocument(fileName: 'sample.osu'),
    );

void main() {
  group('timing points', () {
    test('a red point copies the BPM in effect at the snapped time', () {
      final c = _controller();
      c.seek(2010); // 1/4 at 180 BPM → 2000
      final p = c.addTimingPoint(red: true);
      expect(p.time, 2000);
      expect(p.uninherited, isTrue);
      expect(p.bpm, closeTo(180, 1e-9));
      expect(p.sampleSet, 2);
      expect(p.volume, 60);
      expect(c.beatmap.timingPoints[1], same(p));
      c.undo();
      expect(c.serialize(), _src);
    });

    test('a green point copies SV, sample settings and kiai', () {
      final c = _controller();
      c.seek(6000); // after the 1.5x kiai point at 5000
      final p = c.addTimingPoint(red: false);
      expect(p.uninherited, isFalse);
      expect(p.sliderVelocity, closeTo(1.5, 1e-9));
      expect(p.kiai, isTrue);
      expect(p.volume, 70);
      expect(c.serialize(), contains('\r\n6000,-66.6666666666667,4,2,0,70,0,1\r\n'));
    });

    test('adding where a point of that kind exists returns it', () {
      final c = _controller();
      c.seek(1000);
      final existing = c.beatmap.timingPoints.first;
      expect(c.addTimingPoint(red: true), same(existing));
      expect(c.isDirty, isFalse);
      // A green point at the same time is a different kind.
      expect(c.addTimingPoint(red: false).uninherited, isFalse);
      expect(c.beatmap.timingPoints.length, 5);
    });

    test('update and delete are undoable; no-op updates add nothing', () {
      final c = _controller();
      final p = c.beatmap.timingPoints.first;
      expect(c.updateTimingPoint(p, p.copyWith()), same(p));
      expect(c.isDirty, isFalse);

      final faster = c.updateTimingPoint(p, p.copyWith(beatLength: 60000 / 200, effects: TimingEffects.kiai));
      expect(c.beatmap.timingPoints.first, same(faster));
      expect(c.serialize(), contains('\r\n1000,300,4,2,0,60,1,1\r\n'));
      expect(c.timing.beatLengthAt(1500), 300);

      c.deleteTimingPoint(faster);
      expect(c.beatmap.timingPoints.length, 3);
      c.undo();
      c.undo();
      expect(c.serialize(), _src);
    });
  });

  group('setValues', () {
    test('changed values are one undo step; unchanged keep their lines', () {
      final c = _controller();
      expect(c.setValues('Song setup', [(SectionNames.metadata, 'Title', 'Sample Map')]), isFalse);
      expect(c.isDirty, isFalse);

      final changed = c.setValues('Song setup', [
        (SectionNames.metadata, 'Title', 'Other'),
        (SectionNames.metadata, 'Artist', 'osuEdit'),
        (SectionNames.difficulty, 'CircleSize', '5.5'),
      ]);
      expect(changed, isTrue);
      expect(c.beatmap.title, 'Other');
      expect(c.circleRadius, OsuRules.circleRadius(5.5));
      expect(c.history.undoLabel, 'Song setup');
      c.undo();
      expect(c.serialize(), _src);
    });
  });

  group('screens', () {
    Future<void> pumpScreen(WidgetTester tester, Widget screen) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: screen));
    }

    testWidgets('control points panel lists points and edits the selection', (tester) async {
      final c = _controller();
      c.seek(6000);
      await pumpScreen(
        tester,
        Scaffold(
          body: ListenableBuilder(listenable: c, builder: (_, _) => ControlPointsPanel(controller: c)),
        ),
      );
      expect(find.text('180 BPM  4/4'), findsOneWidget);
      expect(find.text('1.5x SV'), findsOneWidget);
      expect(find.text('INHERITED POINT'), findsOneWidget); // editor title (caps) (the button says "Inherited")

      // Kiai switch of the selected (5000 ms) point.
      await tester.tap(find.text('Kiai time'));
      await tester.pump();
      expect(c.beatmap.timingPoints[2].kiai, isFalse);
      // Undo swaps the point back in: the editor stays on it.
      c.undo();
      await tester.pump();
      expect(c.beatmap.timingPoints[2].kiai, isTrue);
      expect(find.text('Select a point'), findsNothing);
      await tester.tap(find.text('Kiai time'));
      await tester.pump();
      expect(c.beatmap.timingPoints[2].kiai, isFalse);

      // SV and volume can be typed next to their sliders, beyond the
      // slider's range too; out-of-range text is rejected.
      Future<void> type(String current, String text) async {
        await tester.enterText(find.widgetWithText(TextField, current), text);
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();
      }

      await type('1.5', '5.25');
      expect(c.beatmap.timingPoints[2].sliderVelocity, closeTo(5.25, 1e-9));
      await type('5.25', '12');
      expect(c.beatmap.timingPoints[2].sliderVelocity, closeTo(5.25, 1e-9));
      expect(find.widgetWithText(TextField, '5.25'), findsOneWidget);
      await type('70', '55');
      expect(c.beatmap.timingPoints[2].volume, 55);
      c.undo();
      c.undo();
      await tester.pump();
      expect(c.beatmap.timingPoints[2].sliderVelocity, closeTo(1.5, 1e-9));
      expect(c.beatmap.timingPoints[2].volume, 70);

      // Edit the BPM of the first red point.
      await tester.tap(find.text('180 BPM  4/4'));
      await tester.pump();
      expect(c.time.value, 1000);
      await tester.enterText(find.widgetWithText(TextField, 'BPM'), '150');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(c.beatmap.timingPoints.first.bpm, closeTo(150, 1e-9));

      // Add a green point at the playhead, then undo everything.
      await tester.tap(find.text('Inherited'));
      await tester.pump();
      expect(c.beatmap.timingPoints.length, 5);
      for (var i = 0; i < 3; i++) {
        c.undo();
        await tester.pump();
      }
      expect(c.serialize(), _src);
    });

    testWidgets('editing a point keeps the editor scrolled where it was', (tester) async {
      final c = _controller();
      c.seek(6000);
      tester.view.physicalSize = const Size(1280, 300);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListenableBuilder(listenable: c, builder: (_, _) => ControlPointsPanel(controller: c)),
          ),
        ),
      );
      ScrollPosition editorScroll() =>
          tester.state<ScrollableState>(find.ancestor(of: find.text('Offset'), matching: find.byType(Scrollable))).position;
      editorScroll().jumpTo(editorScroll().maxScrollExtent);
      await tester.pump();
      final scrolled = editorScroll().pixels;
      expect(scrolled, greaterThan(0));

      await tester.tap(find.text('Kiai time'));
      await tester.pump();
      expect(c.beatmap.timingPoints[2].kiai, isFalse);
      expect(editorScroll().pixels, scrolled);
      c.undo();
      await tester.pump();
      expect(editorScroll().pixels, scrolled);

      // Picking another point starts its editor at the top.
      await tester.tap(find.text('180 BPM  4/4'));
      await tester.pump();
      expect(editorScroll().pixels, 0);
    });

    testWidgets('long-press multi-selects points and edits what they share', (tester) async {
      final c = _controller();
      c.seek(6000); // starts on the 5000 ms point (1.5x SV, kiai)
      await pumpScreen(
        tester,
        Scaffold(
          body: ListenableBuilder(listenable: c, builder: (_, _) => ControlPointsPanel(controller: c)),
        ),
      );
      await tester.longPress(find.text('180 BPM  4/4'));
      await tester.pump();
      expect(find.text('2 POINTS SELECTED'), findsOneWidget);
      // Only the shared settings: no offset / BPM / SV.
      expect(find.widgetWithText(TextField, 'Offset'), findsNothing);
      expect(find.text('Slider velocity'), findsNothing);
      expect(find.text('Volume (mixed)'), findsOneWidget);

      // Kiai is mixed: one tap turns it on for both, as one undo step.
      await tester.tap(find.text('Kiai time'));
      await tester.pump();
      expect([for (final p in c.beatmap.timingPoints) p.kiai], [true, false, true, false]);
      expect(find.text('2 POINTS SELECTED'), findsOneWidget); // follows the new instances
      c.undo();
      await tester.pump();
      expect(c.serialize(), _src);
      expect(find.text('2 POINTS SELECTED'), findsOneWidget); // and undo's

      // While multi-selecting, a tap adds / removes a point.
      await tester.tap(find.text('120 BPM  3/4'));
      await tester.pump();
      expect(find.text('3 POINTS SELECTED'), findsOneWidget);
      await tester.tap(find.byTooltip('Delete 3 points'));
      await tester.pump();
      expect(c.beatmap.timingPoints, hasLength(1));
      c.undo();
      await tester.pump();
      expect(c.serialize(), _src);
      expect(find.text('3 POINTS SELECTED'), findsOneWidget); // the restored points
      await tester.tap(find.byTooltip('Clear selection'));
      await tester.pump();

      // Taking points out down to one goes back to the single editor.
      await tester.longPress(find.text('1x SV'));
      await tester.pump();
      await tester.tap(find.text('1x SV'));
      await tester.pump();
      expect(find.text('2 POINTS SELECTED'), findsNothing);
      expect(find.widgetWithText(TextField, 'Offset'), findsOneWidget);
    });

    testWidgets('song setup commits each field as its own step', (tester) async {
      final c = _controller();
      await pumpScreen(
        tester,
        Scaffold(
          body: ListenableBuilder(
            listenable: c,
            builder: (_, _) => SongSetupPanel(
              controller: c,
              onSetAudio: () {},
              onSetBackground: () {},
              onNewDifficulty: (_) {},
            ),
          ),
        ),
      );
      Future<void> submit(String label, String text) async {
        await tester.enterText(find.widgetWithText(TextField, label), text);
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();
      }

      // Not a library map: the set's difficulties can't be added to.
      expect(find.text('New difficulty…'), findsNothing);
      await submit('Difficulty name', 'Insane');
      expect(c.beatmap.version, 'Insane');
      expect(c.history.undoLabel, contains('Version'));

      // Invalid text shows an error while typing and is never committed.
      await tester.enterText(find.widgetWithText(TextField, 'Title (romanised)'), '샘플');
      await tester.pump();
      expect(find.text('Latin characters only'), findsOneWidget);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(c.beatmap.title, 'Sample Map');
      expect(find.text('Latin characters only'), findsNothing);

      await submit('Title (romanised)', 'Sample');
      expect(c.beatmap.title, 'Sample');
      // Untouched difficulty values keep their exact lines.
      expect(c.serialize(), _src.replaceFirst('Version:Normal', 'Version:Insane').replaceFirst('Title:Sample Map', 'Title:Sample'));

      // Undo shows up in the fields (they mirror the map).
      c.undo();
      c.undo();
      await tester.pump();
      expect(c.serialize(), _src);
      expect(find.widgetWithText(TextField, 'Normal'), findsOneWidget);

      // Preview time is one step too.
      c.seek(1500);
      await tester.tap(find.text('Use current time'));
      await tester.pump();
      expect(c.beatmap.getValue(SectionNames.general, 'PreviewTime'), '1500');
      expect(find.text(formatEditorTime(1500)), findsOneWidget);
    });

    testWidgets('the mode button switches between the editor screens', (tester) async {
      final c = _controller();
      await pumpScreen(tester, EditorScreen(controller: c));
      expect(find.byType(PlayfieldView), findsOneWidget);

      Future<void> pick(String label) async {
        await tester.tap(find.byType(EditorModeButton));
        await tester.pumpAndSettle();
        // The list opens to the right of the button.
        expect(tester.getTopLeft(find.text(label)).dx, greaterThan(tester.getTopRight(find.byType(EditorModeButton)).dx));
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
      }

      await pick('Song setup');
      expect(find.byType(SongSetupPanel), findsOneWidget);
      expect(find.byType(PlayfieldView), findsNothing);
      expect(find.byType(TimelineView), findsOneWidget); // the top bar stays

      await pick('Timing');
      expect(find.byType(TimingModePanel), findsOneWidget);
      expect(find.byType(HitsoundView), findsNothing);
      await pick('Hitsound');
      expect(find.byType(HitsoundView), findsOneWidget);
      expect(find.byType(PlayfieldView), findsNothing);

      await pick('Compose');
      expect(find.byType(PlayfieldView), findsOneWidget);
      expect(find.byType(HitsoundView), findsNothing);
    });

    testWidgets('Control Points opens as a popup over the current screen', (tester) async {
      final c = _controller();
      await pumpScreen(tester, EditorScreen(controller: c));
      Future<void> openPopup() async {
        await tester.tap(find.byType(EditorModeButton));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Control Points'));
        await tester.pumpAndSettle();
      }

      await openPopup();
      expect(find.byType(ControlPointsPanel), findsOneWidget);
      expect(find.byType(PlayfieldView), findsOneWidget); // the mode is unchanged, underneath
      // It leaves the top bar alone: the timeline still scrubs.
      final popup = tester.getRect(find.byType(ControlPointsPanel));
      final strip = tester.getRect(find.byType(TimelineView));
      expect(popup.top, greaterThan(strip.bottom));
      final t = c.time.value;
      await tester.dragFrom(strip.center, const Offset(-100, 0));
      await tester.pump();
      expect(c.time.value, greaterThan(t));

      // Edits work as before.
      await tester.tap(find.text('180 BPM  4/4'));
      await tester.pump();
      await tester.enterText(find.widgetWithText(TextField, 'BPM'), '150');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(c.beatmap.timingPoints.first.bpm, closeTo(150, 1e-9));

      // Close button, then the dimmed area outside, both close it.
      await tester.tap(find.byTooltip('Close'));
      await tester.pump();
      expect(find.byType(ControlPointsPanel), findsNothing);
      await openPopup();
      await tester.tapAt(tester.getBottomLeft(find.byType(ControlPointsPanel)) + const Offset(2, 4));
      await tester.pump();
      expect(find.byType(ControlPointsPanel), findsNothing);
    });

    testWidgets('timeline objects are faded in every mode but Compose', (tester) async {
      final c = _controller();
      await pumpScreen(tester, EditorScreen(controller: c));
      bool faded() => tester.widget<TimelineView>(find.byType(TimelineView)).objectsInBackground;
      expect(faded(), isFalse);
      for (final m in EditorMode.values) {
        await tester.tap(find.byType(EditorModeButton));
        await tester.pumpAndSettle();
        await tester.tap(find.text(m.label).last);
        await tester.pumpAndSettle();
        expect(faded(), m != EditorMode.compose, reason: m.label);
      }
    });

    testWidgets('in Timing mode timeline objects are faded and not editable', (tester) async {
      final c = _controller();
      await pumpScreen(tester, EditorScreen(controller: c));
      await tester.tap(find.byType(EditorModeButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Timing'));
      await tester.pumpAndSettle();
      expect(tester.widget<TimelineView>(find.byType(TimelineView)).objectsInBackground, isTrue);

      final o = c.beatmap.hitObjects.first;
      c.seek(o.time.toDouble());
      await tester.pump();
      final strip = tester.getRect(find.byType(TimelineView));
      double x(double t) => strip.left + TimelinePainter.xOf(t, c.time.value, c.timelineZoom, strip.width);
      final onObject = Offset(x(o.time.toDouble()), strip.center.dy);

      // Tap on an object: no selection.
      await tester.tapAt(onObject);
      await tester.pump(const Duration(milliseconds: 500));
      expect(c.selection, isEmpty);

      // Dragging a selected object scrubs instead of moving it.
      c.select(o);
      await tester.pump();
      final src = c.serialize();
      await tester.dragFrom(onObject, const Offset(-120, 0), touchSlopX: 0);
      await tester.pump();
      expect(c.serialize(), src);
      expect(c.time.value, greaterThan(o.time));

      // Long-press drag doesn't range-select.
      c.clearSelection();
      final g = await tester.startGesture(Offset(strip.left + 40, strip.top + 4));
      await tester.pump(const Duration(milliseconds: 700));
      await g.moveTo(Offset(strip.right - 40, strip.top + 4));
      await tester.pump();
      expect(c.timelineBox, isNull);
      await g.up();
      await tester.pump();
      expect(c.selection, isEmpty);
    });
  });
}
