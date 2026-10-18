import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/editor/editor_screen.dart';
import 'package:osu_edit/editor/song_setup_screen.dart';
import 'package:osu_edit/editor/timing_mode_panel.dart';
import 'package:osu_edit/editor/timing_screen.dart';
import 'package:osu_edit/platform/beatmap_file_service.dart';

/// 120 BPM from 0, a green point at 4000, AR 9 (preempt 600), circles at
/// 1000, 5000 and 9000.
const src = 'osu file format v14\r\n'
    '\r\n'
    '[General]\r\n'
    'PreviewTime: -1\r\n'
    '\r\n'
    '[Editor]\r\n'
    'BeatDivisor: 4\r\n'
    '\r\n'
    '[Metadata]\r\n'
    'Title:A\r\n'
    'Version:Normal\r\n'
    '\r\n'
    '[Difficulty]\r\n'
    'HPDrainRate:5\r\n'
    'ApproachRate:9\r\n'
    'SliderMultiplier:1.4\r\n'
    '\r\n'
    '[Events]\r\n'
    '//Break Periods\r\n'
    '\r\n'
    '[TimingPoints]\r\n'
    '0,500,4,2,0,100,1,0\r\n'
    '4000,-100,4,2,0,100,0,0\r\n'
    '\r\n'
    '\r\n'
    '[HitObjects]\r\n'
    '100,100,1000,1,0,0:0:0:0:\r\n'
    '100,100,5000,1,0,0:0:0:0:\r\n'
    '100,100,9000,1,0,0:0:0:0:\r\n';

EditorController controller() => EditorController(
      beatmap: OsuParser.parse(src),
      document: const BeatmapDocument(fileName: 'b.osu'),
    );

void main() {
  group('EditFocus', () {
    test('objects: restored ones are focused, removed ones give the time', () {
      final b = OsuParser.parse(src);
      final h = EditHistory(b);
      final o = b.hitObjects[1];
      h.execute(RemoveHitObjectsCommand([o]));

      var before = EditSnapshot.of(b);
      h.undo();
      var f = EditFocus.between(before, b, h.lastStep!);
      expect(f.area, EditArea.objects);
      expect(f.objects, [same(o)]);
      expect(f.time, 5000);
      expect(f.label, 'Delete object');

      before = EditSnapshot.of(b);
      h.redo();
      f = EditFocus.between(before, b, h.lastStep!);
      expect(f.area, EditArea.objects);
      expect(f.objects, isEmpty);
      expect(f.time, 5000);
    });

    test('timing beats objects; green-only changes are flagged', () {
      final b = OsuParser.parse(src);
      final h = EditHistory(b);
      final green = b.timingPoints[1];
      h.execute(ReplaceTimingPointCommand(green, green.copyWith(beatLength: -50)));
      var before = EditSnapshot.of(b);
      h.undo();
      var f = EditFocus.between(before, b, h.lastStep!);
      expect(f.area, EditArea.timing);
      expect(f.timingPoints, [same(green)]);
      expect(f.inheritedOnly, isTrue);
      expect(f.time, 4000);

      final red = b.timingPoints[0];
      final moved = [for (final o in b.hitObjects) o.shiftedInTime(10)];
      h.execute(CompositeCommand('Move objects with timing', [
        ReplaceTimingPointCommand(red, red.copyWith(time: 10)),
        ReplaceHitObjectsCommand(List.of(b.hitObjects), moved),
      ]));
      before = EditSnapshot.of(b);
      h.undo();
      f = EditFocus.between(before, b, h.lastStep!);
      expect(f.area, EditArea.timing);
      expect(f.inheritedOnly, isFalse);
      expect(f.time, 0);
    });

    test('settings map to their screen with friendly names', () {
      final b = OsuParser.parse(src);
      final h = EditHistory(b);
      EditFocus step(EditCommand c) {
        h.execute(c);
        final before = EditSnapshot.of(b);
        h.undo();
        return EditFocus.between(before, b, h.lastStep!);
      }

      var f = step(SetValueCommand(SectionNames.difficulty, 'HPDrainRate', '6'));
      expect((f.area, f.label), (EditArea.songSetup, 'Change HP drain'));
      f = step(SetValueCommand(SectionNames.metadata, 'Title', 'B'));
      expect((f.area, f.label), (EditArea.songSetup, 'Change romanised title'));
      f = step(SetValueCommand(SectionNames.difficulty, 'SliderMultiplier', '2'));
      expect(f.area, EditArea.sliderSettings);
      f = step(SetValueCommand(SectionNames.editor, 'GridSize', '8'));
      expect(f.area, EditArea.composeSettings);
      f = step(SetBackgroundCommand('bg.png'));
      expect((f.area, f.label), (EditArea.songSetup, 'Set background'));
      f = step(CompositeCommand('Add bookmark', [SetValueCommand(SectionNames.editor, 'Bookmarks', '7000')]));
      expect((f.area, f.time), (EditArea.bookmarks, 7000));
      f = step(AddBreakCommand(1200, 4000));
      expect((f.area, f.time), (EditArea.breaks, 1200));
    });
  });

  group('controller', () {
    test('undo selects the restored objects and seeks to them', () {
      final c = controller();
      final o = c.beatmap.hitObjects[2];
      c.select(o);
      c.deleteSelection();
      c.seek(1000);
      c.undo();
      expect(c.selection, [same(o)]);
      expect(c.time.value, 9000);
      expect(c.lastHistoryStep.value!.undo, isTrue);
      expect(c.lastHistoryStep.value!.focus.label, 'Delete object');
    });

    test('no seek when the object is already on the playfield', () {
      final c = controller();
      c.select(c.beatmap.hitObjects[1]);
      c.toggleNewComboOnSelection();
      c.seek(4700); // 300 ms before it, inside preempt (600)
      c.undo();
      expect(c.time.value, 4700);
      expect(c.selection.single.time, 5000);
      c.redo();
      expect(c.time.value, 4700);
      expect(c.lastHistoryStep.value!.undo, isFalse);
    });

    test('a timing change seeks to its point', () {
      final c = controller();
      final red = c.beatmap.timingPoints.first;
      c.seek(8000);
      c.updateTimingPoint(red, red.copyWith(beatLength: 400));
      c.undo();
      expect(c.time.value, 0);
      expect(c.lastHistoryStep.value!.focus.area, EditArea.timing);
    });
  });

  group('screen', () {
    Future<EditorController> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(891, 411);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = controller();
      await tester.pumpWidget(MaterialApp(home: EditorScreen(controller: c)));
      return c;
    }

    testWidgets('undo / redo show a toast that fades away', (tester) async {
      final c = await pump(tester);
      c.select(c.beatmap.hitObjects[2]);
      c.deleteSelection();
      await tester.pump();
      expect(find.byType(HistoryToast), findsOneWidget);
      expect(find.textContaining('Undo:'), findsNothing);

      c.undo();
      await tester.pump();
      expect(find.text('Undo: Delete object · 00:09:000'), findsOneWidget);
      c.redo();
      await tester.pump();
      expect(find.text('Redo: Delete object · 00:09:000'), findsOneWidget);
      await tester.pump(HistoryToast.shownFor);
      await tester.pumpAndSettle();
      final opacity = tester.widget<AnimatedOpacity>(
          find.ancestor(of: find.textContaining('Redo:'), matching: find.byType(AnimatedOpacity)));
      expect(opacity.opacity, 0);
    });

    testWidgets('undo goes to the mode / panel holding the change', (tester) async {
      final c = await pump(tester);

      // Song setup value from Compose -> Song setup.
      c.setValues('Song setup', [(SectionNames.difficulty, 'HPDrainRate', '7')]);
      c.undo();
      await tester.pumpAndSettle();
      expect(find.byType(SongSetupPanel), findsOneWidget);
      expect(find.text('Undo: Change HP drain'), findsOneWidget);

      // Objects from Song setup -> Compose.
      c.select(c.beatmap.hitObjects[0]);
      c.deleteSelection();
      c.undo();
      await tester.pumpAndSettle();
      expect(find.byType(SongSetupPanel), findsNothing);
      expect(c.selection.single.time, 1000);

      // Red point -> Timing mode.
      final red = c.beatmap.timingPoints.first;
      c.updateTimingPoint(red, red.copyWith(beatLength: 400));
      c.undo();
      await tester.pumpAndSettle();
      expect(find.byType(TimingModePanel), findsOneWidget);

      // Green point -> the Control Points popup, on that point.
      final green = c.beatmap.timingPoints[1];
      c.updateTimingPoint(green, green.copyWith(beatLength: -50));
      c.undo();
      await tester.pumpAndSettle();
      expect(find.byType(ControlPointsPanel), findsOneWidget);
      expect(c.time.value, 4000);
      expect(find.text('Undo: Modify timing point · 00:04:000'), findsOneWidget);
    });
  });
}
