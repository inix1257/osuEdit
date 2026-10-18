// Desktop background check: the Scale panel's "Keep slider nodes" switch
// (off by default; on, sliders only move with their heads).
//
// Run: OSUEDIT_BACKGROUND=1 /c/src/flutter/bin/flutter test integration_test/desktop/scale_keep_nodes_test.dart -d windows
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/editor/editor_screen.dart';

import 'harness.dart';

void main() {
  ensureDesktopBinding();

  testWidgets('scale keeps slider nodes', (tester) async {
    final lib = await tempLibrary(osz: ['tool/test_set/osuEdit test set.osz']);
    await pumpApp(tester, lib);
    await openDifficulty(tester, 'Sync Test', 'Snaps');
    final EditorController c = tester.widget<EditorScreen>(find.byType(EditorScreen)).controller;
    final slider = c.beatmap.hitObjects.whereType<SliderObject>().first;
    final other = c.beatmap.hitObjects.firstWhere((h) => h is HitCircle);
    c.seek(slider.time);
    c.select(slider);
    c.select(other, additive: true);
    await settle(tester, const Duration(milliseconds: 300));

    await tester.tap(find.text('Scale').last);
    await settle(tester, const Duration(milliseconds: 300));
    final sw = find.widgetWithText(SwitchListTile, 'Keep slider nodes');
    expect(tester.widget<SwitchListTile>(sw).value, isFalse, reason: 'off by default');
    await tester.tap(sw);
    await settle(tester, const Duration(milliseconds: 200));
    expect(c.scaleKeepsSliderShape, isTrue);

    // 80% from the field.
    await tester.enterText(find.byType(TextField).first, '80');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester, const Duration(milliseconds: 300));
    await shot(tester, 'scale_keep_nodes_on');
    final kept = c.selection.whereType<SliderObject>().single;
    final d = kept.position - slider.position;
    expect(kept.controlPoints, [for (final p in slider.controlPoints) p + d]);
    expect(kept.length, slider.length);

    await tester.tap(sw);
    await settle(tester, const Duration(milliseconds: 300));
    await shot(tester, 'scale_keep_nodes_off');
    final scaled = c.selection.whereType<SliderObject>().single;
    expect(scaled.controlPoints, isNot([for (final p in slider.controlPoints) p + d]));

    await tester.tap(find.text('Cancel'));
    await settle(tester, const Duration(milliseconds: 300));
    expect(identical(c.beatmap.hitObjects.whereType<SliderObject>().first, slider), isTrue);
  });
}
