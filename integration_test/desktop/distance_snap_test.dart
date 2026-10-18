// Desktop background check: distance snap — the Snap settings side panels
// with 0.01 steps, no ring after a spinner, the grid winning over the ring.
//
// Run: OSUEDIT_BACKGROUND=1 /c/src/flutter/bin/flutter test integration_test/desktop/distance_snap_test.dart -d windows
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/editor/editor_screen.dart';

import 'harness.dart';

void main() {
  ensureDesktopBinding();

  testWidgets('distance snap', (tester) async {
    final lib = await tempLibrary(osz: ['tool/test_set/osuEdit test set.osz']);
    await pumpApp(tester, lib);
    await openDifficulty(tester, 'Sync Test', 'Snaps');
    final EditorController c = tester.widget<EditorScreen>(find.byType(EditorScreen)).controller;

    // Snap settings: +0.01 twice, then the label.
    await tester.longPress(find.textContaining('Dist '));
    await settle(tester, const Duration(milliseconds: 300));
    final before = c.distanceSpacing;
    await tester.tap(find.text('+0.01'));
    await settle(tester, const Duration(milliseconds: 100));
    await tester.tap(find.text('+0.01'));
    await settle(tester, const Duration(milliseconds: 200));
    await shot(tester, 'distance_snap_settings');
    expect(c.distanceSpacing, closeTo(before + 0.02, 1e-9));
    await tester.tapAt(const Offset(300, 200)); // outside: closes the side panel
    await settle(tester, const Duration(milliseconds: 300));
    expect(find.text('+0.01'), findsNothing);
    await tester.longPress(find.textContaining('Grid '));
    await settle(tester, const Duration(milliseconds: 300));
    await shot(tester, 'grid_settings_panel');
    await tester.tap(find.text('8'));
    await settle(tester, const Duration(milliseconds: 200));
    expect(c.gridSize, 8);
    await tester.tapAt(const Offset(300, 200));
    await settle(tester, const Duration(milliseconds: 300));
    debugPrint('spacing $before → ${c.distanceSpacing}');
    expect(find.textContaining('Dist ${formatSpacingForTest(c.distanceSpacing)}'), findsOneWidget);

    // Circle tool with distance snap: the ring around the previous object.
    c.distanceSnap = true;
    c.tool = EditorTool.circle;
    final objs = c.beatmap.hitObjects.where((h) => h is! Spinner).toList();
    c.seek(objs[3].time + 250);
    await settle(tester, const Duration(milliseconds: 300));
    await shot(tester, 'distance_snap_ring');
    final t = c.timing.snap(c.time.value, c.divisor);
    final g = c.distanceSnapGuide(t);
    expect(g, isNotNull);
    final ring = c.placementPosition(g!.$1 + const Vec2(37, 53), t);
    c.gridSnap = true;
    final grid = c.placementPosition(g.$1 + const Vec2(37, 53), t);
    debugPrint('ring $ring grid $grid');
    expect(grid, c.snapPosition(ring));
    await settle(tester, const Duration(milliseconds: 200));
    await shot(tester, 'distance_snap_ring_grid');

    // After a spinner (if the map has one): no ring.
    final spinner = c.beatmap.hitObjects.whereType<Spinner>().firstOrNull;
    if (spinner != null) {
      final next = c.beatmap.hitObjects.where((h) => h.time > spinner.endTime).firstOrNull;
      final at = spinner.endTime + 100;
      if (next == null || next.time > at + 1) {
        expect(c.distanceSnapGuide(at), isNull);
        debugPrint('after spinner @$at: no ring');
      }
    }
  });
}

String formatSpacingForTest(double v) {
  final two = v.toStringAsFixed(2);
  return two.endsWith('0') ? v.toStringAsFixed(1) : two;
}
