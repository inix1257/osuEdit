// Desktop background check: long-pressing the bottom overview bar seeks
// there and enters fine adjustment — holding the finger right / left of
// the anchor moves the playhead that way, faster the farther away; release
// snaps to the beat.
//
// Run: OSUEDIT_BACKGROUND=1 /c/src/flutter/bin/flutter test integration_test/desktop/mini_timeline_fine_test.dart -d windows
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/editor/editor_screen.dart';
import 'package:osu_edit/editor/widgets/mini_timeline.dart';

import 'harness.dart';

void main() {
  ensureDesktopBinding();

  testWidgets('mini timeline long-press fine adjustment', (tester) async {
    final lib = await tempLibrary(osz: ['tool/test_set/osuEdit test set.osz']);
    await pumpApp(tester, lib);
    await openDifficulty(tester, 'Sync Test', 'Snaps');
    final c = tester.widget<EditorScreen>(find.byType(EditorScreen)).controller;
    if (!c.showMiniTimeline) {
      c.showMiniTimeline = true;
      await settle(tester, const Duration(milliseconds: 300));
    }
    final bar = find.byType(MiniTimeline);
    expect(bar, findsOneWidget);
    final rect = tester.getRect(bar);
    final mid = rect.center;

    // Long-press: seeks to the pressed spot.
    final g = await tester.startGesture(mid);
    await settle(tester, const Duration(milliseconds: 800));
    final anchorTime = c.time.value;
    debugPrint('fine: width ${rect.width}, anchor time $anchorTime, max ${c.maxTime}');
    await shot(tester, 'mini_fine_anchor');
    final loupe = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is MiniTimelineLoupePainter);
    expect(loupe, findsOneWidget);
    // Right above the bar.
    expect(tester.getRect(loupe).bottom, closeTo(rect.top, 0.5));

    // Within the dead zone: holds still.
    await g.moveBy(const Offset(3, 0));
    await settle(tester, const Duration(milliseconds: 500));
    expect(c.time.value, closeTo(anchorTime, 0.001));

    // Slightly right: creeps forward slowly.
    await g.moveBy(const Offset(17, 0)); // 20 px from the anchor
    final t0 = c.time.value;
    await settle(tester, const Duration(milliseconds: 1000));
    final slow = c.time.value - t0;
    debugPrint('fine: 20px for 1s -> +$slow ms');
    expect(slow, greaterThan(0));

    // Farther right: much faster.
    await g.moveBy(const Offset(80, 0)); // 100 px
    final t1 = c.time.value;
    await settle(tester, const Duration(milliseconds: 1000));
    final fast = c.time.value - t1;
    debugPrint('fine: 100px for 1s -> +$fast ms');
    expect(fast, greaterThan(slow * 5));
    await shot(tester, 'mini_fine_right');

    // Measured from the playhead, not the press: as it catches up with the
    // held finger it slows down and never passes it.
    final fingerTime = anchorTime + 100 / rect.width * c.maxTime;
    final t1b = c.time.value;
    await settle(tester, const Duration(milliseconds: 1000));
    final later = c.time.value - t1b;
    debugPrint('fine: next 1s -> +$later ms (finger at ${fingerTime.round()}, playhead ${c.time.value.round()})');
    expect(later, lessThan(fast));
    expect(c.time.value, lessThan(fingerTime));
    await shot(tester, 'mini_fine_catch_up');

    // Left of the anchor: goes back.
    await g.moveBy(const Offset(-160, 0)); // -60 px
    final t2 = c.time.value;
    await settle(tester, const Duration(milliseconds: 600));
    expect(c.time.value, lessThan(t2));
    await shot(tester, 'mini_fine_left');

    // Release: snapped to the beat divisor, fine marks gone.
    await g.up();
    await settle(tester, const Duration(milliseconds: 300));
    final t = c.time.value;
    expect(t, closeTo(c.timing.snap(t, c.divisor), 0.5));
    expect(loupe, findsNothing);
    await shot(tester, 'mini_fine_released');
  });
}
