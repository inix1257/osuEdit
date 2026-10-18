import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/editor/editor_screen.dart';
import 'package:osu_edit/editor/widgets/editor_toolbars.dart';
import 'package:osu_edit/platform/beatmap_file_service.dart';

/// The star rating at the top left of Compose's inner area: it fades in a
/// second after the side strips go and hides at once when they appear.
void main() {
  Future<EditorController> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(891, 411);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = EditorController(
      beatmap: OsuParser.parse(File('test/fixtures/sample_v14.osu').readAsStringSync()),
      document: const BeatmapDocument(fileName: 'sample.osu'),
    );
    await tester.pumpWidget(MaterialApp(home: EditorScreen(controller: c)));
    c.difficulty.value =
        StarAnalysis(stars: 4.56, aim: 2, speed: 1, reading: 1, times: Float64List(0), strains: Float64List(0));
    await tester.pump();
    return c;
  }

  double opacity(WidgetTester tester) => tester
      .widget<AnimatedOpacity>(find.ancestor(of: find.byKey(const ValueKey('star rating')), matching: find.byType(AnimatedOpacity)))
      .opacity;

  testWidgets('fades in a second after nothing is selected; selecting hides it at once', (tester) async {
    final c = await pump(tester);
    expect(find.text('★ 4.56'), findsOneWidget);
    expect(opacity(tester), 0, reason: 'not yet');
    await tester.pump(const Duration(milliseconds: 900));
    expect(opacity(tester), 0);
    await tester.pump(const Duration(milliseconds: 200));
    expect(opacity(tester), 1);
    await tester.pumpAndSettle();

    // Top left of the inner area: right of the left toolbox, near the top.
    final chip = tester.getRect(find.byKey(const ValueKey('star rating')));
    final toolbox = tester.getRect(find.byType(ComposeToolbox));
    expect(chip.left, greaterThan(toolbox.right));
    expect(chip.left - toolbox.right, lessThan(24));
    expect(chip.top, lessThan(toolbox.top + 24));

    // Selecting an object: the strips appear and the chip goes at once.
    c.select(c.beatmap.hitObjects.first);
    await tester.pump();
    expect(opacity(tester), 0);
    expect(find.text('1 selected'), findsOneWidget);

    // Deselecting: back a second later, not before.
    c.clearSelection();
    await tester.pump(const Duration(milliseconds: 500));
    expect(opacity(tester), 0);
    // Selected again within the second: the pending fade-in is cancelled.
    c.select(c.beatmap.hitObjects.first);
    await tester.pump(const Duration(milliseconds: 800));
    expect(opacity(tester), 0);
    c.clearSelection();
    await tester.pump(const Duration(milliseconds: 1100));
    expect(opacity(tester), 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('not in the bottom bar any more', (tester) async {
    await pump(tester);
    await tester.pump(const Duration(seconds: 2));
    expect(find.byKey(const ValueKey('star rating')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
