// Desktop background check: the Hitsound mode's timeline and layers
// (Sampleset / Additions / Whistle / Finish / Clap) and editing them.
//
// Run: OSUEDIT_BACKGROUND=1 /c/src/flutter/bin/flutter test integration_test/desktop/hitsound_view_test.dart -d windows
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/editor/editor_screen.dart';
import 'package:osu_edit/editor/render/hitsound_painter.dart';
import 'package:osu_edit/editor/widgets/editor_mode_button.dart';
import 'package:osu_edit/editor/widgets/hitsound_view.dart';
import 'package:osu_edit/editor/widgets/timeline_view.dart';
import 'package:osu_edit/platform/beatmap_file_service.dart';

import 'harness.dart';

void main() {
  ensureDesktopBinding();

  testWidgets('hitsound screen', (tester) async {
    final lib = await tempLibrary(osz: ['tool/test_set/osuEdit test set.osz']);
    await pumpApp(tester, lib);
    await openDifficulty(tester, 'Sync Test', 'Snaps');
    final EditorController c = tester.widget<EditorScreen>(find.byType(EditorScreen)).controller;
    await tester.tap(find.byType(EditorModeButton));
    await settle(tester, const Duration(milliseconds: 400));
    await tester.tap(find.text('Hitsound').last);
    await settle(tester);
    expect(find.byType(HitsoundView), findsOneWidget);
    expect(tester.widget<TimelineView>(find.byType(TimelineView)).objectsInBackground, isTrue);

    for (final t in [3000.0, 19500.0]) {
      c.seek(t);
      await settle(tester, const Duration(milliseconds: 300));
      await shot(tester, 'hitsound_${t.round()}');
    }
    // A slider (edges) if the map has one.
    final sliders = c.beatmap.hitObjects.where((h) => c.endTimeOf(h) > h.time).toList();
    if (sliders.isNotEmpty) {
      c.seek(sliders.first.time);
      c.select(sliders.first);
      await settle(tester, const Duration(milliseconds: 300));
      await shot(tester, 'hitsound_slider');
    }
  });

  // Repeat sliders with per-edge hitsounds / sets and body whistle: the
  // strip draws head, repeat rings and tail; the rows show every edge and
  // the body bars.
  testWidgets('slider edges and bodies', (tester) async {
    final text = File(projectPath('test/fixtures/sample_v14.osu')).readAsStringSync();
    final c = EditorController(
      beatmap: OsuParser.parse('${text.substring(0, text.indexOf('[HitObjects]'))}[HitObjects]\n'
          '100,100,2000,2,2,L|300:100,3,200,2|8|4|0,1:2|2:0|0:3|3:3,2:3:0:0:\n'
          '300,300,4500,2,0,L|400:300,2,100\n'
          '256,192,5500,12,4,6500,0:0:0:0:\n'),
      document: const BeatmapDocument(fileName: 'edges.osu'),
    );
    await pumpEditor(tester, c);
    await tester.tap(find.byType(EditorModeButton));
    await settle(tester, const Duration(milliseconds: 400));
    await tester.tap(find.text('Hitsound').last);
    await settle(tester);
    c.timelineZoom = 0.18;
    c.seek(3200);
    await settle(tester, const Duration(milliseconds: 300));
    await shot(tester, 'hitsound_edges');
    c.seek(5300);
    await settle(tester, const Duration(milliseconds: 300));
    await shot(tester, 'hitsound_edges_b');
  });

  // Timing row chips, sample index ("S3"), own volume (tinted bar) vs
  // inherited, an own sample file ("F", additions faded), slider ticks and
  // a slider body whose volume steps with the green lines.
  testWidgets('timing row, index, volume, file, ticks', (tester) async {
    final text = File(projectPath('test/fixtures/sample_v14.osu')).readAsStringSync();
    final head = text.substring(0, text.indexOf('[HitObjects]')).replaceFirst(
        '3666,-100,4,2,0,60,0,0', '2500,-100,4,2,2,30,0,0\n3000,-100,4,3,2,90,0,0\n3666,-100,4,2,0,60,0,0');
    final c = EditorController(
      beatmap: OsuParser.parse('$head[HitObjects]\n'
          '100,100,1000,1,2,0:0:3:40:\n'
          '200,100,1333,1,8,2:0:0:0:clap.wav\n'
          '300,100,1666,1,4,0:0:0:0:\n'
          '100,300,2000,2,2,L|400:300,1,600\n'
          '300,300,4000,2,0,L|400:300,1,100,0|0,0:0|0:0,0:0:0:25:\n'),
      document: const BeatmapDocument(fileName: 'volume.osu'),
    );
    await pumpEditor(tester, c);
    await tester.tap(find.byType(EditorModeButton));
    await settle(tester, const Duration(milliseconds: 400));
    await tester.tap(find.text('Hitsound').last);
    await settle(tester);
    c.timelineZoom = 0.16;
    c.seek(2300);
    await settle(tester, const Duration(milliseconds: 300));
    await shot(tester, 'hitsound_volume');
    c.seek(3800);
    await settle(tester, const Duration(milliseconds: 300));
    await shot(tester, 'hitsound_volume_b');
  });

  // Zoomed far out: timing points are dense. Which points get a chip (vs a
  // thin marker) must not change while scrolling a few pixels.
  testWidgets('timing chips stay put while scrolling dense points', (tester) async {
    final text = File(projectPath('test/fixtures/sample_v14.osu')).readAsStringSync();
    final extra = StringBuffer();
    for (var k = 0; k < 40; k++) {
      extra.write('${2500 + k * 170},-100,4,2,${k % 3 + 1},${30 + k},0,0\n');
    }
    final head = text.substring(0, text.indexOf('[HitObjects]')).replaceFirst(
        '3666,-100,4,2,0,60,0,0', '${extra}3666,-100,4,2,0,60,0,0');
    final c = EditorController(
      beatmap: OsuParser.parse('$head[HitObjects]\n100,100,1000,1,0,0:0:0:0:\n'),
      document: const BeatmapDocument(fileName: 'dense.osu'),
    );
    await pumpEditor(tester, c);
    await tester.tap(find.byType(EditorModeButton));
    await settle(tester, const Duration(milliseconds: 400));
    await tester.tap(find.text('Hitsound').last);
    await settle(tester);
    c.timelineZoom = 0.05;
    var i = 0;
    for (final t in [4000.0, 4015.0, 4030.0, 4045.0]) {
      c.seek(t);
      await settle(tester, const Duration(milliseconds: 300));
      await shot(tester, 'hitsound_dense_${i++}');
    }
  });

  // Note blocks (and timing chips) narrow as the timeline zooms out, losing
  // their letters; taps on the rows edit the note under the playhead and a
  // long press opens the index / volume dialog.
  testWidgets('zoomed block widths and editing', (tester) async {
    final lib = await tempLibrary(osz: ['tool/test_set/osuEdit test set.osz']);
    await pumpApp(tester, lib);
    await openDifficulty(tester, 'Sync Test', 'Snaps');
    final EditorController c = tester.widget<EditorScreen>(find.byType(EditorScreen)).controller;
    await tester.tap(find.byType(EditorModeButton));
    await settle(tester, const Duration(milliseconds: 400));
    await tester.tap(find.text('Hitsound').last);
    await settle(tester);
    final first = c.beatmap.hitObjects.first;
    for (final (name, zoom) in [('in', 0.6), ('mid', 0.2), ('out', 0.06), ('far', 0.02)]) {
      c.timelineZoom = zoom;
      c.seek(first.time + 600);
      await settle(tester, const Duration(milliseconds: 300));
      await shot(tester, 'hitsound_zoom_$name');
    }

    c.timelineZoom = 0.25;
    c.seek(first.time);
    await settle(tester, const Duration(milliseconds: 300));
    final rect = tester.getRect(find.byType(HitsoundTimeline));
    final g = HitsoundGeometry(rect.height);
    Offset row(HitsoundLayer l) => Offset(rect.center.dx, rect.top + g.rowTop(l) + g.rowHeight / 2);
    for (final l in [HitsoundLayer.whistle, HitsoundLayer.clap, HitsoundLayer.sampleSet, HitsoundLayer.additions]) {
      await tester.tapAt(row(l));
      await settle(tester, const Duration(milliseconds: 400));
    }
    final edited = c.beatmap.hitObjects.first;
    expect(edited.hitSound & HitSoundFlags.clap, isNot(0));
    await shot(tester, 'hitsound_edited');
    await tester.longPressAt(row(HitsoundLayer.finish));
    await settle(tester, const Duration(milliseconds: 500));
    expect(find.byType(HitsoundSampleDialog), findsOneWidget);
    await tester.tap(find.byTooltip('Raise index'));
    await tester.tap(find.text('Own volume'));
    await settle(tester, const Duration(milliseconds: 300));
    await shot(tester, 'hitsound_dialog');
    await tester.tap(find.text('Close'));
    await settle(tester, const Duration(milliseconds: 400));
    await shot(tester, 'hitsound_edited_b');
  });
}
