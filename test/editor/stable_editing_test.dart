import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/platform/beatmap_file_service.dart';

/// 120 BPM from 0, SliderMultiplier 1.4 (a 140 px slider spans 500ms).
EditorController _controller(List<HitObject> objects) {
  final b = Beatmap.empty();
  b.setValue(SectionNames.difficulty, 'SliderMultiplier', '1.4');
  b.insertTimingPoint(TimingPoint.red(time: 0, bpm: 120));
  for (final h in objects) {
    b.insertHitObject(h);
  }
  b.revision = 0;
  return EditorController(beatmap: b, document: const BeatmapDocument(fileName: 'new.osu'));
}

SliderObject _parse(String line) => OsuParser.parseHitObject(line)! as SliderObject;

void main() {
  late EditorController c;
  tearDown(() => c.dispose());

  SliderObject selectOnly(HitObject h) {
    c.select(h);
    return h as SliderObject;
  }

  group('slider edge hitsounds (stable)', () {
    // Two repeats: edges at 1000 (head), 1500 (repeat), 2000 (tail).
    final line = '100,100,1000,2,0,L|240:100,2,140';

    test('edge times and names', () {
      final s = _parse(line);
      c = _controller([s]);
      selectOnly(s);
      expect(c.edgeTimes(s), [1000, 1500, 2000]);
      expect(EditorController.edgeName(s, 0), 'Head');
      expect(EditorController.edgeName(s, 1), 'Repeat 1');
      expect(EditorController.edgeName(s, 2), 'Tail');
    });

    test('toggles and sample sets edit only the picked edge, one undo step each', () {
      final s = _parse(line);
      c = _controller([s]);
      selectOnly(s);
      c.selectEdge(2);
      expect(c.selectedEdge, 2);
      expect(c.additionState(HitSoundFlags.whistle), isFalse);

      c.toggleAddition(HitSoundFlags.whistle);
      expect(c.selectedEdge, 2, reason: 'the edge stays picked on the edited copy');
      expect(c.additionState(HitSoundFlags.whistle), isTrue);
      c.setAdditionSet(SampleSet.drum);
      expect(c.additionSetState, SampleSet.drum);

      final edited = c.editedSlider!;
      expect(edited.hitSound, 0, reason: 'the body is untouched');
      expect(OsuWriter.encodeHitObject(edited), '100,100,1000,2,0,L|240:100,2,140,0|0|2,0:0|0:0|0:3,0:0:0:0:');

      // Back to the whole slider: the toggles show the body again.
      c.selectEdge(null);
      expect(c.additionState(HitSoundFlags.whistle), isFalse);

      c.undo();
      c.undo();
      expect(OsuWriter.encodeHitObject(c.beatmap.hitObjects.single), OsuWriter.encodeHitObject(s));
    });

    test('the picked edge plays its own sounds', () {
      final s = _parse(line);
      c = _controller([s]);
      selectOnly(s);
      c.selectEdge(1);
      c.toggleAddition(HitSoundFlags.clap);
      final plays = HitsoundResolver.resolve(c.beatmap, c.timing).where((p) => p.name == 'hitclap').toList();
      expect([for (final p in plays) p.time], [1500]);
    });

    test('picking is cleared by another selection and only works with the Select tool', () {
      final s = _parse(line);
      final other = HitCircle(position: const Vec2(10, 10), time: 3000);
      c = _controller([s, other]);
      selectOnly(s);
      c.selectEdge(0);
      c.tool = EditorTool.circle;
      expect(c.selectedEdge, isNull);
      c.tool = EditorTool.select;
      c.select(s);
      expect(c.selectedEdge, isNull, reason: 'selecting again picks the whole slider');
      c.selectEdge(0);
      c.select(other);
      expect(c.selectedEdge, isNull);
    });

    test('a slider without per-edge sounds keeps playing its own on the other edges', () {
      final s = _parse('100,100,1000,2,2,L|240:100,1,140'); // whistle, no edge fields
      c = _controller([s]);
      selectOnly(s);
      c.selectEdge(0);
      expect(c.additionState(HitSoundFlags.whistle), isTrue);
      c.toggleAddition(HitSoundFlags.whistle);
      expect(c.editedSlider!.edgeSounds, [0, 2]);
    });
  });

  group('stable curve type menu', () {
    test('choices: perfect only with three points; none for lazer sliders', () {
      final three = _parse('100,100,1000,2,0,P|150:50|200:100,1,140');
      c = _controller([three]);
      selectOnly(three);
      expect(c.curveTypeChoices,
          [CurveType.bezier, CurveType.perfectCircle, CurveType.catmull, CurveType.linear]);
      expect(c.curveTypeState, CurveType.perfectCircle);
      c.setCurveType(CurveType.linear);
      expect(c.editedSlider!.curveType, CurveType.linear);
      c.dispose();

      final four = _parse('100,100,1000,2,0,B|150:50|200:100|250:50,1,140');
      c = _controller([four]);
      selectOnly(four);
      expect(c.curveTypeChoices, [CurveType.bezier, CurveType.catmull, CurveType.linear]);
    });

    test('red anchor toggle on middle points only, one undo step', () {
      final s = _parse('100,100,1000,2,0,B|150:50|200:100|250:50,1,140');
      c = _controller([s]);
      selectOnly(s);
      expect(c.canToggleRedAnchor(0), isFalse);
      expect(c.canToggleRedAnchor(3), isFalse);
      expect(c.canToggleRedAnchor(2), isTrue);
      c.toggleRedAnchor(2);
      expect(c.isRedAnchor(2), isTrue);
      expect(c.curveTypeState, CurveType.bezier);
      expect(OsuWriter.encodeCurve(c.editedSlider!), 'B|150:50|200:100|200:100|250:50');
      c.undo();
      expect(c.beatmap.hitObjects.single, same(s));
    });
  });

  group('combo colours', () {
    test('set, highlight in Song setup, undo goes to Song setup', () {
      c = _controller([HitCircle(position: const Vec2(0, 0), time: 0)]);
      expect(c.mapComboColours, isEmpty);
      expect(c.comboColourAt(1), EditorController.defaultComboColours[1]);
      c.setComboColours(const [RgbColour(10, 20, 30), RgbColour(40, 50, 60)]);
      expect(c.mapComboColours, hasLength(2));
      expect(c.comboColourAt(1), const Color(0xFF28323C));
      expect(c.songSetupChanged('Colours.Combo'), isTrue);
      c.undo();
      expect(c.lastHistoryStep.value!.focus.area, EditArea.songSetup);
      expect(c.mapComboColours, isEmpty);
      expect(c.songSetupChanged('Colours.Combo'), isFalse);
    });
  });

  group('slider colours', () {
    test('track / border: drawn colours, highlight, undo', () {
      c = _controller([HitCircle(position: const Vec2(0, 0), time: 0)]);
      expect(c.sliderTrackColour, isNull);
      c.setMapColour(ComboColours.sliderTrack, const RgbColour(255, 0, 0));
      expect(c.sliderTrackColour, const Color(0xFFFF0000));
      expect(c.songSetupChanged('Colours.SliderTrackOverride'), isTrue);
      c.setMapColour(ComboColours.sliderBorder, const RgbColour(0, 0, 255));
      expect(c.sliderBorderColour, const Color(0xFF0000FF));
      c.undo();
      c.undo();
      expect(c.sliderTrackColour, isNull);
      expect(c.sliderBorderColour, isNull);
      expect(c.isDirty, isFalse);
      expect(c.lastHistoryStep.value!.focus.area, EditArea.songSetup);
    });
  });

  group('follow points', () {
    test('connections near the playhead, none across a new combo', () {
      c = _controller([
        HitCircle(position: const Vec2(0, 100), time: 1000),
        HitCircle(position: const Vec2(300, 100), time: 1500),
        HitCircle(position: const Vec2(0, 300), time: 2000, newCombo: true),
        HitCircle(position: const Vec2(300, 300), time: 9000),
      ]);
      expect(c.followConnectionsAt(1100).map((x) => x.endTime), [1500]);
      expect(c.followConnectionsAt(5000).map((x) => x.endTime), [9000]);
      expect(c.followConnectionsAt(-2000), isEmpty);
      expect(c.showFollowPoints, isTrue);
    });
  });
}
