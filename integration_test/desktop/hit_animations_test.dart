// Playfield object visuals (lazer editor, classic skin): hit markers (white,
// fading) vs the Hit animations option, circles and sliders.
//
// Run: OSUEDIT_BACKGROUND=1 /c/src/flutter/bin/flutter test integration_test/desktop/hit_animations_test.dart -d windows
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/editor_screen.dart';

import 'harness.dart';

void main() {
  ensureDesktopBinding();

  testWidgets('hit markers vs hit animations', (tester) async {
    final lib = await tempLibrary(osz: ['tool/test_set/osuEdit test set.osz']);
    await pumpApp(tester, lib);
    await openDifficulty(tester, 'Sync Test', 'Snaps');
    var c = tester.widget<EditorScreen>(find.byType(EditorScreen)).controller;
    final circle = c.beatmap.hitObjects.whereType<HitCircle>().elementAt(20);

    Future<void> at(double t, String name) async {
      c.seek(t);
      await settle(tester, const Duration(milliseconds: 200));
      await shot(tester, name);
    }

    expect(c.hitAnimations, isFalse);
    await at(circle.time - 150, 'vis_circle_before');
    await at(circle.time + 100, 'vis_circle_markers');
    c.hitAnimations = true;
    await at(circle.time + 100, 'vis_circle_anim');

    await back(tester);
    await waitFor(tester, find.text('Shapes'));
    await tapDifficulty(tester, 'Shapes');
    await waitFor(tester, find.byType(EditorScreen));
    await settle(tester, const Duration(seconds: 1));
    c = tester.widget<EditorScreen>(find.byType(EditorScreen)).controller;
    final slider = c.beatmap.hitObjects.whereType<SliderObject>().firstWhere((s) => s.slides > 1,
        orElse: () => c.beatmap.hitObjects.whereType<SliderObject>().first);
    final end = c.endTimeOf(slider);
    expect(c.hitAnimations, isTrue, reason: 'the setting is kept');
    await at(slider.time - 200, 'vis_slider_before');
    await at((slider.time + end) / 2, 'vis_slider_mid_anim');
    c.hitAnimations = false;
    await at((slider.time + end) / 2, 'vis_slider_mid_markers');
    await at(end + 100, 'vis_slider_after_markers');
  });
}
