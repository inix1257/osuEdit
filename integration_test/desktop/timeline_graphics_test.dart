// Desktop background check: the Compose timeline draws objects like the
// playfield (circles, slider track, end circles with repeat arrows; a
// skin's textures once one is selected), and Display → Stacking turns the
// stack offset off and on.
//
// Run: OSUEDIT_BACKGROUND=1 /c/src/flutter/bin/flutter test integration_test/desktop/timeline_graphics_test.dart -d windows
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/editor_screen.dart';
import 'package:osu_edit/platform/beatmap_library.dart';
import 'package:osu_edit/platform/skin_library.dart';

import 'harness.dart';

void main() {
  ensureDesktopBinding();

  testWidgets('timeline objects look like the playfield; stacking toggle', (tester) async {
    final lib = await tempLibrary(osz: ['tool/test_set/osuEdit test set.osz']);
    await pumpApp(tester, lib);
    await openDifficulty(tester, 'Sync Test', 'Snaps');
    final c = tester.widget<EditorScreen>(find.byType(EditorScreen)).controller;

    Future<void> at(double t, String name) async {
      c.seek(t);
      await settle(tester, const Duration(milliseconds: 250));
      await shot(tester, name);
    }

    final slider = c.beatmap.hitObjects.whereType<SliderObject>().firstWhere((s) => s.slides > 1);
    await at(slider.time, 'timeline_gfx_slider');
    final circle = c.beatmap.hitObjects.whereType<HitCircle>().elementAt(20);
    await at(circle.time, 'timeline_gfx_circles');
    final spinner = c.beatmap.hitObjects.whereType<Spinner>().first;
    await at(spinner.time, 'timeline_gfx_spinner');

    // Stacking: on by default; off draws stacked objects at their file
    // positions, on again shifts them back.
    expect(c.showStacking, isTrue);
    // The test map has no stack: put a circle right after one, on top of it.
    final objs = c.beatmap.hitObjects;
    final i = [
      for (var i = 0; i + 1 < objs.length; i++)
        if (objs[i] is HitCircle && objs[i + 1].time - objs[i].time > c.timing.beatLengthAt(objs[i].time) * 0.6) i
    ].first;
    c.seek(objs[i].time + c.timing.beatLengthAt(objs[i].time) / 4);
    c.placeCircle(objs[i].position);
    await settle(tester, const Duration(milliseconds: 200));
    final stacked = c.beatmap.hitObjects.firstWhere((h) => c.stackHeightOf(h) != 0);
    final shifted = c.displayPositionOf(stacked);
    expect(shifted, isNot(stacked.position));
    await at(stacked.time, 'stacking_on');
    await tester.tap(find.byTooltip('Menu'));
    await settle(tester);
    await tester.tap(find.text('Settings'));
    await settle(tester);
    await tester.tap(find.text('Display…'));
    await settle(tester);
    await tester.scrollUntilVisible(find.text('Stacking'), 40, scrollable: find.byType(Scrollable).last);
    await shot(tester, 'stacking_display_dialog');
    await tester.tap(find.text('Stacking'));
    await settle(tester, const Duration(milliseconds: 300));
    expect(c.showStacking, isFalse);
    expect(c.displayPositionOf(stacked), stacked.position);
    await tester.tap(find.text('Done').last);
    await settle(tester);
    await shot(tester, 'stacking_off');
    c.showStacking = true;
    await settle(tester, const Duration(milliseconds: 200));
    expect(c.displayPositionOf(stacked), shifted);
  });

  testWidgets('timeline uses the skin', (tester) async {
    final songs = await tempLibrary(osz: ['tool/test_set/osuEdit test set.osz']);
    final inbox = Directory(BeatmapLibrary.joinPath(songs.root.parent.path, 'Inbox'))..createSync();
    final lib = BeatmapLibrary(songs.root, inboxes: [inbox]);
    addTearDown(SkinManager.instance.reset);
    await File(projectPath('tool/test_set/osuEdit test skin.osk'))
        .copy(BeatmapLibrary.joinPath(inbox.path, 'osuEdit test skin.osk'));
    await pumpApp(tester, lib);
    await waitFor(tester, find.textContaining('.osk file(s) found'));
    await tester.tap(find.text('Import'));
    await waitFor(tester, find.textContaining('imported and selected'));
    await openDifficulty(tester, 'Sync Test', 'Snaps');
    final c = tester.widget<EditorScreen>(find.byType(EditorScreen)).controller;
    final slider = c.beatmap.hitObjects.whereType<SliderObject>().firstWhere((s) => s.slides > 1);
    c.seek(slider.time);
    await settle(tester, const Duration(milliseconds: 300));
    await shot(tester, 'timeline_gfx_skin');
  });
}
