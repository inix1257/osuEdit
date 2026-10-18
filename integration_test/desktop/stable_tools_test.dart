// Desktop background check of stable's tools: Polygon circles panel, reset
// samples / combo colours, revert to saved (⋮ menu), [General] settings and
// Delete difficulty (Song setup).
//
// Run: OSUEDIT_BACKGROUND=1 /c/src/flutter/bin/flutter test integration_test/desktop/stable_tools_test.dart -d windows
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/editor/editor_screen.dart';
import 'package:osu_edit/editor/widgets/editor_mode_button.dart';

import 'harness.dart';

void main() {
  ensureDesktopBinding();

  EditorController controllerOf(WidgetTester tester) => tester.widget<EditorScreen>(find.byType(EditorScreen)).controller;

  /// ⋮ → [group] → [item].
  Future<void> menu(WidgetTester tester, String group, String item) async {
    await tester.tap(find.byTooltip('Menu'));
    await settle(tester, const Duration(milliseconds: 400));
    await tester.tap(find.text(group));
    await settle(tester, const Duration(milliseconds: 400));
    await tester.tap(find.text(item));
    await settle(tester, const Duration(milliseconds: 500));
  }

  testWidgets('stable tools', (tester) async {
    final lib = await tempLibrary(osz: ['tool/test_set/osuEdit test set.osz']);
    await pumpApp(tester, lib);
    await openDifficulty(tester, 'Sync Test', 'Shapes');
    final c = controllerOf(tester);
    final n = c.beatmap.hitObjects.length;

    // --- Polygon circles in the empty stretch after the spinner.
    c.seek(12000);
    await settle(tester, const Duration(milliseconds: 300));
    await menu(tester, 'Edit', 'Polygon circles…');
    expect(find.textContaining('Polygon · 3 circles'), findsOneWidget);
    expect(c.beatmap.hitObjects.length, n + 3);
    await shot(tester, 'tools_polygon_3');
    // Vertices slider to the right end (10).
    final panel = find.ancestor(of: find.textContaining('Polygon ·'), matching: find.byType(Column)).first;
    final sliders = find.descendant(of: panel, matching: find.byType(Slider));
    expect(sliders, findsNWidgets(4));
    await tester.drag(sliders.first, const Offset(300, 0));
    await settle(tester, const Duration(milliseconds: 300));
    expect(find.textContaining('10 circles'), findsOneWidget);
    await shot(tester, 'tools_polygon_10');
    await tester.tap(find.text('Create'));
    await settle(tester, const Duration(milliseconds: 400));
    expect(c.beatmap.hitObjects.length, n + 10);
    expect(c.history.undoLabel, 'Polygon circles');
    await shot(tester, 'tools_polygon_created');

    // --- Reset combo colours / samples on everything.
    c.clearSelection();
    await settle(tester, const Duration(milliseconds: 200));
    await menu(tester, 'Edit', 'Reset all samples');
    expect(find.textContaining('No samples to reset'), findsOneWidget);

    // --- Revert to saved: back to the opened file.
    await menu(tester, 'Map', 'Revert to saved…');
    expect(find.text('Revert to saved?'), findsOneWidget);
    await tester.tap(find.text('Revert'));
    await settle(tester, const Duration(milliseconds: 500));
    expect(c.beatmap.hitObjects.length, n);
    expect(c.isDirty, isFalse);
    await shot(tester, 'tools_reverted');

    // --- [General] settings and Delete difficulty in Song setup.
    await tester.tap(find.byType(EditorModeButton));
    await settle(tester, const Duration(milliseconds: 400));
    await tester.tap(find.text('Song setup').last);
    await settle(tester, const Duration(milliseconds: 600));
    final right = find.byType(ListView).last;
    await tester.scrollUntilVisible(find.text('GENERAL'), 200, scrollable: find.descendant(of: right, matching: find.byType(Scrollable)).first);
    await settle(tester, const Duration(milliseconds: 300));
    await shot(tester, 'tools_general_top');
    await tester.scrollUntilVisible(find.text('Epilepsy warning'), 200, scrollable: find.descendant(of: right, matching: find.byType(Scrollable)).first);
    await settle(tester, const Duration(milliseconds: 300));
    final epilepsy = find.ancestor(of: find.text('Epilepsy warning'), matching: find.byType(Row)).first;
    await tester.tap(find.descendant(of: epilepsy, matching: find.byType(Switch)));
    await settle(tester, const Duration(milliseconds: 300));
    expect(c.beatmap.getValue(SectionNames.general, 'EpilepsyWarning'), '1');
    expect(c.songSetupChanged('General.EpilepsyWarning'), isTrue);
    await shot(tester, 'tools_general_changed');
    c.undo();
    await settle(tester, const Duration(milliseconds: 300));
    expect(c.isDirty, isFalse);

    await tester.scrollUntilVisible(find.text('Delete this difficulty…'), -200, scrollable: find.descendant(of: right, matching: find.byType(Scrollable)).first);
    await tester.ensureVisible(find.text('Delete this difficulty…'));
    await settle(tester, const Duration(milliseconds: 300));
    // Counting the set's difficulties is real file IO.
    await tester.runAsync(() async {
      await tester.tap(find.text('Delete this difficulty…'));
      await Future<void>.delayed(const Duration(milliseconds: 800));
    });
    await settle(tester, const Duration(milliseconds: 500));
    await shot(tester, 'tools_delete_tap');
    expect(find.text('Delete "Shapes"?'), findsOneWidget);
    await shot(tester, 'tools_delete_confirm');
    await tester.tap(find.text('Cancel'));
    await settle(tester, const Duration(milliseconds: 300));
    expect(find.byType(EditorScreen), findsOneWidget);
  });
}
