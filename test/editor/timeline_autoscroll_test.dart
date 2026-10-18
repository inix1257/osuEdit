import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/editor/editor_screen.dart';
import 'package:osu_edit/editor/render/timeline_painter.dart';
import 'package:osu_edit/editor/widgets/timeline_view.dart';
import 'package:osu_edit/platform/beatmap_file_service.dart';

/// Objects from 1000 to 10000 ms.
EditorController _sample() => EditorController(
      beatmap: OsuParser.parse(File('test/fixtures/sample_v14.osu').readAsStringSync()),
      document: const BeatmapDocument(fileName: 'sample.osu'),
    );

void main() {
  Future<(EditorController, Rect)> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(891, 411);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = _sample();
    await tester.pumpWidget(MaterialApp(home: EditorScreen(controller: c)));
    c.seek(1000);
    await tester.pump();
    return (c, tester.getRect(find.byType(TimelineView)));
  }

  testWidgets('a range selection held at the right edge scrolls and selects beyond the screen', (tester) async {
    final (c, strip) = await pump(tester);
    final y = strip.top + 4; // above the object line
    final visibleEnd = TimelinePainter.timeAt(strip.width, c.time.value, c.timelineZoom, strip.width);
    final g = await tester.startGesture(Offset(strip.left + strip.width / 2 - 20, y), kind: PointerDeviceKind.touch);
    await tester.pump(const Duration(milliseconds: 700)); // long-press
    await g.moveTo(Offset(strip.right - 4, y));
    await tester.pump();
    final t0 = c.time.value;
    // Hold at the edge for a second: the timeline keeps scrolling.
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(c.time.value, greaterThan(t0 + 500));
    await g.up();
    await tester.pump();
    final picked = [for (final h in c.selection) h.time];
    expect(picked.any((t) => t > visibleEnd), isTrue, reason: 'objects that were off screen');
    expect(c.timelineBox, isNull);

    // A plain scrub to the edge doesn't keep scrolling.
    final s = await tester.startGesture(Offset(strip.left + strip.width / 2, y), kind: PointerDeviceKind.touch);
    await s.moveTo(Offset(strip.right - 4, y));
    await tester.pump();
    final t1 = c.time.value;
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(c.time.value, t1);
    await s.up();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a selected object dragged in time to the left edge follows it back in time', (tester) async {
    final (c, strip) = await pump(tester);
    c.seek(9000);
    final h = c.beatmap.hitObjects.lastWhere((o) => o.time <= 9000);
    c.select(h);
    await tester.pump();
    final x = strip.left + TimelinePainter.xOf(h.time, c.time.value, c.timelineZoom, strip.width);
    final visibleStartAtFirst = 9000 - strip.width / 2 / c.timelineZoom;
    final g = await tester.startGesture(Offset(x, strip.center.dy), kind: PointerDeviceKind.touch);
    await g.moveBy(const Offset(-30, 0));
    await g.moveTo(Offset(strip.left + 3, strip.center.dy));
    await tester.pump();
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await tester.pump();
    final moved = c.selection.single;
    expect(moved.time, lessThan(visibleStartAtFirst), reason: 'carried past the starting view');
    expect(c.history.undoLabel, isNotNull);
    await tester.pumpWidget(const SizedBox());
  });
}
