// Desktop background check: the Timing mode's left panel and the Control
// Points popup in the Song setup style (cards, filled fields, pills).
//
// Run: OSUEDIT_BACKGROUND=1 /c/src/flutter/bin/flutter test integration_test/desktop/timing_panels_style_test.dart -d windows
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/editor/editor_screen.dart';
import 'package:osu_edit/editor/widgets/editor_mode_button.dart';

import 'harness.dart';

void main() {
  ensureDesktopBinding();

  testWidgets('Timing panel and Control Points in the setup style', (tester) async {
    final lib = await tempLibrary(osz: ['tool/test_set/osuEdit test set.osz']);
    await pumpApp(tester, lib);
    await openDifficulty(tester, 'Sync Test', 'Snaps');
    final EditorController c = tester.widget<EditorScreen>(find.byType(EditorScreen)).controller;

    Future<void> pick(String label) async {
      await tester.tap(find.byType(EditorModeButton));
      await settle(tester, const Duration(milliseconds: 400));
      await tester.tap(find.text(label).last);
      await settle(tester, const Duration(milliseconds: 600));
    }

    await pick(EditorMode.timing.label);
    expect(find.text('Omit first bar line'), findsNothing);
    await shot(tester, 'style_timing_panel');
    // The meter pill opens its menu.
    await tester.tap(find.text('4/4'));
    await settle(tester, const Duration(milliseconds: 400));
    await shot(tester, 'style_timing_meter_menu');
    await tester.tap(find.text('3/4').last);
    await settle(tester, const Duration(milliseconds: 400));
    expect(c.timing.redPoints.first.meter, 3);
    c.undo();
    await settle(tester, const Duration(milliseconds: 300));

    await pick('Control Points');
    expect(find.text('Omit first bar line'), findsOneWidget); // red point selected
    await shot(tester, 'style_control_points_red');
    await tester.tap(find.byTooltip('Filter'));
    await settle(tester, const Duration(milliseconds: 400));
    await shot(tester, 'style_control_points_filter_menu');
    await tester.tap(find.text('Inherited').last);
    await settle(tester, const Duration(milliseconds: 400));
    await tester.tap(find.text('Select all'));
    await settle(tester, const Duration(milliseconds: 400));
    await shot(tester, 'style_control_points_filtered_all');
    await tester.tap(find.byTooltip('Clear selection'));
    await tester.tap(find.byTooltip('Filter'));
    await settle(tester, const Duration(milliseconds: 400));
    await tester.tap(find.text('All points').last);
    await settle(tester, const Duration(milliseconds: 400));
    await tester.tap(find.text('180 BPM  4/4'));
    await settle(tester, const Duration(milliseconds: 400));
    await tester.tap(find.text('Omit first bar line'));
    await tester.pump();
    expect(c.timing.redPoints.first.effects & 8, 8);
    c.undo();
    await settle(tester, const Duration(milliseconds: 2000)); // toast gone
    await tester.drag(find.text('Omit first bar line'), const Offset(0, -200));
    await settle(tester, const Duration(milliseconds: 400));
    await shot(tester, 'style_control_points_sounds');
    await tester.tap(find.text('Inherited'));
    await settle(tester, const Duration(milliseconds: 400));
    expect(find.text('INHERITED POINT'), findsOneWidget);
    await shot(tester, 'style_control_points_green');
    // Multi-select: long press a second row.
    await tester.longPress(find.text('00:09:000'));
    await settle(tester, const Duration(milliseconds: 400));
    await shot(tester, 'style_control_points_multi');
    c.undo();
    await settle(tester, const Duration(milliseconds: 400));
  });
}
