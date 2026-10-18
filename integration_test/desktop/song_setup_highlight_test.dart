// Desktop background check: Song setup highlights values changed since the
// last save and clears the highlight on save.
//
// Run: OSUEDIT_BACKGROUND=1 /c/src/flutter/bin/flutter test integration_test/desktop/song_setup_highlight_test.dart -d windows
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/editor/song_setup_screen.dart';
import 'package:osu_edit/editor/widgets/editor_mode_button.dart';

import 'harness.dart';

void main() {
  ensureDesktopBinding();

  testWidgets('song setup highlights unsaved changes', (tester) async {
    final lib = await tempLibrary(osz: ['tool/test_set/osuEdit test set.osz']);
    await pumpApp(tester, lib);
    await openDifficulty(tester, 'Sync Test', 'Snaps');

    await tester.tap(find.byType(EditorModeButton));
    await settle(tester, const Duration(milliseconds: 400));
    await tester.tap(find.text('Song setup').last);
    await settle(tester, const Duration(milliseconds: 600));

    final c = tester.widget<SongSetupPanel>(find.byType(SongSetupPanel)).controller;
    int marked() => find
        .descendant(
          of: find.byType(SongSetupPanel),
          matching: find.byWidgetPredicate(
            (w) => w is Container && w.decoration is BoxDecoration && (w.decoration as BoxDecoration).border != null,
          ),
        )
        .evaluate()
        .length;
    final base = marked();
    await shot(tester, 'song_setup_layout_top');

    final field = find.widgetWithText(TextField, 'Artist (romanised)');
    final fieldRect = tester.getRect(field);
    final belowRect = tester.getRect(find.widgetWithText(TextField, 'Title (romanised)'));
    await tester.enterText(field, 'Highlight test');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester, const Duration(milliseconds: 400));
    expect(c.songSetupChanged('Metadata.Artist'), isTrue);
    expect(marked(), base + 1);
    // The highlight must not change the row's height (nor push rows below).
    expect(tester.getRect(field).height, fieldRect.height);
    expect(tester.getRect(field).top, fieldRect.top);
    expect(tester.getRect(find.widgetWithText(TextField, 'Title (romanised)')).top, belowRect.top);
    await shot(tester, 'song_setup_highlight_changed');

    c.undo();
    await settle(tester, const Duration(milliseconds: 400));
    expect(marked(), base);
    c.redo();
    await settle(tester, const Duration(milliseconds: 400));
    expect(marked(), base + 1);

    await tester.runAsync(c.save);
    await settle(tester, const Duration(milliseconds: 400));
    expect(marked(), base);
    await tester.drag(find.byType(ListView).last, const Offset(0, -250));
    await settle(tester, const Duration(milliseconds: 300));
    await shot(tester, 'song_setup_highlight_saved');
    // To the difficulty card (the right column continues below it).
    await tester.ensureVisible(find.byTooltip('Slider tick rate'));
    await settle(tester, const Duration(milliseconds: 300));
    await shot(tester, 'song_setup_layout_bottom');
    // Slider velocity and tick rate share one row.
    expect(tester.getCenter(find.text('Tick rate')).dy, closeTo(tester.getCenter(find.text('SV')).dy, 4));

    // The tick rate pill opens a menu; picking a rate is one undo step.
    await tester.tap(find.byTooltip('Slider tick rate'));
    await settle(tester, const Duration(milliseconds: 400));
    await shot(tester, 'song_setup_tick_rate_menu');
    await tester.tap(find.text('2').last);
    await settle(tester, const Duration(milliseconds: 400));
    expect(c.beatmap.sliderTickRate, 2);
    expect(c.songSetupChanged('Difficulty.SliderTickRate'), isTrue);
    await shot(tester, 'song_setup_tick_rate_changed');
    c.undo();
    await settle(tester, const Duration(milliseconds: 400));
    expect(c.beatmap.sliderTickRate, 1);
  });
}
