// Desktop background check: unsaved edits autosaved in the editor are
// offered back when the map is opened again (as after the app was killed),
// "Discard" drops them; plus the grouped ⋮ menu and typed transform values.
//
// Run: OSUEDIT_BACKGROUND=1 /c/src/flutter/bin/flutter test integration_test/desktop/recovery_test.dart -d windows
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/editor/editor_screen.dart';
import 'package:osu_edit/platform/recovery_store.dart';

import 'harness.dart';

void main() {
  ensureDesktopBinding();

  EditorController controllerOf(WidgetTester tester) => tester.widget<EditorScreen>(find.byType(EditorScreen)).controller;

  testWidgets('autosave, recovery prompt, grouped menu, typed transform', (tester) async {
    final lib = await tempLibrary(osz: ['tool/test_set/osuEdit test set.osz']);
    await pumpApp(tester, lib);
    await openDifficulty(tester, 'Sync Test', 'Shapes');
    var c = controllerOf(tester);
    final path = c.document.path!;
    final n = c.beatmap.hitObjects.length;

    // The grouped menu: five groups, items one level down.
    await tester.tap(find.byTooltip('Menu'));
    await settle(tester, const Duration(milliseconds: 400));
    for (final g in ['Edit', 'Bookmarks', 'Map', 'Settings', 'Close editor']) {
      expect(find.text(g), findsOneWidget);
    }
    await tester.tap(find.text('Map'));
    await settle(tester, const Duration(milliseconds: 400));
    expect(find.text('Revert to saved…'), findsOneWidget);
    await shot(tester, 'menu_grouped');
    // System back closes the menu only, not the editor.
    await back(tester);
    expect(find.text('Revert to saved…'), findsNothing);
    expect(find.byType(EditorScreen), findsOneWidget);

    // Typed rotation in the transform panel.
    c.seek(1000);
    await settle(tester, const Duration(milliseconds: 300));
    c.select(c.beatmap.hitObjects.first);
    await settle(tester, const Duration(milliseconds: 300));
    await tester.tap(find.text('Rotate'));
    await settle(tester, const Duration(milliseconds: 500));
    final rotate = find.byType(TextField).first;
    await tester.enterText(rotate, '45');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester, const Duration(milliseconds: 300));
    await shot(tester, 'transform_typed');
    await tester.tap(rotate); // like a finger: focus the field first
    await settle(tester, const Duration(milliseconds: 200));
    await tester.enterText(rotate, '999');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester, const Duration(milliseconds: 300));
    expect(tester.widget<TextField>(rotate).controller!.text, '180', reason: 'clamped to the range');
    await tester.tap(find.text('Apply'));
    await settle(tester, const Duration(milliseconds: 400));
    expect(c.history.undoLabel, 'Rotate');

    // An unsaved edit, autosaved; then the editor is gone without saving
    // (as if the app were killed: the autosave stays).
    c.seek(12000); // empty: a circle on an object's time would replace it
    c.placeCircle(const Vec2(10, 10));
    await tester.runAsync(c.autosave);
    final store = RecoveryStore.besideLibrary(lib.root);
    expect((await tester.runAsync(() => store.read(path)))!.text, c.serialize());
    final edited = c.serialize();
    // Pop the editor directly (Discard would delete the autosave).
    Navigator.of(tester.element(find.byType(EditorScreen))).pop();
    await settle(tester);

    // Opening it again offers the changes.
    await tapDifficulty(tester, 'Shapes');
    await waitFor(tester, find.text('Recover unsaved changes?'));
    await shot(tester, 'recovery_prompt');
    await tester.tap(find.text('Recover'));
    await waitFor(tester, find.byType(EditorScreen));
    await settle(tester, const Duration(seconds: 1));
    c = controllerOf(tester);
    expect(c.serialize(), edited);
    expect(c.isDirty, isTrue);
    expect(c.beatmap.hitObjects.length, n + 1);
    await shot(tester, 'recovered');

    // Close and discard: the autosave goes too, the next open is plain.
    await back(tester);
    await tester.tap(find.text('Discard'));
    await settle(tester);
    expect(await tester.runAsync(() => store.read(path)), isNull);
    await tapDifficulty(tester, 'Shapes');
    await waitFor(tester, find.byType(EditorScreen));
    expect(find.text('Recover unsaved changes?'), findsNothing);
    expect(controllerOf(tester).beatmap.hitObjects.length, n);
  });
}
