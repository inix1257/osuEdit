import 'package:flutter_test/flutter_test.dart';
import 'package:osu_edit/core/core.dart';
import 'package:osu_edit/editor/editor_controller.dart';
import 'package:osu_edit/platform/beatmap_file_service.dart';

/// 120 BPM from 0, SV 1, SliderMultiplier 1.4: one beat = 500 ms = 140 px,
/// so at 1/4 snap slider lengths are multiples of 35 px.
EditorController _controller() {
  final b = Beatmap.empty();
  b.setValue(SectionNames.difficulty, 'SliderMultiplier', '1.4');
  b.insertTimingPoint(TimingPoint.red(time: 0, bpm: 120));
  b.revision = 0;
  return EditorController(beatmap: b, document: const BeatmapDocument(fileName: 'new.osu'));
}

void main() {
  late EditorController c;
  setUp(() => c = _controller());
  tearDown(() => c.dispose());

  SliderObject drawn(List<Vec2> points) {
    c.tool = EditorTool.slider;
    for (final p in points) {
      c.sliderToolTap(p);
    }
    c.finishSlider(); // Create
    return c.selection.single as SliderObject;
  }

  group('slider tool', () {
    test('taps add points; Create makes a snapped linear slider', () {
      c.seek(1010); // snaps to 1000
      c.tool = EditorTool.slider;
      c.sliderToolTap(const Vec2(100, 100));
      expect(c.isDrafting, isTrue);
      expect(c.draftSlider, isNull);
      c.sliderToolTap(const Vec2(250, 100)); // 150 px drawn
      expect(c.draftSlider!.length, closeTo(140, 1e-9)); // rounded down to 4 × 35
      c.sliderToolTap(const Vec2(252, 101)); // within tolerance: the tail turns red
      c.sliderToolTap(const Vec2(250, 100)); // and back
      expect(c.draftPointCount, 2);
      expect(c.draftPoints.last.red, isFalse);
      c.finishSlider();
      expect(c.isDrafting, isFalse);

      final s = c.selection.single as SliderObject;
      expect(c.beatmap.hitObjects, [same(s)]);
      expect(s.time, 1000);
      expect(s.curveType, CurveType.linear);
      expect(s.position, const Vec2(100, 100));
      expect(s.controlPoints, [const Vec2(250, 100)]);
      expect(c.endTimeOf(s), closeTo(1500, 1e-6)); // exactly one beat
      expect(OsuWriter.encodeHitObject(s), '100,100,1000,2,0,L|250:100,1,140,0|0,0:0|0:0,0:0:0:0:');

      c.undo();
      expect(c.beatmap.hitObjects, isEmpty);
    });

    test('three points make a perfect circle, more make a bezier', () {
      expect(drawn(const [Vec2(100, 200), Vec2(200, 100), Vec2(300, 200)]).curveType, CurveType.perfectCircle);
      c.tool = EditorTool.select;
      expect(drawn(const [Vec2(50, 50), Vec2(150, 80), Vec2(200, 200), Vec2(300, 300)]).curveType,
          CurveType.bezier);
    });

    test('tapping a drawn point again toggles it red; the head ignores it', () {
      c.tool = EditorTool.slider;
      c.sliderToolTap(const Vec2(100, 100));
      c.sliderToolTap(const Vec2(102, 101)); // the head: nothing
      expect(c.draftPointCount, 1);
      c.sliderToolTap(const Vec2(200, 100));
      c.sliderToolTap(const Vec2(200, 100)); // red tail: no boundary yet
      expect(c.draftPoints.last.red, isTrue);
      expect(c.draftSlider!.curveType, CurveType.linear);
      c.sliderToolTap(const Vec2(200, 200));
      expect(c.draftPoints[1].red, isTrue);
      expect(c.draftSlider!.curveType, CurveType.bezier);
      c.sliderToolTap(const Vec2(300, 200));
      c.sliderToolTap(const Vec2(300, 200)); // a red tail at Create is dropped
      c.finishSlider();
      final s = c.selection.single as SliderObject;
      expect(s.curveType, CurveType.bezier);
      expect(s.controlPoints, const [Vec2(200, 100), Vec2(200, 100), Vec2(200, 200), Vec2(300, 200)]);
    });

    test('the snap divisor sets the length unit', () {
      c.divisor = 1;
      expect(drawn(const [Vec2(100, 100), Vec2(400, 100)]).length, closeTo(280, 1e-9)); // 300 → 2 beats
    });

    test('Create needs two points; cancel and switching tools discard the draft', () {
      c.tool = EditorTool.slider;
      c.sliderToolTap(const Vec2(100, 100));
      c.finishSlider();
      expect(c.beatmap.hitObjects, isEmpty);
      c.sliderToolTap(const Vec2(100, 100));
      c.sliderToolTap(const Vec2(200, 100));
      c.clearSelection(); // Esc
      expect(c.isDrafting, isFalse);
      c.sliderToolTap(const Vec2(100, 100));
      c.tool = EditorTool.circle;
      expect(c.isDrafting, isFalse);
      expect(c.beatmap.hitObjects, isEmpty);
      expect(c.canUndo, isFalse);
    });
  });

  group('editing a slider', () {
    late SliderObject s;
    setUp(() {
      s = drawn(const [Vec2(100, 100), Vec2(200, 100), Vec2(300, 100), Vec2(300, 200)]);
      c.tool = EditorTool.select;
      c.history.markSaved();
    });

    test('control points hit-test on the edited slider only', () {
      expect(c.hitTestControlPoint(const Vec2(203, 98), 10), 1);
      expect(c.hitTestControlPoint(const Vec2(250, 250), 10), isNull);
      c.clearSelection();
      expect(c.hitTestControlPoint(const Vec2(203, 98), 10), isNull);
    });

    test('dragging a point is one undo step and re-snaps the length', () {
      c.beginPointDrag(3);
      c.updatePointDrag(const Vec2(300, 150));
      c.updatePointDrag(const Vec2(300, 300.4)); // rounded
      c.endPointDrag();
      final after = c.selection.single as SliderObject;
      expect(after.controlPoints.last, const Vec2(300, 300));
      final full = SliderShape.fullLength(after.curveType, after.allPoints);
      expect(after.length, lessThanOrEqualTo(full));
      expect(after.length / 35, closeTo((after.length / 35).roundToDouble(), 1e-9));
      expect(c.selectedPoint, 3);
      c.undo();
      expect(c.beatmap.hitObjects.single, same(s));
      expect(c.isDirty, isFalse);
    });

    test('a drag that ends where it started leaves the map untouched', () {
      c.beginPointDrag(1);
      c.updatePointDrag(const Vec2(150, 150));
      c.updatePointDrag(const Vec2(200, 100));
      c.endPointDrag();
      expect(c.beatmap.hitObjects.single, same(s));
      expect(c.canUndo, isTrue); // only the creation
      c.undo();
      expect(c.beatmap.hitObjects, isEmpty);
    });

    test('red anchor toggles on interior points and doubles the point in the file', () {
      c.selectedPoint = 0;
      c.toggleRedAnchor(); // head: no-op
      expect(c.isDirty, isFalse);
      c.selectedPoint = 2;
      c.toggleRedAnchor();
      final a = c.selection.single as SliderObject;
      expect(a.curveType, CurveType.bezier);
      expect(a.controlPoints, const [Vec2(200, 100), Vec2(300, 100), Vec2(300, 100), Vec2(300, 200)]);
      c.toggleRedAnchor();
      expect((c.selection.single as SliderObject).controlPoints, s.controlPoints);
    });

    test('insert / delete control points', () {
      c.selectedPoint = 0;
      c.insertControlPoint();
      var a = c.selection.single as SliderObject;
      expect(a.controlPoints.first, const Vec2(150, 100));
      expect(c.selectedPoint, 1);
      c.deleteControlPoint();
      a = c.selection.single as SliderObject;
      expect(a.controlPoints, s.controlPoints);
      expect(c.selectedPoint, 0);
      // Never below two points.
      final line = drawn(const [Vec2(10, 10), Vec2(100, 10)]);
      c.tool = EditorTool.select;
      c.selectedPoint = 1;
      c.deleteControlPoint();
      expect(c.selection.single, same(line));
    });

    test('curve type change drops red anchors unless bezier; perfect circle needs 3 points', () {
      c.setCurveType(CurveType.linear);
      final l = c.selection.single as SliderObject;
      expect(l.curveType, CurveType.linear);
      expect(l.length, closeTo(280, 1e-9)); // 300 px polyline → 8 × 35
      c.setCurveType(CurveType.perfectCircle); // 4 points → falls back to bezier
      expect((c.selection.single as SliderObject).curveType, CurveType.bezier);
    });

    test('repeats change via the panel and via the timeline end drag', () {
      c.setSlides(3);
      var a = c.selection.single as SliderObject;
      expect(a.slides, 3);
      final span = c.timing.sliderSpanDuration(a, c.beatmap.sliderMultiplier);
      c.beginEndDrag();
      c.updateEndDrag(a.time + span * 4.8); // nearest whole span count: 5
      c.updateEndDrag(a.time + span * 5.2);
      c.endEndDrag();
      a = c.selection.single as SliderObject;
      expect(a.slides, 5);
      c.setSlides(0); // ignored
      expect((c.selection.single as SliderObject).slides, 5);
      c.undo();
      expect((c.beatmap.hitObjects.single as SliderObject).slides, 3);
    });

    test('edge hitsounds follow the repeat count', () {
      final withEdges = s.copyWith(edgeSounds: [2, 8], edgeSets: [const EdgeSet(1, 0), const EdgeSet(2, 0)]);
      c.history.execute(ReplaceHitObjectsCommand([s], [withEdges]));
      c.select(withEdges);
      c.setSlides(3);
      final a = c.selection.single as SliderObject;
      expect(a.edgeSounds, [2, 0, 0, 8]);
      expect(a.edgeSets, [const EdgeSet(1, 0), const EdgeSet(0, 0), const EdgeSet(0, 0), const EdgeSet(2, 0)]);
    });
  });

  group('spinner tool', () {
    test('places a one-measure spinner at the snapped time; end drags on the snap', () {
      c.seek(2040);
      c.tool = EditorTool.spinner;
      c.placeSpinner();
      final s = c.selection.single as Spinner;
      expect(s.time, 2000);
      expect(s.endTime, 4000); // 4 beats of 500 ms
      expect(s.position, Spinner.center);
      expect(s.newCombo, isTrue);

      c.beginEndDrag();
      c.updateEndDrag(3130); // → 3125 (1/4 snap = 125 ms)
      c.endEndDrag();
      expect((c.selection.single as Spinner).endTime, 3125);
      c.beginEndDrag();
      c.updateEndDrag(1000); // before the start: clamps to one snap
      c.endEndDrag();
      expect((c.selection.single as Spinner).endTime, 2125);
      c.undo();
      c.undo();
      expect((c.beatmap.hitObjects.single as Spinner).endTime, 4000);
    });
  });
}
