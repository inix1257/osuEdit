// Desktop background check: slider track / border colours ([Colours]
// SliderTrackOverride / SliderBorder) edited in Song setup and drawn on the
// playfield.
//
// Run: OSUEDIT_BACKGROUND=1 /c/src/flutter/bin/flutter test integration_test/desktop/slider_colours_test.dart -d windows
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/editor/editor_screen.dart';
import 'package:osu_edit/editor/widgets/editor_mode_button.dart';

import 'harness.dart';

void main() {
  ensureDesktopBinding();

  testWidgets('slider track and border colours', (tester) async {
    final lib = await tempLibrary(osz: ['tool/test_set/osuEdit test set.osz']);
    await pumpApp(tester, lib);
    await openDifficulty(tester, 'Sync Test', 'Shapes');
    final EditorController c = tester.widget<EditorScreen>(find.byType(EditorScreen)).controller;
    c.seek(1667);
    await settle(tester, const Duration(milliseconds: 300));
    await shot(tester, 'slider_colours_before');

    Future<void> mode(String name) async {
      await tester.tap(find.byType(EditorModeButton));
      await settle(tester, const Duration(milliseconds: 400));
      await tester.tap(find.text(name).last);
      await settle(tester, const Duration(milliseconds: 600));
    }

    Future<void> setColour(String row, String hex) async {
      await tester.ensureVisible(find.text(row));
      await settle(tester, const Duration(milliseconds: 300));
      await tester.tap(find.text(row));
      await settle(tester, const Duration(milliseconds: 400));
      await tester.enterText(find.widgetWithText(TextField, 'Hex'), hex);
      await settle(tester, const Duration(milliseconds: 200));
      await tester.tap(find.text('OK'));
      await settle(tester, const Duration(milliseconds: 400));
    }

    await mode('Song setup');
    await tester.scrollUntilVisible(find.text('Slider border'), 200,
        scrollable: find.descendant(of: find.byType(ListView).first, matching: find.byType(Scrollable)).first);
    await settle(tester, const Duration(milliseconds: 300));
    expect(find.text('Combo colour'), findsOneWidget);
    expect(find.text('White'), findsOneWidget);
    await setColour('Slider track', 'FF8000');
    await setColour('Slider border', '00C0FF');
    expect(c.mapColour(ComboColours.sliderTrack), const RgbColour(255, 128, 0));
    expect(c.mapColour(ComboColours.sliderBorder), const RgbColour(0, 192, 255));
    expect(find.text('#FF8000'), findsOneWidget);
    expect(c.songSetupChanged('Colours.SliderBorder'), isTrue);
    await shot(tester, 'slider_colours_setup');

    await mode('Compose');
    await shot(tester, 'slider_colours_after');

    // "Use default" removes the key again.
    await mode('Song setup');
    await tester.scrollUntilVisible(find.text('Slider border'), 200,
        scrollable: find.descendant(of: find.byType(ListView).first, matching: find.byType(Scrollable)).first);
    await settle(tester, const Duration(milliseconds: 300));
    await tester.tap(find.text('Slider border'));
    await settle(tester, const Duration(milliseconds: 400));
    await tester.tap(find.text('Use default'));
    await settle(tester, const Duration(milliseconds: 400));
    expect(c.mapColour(ComboColours.sliderBorder), isNull);
    c.undo();
    c.undo();
    c.undo();
    await settle(tester, const Duration(milliseconds: 300));
    expect(c.isDirty, isFalse);
  });
}
