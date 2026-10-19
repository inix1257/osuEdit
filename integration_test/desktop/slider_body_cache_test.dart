// Desktop background check: slider bodies drawn from their cached images
// (playfield) and the nine-slice pill (timeline) look the same as the
// bodies drawn as path strokes. Writes both shots plus the same frame
// while snaking; compare build/desktop_shots/slider_body_{images,paths}.png.
//
// Run: OSUEDIT_BACKGROUND=1 /c/src/flutter/bin/flutter test integration_test/desktop/slider_body_cache_test.dart -d windows
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/editor/editor_screen.dart';
import 'package:osu_edit/editor/render/playfield_painter.dart';

import 'harness.dart';

void main() {
  ensureDesktopBinding();

  testWidgets('cached slider bodies match the path-drawn ones', (tester) async {
    final lib = await tempLibrary(osz: ['tool/test_set/osuEdit test set.osz']);
    await pumpApp(tester, lib);
    await openDifficulty(tester, 'Sync Test', 'Shapes');
    final EditorController c = tester.widget<EditorScreen>(find.byType(EditorScreen)).controller;

    Future<void> at(double t, String name) async {
      c.seek(t);
      await settle(tester, const Duration(milliseconds: 300));
      c.seek(t + 1); // a second frame at the same scale: the images are made
      await settle(tester, const Duration(milliseconds: 300));
      await shot(tester, name, pixelRatio: phoneDpr); // 1:1 with the device pixels the images are made for
    }

    await at(1667, 'slider_body_images');
    PlayfieldPainter.debugNoBodyImages = true;
    await at(1667, 'slider_body_paths');
    PlayfieldPainter.debugNoBodyImages = false;
    // Zoomed timeline and playfield: images made again at the new scale.
    c.timelineZoom = c.timelineZoom * 2;
    await at(1667, 'slider_body_images_zoom');
    PlayfieldPainter.debugNoBodyImages = true;
    await at(1667, 'slider_body_paths_zoom');
    PlayfieldPainter.debugNoBodyImages = false;
  });
}
