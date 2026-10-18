// Desktop background check: the lazer-style selection box (outline, corner
// handles, rotation handle) and its readout while rotating.
//
// Run: OSUEDIT_BACKGROUND=1 /c/src/flutter/bin/flutter test integration_test/desktop/selection_box_test.dart -d windows
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/editor/editor_screen.dart';
import 'package:osu_edit/editor/render/playfield_painter.dart';
import 'package:osu_edit/editor/render/playfield_transform.dart';
import 'package:osu_edit/editor/widgets/playfield_view.dart';

import 'harness.dart';

void main() {
  ensureDesktopBinding();

  testWidgets('selection box', (tester) async {
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
    await shot(tester, 'selection_box');

    final area = tester.getRect(find.byType(PlayfieldView));
    final tf = PlayfieldTransform.fit(area.size, c.playfieldZoom.value);
    final (min, max) = c.selectionBounds!;
    final (rect, handle) = PlayfieldPainter.selectionBoxGeometry(min, max, tf, area.size);
    final g = await tester.startGesture(area.topLeft + handle);
    await g.moveBy(const Offset(30, 0));
    await g.moveBy(const Offset(40, 30));
    await settle(tester, const Duration(milliseconds: 200));
    await shot(tester, 'selection_box_rotating');
    await g.up();
    await settle(tester, const Duration(milliseconds: 200));
    expect(c.history.undoLabel, 'Rotate');
    expect(rect.width, greaterThan(0));
    c.undo();
    await settle(tester, const Duration(milliseconds: 200));

    // Dragging the bottom-right corner: it stays under the finger (mid-drag)
    // and the top-left corner stays put.
    final finger = area.topLeft + rect.bottomRight + const Offset(80, 60);
    final s = await tester.startGesture(area.topLeft + rect.bottomRight);
    await s.moveBy(const Offset(30, 0));
    await s.moveTo(finger);
    await settle(tester, const Duration(milliseconds: 200));
    await shot(tester, 'selection_box_scaling');
    final (min2, max2) = c.selectionBounds!;
    final now = PlayfieldPainter.selectionBoxGeometry(min2, max2, tf, area.size).$1.shift(area.topLeft);
    expect((now.topLeft - (area.topLeft + rect.topLeft)).distance, lessThan(2));
    // A uniform scale moves the corner along the objects' diagonal (the box
    // minus its circle-radius padding): it is as near the finger as it can be.
    final pad = c.circleRadius * tf.scale;
    final diag = rect.deflate(pad).bottomRight - rect.deflate(pad).topLeft;
    final miss = finger - now.bottomRight;
    expect((miss.dx * diag.dx + miss.dy * diag.dy) / diag.distance, closeTo(0, 2));
    await s.up();
    await settle(tester, const Duration(milliseconds: 200));
    expect(c.history.undoLabel, 'Scale');
    c.undo();
  });
}
