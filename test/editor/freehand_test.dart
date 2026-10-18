import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/editor/editor_screen.dart';
import 'package:osu_edit/editor/render/playfield_transform.dart';
import 'package:osu_edit/editor/widgets/playfield_view.dart';
import 'package:osu_edit/platform/beatmap_file_service.dart';

void main() {
  Future<(EditorController, Offset Function(double, double))> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(891, 411);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = EditorController(
      beatmap: OsuParser.parse(File('test/fixtures/sample_v14.osu').readAsStringSync()),
      document: const BeatmapDocument(fileName: 'sample.osu'),
    );
    await tester.pumpWidget(MaterialApp(home: EditorScreen(controller: c)));
    final area = tester.getRect(find.byType(PlayfieldView));
    final tf = PlayfieldTransform.fit(area.size);
    return (c, (double x, double y) => area.topLeft + tf.toScreen(Vec2(x, y)));
  }

  /// A half circle from (150, 250) over the top to (350, 250).
  List<Vec2> arc() => [
        for (var i = 0; i <= 40; i++)
          Vec2(250 - 100 * math.cos(math.pi * i / 40), 250 - 100 * math.sin(math.pi * i / 40)),
      ];

  testWidgets('a Slider tool drag turns a stroke into one slider along it; undo removes it', (tester) async {
    final (c, at) = await pump(tester);
    c.seek(12000);
    c.tool = EditorTool.slider;
    await tester.pump();
    final n = c.beatmap.hitObjects.length;

    final pts = arc();
    final g = await tester.startGesture(at(pts.first.x, pts.first.y), kind: PointerDeviceKind.touch);
    for (final p in pts.skip(1)) {
      await g.moveTo(at(p.x, p.y));
      await tester.pump(const Duration(milliseconds: 8));
    }
    expect(c.freehandStroke, isNotNull, reason: 'the stroke shows while drawing');
    await g.up();
    await tester.pump();

    expect(c.freehandStroke, isNull);
    expect(c.beatmap.hitObjects, hasLength(n + 1));
    final s = c.selection.single as SliderObject;
    expect(s.time, c.timing.snap(12000, c.divisor));
    expect(s.curveType, CurveType.bezier);
    expect(s.isLazerPath, isFalse);
    // Its path follows the stroke (until its length, snapped down to the beat).
    final path = c.sliderPath(s);
    for (final v in path.vertices) {
      final nearest = pts.map((p) => p.distanceTo(v)).reduce(math.min);
      expect(nearest, lessThan(8), reason: '$v');
    }
    expect(path.distance, greaterThan(200), reason: 'most of the ~314 px stroke');

    c.undo();
    expect(c.beatmap.hitObjects, hasLength(n));
  });

  testWidgets('a tap or a second finger draws no freehand slider', (tester) async {
    final (c, at) = await pump(tester);
    c.seek(12000);
    c.tool = EditorTool.slider;
    await tester.pump();
    final n = c.beatmap.hitObjects.length;

    await tester.tapAt(at(200, 200));
    await tester.pump();
    expect(c.beatmap.hitObjects, hasLength(n));

    final a = await tester.startGesture(at(150, 250), kind: PointerDeviceKind.touch, pointer: 1);
    await a.moveTo(at(200, 250));
    await tester.pump();
    final b = await tester.startGesture(at(300, 300), kind: PointerDeviceKind.touch, pointer: 2);
    await a.moveTo(at(260, 250));
    await b.moveTo(at(320, 320));
    await tester.pump();
    await a.up();
    await b.up();
    await tester.pumpAndSettle();
    expect(c.beatmap.hitObjects, hasLength(n));
    expect(c.freehandStroke, isNull);
  });
}
