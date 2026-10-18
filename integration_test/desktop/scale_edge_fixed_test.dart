// Desktop background check: dragging a selection-box corner past the
// playfield edge never moves the opposite (pivot) corner.
//
// Run: OSUEDIT_BACKGROUND=1 /c/src/flutter/bin/flutter test integration_test/desktop/scale_edge_fixed_test.dart -d windows
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/editor/editor_screen.dart';
import 'package:osu_edit/editor/render/playfield_painter.dart';
import 'package:osu_edit/editor/render/playfield_transform.dart';
import 'package:osu_edit/editor/widgets/playfield_view.dart';

import 'harness.dart';

void main() {
  ensureDesktopBinding();

  testWidgets('scale edge fixed', (tester) async {
    final lib = await tempLibrary(osz: ['tool/test_set/osuEdit test set.osz']);
    await pumpApp(tester, lib);
    await openDifficulty(tester, 'Sync Test', 'Snaps');
    final EditorController c = tester.widget<EditorScreen>(find.byType(EditorScreen)).controller;
    final objs = c.beatmap.hitObjects;
    c.seek(objs[2].time);
    c.select(objs[1]);
    c.select(objs[2], additive: true);
    c.select(objs[3], additive: true);
    await settle(tester, const Duration(milliseconds: 300));

    final area = tester.getRect(find.byType(PlayfieldView));
    final tf = PlayfieldTransform.fit(area.size, c.playfieldZoom.value);
    final (min, max) = c.selectionBounds!;
    final (rect, _) = PlayfieldPainter.selectionBoxGeometry(min, max, tf, area.size);

    final g = await tester.startGesture(area.topLeft + rect.bottomRight);
    for (var i = 1; i <= 12; i++) {
      await g.moveBy(const Offset(40, 30));
      await tester.pump(const Duration(milliseconds: 16));
      final (a, _) = c.selectionBounds!;
      expect(a.x, closeTo(min.x, 0.01), reason: 'left stays at step $i');
      expect(a.y, closeTo(min.y, 0.01), reason: 'top stays at step $i');
    }
    await shot(tester, 'scale_edge_fixed');
    await g.up();
    await settle(tester, const Duration(milliseconds: 200));
    c.undo();
  });
}
