// Skins (.osk): one handed over to the app (inbox, like "Open with" on
// Android) is imported and selected, the playfield draws with it, and the
// skin picker switches back to the built-in look.
//
// Run: OSUEDIT_BACKGROUND=1 /c/src/flutter/bin/flutter test integration_test/desktop/skin_test.dart -d windows
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/app_dialog.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/editor_screen.dart';
import 'package:osu_edit/platform/beatmap_library.dart';
import 'package:osu_edit/platform/skin_library.dart';

import 'harness.dart';

void main() {
  ensureDesktopBinding();

  testWidgets('.osk import, skinned playfield, picker', (tester) async {
    final songs = await tempLibrary(osz: ['tool/test_set/osuEdit test set.osz']);
    final inbox = Directory(BeatmapLibrary.joinPath(songs.root.parent.path, 'Inbox'))..createSync();
    final lib = BeatmapLibrary(songs.root, inboxes: [inbox]);
    addTearDown(SkinManager.instance.reset);
    await File(projectPath('tool/test_set/osuEdit test skin.osk'))
        .copy(BeatmapLibrary.joinPath(inbox.path, 'osuEdit test skin.osk'));

    await pumpApp(tester, lib);
    await waitFor(tester, find.textContaining('.osk file(s) found'));
    await tester.tap(find.text('Import'));
    await waitFor(tester, find.textContaining('Skin "osuEdit Test Skin" imported and selected'));
    expect(SkinManager.instance.current.value?.info.name, 'osuEdit Test Skin');
    expect(inbox.listSync(), isEmpty);
    await shot(tester, 'skin_import_snack');

    await openDifficulty(tester, 'Sync Test', 'Snaps');
    final c = tester.widget<EditorScreen>(find.byType(EditorScreen)).controller;
    expect(c.skin, isNotNull);

    Future<void> at(double t, String name) async {
      c.seek(t);
      await settle(tester, const Duration(milliseconds: 250));
      await shot(tester, name);
    }

    final circle = c.beatmap.hitObjects.whereType<HitCircle>().elementAt(20);
    await at(circle.time - 300, 'skin_circles');
    final slider = c.beatmap.hitObjects.whereType<SliderObject>().firstWhere((s) => s.slides > 1);
    final end = c.endTimeOf(slider);
    await at(slider.time - 150, 'skin_slider_before');
    await at(slider.time + (end - slider.time) * 0.3, 'skin_slider_mid');
    final spinner = c.beatmap.hitObjects.whereType<Spinner>().first;
    await at((spinner.time + spinner.endTime) / 2, 'skin_spinner');

    // Display → Skin → back to the built-in look.
    c.seek(circle.time - 300);
    await tester.tap(find.byTooltip('Menu'));
    await settle(tester);
    await tester.tap(find.text('Settings'));
    await settle(tester);
    await tester.tap(find.text('Display…'));
    await settle(tester);
    expect(find.text('osuEdit Test Skin'), findsOneWidget, reason: 'the Skin row names it');
    await tester.tap(find.text('Skin'));
    await settle(tester);
    await shot(tester, 'skin_picker');
    await tester.tap(find.text('Default'));
    await settle(tester);
    expect(SkinManager.instance.current.value, isNull);
    await tester.tap(find.text('Done').last);
    await settle(tester);
    await tester.tap(find.text('Done').last);
    await settle(tester);
    expect(find.byType(AppDialog), findsNothing);
    await shot(tester, 'skin_default_circles');
  });
}
