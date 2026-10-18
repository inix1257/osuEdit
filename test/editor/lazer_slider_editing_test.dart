import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/platform/beatmap_file_service.dart';

/// 120 BPM from 0, SliderMultiplier 1.4: at 1/4 snap slider lengths are
/// multiples of 35 px. [lazer]: sliders are edited the osu!lazer way.
EditorController _controller({bool lazer = true, List<HitObject> objects = const []}) {
  final b = Beatmap.empty();
  b.setValue(SectionNames.difficulty, 'SliderMultiplier', '1.4');
  b.insertTimingPoint(TimingPoint.red(time: 0, bpm: 120));
  for (final h in objects) {
    b.insertHitObject(h);
  }
  b.revision = 0;
  return EditorController(beatmap: b, document: const BeatmapDocument(fileName: 'new.osu'), lazerSliders: lazer);
}

SliderObject _parse(String line) => OsuParser.parseHitObject(line, formatVersion: 128)! as SliderObject;

void main() {
  late EditorController c;
  tearDown(() => c.dispose());

  SliderObject drawn(List<Vec2> taps) {
    c.tool = EditorTool.slider;
    for (final p in taps) {
      c.sliderToolTap(p);
    }
    c.finishSlider();
    return c.selection.single as SliderObject;
  }

  SliderObject select(SliderObject s) {
    c.selection
      ..clear()
      ..add(s);
    return s;
  }

  SliderObject edited() => c.editedSlider!;
  List<PathType?> types() => [for (final p in c.editablePoints(edited())) p.type];

  group('drawing (lazer placement)', () {
    test('red points start segments typed by their point count', () {
      c = _controller();
      // head, a, b(red), c: segment 1 = head..b (3 points → perfect), segment 2 = b..c (2 → linear).
      final s = drawn(const [Vec2(100, 200), Vec2(150, 150), Vec2(200, 200), Vec2(200, 200), Vec2(300, 200)]);
      expect(s.isLazerPath, isTrue);
      expect(s.pointTypes, [PathType.perfectCurve, null, PathType.linear, null]);
      expect(OsuWriter.encodeCurve(s), 'P|150:150|L|200:200|300:200');
      expect(c.editsTyped(s), isTrue);
    });

    test('a single-type drawing is written in stable syntax', () {
      c = _controller();
      final s = drawn(const [Vec2(100, 100), Vec2(200, 50), Vec2(300, 100), Vec2(400, 50)]);
      expect(s.pointTypes!.first, PathType.bezier);
      expect(OsuWriter.encodeCurve(s), 'B|200:50|300:100|400:50');
    });

    test('stable mode is unchanged', () {
      c = _controller(lazer: false);
      final s = drawn(const [Vec2(100, 200), Vec2(150, 150), Vec2(200, 200), Vec2(200, 200), Vec2(300, 200)]);
      expect(s.isLazerPath, isFalse);
      expect(s.curveType, CurveType.bezier);
    });
  });

  group('curve type of a control point', () {
    test('choices like lazer: no Inherit for the head, nothing for the tail, Catmull only if already', () {
      c = _controller(objects: [_parse('100,100,0,2,0,B|200:100|300:200|400:100,1,280')]);
      select(c.beatmap.hitObjects.single as SliderObject);
      expect(c.pointTypeChoices(0), [PathType.linear, PathType.bezier, PathType.perfectCurve, PathType.bSpline4]);
      expect(c.pointTypeChoices(1).first, isNull);
      expect(c.pointTypeChoices(3), isEmpty);
    });

    test('setting a type splits the segment; Inherit joins it again (one undo step each)', () {
      final orig = _parse('100,100,0,2,0,B|200:100|300:200|400:100,1,280');
      c = _controller(objects: [orig]);
      select(orig);
      c.setPointType(2, PathType.linear);
      expect(types(), [PathType.bezier, null, PathType.linear, null]);
      expect(LazerPath.isLazerCurve(OsuWriter.encodeCurve(edited())), isTrue);
      expect(edited().length, orig.length); // the new path is longer: length kept
      c.setPointType(2, null);
      expect(types(), [PathType.bezier, null, null, null]);
      c.undo();
      c.undo();
      expect(c.beatmap.hitObjects.single, same(orig));
    });

    test('perfect curve on a longer segment splits off the rest two points later', () {
      c = _controller(objects: [_parse('0,0,0,2,0,B|100:0|200:100|300:0|400:100,1,280')]);
      select(c.beatmap.hitObjects.single as SliderObject);
      c.setPointType(0, PathType.perfectCurve);
      expect(types(), [PathType.perfectCurve, null, PathType.bezier, null, null]);
    });

    test('a stable slider in a lazer-mode map can get mixed types', () {
      final orig = OsuParser.parseHitObject('100,100,0,2,0,B|200:100|200:100|300:200|400:100,1,280')! as SliderObject;
      c = _controller(objects: [orig]);
      select(orig);
      // The doubled point (stable red anchor) is a bezier-typed point.
      expect(types(), [PathType.bezier, PathType.bezier, null, null]);
      c.setPointType(1, PathType.linear);
      expect(edited().pointTypes, [PathType.bezier, PathType.linear, null, null]);
      expect(LazerPath.isLazerCurve(OsuWriter.encodeCurve(edited())), isTrue);
    });

    test('not offered when editing the stable way', () {
      final orig = OsuParser.parseHitObject('100,100,0,2,0,B|200:100|300:200,1,140')! as SliderObject;
      c = _controller(lazer: false, objects: [orig]);
      select(orig);
      expect(c.pointTypeChoices(0), isEmpty);
      c.setPointType(0, PathType.linear);
      expect(c.beatmap.hitObjects.single, same(orig));
    });
  });

  group('adding / removing points (lazer rules)', () {
    test('an added point inherits; a perfect curve that gets a fourth point turns bezier', () {
      c = _controller(objects: [_parse('100,200,0,2,0,P|200:100|300:200,1,140')]);
      select(c.beatmap.hitObjects.single as SliderObject);
      expect(c.insertControlPointAt(const Vec2(150, 150)), 1);
      expect(types(), [PathType.bezier, null, null, null]);
    });

    test('removing the head gives its type to the next point', () {
      c = _controller(objects: [_parse('0,0,0,2,0,L|100:0|P|200:0|250:50|300:0,1,140')]);
      select(c.beatmap.hitObjects.single as SliderObject);
      c.deleteControlPoint(0);
      expect(edited().position, const Vec2(100, 0));
      expect(types(), [PathType.linear, PathType.perfectCurve, null, null]);
    });

    test('dragging a point keeps the segment types', () {
      c = _controller(objects: [_parse('0,0,0,2,0,L|100:0|P|200:0|250:50|300:0,1,140')]);
      select(c.beatmap.hitObjects.single as SliderObject);
      c.beginPointDrag(3);
      c.updatePointDrag(const Vec2(250, 80));
      c.endPointDrag();
      expect(types(), [PathType.linear, null, PathType.perfectCurve, null, null]);
      expect(c.editablePoints(edited())[3].position, const Vec2(250, 80));
    });
  });

  group('converting / pasting', () {
    test('convertSlidersToStable is one undo step', () {
      final orig = _parse('100,100,0,2,0,L|P|200:100|250:150|300:100,1,140');
      c = _controller(lazer: false, objects: [orig]);
      expect(c.convertSlidersToStable(), 1);
      final s = c.beatmap.hitObjects.single as SliderObject;
      expect(s.isLazerPath, isFalse);
      expect(s.length, orig.length);
      c.undo();
      expect(c.beatmap.hitObjects.single, same(orig));
    });

    test('pasting a lazer slider into a stable-mode map converts it', () {
      c = _controller(objects: [_parse('100,100,0,2,0,L|P|200:100|250:150|300:100,1,140')]);
      select(c.beatmap.hitObjects.single as SliderObject);
      c.copySelection();
      c.dispose();
      c = _controller(lazer: false);
      c.seek(2000);
      c.paste();
      expect((c.beatmap.hitObjects.single as SliderObject).isLazerPath, isFalse);
    });
  });
}
