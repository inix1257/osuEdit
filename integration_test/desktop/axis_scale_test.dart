// Desktop background check: scaling width and height separately — the
// selection box's side handles and the Scale panel's lock.
//
// Run: OSUEDIT_BACKGROUND=1 /c/src/flutter/bin/flutter test integration_test/desktop/axis_scale_test.dart -d windows
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/editor/editor_screen.dart';
import 'package:osu_edit/editor/render/playfield_painter.dart';
import 'package:osu_edit/editor/render/playfield_transform.dart';
import 'package:osu_edit/editor/widgets/playfield_view.dart';

import 'harness.dart';

void main() {
  ensureDesktopBinding();

  testWidgets('axis scale', (tester) async {
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
    await shot(tester, 'axis_scale_box');

    final area = tester.getRect(find.byType(PlayfieldView));
    final tf = PlayfieldTransform.fit(area.size, c.playfieldZoom.value);
    final (min, max) = c.selectionBounds!;
    final (rect, _) = PlayfieldPainter.selectionBoxGeometry(min, max, tf, area.size);
    final edges = PlayfieldPainter.selectionEdgeHandles(rect, padding: c.circleRadius * tf.scale);
    debugPrint('box $rect edges $edges');
    expect(edges.where((e) => e.$2), isNotEmpty, reason: 'left / right handles');

    // Right side: only the width follows the finger, the left side stays.
    final before = [for (final h in c.selection) h.position.y]..sort();
    final g = await tester.startGesture(area.topLeft + rect.centerRight);
    await g.moveBy(const Offset(30, 0));
    await g.moveBy(const Offset(40, 25));
    await settle(tester, const Duration(milliseconds: 200));
    await shot(tester, 'axis_scale_side_drag');
    final (min2, max2) = c.selectionBounds!;
    final now = PlayfieldPainter.selectionBoxGeometry(min2, max2, tf, area.size).$1;
    expect((now.left - rect.left).abs(), lessThan(2));
    expect(now.right, closeTo(rect.right + 70, 2));
    expect(([for (final h in c.selection) h.position.y]..sort()), before);
    await g.up();
    await settle(tester, const Duration(milliseconds: 200));
    expect(c.history.undoLabel, 'Scale');
    c.undo();
    await settle(tester, const Duration(milliseconds: 200));

    // The Scale panel unlocked: Width and Height.
    await tester.tap(find.text('Scale').last);
    await settle(tester, const Duration(milliseconds: 300));
    await shot(tester, 'axis_scale_panel_locked');
    // The panel's (the box's own lock button is under the panel).
    await tester.tap(find.byTooltip('Unlock width / height').last);
    await settle(tester, const Duration(milliseconds: 200));
    expect(c.scaleLocksAspect, isFalse);
    expect(find.text('Width'), findsOneWidget);
    expect(find.text('Height'), findsOneWidget);
    await tester.enterText(find.byType(TextField).at(0), '130');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester, const Duration(milliseconds: 200));
    await tester.enterText(find.byType(TextField).at(1), '70');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester, const Duration(milliseconds: 300));
    await shot(tester, 'axis_scale_panel_unlocked');
    expect(find.text('Apply').hitTestable(), findsOneWidget, reason: 'fits without scrolling');
    await tester.tap(find.text('Apply'));
    await settle(tester, const Duration(milliseconds: 300));
    expect(c.history.undoLabel, 'Scale');
    final (min3, max3) = c.selectionBounds!;
    final r = c.circleRadius;
    final w0 = max.x - min.x - 2 * r, h0 = max.y - min.y - 2 * r;
    debugPrint('objects ${w0}x$h0 → ${max3.x - min3.x - 2 * r}x${max3.y - min3.y - 2 * r}');
    if (w0 > 20) expect((max3.x - min3.x - 2 * r) / w0, closeTo(1.3, 0.05));
    if (h0 > 20) expect((max3.y - min3.y - 2 * r) / h0, closeTo(0.7, 0.05));
    await shot(tester, 'axis_scale_applied');
    c.undo();
    await settle(tester, const Duration(milliseconds: 200));

    // The box's lock button shows the shared (now unlocked) state; locking
    // and unlocking it there.
    expect(find.byTooltip('Lock width / height'), findsOneWidget);
    await shot(tester, 'axis_scale_box_unlocked');
    await tester.tap(find.byTooltip('Lock width / height'));
    await settle(tester, const Duration(milliseconds: 200));
    expect(c.scaleLocksAspect, isTrue);
    expect(find.textContaining('Aspect ratio locked'), findsOneWidget);
    await shot(tester, 'axis_scale_box_locked');
    await tester.tap(find.byTooltip('Unlock width / height'));
    await settle(tester, const Duration(milliseconds: 200));
    expect(c.scaleLocksAspect, isFalse);

    // Unlocked two fingers: side by side, spreading across → only wider.
    final ys = [for (final h in c.selection) h.position.y]..sort();
    final box0 = PlayfieldPainter.selectionBoxGeometry(min, max, tf, area.size).$1.shift(area.topLeft);
    final f1 = await tester.startGesture(box0.center - const Offset(25, 0), pointer: 11);
    final f2 = await tester.startGesture(box0.center + const Offset(25, 0), pointer: 12);
    for (var i = 0; i < 5; i++) {
      await f1.moveBy(const Offset(-6, 0));
      await f2.moveBy(const Offset(6, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await settle(tester, const Duration(milliseconds: 100));
    await shot(tester, 'axis_scale_two_finger_stretch');
    await f1.up();
    await f2.up();
    await settle(tester, const Duration(milliseconds: 200));
    expect(c.history.undoLabel, 'Scale');
    expect(([for (final h in c.selection) h.position.y]..sort()), ys);
    final (min4, max4) = c.selectionBounds!;
    debugPrint('two-finger width ${max.x - min.x} → ${max4.x - min4.x}');
    expect(max4.x - min4.x, greaterThan(max.x - min.x + 20));
  });
}
