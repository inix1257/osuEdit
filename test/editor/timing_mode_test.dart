import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/editor/timing_mode_panel.dart';
import 'package:osu_edit/platform/beatmap_file_service.dart';

final _src = File('test/fixtures/sample_v14.osu').readAsStringSync();

EditorController _controller() => EditorController(
      beatmap: OsuParser.parse(_src),
      document: const BeatmapDocument(fileName: 'sample.osu'),
    );

void main() {
  group('retimePoint', () {
    test('without "move objects" only the point changes', () {
      final c = _controller();
      final red = c.beatmap.timingPoints.first;
      c.retimePoint(red, red.copyWith(time: 1010));
      expect(c.beatmap.hitObjects.first.time, 1000);
      c.undo();
      expect(c.serialize(), _src);
    });

    test('with "move objects" the section follows in one step and stays selected', () {
      final c = _controller();
      c.moveObjectsWithTiming = true;
      c.selection.add(c.beatmap.hitObjects[1]);
      final red = c.beatmap.timingPoints.first;
      final after = c.retimePoint(red, red.copyWith(time: 1010));
      expect(c.beatmap.timingPoints.first, same(after));
      expect(c.beatmap.hitObjects.first.time, 1010);
      expect(c.selection.single.time, 1343);
      expect(c.selection.single, same(c.beatmap.hitObjects[1]));
      // Meter / sample changes don't move anything.
      c.retimePoint(after, after.copyWith(meter: 3));
      expect(c.beatmap.hitObjects.first.time, 1010);
      c.undo();
      c.undo();
      expect(c.serialize(), _src);
    });
  });

  group('panel', () {
    Future<void> pump(WidgetTester tester, EditorController c) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ListenableBuilder(listenable: c, builder: (_, _) => TimingModePanel(controller: c)),
        ),
      ));
    }

    Finder richText(String s) => find.textContaining(s, findRichText: true);

    Future<void> enter(WidgetTester tester, String label, String text) async {
      await tester.enterText(find.widgetWithText(TextField, label), text);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
    }

    testWidgets('edits the points in effect at the playhead', (tester) async {
      final c = _controller();
      c.seek(6000);
      await pump(tester, c);
      expect(richText('00:01:000'), findsOneWidget); // red point
      // Sounds / kiai live in the Control Points popup, base SV and tick
      // rate in Song setup.
      expect(find.text('INHERITED POINT'), findsNothing);
      expect(find.text('Kiai time'), findsNothing);
      expect(find.text('Slider tick rate'), findsNothing);
      expect(find.widgetWithText(TextField, 'Base slider velocity'), findsNothing);
      expect(find.byKey(const ValueKey('bpm-strip')), findsOneWidget);
      expect(find.byKey(const ValueKey('bpm-rows')), findsOneWidget);

      await tester.tap(find.text('+1').first);
      await tester.pump();
      expect(c.beatmap.timingPoints.first.bpm, closeTo(181, 1e-9));

      await tester.tap(find.text('+10'));
      await tester.pump();
      expect(c.beatmap.timingPoints.first.time, 1010);
      expect(richText('00:01:010'), findsOneWidget);

      await enter(tester, 'BPM', '200');
      expect(c.beatmap.timingPoints.first.bpm, closeTo(200, 1e-9));

      for (var i = 0; i < 3; i++) {
        c.undo();
      }
      expect(c.serialize(), _src);
    });

    testWidgets('follows the playhead into the next section', (tester) async {
      final c = _controller();
      c.seek(6000);
      await pump(tester, c);
      await tester.tap(find.byTooltip('Next').first); // next red point
      await tester.pump();
      expect(c.time.value, 9000);
      expect(richText('00:09:000'), findsWidgets);
      expect(find.text('120'), findsOneWidget); // its BPM

      await tester.tap(find.byTooltip('Previous').first);
      await tester.pump();
      expect(c.time.value, 1000);
    });

    testWidgets('"Move objects with timing" carries objects along', (tester) async {
      final c = _controller();
      c.seek(2000);
      await pump(tester, c);
      await tester.tap(find.text('Move objects with timing'));
      await tester.pump();
      expect(c.moveObjectsWithTiming, isTrue);
      await tester.tap(find.text('−10'));
      await tester.pump();
      expect(c.beatmap.timingPoints.first.time, 990);
      expect(c.beatmap.hitObjects[1].time, 1323);
      c.undo();
      expect(c.serialize(), _src);
    });

    testWidgets('a point moved past the playhead takes the playhead along', (tester) async {
      final c = _controller();
      c.seek(1005);
      await pump(tester, c);
      await tester.tap(find.text('+10'));
      await tester.pump();
      expect(c.time.value, 1010);
      expect(richText('00:01:010'), findsOneWidget);
    });
  });
}
