// "Copy hitsounds to…" (dialog → copy → Undo) and a Slider-tool drag.
//
// Run: OSUEDIT_BACKGROUND=1 /c/src/flutter/bin/flutter test integration_test/desktop/hitsound_copy_freehand_test.dart -d windows
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/editor/editor_screen.dart';
import 'package:osu_edit/editor/render/playfield_transform.dart';
import 'package:osu_edit/editor/widgets/playfield_view.dart';

import 'harness.dart';

void main() {
  ensureDesktopBinding();

  testWidgets('copy hitsounds to another difficulty, undo; draw a slider', (tester) async {
    final lib = await tempLibrary(osz: ['tool/test_set/osuEdit test set.osz']);
    await pumpApp(tester, lib);
    await openDifficulty(tester, 'Sync Test', 'Snaps');
    final c = tester.widget<EditorScreen>(find.byType(EditorScreen)).controller;
    final shapes = (await tester.runAsync(c.otherDifficulties))!.single;
    final before = File(shapes.path).readAsBytesSync();
    await shot(tester, 'bottom_bar');
    c.showMiniTimeline = true;
    await settle(tester);
    await shot(tester, 'bottom_bar_expanded');
    c.showMiniTimeline = false;
    await settle(tester);

    await tester.tap(find.byTooltip('Menu'));
    await settle(tester);
    await tester.tap(find.text('Map'));
    await settle(tester);
    await tester.tap(find.text('Copy hitsounds to…'));
    await settle(tester, const Duration(seconds: 1));
    expect(find.text('Shapes'), findsWidgets);
    await shot(tester, 'hitsound_copy_dialog');

    await tester.tap(find.text('Copy'));
    await waitFor(tester, find.textContaining('Copied hitsounds to 1 difficulty'));
    await shot(tester, 'hitsound_copy_done');
    final after = File(shapes.path).readAsBytesSync();
    expect(after, isNot(before));
    // Shapes now plays Snaps' sounds where it has objects at the same times.
    final copied = OsuParser.parse(String.fromCharCodes(after));
    expect(copied.version, 'Shapes');

    await tester.tap(find.text('Undo'));
    await settle(tester, const Duration(seconds: 1));
    expect(File(shapes.path).readAsBytesSync(), before);

    // Draw tool: a curved stroke on the playfield.
    c.seek(c.beatmap.hitObjects.last.time + 4000);
    await tester.tap(find.text('Slider'));
    await settle(tester);
    expect(c.tool, EditorTool.slider);
    final area = tester.getRect(find.byType(PlayfieldView));
    final tf = PlayfieldTransform.fit(area.size);
    Offset at(double x, double y) => area.topLeft + tf.toScreen(Vec2(x, y));
    final pts = [
      for (var i = 0; i <= 50; i++) Vec2(120 + 270 * i / 50, 260 - 140 * math.sin(math.pi * i / 50)),
    ];
    final n = c.beatmap.hitObjects.length;
    final g = await tester.startGesture(at(pts.first.x, pts.first.y), kind: PointerDeviceKind.touch);
    for (final p in pts.skip(1).take(30)) {
      await g.moveTo(at(p.x, p.y));
      await tester.pump(const Duration(milliseconds: 8));
    }
    await shot(tester, 'freehand_drawing');
    for (final p in pts.skip(31)) {
      await g.moveTo(at(p.x, p.y));
      await tester.pump(const Duration(milliseconds: 8));
    }
    await g.up();
    await settle(tester);
    expect(c.beatmap.hitObjects, hasLength(n + 1));
    expect(c.selection.single, isA<SliderObject>());
    await shot(tester, 'freehand_slider');
  });
}
