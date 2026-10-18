// Editor menu (Edit -> New slider type): forces the curve type of
// sliders drawn with the Slider tool, and is kept between maps.
//
// Run: OSUEDIT_BACKGROUND=1 /c/src/flutter/bin/flutter test integration_test/desktop/default_slider_type_test.dart -d windows
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/editor_screen.dart';
import 'package:osu_edit/platform/app_settings.dart';

import 'harness.dart';

void main() {
  ensureDesktopBinding();

  testWidgets('default slider type option', (tester) async {
    final lib = await tempLibrary(osz: ['tool/test_set/osuEdit test set.osz']);
    await pumpApp(tester, lib);
    await openDifficulty(tester, 'Sync Test', 'Snaps');
    final c = tester.widget<EditorScreen>(find.byType(EditorScreen)).controller;
    expect(c.defaultSliderType, DefaultSliderType.auto);

    await tester.tap(find.byTooltip('Menu'));
    await settle(tester, const Duration(milliseconds: 400));
    await tester.tap(find.text('Edit'));
    await settle(tester, const Duration(milliseconds: 400));
    await tester.tap(find.text('New slider type'));
    await settle(tester, const Duration(milliseconds: 400));
    await shot(tester, 'default_slider_menu');

    await tester.tap(find.text('Catmull'));
    await settle(tester, const Duration(milliseconds: 300));
    expect(c.defaultSliderType, DefaultSliderType.catmull);

    for (final p in const [Vec2(100, 100), Vec2(200, 160), Vec2(300, 100)]) {
      c.sliderToolTap(p);
    }
    expect(c.draftSlider!.curveType, CurveType.catmull);
    await shot(tester, 'default_slider_draft');
  });
}
