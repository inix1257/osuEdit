import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/editor/timing_screen.dart';
import 'package:osu_edit/platform/beatmap_file_service.dart';

final _src = File('test/fixtures/sample_v14.osu').readAsStringSync();

/// Control Points list: filter and "Select all".
void main() {
  // Points: red 1000, green 3666, green 5000 (kiai), red 9000.
  Future<EditorController> pump(WidgetTester tester) async {
    final c = EditorController(beatmap: OsuParser.parse(_src), document: const BeatmapDocument(fileName: 'sample.osu'));
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ListenableBuilder(listenable: c, builder: (_, _) => ControlPointsPanel(controller: c))),
    ));
    return c;
  }

  Future<void> filter(WidgetTester tester, String label) async {
    await tester.tap(find.byTooltip('Filter'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  testWidgets('the filter narrows the list; Select all marks what it shows', (tester) async {
    final c = await pump(tester);
    expect(find.text('4 shown'), findsOneWidget);

    await filter(tester, 'Timing');
    expect(find.text('2 shown'), findsOneWidget);
    expect(find.text('180 BPM  4/4'), findsOneWidget);
    expect(find.text('120 BPM  3/4'), findsOneWidget);
    expect(find.textContaining('x SV'), findsNothing);

    await filter(tester, 'Kiai');
    expect(find.text('1 shown'), findsOneWidget);
    expect(find.text('1.5x SV'), findsOneWidget);

    // One point: Select all just selects it.
    await tester.tap(find.text('Select all'));
    await tester.pump();
    expect(find.text('INHERITED POINT'), findsOneWidget);
    expect(c.time.value, 5000);

    await filter(tester, 'Inherited');
    await tester.tap(find.text('Select all'));
    await tester.pump();
    expect(find.text('2 POINTS SELECTED'), findsOneWidget);
    // An edit applies to both greens only, as one step.
    await tester.tap(find.text('Kiai time'));
    await tester.pump();
    expect([for (final p in c.beatmap.timingPoints) p.kiai], [false, true, true, false]);
    c.undo();
    expect(c.serialize(), _src);

    await filter(tester, 'All points');
    await tester.tap(find.text('Select all'));
    await tester.pump();
    expect(find.text('4 POINTS SELECTED'), findsOneWidget);
  });

  testWidgets('rows are compact', (tester) async {
    await pump(tester);
    final row = tester.getRect(find.ancestor(of: find.text('180 BPM  4/4'), matching: find.byType(InkWell)).first);
    expect(row.height, lessThanOrEqualTo(28));
  });
}
