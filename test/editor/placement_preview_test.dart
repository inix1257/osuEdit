import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/editor/editor_screen.dart';
import 'package:osu_edit/editor/render/playfield_transform.dart';
import 'package:osu_edit/editor/widgets/playfield_view.dart';
import 'package:osu_edit/platform/beatmap_file_service.dart';

/// 120 BPM; circles at 1000 (new combo), 1500, 2000, 3000 (new combo), 3500.
EditorController _controller() {
  final b = Beatmap.empty()..insertTimingPoint(TimingPoint.red(time: 0, bpm: 120));
  for (final (t, nc) in [(1000.0, true), (1500.0, false), (2000.0, false), (3000.0, true), (3500.0, false)]) {
    b.insertHitObject(HitCircle(position: Vec2(t / 10, 100), time: t, newCombo: nc));
  }
  b.revision = 0;
  return EditorController(beatmap: b, document: const BeatmapDocument(fileName: 'x.osu'));
}

void main() {
  group('ghost combos', () {
    test('a circle inside a combo: it takes the next number, the rest of the combo shifts', () {
      final c = _controller();
      addTearDown(c.dispose);
      c.tool = EditorTool.circle;
      c.seek(1750);
      c.placementCursor = const Vec2(200, 200);
      expect(c.placementGhost!.time, 1750);
      expect(c.placementGhostCombo!.number, 3);
      final objs = c.beatmap.hitObjects;
      expect([for (final h in objs) c.shownComboOf(h).number], [1, 2, 4, 1, 2]);
      expect([for (final h in objs) c.comboOf(h).number], [1, 2, 3, 1, 2], reason: 'the real combos stay');
      expect(c.placementCollides, isFalse);
      c.placementCursor = null;
      expect(c.shownComboOf(objs[2]).number, 3, reason: 'back once the finger is up');
    });

    test('a new combo ghost restarts the numbers and shifts the colours after it', () {
      final c = _controller();
      addTearDown(c.dispose);
      c.tool = EditorTool.circle;
      c.toggleNewCombo();
      c.seek(1750);
      c.placementCursor = const Vec2(200, 200);
      final objs = c.beatmap.hitObjects;
      expect(c.placementGhostCombo!.number, 1);
      expect(c.placementGhostCombo!.colourIndex, c.comboOf(objs[0]).colourIndex + 1);
      expect(c.shownComboOf(objs[2]).number, 2);
      expect(c.shownComboOf(objs[3]).colourIndex, c.comboOf(objs[3]).colourIndex + 1);
    });

    test('on an object\'s time: collides', () {
      final c = _controller();
      addTearDown(c.dispose);
      c.tool = EditorTool.circle;
      c.seek(2000);
      c.placementCursor = const Vec2(300, 300);
      expect(c.placementCollides, isTrue);
    });
  });

  testWidgets('the preview shows as soon as the finger is down; a tap places the circle there', (tester) async {
    tester.view.physicalSize = const Size(891, 411);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = _controller();
    await tester.pumpWidget(MaterialApp(home: EditorScreen(controller: c)));
    c.tool = EditorTool.circle;
    c.seek(1750);
    await tester.pump();
    final area = tester.getRect(find.byType(PlayfieldView));
    final at = area.topLeft + PlayfieldTransform.fit(area.size, c.playfieldZoom.value).toScreen(const Vec2(256, 192));

    final g = await tester.startGesture(at);
    await tester.pump();
    expect(c.placementGhost, isNotNull, reason: 'before any movement');
    expect(c.placementGhost!.position, const Vec2(256, 192));
    await g.up();
    await tester.pump();
    expect(c.placementGhost, isNull);
    expect(c.beatmap.hitObjects.length, 6);
    expect(c.beatmap.hitObjects[2].position, const Vec2(256, 192));
    expect(c.history.canUndo, isTrue);
    await tester.pumpWidget(const SizedBox());
  });
}
